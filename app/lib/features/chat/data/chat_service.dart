import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_storage.dart';
import '../../../core/ffi/zia_crypto_exceptions.dart';
import '../../../core/network/api_client.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../domain/crypto_models.dart';
import 'envelope.dart';
import 'ffi_crypto_gateway.dart';

export '../domain/chat_message.dart';
export '../domain/conversation.dart';

/// Orchestration de l'application : relie le moteur cryptographique natif au
/// serveur. Aucune cryptographie ici — tout passe par le [FfiCryptoGateway].
class ChatService extends ChangeNotifier {
  ApiClient? _api;
  FfiCryptoGateway? _gateway;
  Timer? _poll;
  WebSocket? _socket;
  bool realtime = false;

  String? username;
  String? userId;
  String? deviceId;

  /// Conversations connues, indexées par identifiant de conversation.
  final Map<String, Conversation> _conversations = {};
  String? activeConversationId;

  /// Matériel X3DH en attente d'envoi, par conversation (premier message).
  final Map<String, HandshakeMaterial> _pendingHandshakes = {};

  String? error;
  bool busy = false;

  bool get connected => userId != null;

  /// Conversations, la plus récemment active en tête.
  List<Conversation> get conversations {
    final list = _conversations.values.toList();
    list.sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
    return list;
  }

  Conversation? get active =>
      activeConversationId == null ? null : _conversations[activeConversationId];

  // ------------------------------------------------------------- utilitaires

  /// Localise la bibliothèque native selon la plateforme.
  static String _resolveLibrary() {
    final fromEnv = Platform.environment['ZIA_CRYPTO_LIB'];
    if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final String fileName;
    final List<String> candidates;

    if (Platform.isWindows) {
      fileName = 'zia_crypto.dll';
      candidates = ['$exeDir\\$fileName'];
    } else if (Platform.isMacOS) {
      fileName = 'libzia_crypto.dylib';
      candidates = ['$exeDir/../Frameworks/$fileName', '$exeDir/$fileName'];
    } else if (Platform.isAndroid) {
      return 'libzia_crypto.so'; // chargée depuis les jniLibs de l'APK
    } else {
      fileName = 'libzia_crypto.so';
      candidates = ['$exeDir/lib/$fileName', '$exeDir/$fileName'];
    }

    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return fileName;
  }

  static String _uuidV4() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
    return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-'
        '${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
  }

  static String _platformName() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'linux';
  }

  void _setBusy(bool value, {String? err}) {
    busy = value;
    error = err;
    notifyListeners();
  }

  /// Le moteur n'accepte que [A-Za-z0-9._-] comme nom d'entrée du coffre.
  String _safeKey(String prefix, String id) =>
      '$prefix-${id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}';

  // ---------------------------------------------------------------- connexion

  SavedAccount? get savedAccount => AppStorage.loadAccount();

  Future<FfiCryptoGateway> _openGateway() async {
    final gateway = await FfiCryptoGateway.open(
      AppStorage.engineStoragePath,
      libraryPath: _resolveLibrary(),
    );
    try {
      await gateway.identityPublicKey();
    } on ZiaNotInitializedException {
      await gateway.generateIdentity();
    }
    return gateway;
  }

  Future<void> registerAndConnect({
    required String user,
    required String password,
    String? serverUrl,
  }) async {
    _setBusy(true);
    try {
      final api = ApiClient(serverUrl ?? AppConfig.serverUrl);
      final gateway = await _openGateway();
      final bundle = await gateway.generatePrekeyBundle();

      final res = await api.register(
        username: user,
        password: password,
        device: {
          'platform': _platformName(),
          'deviceName': _platformName(),
          'identityPublicKey': base64Encode(bundle.identityKey),
          'signedPrekey': base64Encode(bundle.signedPrekey),
          'signedPrekeySignature': base64Encode(bundle.signedPrekeySignature),
          'oneTimePrekeys': [base64Encode(bundle.oneTimePrekey!)],
        },
      );

      await _adoptSession(api, gateway, res, user);
      AppStorage.saveAccount(SavedAccount(
        username: user,
        userId: userId!,
        deviceId: deviceId!,
      ));
      _setBusy(false);
    } catch (e) {
      _setBusy(false, err: _humanize(e));
      rethrow;
    }
  }

  Future<void> loginAndConnect({required String password, String? serverUrl}) async {
    final account = savedAccount;
    if (account == null) {
      _setBusy(false, err: 'Aucun compte enregistré sur cet appareil.');
      return;
    }
    _setBusy(true);
    try {
      final api = ApiClient(serverUrl ?? AppConfig.serverUrl);
      final gateway = await _openGateway();
      final res = await api.login(
        username: account.username,
        password: password,
        deviceId: account.deviceId,
      );
      await _adoptSession(api, gateway, res, account.username);
      _setBusy(false);
    } catch (e) {
      _setBusy(false, err: _humanize(e));
      rethrow;
    }
  }

  Future<void> _adoptSession(
    ApiClient api,
    FfiCryptoGateway gateway,
    Map<String, dynamic> res,
    String user,
  ) async {
    api.accessToken = res['accessToken'] as String;
    _api = api;
    _gateway = gateway;
    username = user;
    userId = res['userId'] as String;
    deviceId = res['deviceId'] as String;

    await _loadConversations();
    _startPolling();
    unawaited(_replenishPrekeys());
  }

  /// Ferme la session sans effacer l'identité ni l'historique local.
  Future<void> logout() async {
    _poll?.cancel();
    await _socket?.close();
    _socket = null;
    realtime = false;
    await _gateway?.dispose();
    _gateway = null;
    _api = null;
    userId = null;
    deviceId = null;
    _conversations.clear();
    _pendingHandshakes.clear();
    activeConversationId = null;
    notifyListeners();
  }

  void forgetAccount() {
    AppStorage.clearAccount();
    error = null;
    notifyListeners();
  }

  // ------------------------------------------------------------- persistance

  Future<void> _loadConversations() async {
    final gateway = _gateway;
    if (gateway == null) return;
    try {
      final raw = await gateway.vaultRead('convs');
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(utf8.decode(raw)) as List;
      for (final item in list.cast<Map<String, dynamic>>()) {
        final conv = Conversation.fromJson(item);
        conv.messages.addAll(await _readHistory(conv.id));
        _conversations[conv.id] = conv;
      }
      notifyListeners();
    } catch (_) {
      // Une liste illisible ne doit pas empêcher d'utiliser l'application.
    }
  }

  Future<void> _saveConversations() async {
    final gateway = _gateway;
    if (gateway == null) return;
    final data = jsonEncode(conversations.map((c) => c.toJson()).toList());
    await gateway.vaultWrite('convs', Uint8List.fromList(utf8.encode(data)));
  }

  Future<List<ChatMessage>> _readHistory(String convId) async {
    final gateway = _gateway;
    if (gateway == null) return [];
    try {
      final raw = await gateway.vaultRead(_safeKey('hist', convId));
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(utf8.decode(raw)) as List)
          .cast<Map<String, dynamic>>()
          .map(ChatMessage.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveHistory(Conversation conv) async {
    final gateway = _gateway;
    if (gateway == null) return;
    final data = jsonEncode(conv.messages.map((m) => m.toJson()).toList());
    await gateway.vaultWrite(
        _safeKey('hist', conv.id), Uint8List.fromList(utf8.encode(data)));
  }

  /// Enregistre l'état du ratchet. Sans cela un handshake complet serait refait
  /// à chaque lancement et la chaîne de clés repartirait de zéro.
  /// Enregistre l'état du ratchet de chaque appareil. Sans cela un handshake
  /// complet serait refait à chaque lancement et la chaîne de clés repartirait
  /// de zéro.
  Future<void> _saveSessions(Conversation conv) async {
    final gateway = _gateway;
    if (gateway == null) return;
    for (final entry in conv.sessions.entries) {
      try {
        final blob = await gateway.exportSession(entry.value);
        await gateway.vaultWrite(
            _safeKey('sess', '${conv.id}-${entry.key}'), blob);
      } catch (e) {
        error = 'Session non enregistrée : ${_humanize(e)}';
      }
    }
  }

  /// Restaure les sessions enregistrées pour chaque appareil connu.
  Future<void> _restoreSessions(Conversation conv) async {
    final gateway = _gateway;
    if (gateway == null) return;
    for (final device in conv.targetDeviceIds) {
      if (conv.sessions.containsKey(device)) continue;
      try {
        final blob =
            await gateway.vaultRead(_safeKey('sess', '${conv.id}-$device'));
        if (blob == null || blob.isEmpty) continue;
        conv.sessions[device] = await gateway.importSession(blob);
      } catch (_) {
        // Session illisible : cet appareil repassera par un handshake.
      }
    }
  }

  // ----------------------------------------------------------- conversations

  void openConversation(String conversationId) {
    final conv = _conversations[conversationId];
    if (conv == null) return;
    activeConversationId = conversationId;
    error = null;
    notifyListeners();
    unawaited(_restoreSessions(conv).then((_) => notifyListeners()));
  }

  void closeConversation() {
    activeConversationId = null;
    notifyListeners();
  }

  /// Ouvre — ou rouvre — une conversation avec un correspondant.
  ///
  /// Une session est établie avec **chacun de ses appareils**, et avec les
  /// autres appareils de l'utilisateur lui-même pour qu'il y retrouve ses
  /// propres messages.
  Future<void> startChatWith(String peer) async {
    final api = _api;
    final gateway = _gateway;
    if (api == null || gateway == null) return;
    _setBusy(true);
    try {
      final user = await api.lookupUser(peer);
      final peerUserId = user['id'] as String;
      final convId = await api.createConversation(peerUserId);

      final conv = _conversations[convId] ??
          Conversation(id: convId, peerUsername: peer);
      conv.peerUsername = peer;
      if (!_conversations.containsKey(convId)) {
        conv.messages.addAll(await _readHistory(convId));
        _conversations[convId] = conv;
      }
      activeConversationId = convId;

      await _restoreSessions(conv);
      await _openSessionsWith(conv, peerUserId);
      if (userId != null) await _openSessionsWith(conv, userId!);

      await _saveConversations();
      await _saveSessions(conv);
      _setBusy(false);
    } catch (e) {
      _setBusy(false, err: _humanize(e));
    }
  }

  /// Établit une session avec chaque appareil d'un utilisateur qui n'en a pas
  /// encore. L'appareil courant est ignoré (on ne s'écrit pas à soi-même).
  Future<void> _openSessionsWith(Conversation conv, String targetUserId) async {
    final api = _api;
    final gateway = _gateway;
    if (api == null || gateway == null) return;

    final bundles = await api.prekeyBundles(targetUserId);
    for (final bundleJson in bundles) {
      final device = bundleJson['deviceId'] as String;
      if (device == deviceId) continue; // cet appareil-ci
      conv.targetDeviceIds.add(device);
      if (conv.sessions.containsKey(device)) continue;

      final theirBundle = PrekeyBundle(
        identityKey: base64Decode(bundleJson['identityKey'] as String),
        signedPrekey: base64Decode(bundleJson['signedPrekey'] as String),
        signedPrekeySignature:
            base64Decode(bundleJson['signedPrekeySignature'] as String),
        oneTimePrekey: bundleJson['oneTimePrekey'] != null
            ? base64Decode(bundleJson['oneTimePrekey'] as String)
            : null,
      );
      final init = await gateway.startSession(theirBundle);
      conv.sessions[device] = init.sessionId;
      _pendingHandshakes['${conv.id}-$device'] = init.handshake;
    }
  }

  Future<void> send(String text) async {
    final conv = active;
    final api = _api;
    final gateway = _gateway;
    if (conv == null || api == null || gateway == null || !conv.ready) return;

    try {
      final clearText = Uint8List.fromList(utf8.encode(text));
      var delivered = 0;

      // Chaque appareil a sa propre session : le message est chiffré autant de
      // fois qu'il y a de destinataires. Le serveur ne voit que des blobs.
      for (final device in conv.sessions.keys.toList()) {
        final sessionId = conv.sessions[device];
        if (sessionId == null) continue;
        try {
          final enc = await gateway.encrypt(sessionId, clearText);
          final handshake = _pendingHandshakes['${conv.id}-$device'];
          await api.sendMessage(
            conversationId: conv.id,
            recipientDeviceId: device,
            clientMessageId: _uuidV4(),
            headerB64: base64Encode(Envelope.packHeader(enc.header, handshake)),
            ciphertextB64: base64Encode(enc.ciphertext),
          );
          _pendingHandshakes.remove('${conv.id}-$device');
          delivered++;
        } catch (e) {
          // Un appareil injoignable ne doit pas bloquer les autres.
          error = 'Un appareil n’a pas reçu le message : ${_humanize(e)}';
        }
      }
      if (delivered == 0) {
        notifyListeners();
        return;
      }

      conv.messages.add(ChatMessage(text: text, mine: true, at: DateTime.now()));
      conv.lastActivity = DateTime.now();
      notifyListeners();

      await _saveHistory(conv);
      await _saveSessions(conv); // les ratchets ont avancé
      await _saveConversations();
    } catch (e) {
      error = _humanize(e);
      notifyListeners();
    }
  }

  // --------------------------------------------------------------- réception

  void _startPolling() {
    _poll?.cancel();
    // Le WebSocket supprime la latence ; le relevé périodique reste un filet de
    // sécurité — la remise ne doit jamais dépendre du seul temps réel.
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _pollOnce());
    _connectRealtime();
  }

  Future<void> _connectRealtime() async {
    final api = _api;
    if (api == null || api.accessToken == null) return;
    try {
      final base = Uri.parse(api.baseUrl);
      final wsUri = base.replace(
        scheme: base.scheme == 'https' ? 'wss' : 'ws',
        path: '/ws',
        queryParameters: {'token': api.accessToken!},
      );
      final socket = await WebSocket.connect(wsUri.toString());
      _socket = socket;
      realtime = true;
      notifyListeners();

      socket.listen(
        (event) {
          if (event is String && event.contains('message.pending')) _pollOnce();
        },
        onDone: _onRealtimeLost,
        onError: (_) => _onRealtimeLost(),
        cancelOnError: true,
      );
      await _pollOnce();
    } catch (_) {
      realtime = false;
      notifyListeners();
    }
  }

  void _onRealtimeLost() {
    _socket = null;
    realtime = false;
    notifyListeners();
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (_api != null && _socket == null) _connectRealtime();
    });
  }

  Future<void> _pollOnce() async {
    final api = _api;
    final gateway = _gateway;
    if (api == null || gateway == null) return;
    try {
      final incoming = await api.fetchMessages();
      if (incoming.isEmpty) return;

      final touched = <Conversation>{};
      for (final m in incoming) {
        final conv = await _resolveConversation(m);
        final sender = m['senderDeviceId'] as String;
        final unpacked =
            Envelope.unpackHeader(base64Decode(m['header'] as String));

        // Chaque appareil expéditeur a sa propre session : la première
        // réception depuis un appareil nous en fait le répondeur.
        if (unpacked.handshake != null && !conv.sessions.containsKey(sender)) {
          conv.sessions[sender] = await gateway.acceptSession(unpacked.handshake!);
          conv.targetDeviceIds.add(sender);
        }
        final sessionId = conv.sessions[sender];
        if (sessionId == null) continue;

        final plain = await gateway.decrypt(
          sessionId,
          unpacked.ratchetHeader,
          base64Decode(m['ciphertext'] as String),
        );

        // Un message émis par un autre de mes appareils est un message que
        // j'ai écrit : il s'affiche comme tel plutôt que comme reçu.
        final fromMyself = (m['senderUsername'] as String?) == username;
        conv.messages.add(ChatMessage(
          text: utf8.decode(plain),
          mine: fromMyself,
          at: DateTime.now(),
        ));
        conv.lastActivity = DateTime.now();
        touched.add(conv);
      }

      for (final conv in touched) {
        await _saveHistory(conv);
        await _saveSessions(conv);
      }
      if (touched.isNotEmpty) {
        await _saveConversations();
        notifyListeners();
      }
    } catch (e) {
      error = _humanize(e);
      notifyListeners();
    }
  }

  /// Retrouve la conversation d'un message entrant, ou la crée si un
  /// correspondant nous écrit pour la première fois.
  Future<Conversation> _resolveConversation(Map<String, dynamic> m) async {
    final convId = m['conversationId'] as String;
    final existing = _conversations[convId];
    if (existing != null) {
      await _restoreSessions(existing);
      return existing;
    }

    final conv = Conversation(
      id: convId,
      peerUsername: (m['senderUsername'] as String?) ?? 'inconnu',
      targetDeviceIds: {m['senderDeviceId'] as String},
    );
    conv.messages.addAll(await _readHistory(convId));
    await _restoreSessions(conv);
    _conversations[convId] = conv;
    return conv;
  }

  // ----------------------------------------------------------------- prekeys

  /// Regarnit le pool de one-time prekeys : chaque nouveau correspondant en
  /// consomme une, et sans réapprovisionnement le serveur finit par n'en avoir
  /// plus à distribuer — les nouvelles sessions perdent alors une garantie.
  Future<void> _replenishPrekeys() async {
    final api = _api;
    final gateway = _gateway;
    final device = deviceId;
    if (api == null || gateway == null || device == null) return;
    try {
      final remaining = await api.oneTimePrekeyCount(device);
      if (remaining >= 10) return;

      final keys = <String>[];
      for (var i = remaining; i < 20; i++) {
        final bundle = await gateway.generatePrekeyBundle();
        final otpk = bundle.oneTimePrekey;
        if (otpk != null) keys.add(base64Encode(otpk));
      }
      if (keys.isNotEmpty) await api.uploadPrekeys(device, oneTimePrekeys: keys);
    } catch (_) {
      // Sans conséquence immédiate : nouvelle tentative à la prochaine connexion.
    }
  }

  // ------------------------------------------------------------------ divers

  String _humanize(Object e) {
    final s = e.toString();
    if (s.contains('409')) return 'Ce nom d’utilisateur est déjà pris.';
    if (s.contains('404')) return 'Utilisateur introuvable.';
    if (s.contains('401')) return 'Identifiants refusés.';
    if (s.contains('Connection refused') || s.contains('SocketException')) {
      return 'Serveur injoignable — vérifie ta connexion.';
    }
    return s;
  }

  @override
  void dispose() {
    _poll?.cancel();
    _socket?.close();
    _gateway?.dispose();
    super.dispose();
  }
}
