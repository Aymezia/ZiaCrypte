import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_storage.dart';
import '../../../core/ffi/zia_crypto_exceptions.dart';
import '../../../core/network/api_client.dart';
import '../domain/crypto_models.dart';
import 'envelope.dart';
import 'ffi_crypto_gateway.dart';

class ChatMessage {
  ChatMessage({required this.text, required this.mine, required this.at});
  final String text;
  final bool mine;
  final DateTime at;

  Map<String, Object?> toJson() => {
        't': text,
        'm': mine,
        'a': at.millisecondsSinceEpoch,
      };

  static ChatMessage fromJson(Map<String, Object?> json) => ChatMessage(
        text: json['t'] as String,
        mine: json['m'] as bool,
        at: DateTime.fromMillisecondsSinceEpoch(json['a'] as int),
      );
}

/// Orchestration de l'application : relie le moteur cryptographique natif au
/// serveur. Aucune cryptographie ici — tout passe par le [FfiCryptoGateway].
class ChatService extends ChangeNotifier {
  ApiClient? _api;
  FfiCryptoGateway? _gateway;
  Timer? _poll;

  String? username;
  String? userId;
  String? deviceId;

  String? peerUsername;
  String? peerUserId;
  String? peerDeviceId;
  String? conversationId;
  int? _sessionId;

  /// Matériel X3DH à joindre au premier message (côté initiateur uniquement).
  HandshakeMaterial? _pendingHandshake;

  final List<ChatMessage> messages = [];
  String? error;
  bool busy = false;

  bool get connected => userId != null;
  bool get chatReady => _sessionId != null;

  /// Localise la bibliothèque native : variable d'environnement, puis à côté de
  /// l'exécutable, puis résolution par le chargeur système.
  static String _resolveLibrary() {
    final fromEnv = Platform.environment['ZIA_CRYPTO_LIB'];
    if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;

    // Nom et emplacement diffèrent selon la plateforme.
    final String fileName;
    final List<String> candidates;
    final exeDir = File(Platform.resolvedExecutable).parent.path;

    if (Platform.isWindows) {
      fileName = 'zia_crypto.dll';
      candidates = ['$exeDir\\$fileName'];
    } else if (Platform.isMacOS) {
      fileName = 'libzia_crypto.dylib';
      candidates = [
        '$exeDir/../Frameworks/$fileName', // bundle .app
        '$exeDir/$fileName',
      ];
    } else if (Platform.isAndroid) {
      // Chargée depuis les jniLibs de l'APK, par simple nom.
      return 'libzia_crypto.so';
    } else {
      fileName = 'libzia_crypto.so';
      candidates = ['$exeDir/lib/$fileName', '$exeDir/$fileName'];
    }

    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return fileName; // laisse le chargeur système résoudre
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

  void _setBusy(bool value, {String? err}) {
    busy = value;
    error = err;
    notifyListeners();
  }

  /// Compte déjà associé à cet appareil, s'il existe (permet la reconnexion).
  SavedAccount? get savedAccount => AppStorage.loadAccount();

  /// Ouvre le moteur natif sur le stockage permanent de l'appareil. L'identité
  /// y est rechargée si elle existe déjà ; sinon elle est créée puis persistée.
  Future<FfiCryptoGateway> _openGateway() async {
    final gateway = await FfiCryptoGateway.open(
      AppStorage.engineStoragePath,
      libraryPath: _resolveLibrary(),
    );
    try {
      await gateway.identityPublicKey(); // déjà présente
    } on ZiaNotInitializedException {
      await gateway.generateIdentity();
    }
    return gateway;
  }

  /// Crée un compte et son appareil, puis publie les prekeys.
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
          'deviceName': 'desktop',
          'identityPublicKey': base64Encode(bundle.identityKey),
          'signedPrekey': base64Encode(bundle.signedPrekey),
          'signedPrekeySignature': base64Encode(bundle.signedPrekeySignature),
          'oneTimePrekeys': [base64Encode(bundle.oneTimePrekey!)],
        },
      );

      _adoptSession(api, gateway, res, user);
      // Mémorise le compte pour permettre la reconnexion au prochain lancement.
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

  /// Reconnecte l'appareil à son compte existant : l'identité et les prekeys
  /// sont déjà sur place, seul le mot de passe est redemandé.
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

      _adoptSession(api, gateway, res, account.username);
      _setBusy(false);
    } catch (e) {
      _setBusy(false, err: _humanize(e));
      rethrow;
    }
  }

  // ---- Historique local, chiffré par le moteur ----

  /// Nom de l'entrée du coffre pour une conversation donnée. Les caractères
  /// hors [A-Za-z0-9._-] sont refusés par le moteur : on les remplace.
  String _historyKey(String conversation) =>
      'hist-${conversation.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}';

  Future<void> _loadHistory(String conversation) async {
    final gateway = _gateway;
    if (gateway == null) return;
    try {
      final raw = await gateway.vaultRead(_historyKey(conversation));
      messages.clear();
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(utf8.decode(raw)) as List;
        messages.addAll(list
            .cast<Map<String, dynamic>>()
            .map((m) => ChatMessage.fromJson(m)));
      }
      notifyListeners();
    } catch (_) {
      // Un historique illisible ne doit pas empêcher de discuter.
      messages.clear();
    }
  }

  Future<void> _saveHistory() async {
    final gateway = _gateway;
    final conversation = conversationId;
    if (gateway == null || conversation == null) return;
    try {
      final data = utf8.encode(jsonEncode(messages.map((m) => m.toJson()).toList()));
      await gateway.vaultWrite(_historyKey(conversation), Uint8List.fromList(data));
    } catch (e) {
      error = 'Historique non enregistré : ${_humanize(e)}';
      notifyListeners();
    }
  }

  /// Oublie le compte local et revient à l'écran d'accueil.
  void forgetAccount() {
    AppStorage.clearAccount();
    error = null;
    notifyListeners();
  }

  void _adoptSession(
    ApiClient api,
    FfiCryptoGateway gateway,
    Map<String, dynamic> res,
    String user,
  ) {
    api.accessToken = res['accessToken'] as String;
    _api = api;
    _gateway = gateway;
    username = user;
    userId = res['userId'] as String;
    deviceId = res['deviceId'] as String;
    _startPolling();
  }

  static String _platformName() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'linux';
  }

  /// Ouvre une conversation avec un correspondant et initie le handshake X3DH.
  Future<void> startChatWith(String peer) async {
    final api = _api!;
    final gateway = _gateway!;
    _setBusy(true);
    try {
      final user = await api.lookupUser(peer);
      final pid = user['id'] as String;
      final convId = await api.createConversation(pid);
      final bundleJson = await api.prekeyBundle(pid);

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
      _sessionId = init.sessionId;
      _pendingHandshake = init.handshake;
      peerUsername = peer;
      peerUserId = pid;
      peerDeviceId = bundleJson['deviceId'] as String;
      conversationId = convId;
      await _loadHistory(convId);
      _setBusy(false);
    } catch (e) {
      _setBusy(false, err: _humanize(e));
    }
  }

  /// Chiffre puis dépose le message sur le serveur.
  Future<void> send(String text) async {
    if (_sessionId == null || _api == null) return;
    try {
      final enc = await _gateway!.encrypt(
        _sessionId!,
        Uint8List.fromList(utf8.encode(text)),
      );
      await _api!.sendMessage(
        conversationId: conversationId!,
        recipientDeviceId: peerDeviceId!,
        clientMessageId: _uuidV4(),
        headerB64: base64Encode(Envelope.packHeader(enc.header, _pendingHandshake)),
        ciphertextB64: base64Encode(enc.ciphertext),
      );
      _pendingHandshake = null; // joint une seule fois
      messages.add(ChatMessage(text: text, mine: true, at: DateTime.now()));
      notifyListeners();
      await _saveHistory();
    } catch (e) {
      error = _humanize(e);
      notifyListeners();
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    final api = _api;
    final gateway = _gateway;
    if (api == null || gateway == null) return;
    try {
      final incoming = await api.fetchMessages();
      for (final m in incoming) {
        final unpacked = Envelope.unpackHeader(base64Decode(m['header'] as String));

        // Premier message reçu : on devient le répondeur de la session.
        if (unpacked.handshake != null && _sessionId == null) {
          _sessionId = await gateway.acceptSession(unpacked.handshake!);
          conversationId = m['conversationId'] as String;
          peerDeviceId = m['senderDeviceId'] as String;
          peerUsername = m['senderUsername'] as String?;
          await _loadHistory(conversationId!);
        }
        if (_sessionId == null) continue;

        final plain = await gateway.decrypt(
          _sessionId!,
          unpacked.ratchetHeader,
          base64Decode(m['ciphertext'] as String),
        );
        messages.add(ChatMessage(
          text: utf8.decode(plain),
          mine: false,
          at: DateTime.now(),
        ));
      }
      if (incoming.isNotEmpty) {
        notifyListeners();
        await _saveHistory();
      }
    } catch (e) {
      error = _humanize(e);
      notifyListeners();
    }
  }

  String _humanize(Object e) {
    final s = e.toString();
    if (s.contains('409')) return 'Ce nom d’utilisateur est déjà pris.';
    if (s.contains('404')) return 'Utilisateur introuvable.';
    if (s.contains('401')) return 'Identifiants refusés.';
    if (s.contains('Connection refused') || s.contains('SocketException')) {
      return 'Serveur injoignable — vérifie l’adresse.';
    }
    return s;
  }

  @override
  void dispose() {
    _poll?.cancel();
    _gateway?.dispose();
    super.dispose();
  }
}
