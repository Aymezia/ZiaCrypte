import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_storage.dart';
import '../../../core/ffi/crypto_isolate.dart';
import '../../../core/ffi/zia_crypto_exceptions.dart';
import '../../../core/network/api_client.dart';
import '../domain/chat_message.dart';
import '../domain/conversation.dart';
import '../domain/contact_identity.dart';
import '../domain/crypto_models.dart';
import 'identity_pinning.dart';
import 'envelope.dart';
import 'ffi_crypto_gateway.dart';

export '../domain/chat_message.dart';
export '../domain/conversation.dart';

/// Orchestration de l'application : relie le moteur cryptographique natif au
/// serveur. Aucune cryptographie ici — tout passe par le [FfiCryptoGateway].
class ChatService extends ChangeNotifier {
  ApiClient? _api;
  FfiCryptoGateway? _gateway;
  IdentityPinning? _pinning;

  /// Registre des clés d'identité épinglées. Null tant qu'aucune session n'est
  /// ouverte.
  IdentityPinning? get pinning => _pinning;

  /// Changements de clé détectés et non encore tranchés par l'utilisateur,
  /// indexés par identifiant d'appareil.
  final Map<String, IdentityChangedException> identityAlerts = {};
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

  /// Appareils frères déjà rétro-remplis (pour ne pas le refaire). Persisté.
  final Set<String> _backfilledSiblings = {};

  String? error;
  bool busy = false;

  /// Vrai quand le serveur a répondu qu'un second facteur est requis : le mot
  /// de passe était bon, il manque le code. L'écran de connexion s'en sert pour
  /// demander le code sans l'exiger d'emblée.
  bool needsTotp = false;

  /// Message auquel la prochaine saisie répondra, ou null.
  ChatMessage? replyingTo;

  /// Conversations où le correspondant est en train d'écrire, avec l'instant du
  /// dernier signal reçu. Un signal non renouvelé se périme tout seul : sans
  /// cela, un correspondant qui ferme l'application laisserait l'indicateur
  /// allumé indéfiniment.
  final Map<String, DateTime> _ecritureEnCours = {};
  Timer? _expirationEcriture;

  bool ecritDans(String conversationId) {
    final vu = _ecritureEnCours[conversationId];
    if (vu == null) return false;
    return DateTime.now().difference(vu).inSeconds < 6;
  }

  DateTime? _dernierSignalEnvoye;

  /// Signale que l'on écrit. Limité à un envoi toutes les trois secondes : une
  /// frappe ne doit pas produire un paquet.
  void signalerEcriture() {
    if (!(_settingsEcriture)) return;
    final conv = active;
    final socket = _socket;
    if (conv == null || socket == null) return;
    final now = DateTime.now();
    if (_dernierSignalEnvoye != null &&
        now.difference(_dernierSignalEnvoye!).inSeconds < 3) {
      return;
    }
    _dernierSignalEnvoye = now;
    final cibles = conv.sessions.keys
        .where((d) => !conv.ownDeviceIds.contains(d))
        .toList();
    if (cibles.isEmpty) return;
    try {
      socket.add(jsonEncode({
        'type': 'typing',
        'conversationId': conv.id,
        'to': cibles,
      }));
    } catch (_) {
      // l'indicateur est un confort : son échec n'a aucune conséquence
    }
  }

  /// Émission de l'indicateur, désactivable par l'utilisateur.
  bool _settingsEcriture = true;
  set indicateurEcritureActif(bool v) => _settingsEcriture = v;

  void startReply(ChatMessage m) {
    replyingTo = m;
    notifyListeners();
  }

  void cancelReply() {
    replyingTo = null;
    notifyListeners();
  }

  /// Passe le second facteur au client REST courant (écran d'options).
  ApiClient? get api => _api;

  /// Moteur natif, pour les composants qui en ont besoin directement
  /// (vérification de signature des mises à jour). Null hors session.
  ZiaCryptoEngine? get engine => _gateway?.engine;

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

  /// Nom lisible de cet appareil, envoyé au serveur à l'enregistrement.
  ///
  /// La plateforme seule ne suffit pas : deux machines Linux s'appelaient
  /// toutes les deux « linux », et l'écran des appareils liés ne permettait
  /// donc pas de reconnaître celui qu'on n'a pas rattaché soi-même — ce pour
  /// quoi il existe. Le nom d'hôte les distingue.
  ///
  /// C'est une donnée que le serveur voit : on lui donne le nom de la machine,
  /// pas celui de son propriétaire, et l'utilisateur peut de toute façon
  /// constater ce qui est stocké depuis cet écran.
  static String _deviceName() {
    final hote = Platform.localHostname.trim();
    final plateforme = _platformName();
    if (hote.isEmpty || hote == 'localhost') return plateforme;
    // Borné : le serveur refuse au-delà de 120 caractères, et un nom
    // interminable rendrait la liste illisible.
    final court = hote.length > 40 ? hote.substring(0, 40) : hote;
    return '$court ($plateforme)';
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

  /// Ouvre le moteur sur le dossier d'un compte.
  ///
  /// Chaque compte a le sien : une identité partagée entre deux comptes leur
  /// ferait publier la même clé publique, et le serveur pourrait prouver qu'ils
  /// sont la même personne.
  Future<FfiCryptoGateway> _openGateway(String storagePath) async {
    final gateway = await FfiCryptoGateway.open(
      storagePath,
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
      // Dossier neuf tiré au hasard : le moteur n'y trouve aucune identité et
      // en engendre une. Sans ça, créer un second compte sur cette machine
      // réutiliserait la paire de clés du premier.
      final storageKey = _uuidV4();
      final gateway = await _openGateway(AppStorage.engineStoragePathFor(storageKey));
      final bundle = await gateway.generatePrekeyBundle();

      final res = await api.register(
        username: user,
        password: password,
        device: {
          'platform': _platformName(),
          'deviceName': _deviceName(),
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
        storageKey: storageKey,
      ));
      _setBusy(false);
    } catch (e) {
      _setBusy(false, err: _humanize(e, auth: _AuthKind.creation));
      rethrow;
    }
  }

  /// Entre dans un compte existant depuis cette machine.
  ///
  /// Ce n'est pas une « reconnexion » : les clés privées du compte vivent sur
  /// l'appareil où il a été créé et ne peuvent pas être récupérées auprès du
  /// serveur — c'est la garantie même du chiffrement de bout en bout. Cette
  /// machine devient donc un APPAREIL SUPPLÉMENTAIRE du compte, avec sa propre
  /// identité, et ne verra que les messages échangés à partir de maintenant.
  Future<void> addDeviceAndConnect({
    required String user,
    required String password,
    String? totp,
    String? serverUrl,
  }) async {
    _setBusy(true);
    try {
      final api = ApiClient(serverUrl ?? AppConfig.serverUrl);
      // Dossier neuf : cet appareil a sa propre identité, distincte de celle
      // des autres appareils du compte.
      final storageKey = _uuidV4();
      final gateway =
          await _openGateway(AppStorage.engineStoragePathFor(storageKey));
      final bundle = await gateway.generatePrekeyBundle();

      final res = await api.addDevice(
        username: user,
        password: password,
        totp: totp,
        device: {
          'platform': _platformName(),
          'deviceName': _deviceName(),
          'identityPublicKey': base64Encode(bundle.identityKey),
          'signedPrekey': base64Encode(bundle.signedPrekey),
          'signedPrekeySignature': base64Encode(bundle.signedPrekeySignature),
          'oneTimePrekeys': [base64Encode(bundle.oneTimePrekey!)],
        },
      );

      needsTotp = false;
      await _adoptSession(api, gateway, res, user);
      AppStorage.saveAccount(SavedAccount(
        username: user,
        userId: userId!,
        deviceId: deviceId!,
        storageKey: storageKey,
      ));
      _setBusy(false);
    } catch (e) {
      if (_isTotpRequired(e)) {
        needsTotp = true;
        _setBusy(false,
            err: 'Entre le code de ton application d’authentification.');
        return;
      }
      _setBusy(false, err: _humanize(e, auth: _AuthKind.compteExistant));
      rethrow;
    }
  }

  Future<void> loginAndConnect(
      {required String password, String? totp, String? serverUrl}) async {
    final account = savedAccount;
    if (account == null) {
      _setBusy(false, err: 'Aucun compte enregistré sur cet appareil.');
      return;
    }
    _setBusy(true);
    try {
      final api = ApiClient(serverUrl ?? AppConfig.serverUrl);
      final gateway = await _openGateway(account.enginePath);
      final res = await api.login(
        username: account.username,
        password: password,
        deviceId: account.deviceId,
        totp: totp,
      );
      needsTotp = false;
      await _adoptSession(api, gateway, res, account.username);
      _setBusy(false);
    } catch (e) {
      if (_isTotpRequired(e)) {
        needsTotp = true;
        _setBusy(false,
            err: 'Entre le code de ton application d’authentification.');
        return;
      }
      _setBusy(false, err: _humanize(e, auth: _AuthKind.reconnexion));
      rethrow;
    }
  }

  /// Le serveur signale qu'un second facteur est requis (HTTP 428).
  static bool _isTotpRequired(Object e) =>
      e is DioException && e.response?.statusCode == 428;

  // ------------------------------------------------- réglages du 2e facteur

  Future<bool> twoFactorEnabled() async =>
      await _api?.twoFactorEnabled() ?? false;

  Future<Map<String, dynamic>> twoFactorSetup() async {
    final api = _api;
    if (api == null) throw StateError('non connecté');
    return api.twoFactorSetup();
  }

  Future<void> twoFactorEnable(String code) async {
    await _api?.twoFactorEnable(code);
    notifyListeners();
  }

  Future<void> twoFactorDisable(String password, String code) async {
    await _api?.twoFactorDisable(password, code);
    notifyListeners();
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

    final pinning = IdentityPinning(gateway.engine);
    await pinning.load();
    _pinning = pinning;

    await _chargerAvatars();
    await _loadBackfilled();
    await _loadConversations();
    _startPolling();
    unawaited(_replenishPrekeys());
    unawaited(_syncSiblings());
  }

  /// Ferme la session sans effacer l'identité ni l'historique local.
  Future<void> logout() async {
    // Remis à zéro : sans ça, une révocation constatée collerait à la session
    // suivante et empêcherait toute reconnexion sur cet appareil.
    _revoqueDetectee = false;
    _poll?.cancel();
    await _socket?.close();
    _socket = null;
    realtime = false;
    await _gateway?.dispose();
    _gateway = null;
    _pinning = null;
    identityAlerts.clear();
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
    unawaited(_restoreSessions(conv).then((_) async {
      notifyListeners();
      // Ouvrir la conversation vaut lecture : on confirme, si l'utilisateur
      // l'a activé.
      await marquerLu(conv);
    }));
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
          Conversation(id: convId, peerUsername: peer, peerUserId: peerUserId);
      conv.peerUsername = peer;
      conv.peerUserId = peerUserId;
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

  /// Inscrit dans la conversation qu'un appareil vient d'être rattaché.
  ///
  /// Écrit dans le fil plutôt que dans une notification passagère : un avis
  /// qu'on peut manquer en regardant ailleurs ne protège de rien, et celui-ci
  /// doit rester consultable après coup.
  void _annoncerAppareil(Conversation conv, bool leMien) {
    conv.messages.add(ChatMessage(
      text: leMien
          ? 'Un nouvel appareil a été lié à ton compte. Si ce n’est pas toi, '
              'révoque-le dans les options et change ton mot de passe.'
          : '${conv.peerUsername} a lié un nouvel appareil. Il reçoit '
              'désormais une copie de cette conversation.',
      mine: false,
      at: DateTime.now(),
      systeme: true,
    ));
    _saveHistory(conv);
    notifyListeners();
  }

  /// Produit une sauvegarde chiffrée de cet appareil.
  ///
  /// Le moteur rassemble identité, prekeys et coffre local, puis rechiffre le
  /// tout sous une clé dérivée de la phrase. Rien ne part sur le réseau : c'est
  /// l'appelant qui décide où écrire les octets.
  Future<Uint8List> exporterSauvegarde(String phrase) async {
    final gateway = _gateway;
    if (gateway == null) throw StateError('Connecte-toi d’abord.');
    return gateway.engine.backupExport(phrase);
  }

  /// Restaure une sauvegarde dans le moteur de cet appareil.
  Future<void> importerSauvegarde(String phrase, Uint8List octets) async {
    final gateway = _gateway;
    if (gateway == null) throw StateError('Connecte-toi d’abord.');
    await gateway.engine.backupImport(phrase, octets);
  }

  /// Appareils liés au compte, pour l'écran de gestion.
  Future<List<Map<String, dynamic>>> listerAppareils() async {
    final api = _api;
    if (api == null) throw StateError('Session fermée.');
    return api.mesAppareils();
  }

  Future<void> revoquerAppareil(String id) async {
    final api = _api;
    if (api == null) throw StateError('Session fermée.');
    await api.revoquerAppareil(id);
  }

  /// Établit une session avec chaque appareil d'un utilisateur qui n'en a pas
  /// encore. L'appareil courant est ignoré (on ne s'écrit pas à soi-même).
  Future<void> _openSessionsWith(Conversation conv, String targetUserId) async {
    final api = _api;
    final gateway = _gateway;
    if (api == null || gateway == null) return;

    final bundles = await api.prekeyBundles(targetUserId);

    // Appareils déjà connus pour cet utilisateur, AVANT d'épingler ceux du lot
    // courant. S'il en existait déjà et qu'un inconnu apparaît, c'est qu'un
    // appareil vient d'être rattaché à ce compte.
    final dejaConnus = _pinning?.forUser(targetUserId).length ?? 0;

    for (final bundleJson in bundles) {
      final device = bundleJson['deviceId'] as String;
      if (device == deviceId) continue; // cet appareil-ci
      final inconnu = _pinning?.forDevice(device) == null;
      conv.targetDeviceIds.add(device);
      // Un appareil du correspondant compte pour le reçu de remise ; l'un des
      // miens, non — sa relève ne dit rien de ce que le destinataire a reçu.
      if (targetUserId == userId) conv.ownDeviceIds.add(device);
      if (conv.sessions.containsKey(device)) continue;

      final theirIdentity = base64Decode(bundleJson['identityKey'] as String);

      // Contrôle avant toute ouverture de session : c'est le seul instant où
      // une substitution de clé par le serveur est détectable. Si la clé a
      // changé, on n'ouvre PAS la session — on remonte l'alerte et on laisse
      // l'utilisateur trancher après comparaison du numéro de sécurité.
      // Poursuivre en silence viderait la vérification de tout sens.
      try {
        await _pinning?.checkAndPin(
          deviceId: device,
          userId: targetUserId,
          identityKey: theirIdentity,
        );
      } on IdentityChangedException catch (alert) {
        identityAlerts[device] = alert;
        conv.targetDeviceIds.remove(device);
        notifyListeners();
        continue;
      }

      // Un appareil apparaît alors qu'on en connaissait déjà pour ce compte :
      // quelqu'un vient d'en rattacher un.
      //
      // C'est ce signal qui rend visible l'attaque que la synchronisation
      // multi-appareils a rendue possible — mot de passe volé, appareil lié,
      // copie chiffrée de tout ce qui arrive. C'est aussi ce qui empêche le
      // serveur d'ajouter discrètement un appareil de son cru : pour qu'il
      // reçoive quoi que ce soit, il faut que nous chiffrions à son intention,
      // donc que nous le voyions. Un serveur qui l'ajoute doit l'annoncer.
      if (inconnu && dejaConnus > 0) {
        _annoncerAppareil(conv, targetUserId == userId);
      }

      final theirBundle = PrekeyBundle(
        identityKey: theirIdentity,
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

  /// Crée un groupe avec les pseudos donnés et ouvre les sessions.
  ///
  /// La diffusion réutilise exactement le mécanisme multi-appareils : un
  /// message est chiffré séparément pour chaque appareil de chaque membre. Rien
  /// de nouveau côté cryptographie — c'est ce qui a fait préférer cette
  /// approche aux Sender Keys, au prix d'un coût linéaire en nombre
  /// d'appareils. Convient à des groupes de quelques dizaines de membres.
  ///
  /// Le nom reste local et voyage dans les messages : le serveur n'a jamais à
  /// le connaître.
  Future<void> createGroup({
    required String name,
    required List<String> memberUsernames,
  }) async {
    final api = _api;
    final gateway = _gateway;
    if (api == null || gateway == null) return;
    _setBusy(true);
    try {
      final memberIds = <String>[];
      for (final pseudo in memberUsernames) {
        final user = await api.lookupUser(pseudo.trim());
        memberIds.add(user['id'] as String);
      }
      if (memberIds.isEmpty) {
        _setBusy(false, err: 'Ajoute au moins un membre.');
        return;
      }

      final convId = await api.createGroup(memberIds);
      final conv = _conversations[convId] ??
          Conversation(
            id: convId,
            peerUsername: name,
            isGroup: true,
            memberUserIds: memberIds.toSet(),
          );
      conv.peerUsername = name;
      conv.memberUserIds.addAll(memberIds);
      _conversations[convId] = conv;
      activeConversationId = convId;

      await _restoreSessions(conv);
      for (final memberId in memberIds) {
        await _openSessionsWith(conv, memberId);
      }
      // Les autres appareils de l'utilisateur reçoivent aussi ses messages.
      if (userId != null) await _openSessionsWith(conv, userId!);

      await _saveConversations();
      await _saveSessions(conv);
      _setBusy(false);

      // Le nom du groupe est annoncé DANS le canal chiffré : c'est ainsi que
      // les autres membres l'apprennent, sans que le serveur le voie passer.
      await _sendPayload('__zia_groupe__:$name', null);
    } catch (e) {
      _setBusy(false, err: _humanize(e));
    }
  }

  /// Recharge la composition d'un groupe et ouvre les sessions manquantes.
  Future<void> refreshGroupMembers() async {
    final conv = active;
    final api = _api;
    if (conv == null || api == null || !conv.isGroup) return;
    try {
      final membres = await api.conversationMembers(conv.id);
      conv.memberUserIds
        ..clear()
        ..addAll(membres.map((m) => m['userId'] as String));
      for (final memberId in conv.memberUserIds) {
        await _openSessionsWith(conv, memberId);
      }
      await _saveConversations();
      await _saveSessions(conv);
      notifyListeners();
    } catch (e) {
      _setBusy(false, err: _humanize(e));
    }
  }

  /// Préfixe des annonces internes échangées dans le canal chiffré.
  ///
  /// Elles servent à transmettre ce que le serveur ne doit pas connaître — à
  /// commencer par le nom d'un groupe — et ne s'affichent jamais.
  static const _prefixeAnnonce = '__zia_groupe__:';

  static bool _estAnnonceInterne(String texte) =>
      texte.startsWith(_prefixeAnnonce);

  /// Préfixe des messages de synchronisation d'historique entre appareils d'un
  /// même compte. Comme l'annonce de groupe, ils voyagent dans le canal chiffré
  /// et ne s'affichent jamais.
  static const _prefixeSync = '__zia_sync__:';

  static bool _estSync(String texte) => texte.startsWith(_prefixeSync);

  /// Préfixes des messages de CONTRÔLE : édition et suppression.
  ///
  /// Ce sont des messages chiffrés comme les autres. Le serveur ne peut donc ni
  /// les lire, ni les fabriquer, ni supprimer un message à la place de son
  /// auteur — la suppression « pour tout le monde » reste une décision de
  /// l'auteur, transmise de bout en bout, pas une opération serveur.
  static const _prefixeEdit = '__zia_edit__:';
  static const _prefixeSuppr = '__zia_del__:';

  /// Accusé de lecture. Chiffré comme le reste : le serveur ne peut pas savoir
  /// que le message a été ouvert. Désactivé par défaut côté préférences.
  static const _prefixeLu = '__zia_read__:';

  /// Annonce d'une photo de profil.
  ///
  /// ## Pourquoi elle passe par le canal chiffré
  ///
  /// Un avatar déposé en clair sur le serveur, comme le font la plupart des
  /// messageries, dit à l'hébergeur à quoi ressemble chaque utilisateur — et
  /// permet de relier un compte à une personne bien plus sûrement qu'un pseudo.
  /// Ici l'image est chiffrée avec une clé aléatoire, exactement comme une
  /// pièce jointe, et cette clé ne voyage que dans les messages de bout en
  /// bout. Le stockage n'héberge qu'un blob, le serveur ne voit rien.
  ///
  /// Conséquence assumée : seules les personnes avec qui on a une conversation
  /// ouverte voient la photo. Un annuaire d'avatars visible de tous supposerait
  /// de les livrer au serveur.
  static const _prefixeAvatar = '__zia_avatar__:';

  static bool _estControle(String t) =>
      t.startsWith(_prefixeEdit) ||
      t.startsWith(_prefixeSuppr) ||
      t.startsWith(_prefixeLu) ||
      t.startsWith(_prefixeAvatar);

  /// Émission des accusés de lecture, pilotée par les préférences.
  bool accusesLectureActifs = false;

  /// Signale que les messages reçus de cette conversation ont été lus.
  ///
  /// N'envoie rien si l'utilisateur ne l'a pas activé, et rien non plus s'il
  /// n'y a aucun message reçu à confirmer.
  Future<void> marquerLu(Conversation conv) async {
    if (!accusesLectureActifs) return;
    final ids = <String>[];
    for (final m in conv.messages) {
      if (!m.mine && m.id != null && !m.readAckSent) {
        ids.add(m.id!);
        m.readAckSent = true;
      }
    }
    if (ids.isEmpty) return;
    await _diffuserControle(conv, '$_prefixeLu${jsonEncode({'ids': ids})}');
  }

  /// Modifie un message déjà envoyé, chez soi et chez les destinataires.
  Future<void> editMessage(ChatMessage m, String nouveauTexte) async {
    final conv = active;
    if (conv == null || m.id == null || !m.mine) return;
    final texte = nouveauTexte.trim();
    if (texte.isEmpty || texte == m.text) return;

    m.text = texte;
    m.editedAt = DateTime.now();
    notifyListeners();
    await _saveHistory(conv);

    await _diffuserControle(
        conv, '$_prefixeEdit${jsonEncode({'id': m.id, 't': texte})}');
  }

  /// Retire un message pour tout le monde.
  Future<void> deleteForEveryone(ChatMessage m) async {
    final conv = active;
    if (conv == null || m.id == null || !m.mine) return;

    m.deletedForEveryone = true;
    m.text = '';
    notifyListeners();
    await _saveHistory(conv);

    await _diffuserControle(
        conv, '$_prefixeSuppr${jsonEncode({'id': m.id})}');
  }

  /// Envoie un message de contrôle à tous les appareils de la conversation.
  /// Avatars connus, par identifiant d'utilisateur. Conservés dans le coffre
  /// chiffré du moteur — jamais sur le serveur.
  final Map<String, AttachmentRef> avatars = {};
  static const _cleCoffreAvatars = 'avatars_contacts';

  final Map<String, Uint8List> _photos = {};
  final Set<String> _photosEnCours = {};

  /// Photo de profil déchiffrée d'un utilisateur, si elle est déjà là.
  ///
  /// Renvoie `null` et lance la récupération en arrière-plan au premier appel :
  /// un avatar ne doit jamais retarder l'affichage d'une conversation. Les
  /// octets restent en mémoire — une photo de contact déchiffrée n'a pas plus
  /// de raison de traîner sur le disque qu'un message.
  Uint8List? photoDe(String? user) {
    if (user == null) return null;
    final dejaLa = _photos[user];
    if (dejaLa != null) return dejaLa;

    final ref = avatars[user];
    if (ref == null || _photosEnCours.contains(user)) return null;

    _photosEnCours.add(user);
    telechargerEnMemoire(ref).then((octets) {
      _photos[user] = octets;
      _photosEnCours.remove(user);
      notifyListeners();
    }).catchError((_) {
      // Photo introuvable ou illisible : on n'insiste pas, le dégradé dérivé
      // de la clé reste affiché. Retenter en boucle ne ferait que marteler le
      // stockage pour un élément décoratif.
      _photosEnCours.remove(user);
    });
    return null;
  }

  Future<void> _chargerAvatars() async {
    final gateway = _gateway;
    if (gateway == null) return;
    try {
      final brut = await gateway.vaultRead(_cleCoffreAvatars);
      if (brut == null || brut.isEmpty) return;
      final json = jsonDecode(utf8.decode(brut)) as Map<String, dynamic>;
      avatars.clear();
      json.forEach((user, ref) {
        avatars[user] =
            AttachmentRef.fromJson((ref as Map).cast<String, Object?>());
      });
      notifyListeners();
    } catch (_) {
      // Registre illisible : on repart à vide plutôt que d'empêcher le
      // démarrage. Les photos réapparaîtront à la prochaine annonce.
      avatars.clear();
    }
  }

  Future<void> _sauverAvatars() async {
    final gateway = _gateway;
    if (gateway == null) return;
    final json = <String, Object?>{};
    avatars.forEach((user, ref) => json[user] = ref.toJson());
    await gateway.vaultWrite(
        _cleCoffreAvatars, Uint8List.fromList(utf8.encode(jsonEncode(json))));
  }

  /// Définit sa photo de profil et l'annonce à ses correspondants.
  ///
  /// L'image suit le chemin des pièces jointes : chiffrée sur l'appareil avec
  /// une clé aléatoire, déposée sur le stockage, et seule la référence — avec
  /// sa clé — est diffusée dans le canal chiffré.
  Future<void> definirAvatar(String cheminImage) async {
    final api = _api;
    final gateway = _gateway;
    final moi = userId;
    if (api == null || gateway == null || moi == null) return;

    _setBusy(true);
    try {
      final octets = await File(cheminImage).readAsBytes();
      // Borne volontairement basse : un avatar est affiché à 40 pixels de côté.
      // Au-delà, on ferait payer à chaque correspondant le téléchargement d'une
      // photo pleine résolution pour une vignette.
      if (octets.length > 2 * 1024 * 1024) {
        _setBusy(false,
            err: 'Photo trop lourde (2 Mo maximum). Réduis-la avant de '
                'l’envoyer — elle sera affichée en tout petit.');
        return;
      }
      final nom = cheminImage.split(Platform.pathSeparator).last;
      final ref = await _deposerPieceJointe(octets, nom);

      avatars[moi] = ref;
      await _sauverAvatars();

      // Annonce à toutes les conversations ouvertes : chacune a déjà des
      // sessions établies, donc rien de nouveau n'est révélé au serveur.
      final charge = '$_prefixeAvatar${jsonEncode(ref.toJson())}';
      for (final conv in _conversations.values) {
        await _diffuserControle(conv, charge);
      }
      _setBusy(false);
    } catch (e) {
      _setBusy(false, err: _humanize(e));
    }
  }

  Future<void> _diffuserControle(Conversation conv, String charge) async {
    for (final device in conv.sessions.keys.toList()) {
      try {
        await _sendToDevice(conv, device, charge);
      } catch (_) {
        // Un appareil injoignable ne doit pas empêcher les autres d'appliquer
        // la modification.
      }
    }
  }

  /// Applique un message de contrôle reçu.
  ///
  /// Ne s'applique qu'aux messages de l'AUTEUR du contrôle : on ne laisse pas
  /// quelqu'un modifier ou effacer les messages d'autrui. Comme le contrôle
  /// arrive par la session de son auteur, la correspondance est garantie par le
  /// chiffrement lui-même.
  Future<void> _appliquerControle(
      Conversation conv, String texte, bool deMoi) async {
    try {
      // Photo de profil annoncée par un correspondant (ou par un de mes
      // propres appareils). On retient la référence ; l'image elle-même n'est
      // téléchargée qu'au moment de l'afficher.
      if (texte.startsWith(_prefixeAvatar)) {
        final json = jsonDecode(texte.substring(_prefixeAvatar.length))
            as Map<String, dynamic>;
        final ref = AttachmentRef.fromJson(json.cast<String, Object?>());
        final proprietaire = deMoi ? userId : conv.peerUserId;
        if (proprietaire != null) {
          avatars[proprietaire] = ref;
          await _sauverAvatars();
          notifyListeners();
        }
        return;
      }

      // Accusé de lecture : marque MES messages comme lus.
      if (texte.startsWith(_prefixeLu)) {
        if (deMoi) return; // un accusé venant de moi-même n'a pas de sens
        final json = jsonDecode(texte.substring(_prefixeLu.length))
            as Map<String, dynamic>;
        final ids = ((json['ids'] as List?) ?? const []).cast<String>().toSet();
        var change = false;
        for (final m in conv.messages) {
          if (m.mine && m.id != null && ids.contains(m.id) && !m.readByPeer) {
            m.readByPeer = true;
            change = true;
          }
        }
        if (change) {
          await _saveHistory(conv);
          notifyListeners();
        }
        return;
      }

      final estEdit = texte.startsWith(_prefixeEdit);
      final json = jsonDecode(texte.substring(
          (estEdit ? _prefixeEdit : _prefixeSuppr).length)) as Map<String, dynamic>;
      final cible = json['id'] as String?;
      if (cible == null) return;

      for (final m in conv.messages) {
        if (m.id != cible) continue;
        // L'auteur du contrôle doit être l'auteur du message.
        if (m.mine != deMoi) return;
        if (estEdit) {
          m.text = json['t'] as String? ?? m.text;
          m.editedAt = DateTime.now();
        } else {
          m.deletedForEveryone = true;
          m.text = '';
        }
        await _saveHistory(conv);
        notifyListeners();
        return;
      }
    } catch (_) {
      // un contrôle illisible est ignoré
    }
  }

  // ------------------------------------------ synchronisation multi-appareils

  /// Rétro-remplit les appareils frères plus récents avec l'historique.
  ///
  /// Les messages en DIRECT atteignent déjà tous les appareils d'un compte —
  /// chacun est un destinataire de plein droit. Le seul manque est l'historique
  /// d'AVANT la liaison d'un nouvel appareil. On le comble ici, d'appareil à
  /// appareil, chiffré de bout en bout.
  ///
  /// Règle anti-boucle et anti-doublon : l'appareil le plus ANCIEN fait
  /// autorité et n'envoie qu'aux plus récents, en ne renvoyant que les messages
  /// antérieurs à la création du frère — donc sans jamais chevaucher ce que
  /// celui-ci a reçu en direct depuis.
  Future<void> _syncSiblings() async {
    final api = _api;
    final me = userId;
    final myDevice = deviceId;
    if (api == null || me == null || myDevice == null) return;
    try {
      final devices = await api.userDevices(me);
      Map<String, dynamic>? mine;
      for (final d in devices) {
        if (d['id'] == myDevice) mine = d;
      }
      if (mine == null) return;
      final myCreatedAt = DateTime.parse(mine['createdAt'] as String);

      for (final d in devices) {
        final id = d['id'] as String;
        if (id == myDevice) continue;
        if (_backfilledSiblings.contains(id)) continue;
        final theirCreatedAt = DateTime.parse(d['createdAt'] as String);
        // Uniquement les frères plus récents que moi.
        if (!theirCreatedAt.isAfter(myCreatedAt)) continue;

        await _backfillSibling(id, before: theirCreatedAt);
        _backfilledSiblings.add(id);
        await _saveBackfilled();
      }
    } catch (_) {
      // une synchro ratée n'a aucune conséquence : on réessaiera
    }
  }

  Future<void> _backfillSibling(String siblingId,
      {required DateTime before}) async {
    for (final conv in _conversations.values.toList()) {
      final anciens =
          conv.messages.where((m) => m.at.isBefore(before)).toList();
      if (anciens.isEmpty) continue;
      // Borne : on ne renvoie que les 200 derniers messages antérieurs.
      final recent =
          anciens.length > 200 ? anciens.sublist(anciens.length - 200) : anciens;

      final data = jsonEncode({
        'conv': conv.id,
        'peer': conv.peerUsername,
        'peerId': conv.peerUserId,
        'group': conv.isGroup,
        'members': conv.memberUserIds.toList(),
        'msgs': recent
            .map((m) => {
                  't': m.text,
                  'm': m.mine,
                  'a': m.at.millisecondsSinceEpoch,
                  if (m.attachment != null) 'f': m.attachment!.toJson(),
                })
            .toList(),
      });
      await _sendToDevice(conv, siblingId, '$_prefixeSync$data');
    }
  }

  /// Envoie un contenu chiffré à UN seul appareil (pas de diffusion).
  Future<void> _sendToDevice(
      Conversation conv, String device, String text) async {
    final api = _api;
    final gateway = _gateway;
    if (api == null || gateway == null) return;

    if (!conv.sessions.containsKey(device)) {
      // Ouvre les sessions avec mes propres appareils, dont ce frère.
      if (userId != null) await _openSessionsWith(conv, userId!);
    }
    final sessionId = conv.sessions[device];
    if (sessionId == null) return;

    final enc = await gateway.encrypt(sessionId, _encodePayload(text, null));
    final handshake = _pendingHandshakes['${conv.id}-$device'];
    await api.sendMessage(
      conversationId: conv.id,
      recipientDeviceId: device,
      clientMessageId: _uuidV4(),
      headerB64: base64Encode(Envelope.packHeader(enc.header, handshake)),
      ciphertextB64: base64Encode(enc.ciphertext),
    );
    _pendingHandshakes.remove('${conv.id}-$device');
    await _saveSessions(conv);
  }

  /// Intègre un lot d'historique reçu d'un autre de mes appareils.
  Future<void> _applySyncPayload(String json) async {
    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      final convId = data['conv'] as String;
      final conv = _conversations.putIfAbsent(
        convId,
        () => Conversation(
          id: convId,
          peerUsername: data['peer'] as String? ?? 'inconnu',
        ),
      );
      conv.peerUsername = data['peer'] as String? ?? conv.peerUsername;
      conv.peerUserId ??= data['peerId'] as String?;
      if (data['group'] == true) conv.isGroup = true;
      conv.memberUserIds
          .addAll(((data['members'] as List?) ?? const []).cast<String>());

      // Anti-doublon : on ignore les messages dont l'horodatage exact est déjà
      // présent. Le direct et le rétro-remplissage ne se recouvrent pas (bornés
      // par la date de création), ceci n'est qu'une ceinture de sécurité.
      final presents =
          conv.messages.map((m) => m.at.millisecondsSinceEpoch).toSet();
      final entrants = <ChatMessage>[];
      for (final e in (data['msgs'] as List).cast<Map<String, dynamic>>()) {
        final at = (e['a'] as num).toInt();
        if (presents.contains(at)) continue;
        entrants.add(ChatMessage(
          text: e['t'] as String,
          mine: e['m'] as bool,
          at: DateTime.fromMillisecondsSinceEpoch(at),
          attachment: e['f'] == null
              ? null
              : AttachmentRef.fromJson((e['f'] as Map).cast<String, Object?>()),
        ));
      }
      if (entrants.isEmpty) return;
      conv.messages.addAll(entrants);
      conv.messages.sort((a, b) => a.at.compareTo(b.at));

      await _saveHistory(conv);
      await _saveConversations();
      notifyListeners();
    } catch (_) {
      // un lot illisible ne doit pas interrompre la relève
    }
  }

  Future<void> _saveBackfilled() async {
    final gateway = _gateway;
    if (gateway == null) return;
    try {
      await gateway.engine.vaultWrite('backfilled_siblings',
          Uint8List.fromList(utf8.encode(jsonEncode(_backfilledSiblings.toList()))));
    } catch (_) {}
  }

  Future<void> _loadBackfilled() async {
    final gateway = _gateway;
    if (gateway == null) return;
    try {
      final raw = await gateway.engine.vaultRead('backfilled_siblings');
      if (raw == null || raw.isEmpty) return;
      _backfilledSiblings
        ..clear()
        ..addAll((jsonDecode(utf8.decode(raw)) as List).cast<String>());
    } catch (_) {}
  }

  Future<void> send(String text) => _sendPayload(text, null);

  /// Chiffre et diffuse un contenu vers tous les appareils de la conversation.
  Future<void> _sendPayload(String text, AttachmentRef? attachment) async {
    final conv = active;
    final api = _api;
    final gateway = _gateway;
    if (conv == null || api == null || gateway == null || !conv.ready) return;

    try {
      // Identifiant stable du message, transmis dans le canal chiffré : c'est
      // lui que citera une éventuelle réponse.
      final messageId = _uuidV4();
      final citation = replyingTo;
      final clearText = _encodePayload(text, attachment,
          messageId: messageId, replyTo: citation);
      var delivered = 0;
      // Un identifiant de blob par appareil du correspondant : c'est ce qu'on
      // interrogera pour savoir si le message a été remis.
      final receiptIds = <String>[];

      // Chaque appareil a sa propre session : le message est chiffré autant de
      // fois qu'il y a de destinataires. Le serveur ne voit que des blobs.
      for (final device in conv.sessions.keys.toList()) {
        final sessionId = conv.sessions[device];
        if (sessionId == null) continue;
        try {
          final enc = await gateway.encrypt(sessionId, clearText);
          final handshake = _pendingHandshakes['${conv.id}-$device'];
          final clientMessageId = _uuidV4();
          await api.sendMessage(
            conversationId: conv.id,
            recipientDeviceId: device,
            clientMessageId: clientMessageId,
            headerB64: base64Encode(Envelope.packHeader(enc.header, handshake)),
            ciphertextB64: base64Encode(enc.ciphertext),
          );
          if (!conv.ownDeviceIds.contains(device)) receiptIds.add(clientMessageId);
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

      // Les annonces internes (nom de groupe) ne sont pas des messages : elles
      // ne s'affichent ni chez l'expéditeur, ni chez les destinataires. Seule
      // la réception les filtrait, si bien que l'auteur du groupe voyait passer
      // un marqueur technique dans sa propre conversation.
      if (!_estAnnonceInterne(text)) {
        conv.messages.add(ChatMessage(
          text: text,
          mine: true,
          at: DateTime.now(),
          id: messageId,
          replyToId: citation?.id,
          replyToText: citation == null
              ? null
              : (citation.text.length > 160
                  ? '${citation.text.substring(0, 160)}…'
                  : citation.text),
          replyToMine: citation?.mine,
          attachment: attachment,
          pendingReceiptIds: receiptIds,
        ));
      }
      // La citation est consommée, qu'il s'agisse d'un message ou d'une
      // annonce interne : on ne la reporte pas sur l'envoi suivant.
      if (replyingTo != null) {
        replyingTo = null;
      }
      conv.lastActivity = DateTime.now();
      notifyListeners();

      await _saveHistory(conv);
      await _saveSessions(conv); // les ratchets ont avancé
      await _saveConversations();

      // Vérifie tout de suite : si le correspondant est en ligne, le passage à
      // « remis » ne doit pas attendre le prochain tour du relevé périodique.
      unawaited(_checkDeliveries());
    } catch (e) {
      error = _humanize(e);
      notifyListeners();
    }
  }

  // ------------------------------------------------------------ pièces jointes

  /// Contenu d'un message : JSON pour pouvoir porter une pièce jointe.
  Uint8List _encodePayload(
    String text,
    AttachmentRef? attachment, {
    String? messageId,
    ChatMessage? replyTo,
  }) {
    return Uint8List.fromList(utf8.encode(jsonEncode({
      't': text,
      if (attachment != null) 'f': attachment.toJson(),
      if (messageId != null) 'i': messageId,
      if (replyTo != null) ...{
        'q': replyTo.id,
        // L'extrait voyage avec la réponse : le destinataire peut ne pas
        // posséder l'original (appareil lié après coup, historique purgé).
        'qt': replyTo.text.length > 160
            ? '${replyTo.text.substring(0, 160)}…'
            : replyTo.text,
        'qm': replyTo.mine,
      },
    })));
  }

  /// Décode un contenu. Un message qui n'est pas du JSON est du texte brut :
  /// on le rend tel quel plutôt que d'afficher une erreur.
  ({
    String text,
    AttachmentRef? attachment,
    String? id,
    String? replyToId,
    String? replyToText,
    bool? replyToMine,
  }) _decodePayload(Uint8List bytes) {
    final raw = utf8.decode(bytes, allowMalformed: true);
    try {
      final json = jsonDecode(raw);
      if (json is Map && json.containsKey('t')) {
        return (
          text: json['t'] as String,
          attachment: json['f'] == null
              ? null
              : AttachmentRef.fromJson((json['f'] as Map).cast<String, Object?>()),
          id: json['i'] as String?,
          replyToId: json['q'] as String?,
          replyToText: json['qt'] as String?,
          replyToMine: json['qm'] as bool?,
        );
      }
    } catch (_) {
      // contenu non structuré
    }
    return (
      text: raw,
      attachment: null,
      id: null,
      replyToId: null,
      replyToText: null,
      replyToMine: null,
    );
  }

  /// Chiffre un fichier, le dépose sur le stockage objet, puis envoie sa
  /// référence et sa clé dans un message chiffré de bout en bout.
  Future<void> sendAttachment(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    final fileName = filePath.split(Platform.pathSeparator).last;
    await _uploadAndSend(bytes, fileName, label: '📎 $fileName');
  }

  /// Envoie un message vocal : mêmes chiffrement et transport qu'une pièce
  /// jointe (chemin déjà éprouvé), avec une durée qui voyage dans le message
  /// chiffré. L'octet audio ne touche le réseau que chiffré.
  Future<void> sendVoiceMessage(String filePath, int durationMs) async {
    final bytes = await File(filePath).readAsBytes();
    final fileName = filePath.split(Platform.pathSeparator).last;
    await _uploadAndSend(bytes, fileName,
        label: '🎤 Message vocal', voiceDurationMs: durationMs);
  }

  /// Chiffre et dépose des octets sur le stockage, puis renvoie la référence.
  ///
  /// Extrait de l'envoi de pièce jointe parce que la photo de profil suit
  /// exactement le même chemin — chiffrement local, dépôt d'un blob opaque —
  /// mais sans conversation à laquelle la rattacher ni message à publier.
  Future<AttachmentRef> _deposerPieceJointe(
    Uint8List bytes,
    String fileName, {
    String? conversationId,
    int? voiceDurationMs,
  }) async {
    final api = _api!;
    final gateway = _gateway!;
    // Le fichier et son nom sont chiffrés séparément : l'hébergeur du stockage
    // ne voit ni l'un ni l'autre.
    final sealed = await gateway.attachmentEncrypt(bytes);
    final sealedName = await gateway
        .attachmentEncrypt(Uint8List.fromList(utf8.encode(fileName)));

    final created = await api.createAttachment(
      conversationId: conversationId,
      ciphertextSize: sealed.ciphertext.length,
      encryptedMetadataB64: base64Encode(sealedName.ciphertext),
    );
    await api.uploadToStorage(created['uploadUrl'] as String, sealed.ciphertext);

    return AttachmentRef(
      id: created['attachmentId'] as String,
      keyBase64: base64Encode(sealed.key),
      fileName: fileName,
      size: bytes.length,
      voiceDurationMs: voiceDurationMs,
    );
  }

  /// Chiffre, dépose et annonce une pièce jointe (fichier ou vocal).
  Future<void> _uploadAndSend(Uint8List bytes, String fileName,
      {required String label, int? voiceDurationMs}) async {
    final conv = active;
    final api = _api;
    final gateway = _gateway;
    if (conv == null || api == null || gateway == null || !conv.ready) return;

    _setBusy(true);
    try {
      // Le fichier et son nom sont chiffrés séparément : l'hébergeur du
      // stockage ne voit ni l'un ni l'autre.
      final sealed = await gateway.attachmentEncrypt(bytes);
      final sealedName = await gateway.attachmentEncrypt(
          Uint8List.fromList(utf8.encode(fileName)));

      final created = await api.createAttachment(
        conversationId: conv.id,
        ciphertextSize: sealed.ciphertext.length,
        encryptedMetadataB64: base64Encode(sealedName.ciphertext),
      );
      await api.uploadToStorage(
          created['uploadUrl'] as String, sealed.ciphertext);

      final ref = AttachmentRef(
        id: created['attachmentId'] as String,
        keyBase64: base64Encode(sealed.key),
        fileName: fileName,
        size: bytes.length,
        voiceDurationMs: voiceDurationMs,
      );
      await _sendPayload(label, ref);
      _setBusy(false);
    } catch (e) {
      _setBusy(false, err: _humanize(e));
    }
  }

  /// Télécharge et déchiffre une pièce jointe, sans jamais toucher le disque.
  ///
  /// Sert à l'aperçu des images dans le fil. Écrire une photo déchiffrée dans
  /// un dossier temporaire la ferait survivre à l'application, échapper au
  /// chiffrement du coffre et entrer dans les sauvegardes du système — pour un
  /// affichage qui n'a besoin que de la mémoire.
  Future<Uint8List> telechargerEnMemoire(AttachmentRef ref) async {
    final api = _api;
    final gateway = _gateway;
    if (api == null || gateway == null) {
      throw StateError('Session fermée : reconnecte-toi.');
    }
    final info = await api.attachment(ref.id);
    final ciphertext =
        await api.downloadFromStorage(info['downloadUrl'] as String);
    return gateway.attachmentDecrypt(base64Decode(ref.keyBase64), ciphertext);
  }

  /// Télécharge et déchiffre une pièce jointe EN MÉMOIRE, puis l'écrit dans un
  /// fichier temporaire — pour la lecture d'un vocal sans l'exposer en clair
  /// dans un dossier de l'utilisateur.
  ///
  /// Lève en cas d'échec plutôt que de renvoyer `null`. La version précédente
  /// avalait toute exception, et l'appelant ne pouvait afficher qu'un « Lecture
  /// impossible » qui ne disait ni ce qui avait échoué ni quoi y faire.
  Future<String> materializeForPlayback(AttachmentRef ref) async {
    final api = _api;
    final gateway = _gateway;
    if (api == null || gateway == null) {
      throw StateError('Session fermée : reconnecte-toi pour lire ce message.');
    }
    final info = await api.attachment(ref.id);
    final ciphertext =
        await api.downloadFromStorage(info['downloadUrl'] as String);
    final plain =
        await gateway.attachmentDecrypt(base64Decode(ref.keyBase64), ciphertext);

    final dir = await Directory.systemTemp.createTemp('zia_voice');
    final out = File('${dir.path}${Platform.pathSeparator}${ref.fileName}');
    await out.writeAsBytes(plain);
    return out.path;
  }

  /// Télécharge et déchiffre une pièce jointe, puis l'écrit sur le disque.
  /// Renvoie le chemin du fichier, ou null en cas d'échec.
  Future<String?> downloadAttachment(AttachmentRef ref, String targetDir) async {
    final api = _api;
    final gateway = _gateway;
    if (api == null || gateway == null) return null;
    try {
      final info = await api.attachment(ref.id);
      final ciphertext =
          await api.downloadFromStorage(info['downloadUrl'] as String);
      final plain = await gateway.attachmentDecrypt(
          base64Decode(ref.keyBase64), ciphertext);

      // Le dossier indiqué peut ne pas exister encore : on le crée plutôt que
      // d'échouer après avoir déchiffré.
      final dir = Directory(targetDir);
      if (!await dir.exists()) await dir.create(recursive: true);

      final target = File('$targetDir${Platform.pathSeparator}${ref.fileName}');
      await target.writeAsBytes(plain);
      return target.path;
    } catch (e) {
      error = _humanize(e);
      notifyListeners();
      return null;
    }
  }

  // --------------------------------------------------------------- réception

  /// Passe en « remis » les messages envoyés qu'au moins un appareil du
  /// correspondant a relevés.
  ///
  /// Ne demande au serveur que ce qu'il sait déjà (la date de remise qu'il pose
  /// lui-même) : aucun reçu de lecture, aucune métadonnée nouvelle exposée.
  Future<void> _checkDeliveries() async {
    final api = _api;
    if (api == null) return;

    // Rassemble les identifiants encore à confirmer, tous fils confondus.
    final aConfirmer = <String>[];
    for (final conv in _conversations.values) {
      for (final m in conv.messages) {
        if (m.mine && !m.delivered && m.pendingReceiptIds.isNotEmpty) {
          aConfirmer.addAll(m.pendingReceiptIds);
        }
      }
    }
    if (aConfirmer.isEmpty) return;

    Set<String> remis;
    try {
      remis = (await api.deliveredAmong(aConfirmer)).toSet();
    } catch (_) {
      return; // une vérification ratée n'a aucune conséquence : on réessaiera
    }
    if (remis.isEmpty) return;

    var changed = false;
    for (final conv in _conversations.values) {
      var convChanged = false;
      for (final m in conv.messages) {
        if (m.mine && !m.delivered && m.pendingReceiptIds.any(remis.contains)) {
          m.delivered = true; // au moins un appareil du correspondant l'a relevé
          convChanged = true;
        }
      }
      if (convChanged) {
        changed = true;
        await _saveHistory(conv);
      }
    }
    if (changed) notifyListeners();
  }

  void _startPolling() {
    _poll?.cancel();
    // Le WebSocket supprime la latence ; le relevé périodique reste un filet de
    // sécurité — la remise ne doit jamais dépendre du seul temps réel.
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      // Appareil révoqué : plus rien ne peut aboutir. Continuer reviendrait à
      // marteler le serveur pour toujours — un client dont la session est
      // morte et qui interroge quand même est un déni de service qu'on
      // s'inflige à soi-même.
      if (_revoqueDetectee) {
        final message = error;
        // On attend la fermeture avant de reposer le message : logout()
        // réinitialise l'état, et l'écraserait sinon en cours de route.
        logout().then((_) {
          error = message;
          notifyListeners();
        });
        return;
      }
      _pollOnce();
      _checkDeliveries();
      _syncSiblings();
    });
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
          if (event is! String) return;
          if (event.contains('message.pending')) {
            _pollOnce();
            return;
          }
          _traiterSignalEphemere(event);
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

  /// Traite un signal éphémère reçu (indicateur d'écriture).
  void _traiterSignalEphemere(String brut) {
    try {
      final json = jsonDecode(brut) as Map<String, dynamic>;
      final type = json['type'] as String?;
      final convId = json['conversationId'] as String?;
      if (convId == null) return;

      if (type == 'typing') {
        _ecritureEnCours[convId] = DateTime.now();
        notifyListeners();
        // Réveille l'affichage à l'expiration, sinon l'indicateur resterait
        // allumé jusqu'au prochain évènement quelconque.
        _expirationEcriture?.cancel();
        _expirationEcriture = Timer(const Duration(seconds: 7), () {
          notifyListeners();
        });
      } else if (type == 'typing.stop') {
        _ecritureEnCours.remove(convId);
        notifyListeners();
      }
    } catch (_) {
      // signal illisible : ignoré
    }
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
          // Second point d'entrée d'une clé d'identité — celui-ci vient du
          // handshake, pas d'un bundle. Sans le même contrôle qu'à l'émission,
          // il suffirait au serveur de nous faire recevoir en premier pour
          // contourner l'épinglage.
          final senderUserId = m['senderUserId'] as String?;
          if (senderUserId != null) {
            try {
              await _pinning?.checkAndPin(
                deviceId: sender,
                userId: senderUserId,
                identityKey: unpacked.handshake!.initiatorIdentityKey,
              );
            } on IdentityChangedException catch (alert) {
              identityAlerts[sender] = alert;
              notifyListeners();
              continue; // message non déchiffré tant que ce n'est pas tranché
            }
          }
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
        final payload = _decodePayload(plain);

        // Message de contrôle : édition ou suppression d'un message existant.
        if (_estControle(payload.text)) {
          await _appliquerControle(conv, payload.text, fromMyself);
          continue;
        }

        // Lot de synchronisation d'historique venu d'un autre de mes appareils.
        if (_estSync(payload.text)) {
          await _applySyncPayload(payload.text.substring(_prefixeSync.length));
          continue;
        }

        // Annonce du nom d'un groupe : elle sert à nommer la conversation, pas
        // à s'afficher comme un message. Le serveur n'a jamais vu ce nom.
        if (_estAnnonceInterne(payload.text)) {
          conv.peerUsername = payload.text.substring(_prefixeAnnonce.length);
          conv.isGroup = true;
          touched.add(conv);
          continue;
        }
        conv.messages.add(ChatMessage(
          text: payload.text,
          mine: fromMyself,
          at: DateTime.now(),
          id: payload.id,
          replyToId: payload.replyToId,
          replyToText: payload.replyToText,
          // Le drapeau « mien » du message cité est relatif à son AUTEUR : vu
          // d'ici, il s'inverse, sauf si le message vient d'un de mes appareils.
          replyToMine: payload.replyToMine == null
              ? null
              : (fromMyself ? payload.replyToMine : !payload.replyToMine!),
          attachment: payload.attachment,
        ));
        conv.lastActivity = DateTime.now();
        touched.add(conv);
      }

      for (final conv in touched) {
        await _saveHistory(conv);
        await _saveSessions(conv);
        // Un message qui arrive dans la conversation affichée est lu tout de
        // suite : l'accusé doit suivre, pas attendre une réouverture.
        if (conv.id == activeConversationId) await marquerLu(conv);
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
      // Les conversations enregistrées avant l'ajout de ce champ n'ont pas
      // d'identifiant de correspondant : on le complète dès qu'il arrive.
      existing.peerUserId ??= m['senderUserId'] as String?;
      await _restoreSessions(existing);
      return existing;
    }

    final conv = Conversation(
      id: convId,
      peerUsername: (m['senderUsername'] as String?) ?? 'inconnu',
      peerUserId: m['senderUserId'] as String?,
      targetDeviceIds: {m['senderDeviceId'] as String},
    );
    conv.messages.addAll(await _readHistory(convId));
    await _restoreSessions(conv);
    _conversations[convId] = conv;
    return conv;
  }

  // ------------------------------------------------- vérification de contact

  /// Numéros de sécurité de la conversation active, un par appareil du
  /// correspondant.
  ///
  /// Un contact peut avoir plusieurs appareils, chacun avec sa propre clé
  /// d'identité : il y a donc un numéro par appareil, et vérifier l'un ne dit
  /// rien des autres. Masquer cette réalité derrière un numéro unique
  /// donnerait une fausse impression de sécurité.
  Future<List<DeviceVerification>> safetyNumbers() async {
    final conv = active;
    final pinning = _pinning;
    final gateway = _gateway;
    final me = userId;
    if (conv == null || pinning == null || gateway == null || me == null) {
      return const [];
    }
    final peerId = conv.peerUserId;
    if (peerId == null) return const [];

    final myKey = await gateway.identityPublicKey();
    final out = <DeviceVerification>[];
    for (final identity in pinning.forUser(peerId)) {
      String? number;
      String? problem;
      try {
        number = await pinning.safetyNumber(
          myIdentityKey: myKey,
          myUserId: me,
          peerDeviceId: identity.deviceId,
          peerUserId: peerId,
        );
      } on ZiaInvalidArgumentException {
        // Le moteur refuse de calculer une empreinte quand les deux clés
        // d'identité sont identiques. Ce n'est pas un incident technique mais
        // une information : soit cet appareil est le nôtre, soit le serveur
        // nous a renvoyé notre propre clé en la présentant comme celle du
        // correspondant. Aucun numéro n'a de sens dans ce cas.
        problem = 'Cet appareil publie la même clé d’identité que le tien. '
            'Un numéro de sécurité n’a alors aucun sens : il ne pourrait pas '
            'distinguer ton correspondant de toi-même.\n\n'
            'Cela arrive si les deux comptes ont été créés sur cette machine '
            'avec une version antérieure à 0.6.1, qui réutilisait la même '
            'identité. Recrée l’un des deux comptes pour lui donner la sienne.';
      }
      out.add(DeviceVerification(
        identity: identity,
        safetyNumber: number ?? '',
        problem: problem,
      ));
    }
    return out;
  }

  /// Enregistre que l'utilisateur a comparé un numéro hors bande.
  Future<void> markVerified(String deviceId, {bool verified = true}) async {
    await _pinning?.markVerified(deviceId, verified: verified);
    notifyListeners();
  }

  /// Accepte une clé changée après décision explicite de l'utilisateur, puis
  /// lève le blocage. Le contact repasse en « non vérifié ».
  Future<void> acceptIdentityChange(String deviceId) async {
    final alert = identityAlerts[deviceId];
    if (alert == null) return;
    await _pinning?.acceptChange(
      deviceId: deviceId,
      userId: alert.userId,
      identityKey: alert.current,
    );
    identityAlerts.remove(deviceId);
    notifyListeners();
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

  /// Traduit une erreur technique en phrase compréhensible. Afficher une
  /// exception brute à l'utilisateur n'apprend rien à personne.
  /// Traduit une erreur pour l'utilisateur.
  ///
  /// [auth] change le sens de plusieurs codes. Sur une CONNEXION, un 401 veut
  /// dire « identifiants incorrects », pas « session expirée » — dire à
  /// quelqu'un qui essaie de se connecter que sa session a expiré n'a aucun
  /// sens et l'envoie chercher un problème inexistant.
  /// Le serveur signale-t-il une révocation plutôt qu'un jeton périmé ?
  ///
  /// Les deux se présentent en 401 : sans ce code explicite, le client
  /// tenterait un rafraîchissement qui échouerait indéfiniment, exactement le
  /// genre de boucle qui remplit les journaux et masque les vrais incidents.
  static bool _estRevoque(DioException e) {
    final data = e.response?.data;
    return data is Map && data['code'] == 'device_revoked';
  }

  bool _revoqueDetectee = false;

  String _humanize(Object e, {_AuthKind auth = _AuthKind.aucun}) {
    if (e is DioException) {
      final code = e.response?.statusCode;

      // Révocation : ce n'est pas une session expirée, et réessayer ne servira
      // jamais à rien. On coupe pour de bon plutôt que de laisser l'application
      // repolluer le serveur en boucle avec des requêtes vouées à échouer.
      if (code == 401 && _estRevoque(e)) {
        _revoqueDetectee = true;
        return 'Cet appareil a été révoqué depuis un autre appareil de ton '
            'compte. Il ne reçoit plus rien.';
      }

      if (auth != _AuthKind.aucun) {
        switch (code) {
          case 401:
            return 'Nom d’utilisateur ou mot de passe incorrect.';
          case 404:
            return auth == _AuthKind.reconnexion
                ? 'Cet appareil n’est plus reconnu par le serveur. '
                    'Utilise « J’ai déjà un compte ailleurs » pour le rattacher.'
                : 'Ce compte n’existe pas.';
          case 409:
            return auth == _AuthKind.creation
                ? 'Ce nom d’utilisateur est déjà pris.'
                : 'Cet appareil ne peut pas rejoindre ce compte : sa clé '
                    'd’identité est déjà utilisée.';
          case 429:
            return 'Trop de tentatives. Réessaie dans quelques minutes.';
        }
      }

      switch (code) {
        case 400:
          return 'Requête refusée par le serveur.';
        case 401:
          return 'Session expirée — reconnecte-toi.';
        case 403:
          return 'Accès refusé à cette conversation.';
        case 404:
          return 'Introuvable sur le serveur.';
        case 409:
          return 'Ce nom d’utilisateur est déjà pris.';
        case 413:
          return 'Fichier trop volumineux.';
        case 429:
          return 'Trop de requêtes. Réessaie dans un instant.';
        case 503:
          return 'Fonction indisponible sur ce serveur.';
      }
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.connectionError) {
        return 'Serveur injoignable — vérifie ta connexion.';
      }
      return 'Erreur réseau${code != null ? " ($code)" : ""}.';
    }
    if (e is ZiaCryptoException) {
      return 'Erreur cryptographique : ${e.runtimeType}';
    }
    final s = e.toString();
    if (s.contains('SocketException')) {
      return 'Serveur injoignable — vérifie ta connexion.';
    }
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  @override
  void dispose() {
    _poll?.cancel();
    _socket?.close();
    _gateway?.dispose();
    super.dispose();
  }
}

/// Contexte d'une erreur d'authentification, pour en traduire le sens.
///
/// Les mêmes codes HTTP ne veulent pas dire la même chose selon l'action : un
/// 401 sur une connexion signale de mauvais identifiants, pas une session
/// expirée ; un 409 signale un pseudo pris à la création, mais une clé
/// d'identité déjà utilisée à l'ajout d'un appareil.
enum _AuthKind { aucun, creation, reconnexion, compteExistant }
