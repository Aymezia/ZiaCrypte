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
import 'call_session.dart';
import 'identity_pinning.dart';
import 'envelope.dart';
import 'ffi_crypto_gateway.dart';
import 'padding.dart';

export '../domain/chat_message.dart';
export '../domain/conversation.dart';

/// Orchestration de l'application : relie le moteur cryptographique natif au
/// serveur. Aucune cryptographie ici — tout passe par le [FfiCryptoGateway].
class ChatService extends ChangeNotifier {
  ApiClient? _api;

  /// Fabrique du client API.
  ///
  /// Surchargeable par les tests pour OBSERVER les appels réellement émis.
  /// C'est la seule façon d'affirmer qu'un chemin est emprunté et pas seulement
  /// qu'il compile — la phase 33 était écrite, testée et inerte faute d'un tel
  /// contrôle.
  @visibleForTesting
  static ApiClient Function(String baseUrl) fabriqueApi = ApiClient.new;
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

  /// Le compte courant est-il administrateur ? Renseigné par le serveur à la
  /// connexion. N'ouvre AUCUN accès aux messages — il ne fait qu'afficher
  /// l'entrée d'administration, dont chaque action réclame ensuite un code 2FA.
  bool isAdmin = false;

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

  /// Appareils actuellement vus en ligne.
  ///
  /// N'est renseigné que par la passerelle, et remis à zéro dès que le temps
  /// réel tombe : afficher « en ligne » alors qu'on n'a plus de canal pour
  /// apprendre le contraire figerait l'indicateur sur une information fausse.
  final Set<String> _enLigne = {};

  /// Dernier abonnement envoyé, pour ne pas le réémettre à l'identique toutes
  /// les quinze secondes.
  Set<String> _abonnementPresence = {};

  /// Le correspondant de cette conversation est-il joignable ?
  ///
  /// Un appareil suffit : quelqu'un dont le téléphone est connecté est
  /// joignable, que son ordinateur le soit ou non.
  bool enLigneDans(String conversationId) {
    final conv = _conversations[conversationId];
    if (conv == null) return false;
    return conv.sessions.keys
        .any((d) => !conv.ownDeviceIds.contains(d) && _enLigne.contains(d));
  }

  /// Partage de sa propre présence, désactivable par l'utilisateur.
  ///
  /// DÉSACTIVÉ par défaut, comme les accusés de lecture : apparaître « en
  /// ligne » dit à quelle heure on ouvre l'application, donc quand on dort et
  /// quand on travaille. Personne ne doit livrer cela sans l'avoir choisi.
  ///
  /// Observer les autres reste possible sans partager : la réciprocité imposée
  /// par certaines messageries est une règle de politesse, pas de sécurité, et
  /// elle revient à faire payer un réglage de vie privée par un autre.
  bool _settingsPresence = false;
  set partagePresenceActif(bool v) {
    if (v == _settingsPresence) return;
    _settingsPresence = v;
    _declarerPresence();
  }

  /// Annonce (ou retire) sa visibilité à la passerelle.
  void _declarerPresence() {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.add(jsonEncode({'type': 'presence.mode', 'visible': _settingsPresence}));
    } catch (_) {
      // la présence est un confort : son échec n'a aucune conséquence
    }
  }

  /// Réabonne aux appareils des conversations ouvertes, si la liste a changé.
  ///
  /// Appelé à la connexion puis par la boucle périodique : une session ouverte
  /// entre deux relevés doit finir par apparaître, sans qu'il faille brancher
  /// un rappel dans chacun des endroits qui créent une session.
  void _rafraichirAbonnementPresence() {
    final socket = _socket;
    if (socket == null) return;
    final cibles = <String>{};
    for (final conv in _conversations.values) {
      for (final device in conv.sessions.keys) {
        if (!conv.ownDeviceIds.contains(device)) cibles.add(device);
      }
    }
    if (cibles.length == _abonnementPresence.length &&
        cibles.containsAll(_abonnementPresence)) {
      return;
    }
    _abonnementPresence = cibles;
    try {
      socket.add(jsonEncode({
        'type': 'presence.subscribe',
        'devices': cibles.toList(),
      }));
    } catch (_) {
      // idem : un abonnement manqué sera retenté au prochain relevé
    }
  }

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
      candidates = ['$exeDir$fileName'];
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

  /// « Rester connecté » : garde le jeton de reprise dans le coffre chiffré et
  /// le renouvelle à chaque rotation, pour reprendre la session au lancement
  /// sans mot de passe. Réglé à la connexion, mis à false efface le jeton.
  bool resterConnecte = false;

  /// Clé du jeton de reprise dans le coffre local chiffré de l'appareil.
  static const _cleJetonReprise = 'session_refresh';

  /// Écrit ou efface le jeton de reprise selon [resterConnecte]. Best-effort :
  /// un échec de coffre ne doit pas faire échouer la connexion elle-même.
  Future<void> _majJetonReprise() async {
    final gateway = _gateway;
    final api = _api;
    if (gateway == null) return;
    try {
      final token = resterConnecte ? api?.refreshToken : null;
      if (token != null) {
        await gateway.vaultWrite(
            _cleJetonReprise, Uint8List.fromList(utf8.encode(token)));
      } else {
        // Efface un éventuel jeton résiduel (désactivation, ou token absent).
        await gateway.vaultWrite(_cleJetonReprise, Uint8List(0));
      }
    } catch (_) {
      // coffre indisponible : on n'empêche pas la session de vivre pour autant
    }
  }

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
    bool resterConnecte = false,
  }) async {
    _setBusy(true);
    this.resterConnecte = resterConnecte;
    try {
      final api = fabriqueApi(serverUrl ?? AppConfig.serverUrl);
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
      await _majJetonReprise();
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
    bool resterConnecte = false,
  }) async {
    _setBusy(true);
    this.resterConnecte = resterConnecte;
    try {
      final api = fabriqueApi(serverUrl ?? AppConfig.serverUrl);
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
      await _majJetonReprise();
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
      {required String password,
      String? totp,
      String? serverUrl,
      bool resterConnecte = false}) async {
    final account = savedAccount;
    if (account == null) {
      _setBusy(false, err: 'Aucun compte enregistré sur cet appareil.');
      return;
    }
    _setBusy(true);
    try {
      final api = fabriqueApi(serverUrl ?? AppConfig.serverUrl);
      final gateway = await _openGateway(account.enginePath);
      final res = await api.login(
        username: account.username,
        password: password,
        deviceId: account.deviceId,
        totp: totp,
      );
      needsTotp = false;
      this.resterConnecte = resterConnecte;
      await _adoptSession(api, gateway, res, account.username);
      await _majJetonReprise();
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

  /// Reprend la session au lancement SANS mot de passe, si « rester connecté »
  /// a été activé et qu'un jeton de reprise valide subsiste dans le coffre.
  ///
  /// Renvoie true si la session est reprise. En cas d'échec d'authentification
  /// (jeton révoqué/expiré), on efface le jeton mort et on retombe sur l'écran
  /// de connexion. En cas de simple souci réseau, on GARDE le jeton : un
  /// lancement hors-ligne ne doit pas forcer à ressaisir le mot de passe ensuite.
  Future<bool> reprendreSession({String? serverUrl}) async {
    final account = savedAccount;
    if (account == null) return false;
    FfiCryptoGateway? gateway;
    try {
      gateway = await _openGateway(account.enginePath);
      final brut = await gateway.vaultRead(_cleJetonReprise);
      if (brut == null || brut.isEmpty) {
        await gateway.dispose();
        return false;
      }
      final api = fabriqueApi(serverUrl ?? AppConfig.serverUrl);
      api.refreshToken = utf8.decode(brut);
      await api.reprendreSession(); // jetons frais, ou exception
      resterConnecte = true;
      final res = <String, dynamic>{
        'accessToken': api.accessToken,
        'refreshToken': api.refreshToken,
        'userId': account.userId,
        'deviceId': account.deviceId,
        // Le rôle ne voyage pas dans le refresh ; non-admin par défaut. Un login
        // complet au mot de passe le rétablit au besoin (usage admin, rare).
        'role': 'user',
      };
      await _adoptSession(api, gateway, res, account.username);
      await _majJetonReprise();
      notifyListeners();
      return true;
    } catch (e) {
      // Jeton refusé (401/403) → il est mort, on l'efface. Autre cause (réseau,
      // serveur down) → on le conserve pour retenter au prochain lancement.
      final refuse = e is DioException &&
          (e.response?.statusCode == 401 || e.response?.statusCode == 403);
      if (refuse) {
        try {
          await gateway?.vaultWrite(_cleJetonReprise, Uint8List(0));
        } catch (_) {}
      }
      await gateway?.dispose();
      return false;
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
    // Sans le refresh token, le jeton d'accès expirait au bout de 15 min et
    // l'application se retrouvait « déconnectée ». On le confie au client, qui
    // renouvelle tout seul sur 401. Le WebSocket, lui, reste valide après
    // expiration (le serveur ne vérifie le jeton qu'à la poignée de main) et
    // toute reconnexion ultérieure relira le jeton frais — rien à forcer.
    api.refreshToken = res['refreshToken'] as String?;
    // Le refresh token tourne à chaque renouvellement : on réécrit alors le
    // jeton de reprise, sinon « rester connecté » garderait un jeton périmé.
    api.onTokensRenewed = () => unawaited(_majJetonReprise());
    _api = api;
    _gateway = gateway;
    username = user;
    userId = res['userId'] as String;
    deviceId = res['deviceId'] as String;
    isAdmin = res['role'] == 'admin';

    final pinning = IdentityPinning(gateway.engine);
    await pinning.load();
    _pinning = pinning;

    await _chargerAvatars();
    await _chargerStatuts();
    await _chargerJetons();
    // Liste des blocages chargée à la connexion : sans elle, le menu
    // proposerait « Bloquer » à quelqu'un qui l'est déjà.
    listerBlocages().catchError((_) => <Map<String, dynamic>>[]);
    // Notre jeton de remise, publié et annoncé : sans lui, personne ne peut
    // nous écrire de façon scellée et le serveur continue de voir le graphe.
    _publierJeton();
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
    // Déconnexion explicite : on efface le jeton de reprise pour que la
    // prochaine ouverture redemande bien le mot de passe.
    resterConnecte = false;
    await _majJetonReprise();
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
    isAdmin = false;
    _conversations.clear();
    _pendingHandshakes.clear();
    _enLigne.clear();
    _abonnementPresence = {};
    _abonnesCanal.clear();
    _terminerAppel(trace: false);
    statuts.clear();
    // Le jeton de remise appartient à la session qui se ferme. Le conserver
    // ferait annoncer au compte suivant celui du précédent.
    _monJeton = null;
    _jetonAnnonce.clear();
    _cleGroupeDistribuee.clear();
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
    // Ouvrir vaut lecture : le compteur de non-lus retombe à zéro, quel que
    // soit le réglage des accusés de lecture — c'est un repère local, pas un
    // signal envoyé au correspondant.
    if (conv.unread != 0) {
      conv.unread = 0;
      unawaited(_saveConversations());
    }
    notifyListeners();
    // Canal : on récupère le nombre d'abonnés pour l'en-tête. Sans conséquence
    // s'il échoue — c'est une indication, pas une donnée dont dépend l'affichage.
    if (conv.isChannel) unawaited(_rafraichirInfosCanal(conv.id));
    unawaited(_restoreSessions(conv).then((_) async {
      notifyListeners();
      // Ouvrir la conversation vaut lecture : on confirme, si l'utilisateur
      // l'a activé.
      await marquerLu(conv);
    }));
  }

  /// Nombre d'abonnés connus d'un canal, ou null tant qu'on ne l'a pas relevé.
  final Map<String, int> _abonnesCanal = {};
  int? abonnesDuCanal(String id) => _abonnesCanal[id];

  Future<void> _rafraichirInfosCanal(String id) async {
    final api = _api;
    if (api == null) return;
    try {
      final info = await api.channelInfo(id);
      _abonnesCanal[id] = (info['subscriberCount'] as num?)?.toInt() ?? 0;
      notifyListeners();
    } catch (_) {
      // Indication non critique : on laisse l'ancienne valeur, ou aucune.
    }
  }

  /// Renouvelle la clé d'un canal (admin) et renvoie le NOUVEAU lien.
  ///
  /// C'est le geste qui manquait pour retirer réellement un abonné : tant que
  /// la clé ne tourne pas, un partant garde de quoi lire la suite. On crée donc
  /// une clé d'expéditeur neuve, on la scelle sous un NOUVEAU secret de lien, et
  /// on la dépose. L'ancien lien n'ouvre plus rien — d'où la contrepartie : il
  /// faut redistribuer le nouveau lien à ceux qui restent. C'est inhérent au
  /// modèle « le lien EST la clé ».
  Future<String?> renouvelerCleCanal(Conversation conv) async {
    final api = _api;
    final gateway = _gateway;
    if (api == null || gateway == null) return null;
    if (!conv.isChannel || !conv.channelIsAdmin) return null;
    _setBusy(true);
    try {
      final secret = _octetsAleatoires(32);
      final distribution = await gateway.engine.senderKeyCreate(conv.id);
      final scelle = await gateway.engine.channelSealKey(secret, distribution);
      await api.putChannelKey(conv.id, base64Encode(scelle));
      conv.channelLinkSecret = secret;
      await _saveConversations();
      _setBusy(false);
      return _lienCanal(conv.id, secret, conv.peerUsername);
    } catch (e) {
      _setBusy(false, err: _humanize(e));
      return null;
    }
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
      conv.unread = 0; // on la regarde : plus rien en attente

      await _restoreSessions(conv);
      await _openSessionsWith(conv, peerUserId);
      if (userId != null) await _openSessionsWith(conv, userId!);

      // Nouveau correspondant : il n'a jamais reçu notre statut, qui n'est
      // diffusé qu'au moment où on le change. Sans cette annonce, il ne le
      // verrait qu'à la prochaine modification — donc peut-être jamais.
      final mien = statutDe(userId);
      if (mien != null) {
        await _diffuserControle(
            conv, '$_prefixeStatut${jsonEncode({'t': mien})}');
      }

      await _saveConversations();
      await _saveSessions(conv);
      _setBusy(false);
    } catch (e) {
      _setBusy(false, err: _humanize(e));
    }
  }

  /// Durées proposées. Volontairement peu nombreuses : un menu de douze
  /// options fait hésiter sans rien apporter.
  static const dureesEphemeres = <int, String>{
    0: 'Désactivé',
    3600: '1 heure',
    86400: '1 jour',
    604800: '1 semaine',
    2592000: '4 semaines',
  };

  /// Change la durée de vie des messages de la conversation active.
  Future<void> definirTtl(Conversation conv, int secondes) async {
    if (secondes == conv.ttlSecondes) return;
    conv.ttlSecondes = secondes;
    _annoncerTtl(conv, secondes, true);
    await _saveHistory(conv);
    notifyListeners();
    await _diffuserControle(conv, '$_prefixeTtl${jsonEncode({'s': secondes})}');
  }

  void _annoncerTtl(Conversation conv, int secondes, bool parMoi) {
    final qui = parMoi ? 'Tu as' : '${conv.peerUsername} a';
    conv.messages.add(ChatMessage(
      text: secondes == 0
          ? '$qui désactivé les messages éphémères.'
          : '$qui réglé les messages éphémères sur '
              '${dureesEphemeres[secondes] ?? '$secondes s'}. '
              'Le compte démarre à l’envoi.',
      mine: false,
      at: DateTime.now(),
      systeme: true,
    ));
  }

  /// Efface les messages arrivés à échéance.
  ///
  /// Ce n'est PAS une garantie de sécurité et l'interface ne doit pas le
  /// laisser croire : le correspondant peut photographier son écran, recopier
  /// le texte, ou avoir un appareil déjà compromis. Ce que ça réduit vraiment,
  /// c'est ce qu'un appareil saisi ou volé PLUS TARD révélera.
  Future<void> _balayerExpires() async {
    final maintenant = DateTime.now();
    var change = false;
    for (final conv in _conversations.values) {
      final avant = conv.messages.length;
      conv.messages.removeWhere((m) =>
          m.expiresAt != null && m.expiresAt!.isBefore(maintenant));
      if (conv.messages.length != avant) {
        change = true;
        await _saveHistory(conv);
      }
    }
    if (change) notifyListeners();
  }

  /// Échéance à donner à un message de cette conversation, s'il y a lieu.
  DateTime? _echeance(Conversation conv) => conv.ttlSecondes > 0
      ? DateTime.now().add(Duration(seconds: conv.ttlSecondes))
      : null;

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

  /// Un code de verrouillage est-il posé sur cet appareil ?
  Future<bool> verrouillageActif() async {
    final g = _gateway;
    if (g == null) return false;
    return g.engine.appLockIsSet();
  }

  Future<void> definirVerrouillage(String code) async {
    final g = _gateway;
    if (g == null) throw StateError('Connecte-toi d\u2019abord.');
    await g.engine.appLockSet(code);
  }

  Future<bool> verifierVerrouillage(String code) async {
    final g = _gateway;
    if (g == null) return false;
    return g.engine.appLockVerify(code);
  }

  Future<void> retirerVerrouillage() async {
    final g = _gateway;
    if (g == null) return;
    await g.engine.appLockClear();
  }

  /// Jetons de remise connus, par identifiant d'appareil.
  ///
  /// Conservés dans le coffre chiffré : ce sont des secrets partagés, et les
  /// perdre ferait simplement retomber sur le chemin authentifié — dégradation
  /// silencieuse de la confidentialité, donc à éviter.
  final Map<String, String> jetonsRemise = {};
  static const _cleCoffreJetons = 'jetons_remise';

  Future<void> _chargerJetons() async {
    final g = _gateway;
    if (g == null) return;
    try {
      final brut = await g.vaultRead(_cleCoffreJetons);
      if (brut == null || brut.isEmpty) return;
      final json = jsonDecode(utf8.decode(brut)) as Map<String, dynamic>;
      jetonsRemise
        ..clear()
        ..addAll(json.map((k, v) => MapEntry(k, v as String)));
    } catch (_) {
      jetonsRemise.clear();
    }
  }

  Future<void> _sauverJetons() async {
    final g = _gateway;
    if (g == null) return;
    await g.vaultWrite(_cleCoffreJetons,
        Uint8List.fromList(utf8.encode(jsonEncode(jetonsRemise))));
  }

  /// Notre propre jeton de remise, retenu pour pouvoir l'annoncer à chaque
  /// nouvelle conversation.
  String? _monJeton;

  /// Conversations où notre jeton a déjà été annoncé pendant cette session.
  ///
  /// On mémorise ce qui est FAIT, pas ce qui reste à faire. La version
  /// précédente tenait une file alimentée uniquement à l'ouverture d'une
  /// session neuve — or les sessions sont persistées : au deuxième lancement
  /// aucune session n'est ouverte, la file restait donc vide et le jeton ne
  /// partait jamais. Le chemin scellé ne pouvait s'activer que face à un
  /// correspondant tout neuf, jamais sur une conversation déjà entamée.
  final Set<String> _jetonAnnonce = {};

  /// Clés d'expéditeur de groupe déjà distribuées : conversation -> appareils
  /// servis. Sert à détecter tout changement de composition.
  final Map<String, Set<String>> _cleGroupeDistribuee = {};

  /// Publie notre jeton auprès du serveur, une fois par session.
  ///
  /// L'annonce aux correspondants se fait ailleurs, conversation par
  /// conversation : une première version l'annonçait à la connexion, alors
  /// qu'aucune conversation n'est encore chargée — le jeton n'atteignait
  /// personne et le chemin scellé ne s'activait jamais.
  Future<void> _publierJeton() async {
    final api = _api;
    if (api == null || deviceId == null || _monJeton != null) return;
    try {
      _monJeton = await api.publierJetonRemise();
    } catch (_) {
      // Le scellement est une amélioration, pas une condition de
      // fonctionnement : son échec ne doit pas empêcher de communiquer.
    }
  }

  /// Annonce notre jeton dans une conversation dont les sessions sont ouvertes.
  ///
  /// Renvoie false si l'annonce n'a pas abouti, pour qu'elle soit retentée :
  /// un jeton perdu dans une coupure réseau éteindrait le scellement jusqu'au
  /// prochain lancement.
  Future<bool> _annoncerJeton(Conversation conv) async {
    final jeton = _monJeton;
    if (jeton == null || conv.sessions.isEmpty) return false;
    try {
      await _diffuserControle(
          conv, '$_prefixeJeton${jsonEncode({'d': deviceId, 't': jeton})}');
      return true;
    } catch (_) {
      // sans conséquence : on retombe sur le chemin authentifié
      return false;
    }
  }

  /// Identifiants des comptes bloqués, gardés en mémoire pour l'affichage.
  final Set<String> bloques = {};

  Future<List<Map<String, dynamic>>> listerBlocages() async {
    final api = _api;
    if (api == null) throw StateError('Session fermée.');
    final liste = await api.blocages();
    bloques
      ..clear()
      ..addAll(liste.map((b) => b['userId'] as String));
    notifyListeners();
    return liste;
  }

  Future<void> bloquer(String userId) async {
    final api = _api;
    if (api == null) return;
    await api.bloquer(userId);
    bloques.add(userId);
    notifyListeners();
  }

  Future<void> debloquer(String userId) async {
    final api = _api;
    if (api == null) return;
    await api.debloquer(userId);
    bloques.remove(userId);
    notifyListeners();
  }

  /// Motifs de signalement proposés à l'utilisateur (valeur serveur → libellé).
  static const Map<String, String> motifsSignalement = {
    'spam': 'Spam',
    'harcelement': 'Harcèlement',
    'contenu_illegal': 'Contenu illégal',
    'arnaque': 'Arnaque',
    'autre': 'Autre',
  };

  /// Signale un message reçu. On ne transmet que ce que TON appareil a déjà
  /// déchiffré : c'est toi qui choisis de révéler ce message précis, le serveur
  /// n'a jamais pu le lire. Réservé aux conversations directes, où l'auteur est
  /// sans ambiguïté le correspondant.
  Future<void> signaler(
    Conversation conv,
    ChatMessage m, {
    required String motif,
    String? note,
  }) async {
    final api = _api;
    final vise = conv.peerUsername;
    if (api == null || conv.isGroup || conv.peerUserId == null) {
      throw StateError('Signalement indisponible pour cette conversation.');
    }
    final contenu = m.hasAttachment
        ? '[pièce jointe] ${m.attachment?.fileName ?? ''}'
        : m.text;
    final contexte = jsonEncode({
      'conversationId': conv.id,
      'messageAt': m.at.toIso8601String(),
      'pieceJointe': m.hasAttachment,
    });
    await api.signaler(
      reportedUsername: vise,
      reason: motif,
      note: (note != null && note.trim().isNotEmpty) ? note.trim() : null,
      content: contenu.isEmpty ? null : contenu,
      context: contexte,
    );
  }

  // ------------------------------------------------------------ administration
  //
  // Simples relais vers le client : la logique d'autorisation est côté serveur
  // (rôle admin + code 2FA frais à chaque action). Le service n'expose ces
  // méthodes que pour éviter que l'écran d'administration touche au client brut.

  ApiClient _exigerApi() {
    final api = _api;
    if (api == null) throw StateError('Session fermée.');
    return api;
  }

  Future<List<Map<String, dynamic>>> adminRechercherComptes(String totp,
          {String? q}) =>
      _exigerApi().adminUsers(totp, q: q);

  Future<Map<String, dynamic>> adminReinitMotDePasse(String userId, String totp,
          {String? motif}) =>
      _exigerApi().adminIssuePasswordReset(userId, totp, reason: motif);

  Future<void> adminSupprimerCompte(String userId, String totp, String motif) =>
      _exigerApi().adminDeleteUser(userId, totp, motif);

  Future<List<Map<String, dynamic>>> adminJournal(String totp) =>
      _exigerApi().adminActions(totp);

  Future<List<Map<String, dynamic>>> adminSignalements(String totp,
          {String statut = 'open'}) =>
      _exigerApi().adminReports(totp, status: statut);

  Future<void> adminResoudreSignalement(String id, String totp,
          {required String statut, String? resolution}) =>
      _exigerApi().adminResolveReport(id, totp, status: statut, resolution: resolution);

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

  /// Diffuse notre jeton dans les conversations qui ne l'ont pas encore reçu.
  ///
  /// Parcourt TOUTES les conversations chargées, pas seulement celles dont on
  /// vient d'ouvrir la session : c'est ce qui permet au chemin scellé de
  /// s'activer sur des échanges déjà en cours.
  Future<void> _viderFileJeton() async {
    // Publication retentée ici : elle échoue en silence à la connexion si le
    // réseau n'est pas prêt, et sans nouvelle tentative le scellement resterait
    // éteint pour toute la session.
    if (_monJeton == null) await _publierJeton();
    if (_monJeton == null) return;
    for (final conv in _conversations.values.toList()) {
      if (_jetonAnnonce.contains(conv.id) || conv.sessions.isEmpty) continue;
      // Marqué seulement en cas de succès : un échec doit être retenté au tour
      // suivant, pas oublié.
      if (await _annoncerJeton(conv)) _jetonAnnonce.add(conv.id);
    }
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

      // Un appareil de plus dans cette conversation : il n'a pas notre jeton.
      // On redemande l'annonce, sinon il ne pourrait jamais nous écrire de
      // façon scellée.
      _jetonAnnonce.remove(conv.id);

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
    // Un appareil de plus à observer. Sans ce rappel, la pastille n'apparaîtrait
    // qu'au prochain relevé périodique — quinze secondes après l'ouverture de la
    // conversation, là où on la regarde justement.
    _rafraichirAbonnementPresence();
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

  // ------------------------------------------------------------- Canaux
  //
  // Un canal de diffusion réutilise les clés d'expéditeur : l'admin détient la
  // clé de signature (lui seul publie), les abonnés reçoivent la clé de LECTURE
  // scellée sous le secret du lien d'invitation. Le serveur ne fait que garder
  // le blob scellé et recopier les posts — il ne peut rien ouvrir.

  /// Schéma du lien d'invitation. Le secret ET le nom voyagent APRÈS le « # » :
  /// un fragment d'URL n'est pas transmis au serveur, ce qui garde le secret de
  /// lecture — et jusqu'au nom du canal — hors de sa vue.
  static const _schemeCanal = 'ziacrypte://canal/';

  String _lienCanal(String id, Uint8List secret, String nom) {
    final s = base64Url.encode(secret);
    final n = base64Url.encode(utf8.encode(nom));
    return '$_schemeCanal$id#$s.$n';
  }

  /// Crée un canal dont je deviens l'admin, et renvoie le lien à partager.
  ///
  /// Ordre imposé : le serveur assigne l'id, la clé d'expéditeur se range sous
  /// cet id, puis on scelle et on dépose. Un canal existe donc un instant sans
  /// clé — sans conséquence, personne n'a encore le lien.
  Future<String?> creerCanal(String nom) async {
    final api = _api;
    final gateway = _gateway;
    if (api == null || gateway == null || userId == null) return null;
    final propre = nom.trim();
    if (propre.isEmpty) {
      _setBusy(false, err: 'Donne un nom au canal.');
      return null;
    }
    _setBusy(true);
    try {
      final created = await api.createChannel();
      final id = created['id'] as String;
      final adminDevice = created['adminDeviceId'] as String;

      // Secret du lien : 32 octets de la même source que les UUID. Il transite
      // de toute façon par l'URL, donc rien ne gagnerait à le fabriquer côté
      // moteur — mais la clé de LECTURE qu'il protège, elle, ne quitte pas le C++.
      final secret = _octetsAleatoires(32);
      final distribution = await gateway.engine.senderKeyCreate(id);
      final scelle = await gateway.engine.channelSealKey(secret, distribution);
      await api.putChannelKey(id, base64Encode(scelle));

      final conv = Conversation(
        id: id,
        peerUsername: propre,
        isChannel: true,
        channelAdminDevice: adminDevice,
        channelIsAdmin: true,
        channelLinkSecret: secret,
      );
      _conversations[id] = conv;
      activeConversationId = id;
      await _saveConversations();
      _setBusy(false);
      return _lienCanal(id, secret, propre);
    } catch (e) {
      _setBusy(false, err: _humanize(e));
      return null;
    }
  }

  /// Lien d'invitation d'un canal que j'administre. Null si je n'en suis pas
  /// l'admin (je n'ai alors pas le secret).
  String? lienDuCanal(Conversation conv) {
    final secret = conv.channelLinkSecret;
    if (!conv.isChannel || !conv.channelIsAdmin || secret == null) return null;
    return _lienCanal(conv.id, secret, conv.peerUsername);
  }

  /// Rejoint un canal à partir d'un lien d'invitation.
  ///
  /// Le lien porte tout ce qu'il faut : l'id (public) et, après le « # »,
  /// le secret de lecture et le nom. On récupère la clé scellée, on l'ouvre
  /// avec le secret, on l'enregistre, et on s'abonne pour recevoir les posts.
  Future<bool> rejoindreCanalParLien(String lien) async {
    final api = _api;
    final gateway = _gateway;
    if (api == null || gateway == null) return false;
    final parse = _analyserLien(lien.trim());
    if (parse == null) {
      _setBusy(false, err: 'Lien de canal invalide.');
      return false;
    }
    final (id, secret, nom) = parse;
    _setBusy(true);
    try {
      if (_conversations[id]?.isChannel == true) {
        // Déjà abonné : on ouvre simplement le canal.
        activeConversationId = id;
        _setBusy(false);
        notifyListeners();
        return true;
      }

      final scelleB64 = await api.channelKey(id);
      final distribution =
          await gateway.engine.channelOpenKey(secret, base64Decode(scelleB64));
      final info = await api.channelInfo(id);
      final adminDevice = info['adminDeviceId'] as String?;
      if (adminDevice == null) {
        _setBusy(false, err: 'Ce canal n’a plus d’administrateur.');
        return false;
      }

      // La clé de l'admin est rangée sous SON appareil : c'est l'identifiant
      // d'expéditeur que porteront les posts, et donc celui qui déchiffrera.
      await gateway.engine.senderKeyProcess(id, adminDevice, distribution);
      await api.subscribeChannel(id);

      final conv = Conversation(
        id: id,
        peerUsername: nom,
        isChannel: true,
        channelAdminDevice: adminDevice,
        channelIsAdmin: false,
        // Pas de secret conservé : on a déscellé la clé, il n'a plus d'usage.
      );
      _conversations[id] = conv;
      conv.messages.addAll(await _readHistory(id));
      activeConversationId = id;
      await _saveConversations();
      _setBusy(false);
      notifyListeners();
      return true;
    } catch (e) {
      // Un secret faux ou un canal introuvable échouent ici, indistinctement.
      _setBusy(false, err: _humanize(e));
      return false;
    }
  }

  /// Publie dans un canal (admin seulement). Un seul chiffrement, le serveur
  /// recopie à tous les abonnés.
  Future<void> publierDansCanal(String texte) async {
    final conv = active;
    final api = _api;
    final gateway = _gateway;
    if (conv == null || api == null || gateway == null) return;
    if (!conv.isChannel || !conv.channelIsAdmin) return;
    final propre = texte.trim();
    if (propre.isEmpty) return;
    try {
      final clair = _encodePayload(propre, null);
      final chiffre = await gateway.engine.senderKeyEncrypt(conv.id, clair);
      await api.postChannel(
        id: conv.id,
        clientMessageId: _uuidV4(),
        headerB64: base64Encode(Envelope.packGroupHeader()),
        ciphertextB64: base64Encode(chiffre),
      );
      // On affiche son propre post localement : le serveur ne nous le renvoie
      // pas (il exclut l'appareil qui publie).
      conv.messages.add(ChatMessage(text: propre, mine: true, at: DateTime.now()));
      conv.lastActivity = DateTime.now();
      await _saveHistory(conv);
      notifyListeners();
    } catch (e) {
      _setBusy(false, err: _humanize(e));
    }
  }

  /// Quitte un canal (abonné) ou le ferme pour soi (admin).
  Future<void> quitterCanal(Conversation conv) async {
    final api = _api;
    if (api == null || !conv.isChannel || deviceId == null) return;
    try {
      await api.unsubscribeChannel(conv.id, deviceId!);
    } catch (_) {
      // Même injoignable, on retire le canal localement : l'utilisateur a
      // demandé à partir, et la remise cessera de toute façon.
    }
    _conversations.remove(conv.id);
    if (activeConversationId == conv.id) activeConversationId = null;
    await _saveConversations();
    notifyListeners();
  }

  /// Reçoit un post de canal, arrivé par le tuyau commun avec `channelId`.
  ///
  /// Renvoie la conversation touchée, ou null si l'on n'est pas (ou plus)
  /// abonné à ce canal — auquel cas le blob est ignoré.
  Future<Conversation?> _recevoirCanal(Map<String, dynamic> m) async {
    final gateway = _gateway;
    if (gateway == null) return null;
    final canalId = m['channelId'] as String;
    final conv = _conversations[canalId];
    // Pas dans nos canaux : un post pour un canal qu'on a quitté, ou dont
    // l'abonnement local a été perdu. Rien à afficher.
    if (conv == null || !conv.isChannel) return null;
    final sender = m['senderDeviceId'] as String?;
    if (sender == null) return null;

    Uint8List clair;
    try {
      clair = await gateway.engine
          .senderKeyDecrypt(canalId, sender, base64Decode(m['ciphertext'] as String));
    } catch (_) {
      // Clé pas encore en place, ou post antérieur à une rotation : illisible,
      // et le rester est correct.
      return null;
    }

    final payload = _decodePayload(clair);
    if (_estControle(payload.text) || _estAnnonceInterne(payload.text)) {
      return null; // un canal ne porte pas de messages de contrôle
    }
    conv.messages.add(ChatMessage(
      text: payload.text,
      mine: false,
      at: DateTime.fromMillisecondsSinceEpoch(
          (m['timestampMs'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch),
      attachment: payload.attachment,
    ));
    conv.lastActivity = DateTime.now();
    if (conv.id != activeConversationId) conv.unread++;
    await _saveHistory(conv);
    return conv;
  }

  // ------------------------------------------------------------- Appels
  //
  // La voix (à venir en phase 3b, WebRTC) sera chiffrée de bout en bout par
  // DTLS-SRTP. Ce qu'on gère ici est la SIGNALISATION : offre/réponse/ICE. Elle
  // voyage chiffrée par le MÊME Double Ratchet que les messages — pas par le
  // scellé — parce qu'il faut l'AUTHENTICITÉ : le serveur ne doit pas pouvoir
  // forger un faux SDP (donc une fausse empreinte DTLS) et s'intercaler. Seul
  // celui qui détient la session peut produire un chiffré valide.

  /// État de l'appel courant. Un seul à la fois.
  CallEtat callEtat = CallEtat.aucun;
  String? callId;
  String? callPeerName;

  /// Conversation de l'appel courant : là où on inscrira une trace à la fin.
  String? _callConvId;

  /// Instant où l'appel a été accepté (état « connecté »). Sert au minuteur de
  /// durée affiché pendant l'appel, et au calcul de la durée dans la trace.
  DateTime? callDepuis;

  /// Appareil du correspondant avec qui l'appel se déroule (celui qui a
  /// invité, ou celui qui a répondu). C'est par sa session qu'on chiffre.
  String? callPairDevice;

  /// Credentials TURN du dernier appel.
  List<dynamic>? callIceServers;

  /// Session média WebRTC de l'appel courant (null hors appel).
  CallSession? _callSession;

  /// Offre reçue avec une invitation, en attente d'acceptation.
  Map<String, dynamic>? _offreEntrante;

  /// Candidats ICE reçus AVANT que notre session média existe. En relais-seul,
  /// il n'y en a qu'un ou deux, et les perdre suffit à empêcher la connexion.
  /// On les met de côté et on les rejoue dès la session créée.
  final List<Map<String, dynamic>> _iceEnAttente = [];

  /// Micro coupé, et média réellement connecté — pour l'interface d'appel.
  bool callMuet = false;
  bool callMediaConnecte = false;

  /// Le média s'est-il connecté AU MOINS une fois pendant cet appel ? Sert à
  /// distinguer un appel abouti (trace « Appel · durée ») d'un appel accepté
  /// mais jamais établi (trace « Appel échoué »).
  bool _mediaAConnecte = false;

  /// Délai de garde : si le média n'est pas établi peu après l'acceptation, on
  /// termine l'appel avec une erreur au lieu de laisser « Connexion… » à vie.
  Timer? _timeoutMedia;

  /// Appelant : TOUS les appareils du correspondant que l'on fait sonner. Un
  /// correspondant peut en avoir plusieurs (ordi + téléphone, ou un ancien
  /// appareil resté après réinstallation) ; on sonne partout et on fait taire
  /// les autres dès qu'un a répondu.
  List<String> _callCibles = [];

  /// Appelant : candidats ICE locaux produits AVANT qu'un appareil ait répondu.
  /// Tant qu'on ignore lequel décrochera, on ne sait pas où les router : on les
  /// met de côté, puis on les envoie à l'appareil qui répond.
  final List<Map<String, Object?>> _iceLocalEnAttente = [];

  /// Active la couche média WebRTC. Désactivable par les tests : WebRTC exige un
  /// binding natif absent d'un `flutter test`, où seule la SIGNALISATION est
  /// éprouvée. En production, toujours vrai.
  @visibleForTesting
  bool activerMediaAppel = true;

  bool get enAppel => callEtat != CallEtat.aucun;

  /// Coupe ou rétablit le micro pendant un appel.
  void basculerMuet() {
    final s = _callSession;
    if (s == null) return;
    callMuet = s.basculerMuet();
    notifyListeners();
  }

  /// Crée la session média et branche l'émission de ses signaux (candidats ICE)
  /// sur le canal chiffré, vers l'appareil pair. La destination est dynamique :
  /// [callPairDevice] est l'appareil « d'en face » — fixé dès l'invitation côté
  /// appelé, mais seulement au moment de la réponse côté appelant (qui sonne
  /// plusieurs appareils). Avant, les candidats sont mis de côté.
  CallSession _creerSessionMedia(Conversation conv, String id) {
    return CallSession(
      iceServers: callIceServers ?? const [],
      onSignal: (kind, data) {
        final dest = callPairDevice;
        if (dest == null) {
          if (kind == 'ice') _iceLocalEnAttente.add(data);
          return; // on ne sait pas encore vers quel appareil router
        }
        unawaited(_envoyerSignalAppel(conv, dest, id, kind, data));
      },
      onConnecte: (c) {
        callMediaConnecte = c;
        if (c) {
          _mediaAConnecte = true;
          _timeoutMedia?.cancel(); // connecté : plus besoin du délai de garde
        }
        notifyListeners();
      },
    );
  }

  /// Démarre un appel vers le correspondant d'une conversation directe.
  Future<void> appeler(Conversation conv) async {
    final api = _api;
    if (api == null || conv.isGroup || conv.isChannel || enAppel) return;
    // Un relais est nécessaire (on force le relais pour cacher les IP) : sans
    // TURN configuré côté serveur, l'appel ne peut pas aboutir. Toute erreur
    // ici (réseau, jeton) doit se voir : sans ce garde, un échec de la requête
    // faisait échouer l'appel EN SILENCE — rien ne se passait au clic.
    final Map<String, dynamic>? creds;
    try {
      creds = await api.turnCredentials();
    } catch (e) {
      error = 'Impossible de démarrer l’appel : ${_humanize(e)}';
      notifyListeners();
      return;
    }
    if (creds == null) {
      error = 'Les appels ne sont pas disponibles sur ce serveur.';
      notifyListeners();
      return;
    }
    callIceServers = creds['iceServers'] as List<dynamic>?;
    final id = _uuidV4();
    callId = id;
    callPeerName = conv.peerUsername;
    _callConvId = conv.id;
    callEtat = CallEtat.sortant;
    // On sonne chez CHAQUE appareil du correspondant : il décroche où il veut.
    // Ne pas se limiter au premier évite l'écueil « je sonne un appareil mort »
    // (typiquement l'ancien, resté en session après une réinstallation).
    final cibles = conv.sessions.keys
        .where((d) => !conv.ownDeviceIds.contains(d))
        .toList();
    if (cibles.isEmpty) {
      _terminerAppel(trace: false);
      return;
    }
    _callCibles = cibles;
    // Appareil « pair » encore inconnu : il sera fixé par la première réponse.
    callPairDevice = null;
    notifyListeners();

    // Prépare le média et joint l'OFFRE à l'invitation. Best-effort : si le
    // micro est indisponible (permission, environnement sans audio), l'invite
    // part quand même — la signalisation fonctionne, seul le son manque.
    var data = <String, Object?>{'v': 1};
    if (activerMediaAppel) {
      try {
        final session = _creerSessionMedia(conv, id);
        data = await session.creerOffre();
        _callSession = session;
      } catch (e) {
        error = 'Micro indisponible : appel sans audio. (${_humanize(e)})';
      }
    }
    // Même offre chiffrée séparément pour chaque appareil : le premier qui
    // répond devient le pair, les autres seront raccrochés.
    for (final d in cibles) {
      await _envoyerSignalAppel(conv, d, id, 'invite', data);
    }
  }

  /// Accepte l'appel entrant.
  Future<void> accepterAppel() async {
    final device = callPairDevice;
    final id = callId;
    if (callEtat != CallEtat.entrant || device == null || id == null) return;
    final conv = _convPourDevice(device);
    if (conv == null) return;

    // Le correspondant a besoin de SES PROPRES identifiants TURN : en relais
    // forcé (iceTransportPolicy: relay), un pair sans serveur ICE ne peut créer
    // aucun candidat — l'appel resterait bloqué sur « Connexion… » alors que
    // l'appelant, lui, a déjà les siens. C'est pourquoi on les récupère ici,
    // côté appelé, avant de construire la session média.
    final api = _api;
    if (callIceServers == null && api != null) {
      try {
        final creds = await api.turnCredentials();
        callIceServers = creds?['iceServers'] as List<dynamic>?;
      } catch (_) {
        // Échec de récupération : on accepte quand même (l'état reste cohérent
        // et raccrochable), mais l'audio n'aboutira pas faute de relais.
      }
    }

    callEtat = CallEtat.connecte;
    callDepuis = DateTime.now();
    notifyListeners();

    // Répond au média avec la réponse WebRTC, si une offre a été reçue.
    var data = <String, Object?>{'v': 1};
    final offre = _offreEntrante;
    if (activerMediaAppel && offre != null && offre['sdp'] != null) {
      try {
        final session = _creerSessionMedia(conv, id);
        data = await session.repondre(offre);
        _callSession = session;
        // Session prête : on rejoue les candidats ICE arrivés en avance.
        for (final c in _iceEnAttente) {
          try {
            await session.ajouterCandidat(c);
          } catch (_) {}
        }
        _iceEnAttente.clear();
        _armerTimeoutMedia();
      } catch (e) {
        error = 'Micro indisponible : appel sans audio. (${_humanize(e)})';
      }
    }
    await _envoyerSignalAppel(conv, device, id, 'answer', data);
  }

  /// Arme le délai de garde du média : appelé quand l'appel devient « connecté »
  /// et qu'une session média existe. Si le média n'est pas établi dans le délai,
  /// on abandonne proprement plutôt que d'afficher « Connexion… » sans fin.
  void _armerTimeoutMedia() {
    _timeoutMedia?.cancel();
    _timeoutMedia = Timer(const Duration(seconds: 40), () {
      if (callEtat == CallEtat.aucun || callMediaConnecte) return;
      error = 'Appel impossible à connecter : le média ne s’est pas établi. '
          '(Réseau, relais TURN ?)';
      // Prévient le correspondant, puis termine (trace « Appel échoué »).
      final device = callPairDevice;
      final id = callId;
      if (device != null && id != null) {
        final conv = _convPourDevice(device);
        if (conv != null) {
          unawaited(_envoyerSignalAppel(conv, device, id, 'hangup', const {}));
        }
      }
      _terminerAppel();
    });
  }

  /// Refuse un appel entrant, ou raccroche un appel en cours / sortant.
  Future<void> raccrocher() async {
    final id = callId;
    final kind = callEtat == CallEtat.entrant ? 'decline' : 'hangup';
    if (id != null) {
      // Si un appareil pair est déjà choisi, on ne prévient que lui. Sinon
      // (appelant qui annule avant toute réponse), on prévient TOUS les
      // appareils sonnés, faute de quoi ils continueraient de sonner.
      final destinataires =
          callPairDevice != null ? [callPairDevice!] : _callCibles;
      for (final d in destinataires) {
        final conv = _convPourDevice(d);
        if (conv != null) {
          await _envoyerSignalAppel(conv, d, id, kind, const {});
        }
      }
    }
    _terminerAppel(refuse: kind == 'decline');
  }

  /// Termine l'appel courant et libère les ressources média.
  ///
  /// [trace] inscrit une ligne dans la conversation (durée, manqué, refusé…) —
  /// mis à false pour les abandons avant sonnerie et les remises à zéro de
  /// compte, où aucune trace n'a de sens. [refuse] distingue un refus explicite
  /// (par soi ou par le correspondant) d'une simple annulation.
  void _terminerAppel({bool trace = true, bool refuse = false}) {
    _timeoutMedia?.cancel();
    _timeoutMedia = null;
    if (trace) _tracerFinAppel(refuse);
    final s = _callSession;
    _callSession = null;
    if (s != null) unawaited(s.fermer());
    callEtat = CallEtat.aucun;
    callId = null;
    callPeerName = null;
    callPairDevice = null;
    callIceServers = null;
    _offreEntrante = null;
    _iceEnAttente.clear();
    _iceLocalEnAttente.clear();
    _callCibles = [];
    callMuet = false;
    callMediaConnecte = false;
    _mediaAConnecte = false;
    _callConvId = null;
    callDepuis = null;
    notifyListeners();
  }

  /// Ajoute la trace de fin d'appel dans la conversation concernée.
  void _tracerFinAppel(bool refuse) {
    final convId = _callConvId;
    if (convId == null) return;
    final conv = _conversations[convId];
    if (conv == null) return;
    final depuis = callDepuis;
    final String texte;
    if (_mediaAConnecte && depuis != null) {
      // Appel réellement établi : durée.
      texte = 'Appel · ${_dureeAppel(DateTime.now().difference(depuis))}';
    } else if (refuse) {
      texte = 'Appel refusé';
    } else if (callEtat == CallEtat.entrant) {
      texte = 'Appel manqué';
    } else if (callEtat == CallEtat.sortant) {
      texte = 'Appel annulé';
    } else if (callEtat == CallEtat.connecte) {
      // Accepté des deux côtés, mais le média ne s'est jamais établi.
      texte = 'Appel échoué';
    } else {
      return;
    }
    conv.messages.add(ChatMessage(
      text: texte,
      mine: false,
      at: DateTime.now(),
      systeme: true,
    ));
    unawaited(_saveHistory(conv));
  }

  /// Formate une durée d'appel en `M:SS` (ou `H:MM:SS` au-delà de l'heure).
  static String _dureeAppel(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
    return '$m:$ss';
  }

  /// Chiffre une charge de signalisation avec la session du destinataire et
  /// l'envoie par le WebSocket, opaque pour le serveur.
  Future<void> _envoyerSignalAppel(Conversation conv, String device,
      String id, String kind, Map<String, Object?> data) async {
    final gateway = _gateway;
    final socket = _socket;
    final sessionId = conv.sessions[device];
    if (gateway == null || socket == null || sessionId == null) return;
    try {
      final enc = await gateway.encrypt(
          sessionId, Uint8List.fromList(utf8.encode(jsonEncode(data))));
      final handshake = _pendingHandshakes['${conv.id}-$device'];
      final entete = Envelope.packHeader(enc.header, handshake);
      // payload = [longueur d'en-tête sur 2 octets][en-tête ratchet][chiffré].
      // Tout est DANS le payload opaque : le serveur ne relaie que ce champ, il
      // ne faut donc rien mettre à côté qu'il perdrait en route.
      final hlen = entete.length;
      final payload = base64Encode(Uint8List.fromList([
        (hlen >> 8) & 0xff,
        hlen & 0xff,
        ...entete,
        ...enc.ciphertext,
      ]));
      socket.add(jsonEncode({
        'type': 'call.signal',
        'to': [device],
        'callId': id,
        'kind': kind,
        'payload': payload,
      }));
    } catch (_) {
      // un signal d'appel raté n'a pas à interrompre le reste
    }
  }

  /// Reçoit un signal d'appel relayé, le déchiffre, et fait avancer l'état.
  Future<void> _recevoirSignalAppel(Map<String, dynamic> frame) async {
    final gateway = _gateway;
    final from = frame['from'] as String?;
    final kind = frame['kind'] as String?;
    final id = frame['callId'] as String?;
    if (gateway == null || from == null || kind == null || id == null) return;

    // Fin d'appel : pas besoin de déchiffrer, seul l'appel courant est concerné.
    if (kind == 'hangup' || kind == 'decline') {
      if (callId == id) _terminerAppel(refuse: kind == 'decline');
      return;
    }

    final conv = _convPourDevice(from);
    if (conv == null) return;

    // Déchiffre le SDP/ICE. Le déchiffrement PROUVE l'authenticité : un faux
    // signal forgé par le serveur échouerait ici, faute de la session.
    Map<String, dynamic> data;
    try {
      final brut = base64Decode(frame['payload'] as String);
      final hlen = (brut[0] << 8) | brut[1];
      final entete = Uint8List.sublistView(brut, 2, 2 + hlen);
      final chiffre = Uint8List.sublistView(brut, 2 + hlen);
      final unpacked = Envelope.unpackHeader(entete);
      if (unpacked.handshake != null && !conv.sessions.containsKey(from)) {
        conv.sessions[from] = await gateway.acceptSession(unpacked.handshake!);
      }
      final sessionId = conv.sessions[from];
      if (sessionId == null) return;
      final clair = await gateway.decrypt(sessionId, unpacked.ratchetHeader, chiffre);
      data = jsonDecode(utf8.decode(clair)) as Map<String, dynamic>;
    } catch (_) {
      return; // signal illisible ou forgé : ignoré
    }

    switch (kind) {
      case 'invite':
        // Déjà en appel : on refuse (occupé). Sinon on fait sonner.
        if (enAppel) {
          await _envoyerSignalAppel(conv, from, id, 'decline', const {});
          return;
        }
        // On retient l'offre WebRTC (si présente) jusqu'à l'acceptation.
        _offreEntrante = data;
        callId = id;
        callPairDevice = from;
        callPeerName = conv.peerUsername;
        _callConvId = conv.id;
        callEtat = CallEtat.entrant;
        notifyListeners();
      case 'answer':
        if (callId == id && callEtat == CallEtat.sortant) {
          // Premier appareil à répondre : il devient le pair. On l'enregistre
          // AVANT tout, pour router candidats et raccrochés au bon endroit.
          callPairDevice = from;
          callEtat = CallEtat.connecte;
          callDepuis = DateTime.now();
          notifyListeners();
          // L'appelant applique la réponse média de l'appelé.
          if (data['sdp'] != null) {
            try {
              await _callSession?.appliquerReponse(data);
            } catch (_) {}
          }
          // Envoie à l'appareil répondant les candidats ICE mis de côté avant
          // qu'on sache lequel décrocherait.
          for (final c in _iceLocalEnAttente) {
            unawaited(_envoyerSignalAppel(conv, from, id, 'ice', c));
          }
          _iceLocalEnAttente.clear();
          // Fait taire les AUTRES appareils sonnés du correspondant.
          for (final d in _callCibles) {
            if (d != from) {
              unawaited(_envoyerSignalAppel(conv, d, id, 'hangup', const {}));
            }
          }
          // Média en négociation : on arme le délai de garde.
          if (_callSession != null) _armerTimeoutMedia();
        }
      case 'ice':
        // Candidat ICE du correspondant. Si notre session n'existe pas encore
        // (invitation pas encore acceptée), on le met de côté au lieu de le
        // perdre — sinon la connexion échoue faute de candidat relais.
        if (callId != id || data['candidate'] == null) break;
        // Un appareil pair déjà choisi : on ignore les candidats venus d'un
        // autre appareil (cas multi-appareils où l'on a sonné partout).
        if (callPairDevice != null && from != callPairDevice) break;
        if (_callSession == null) {
          _iceEnAttente.add(data);
        } else {
          try {
            await _callSession!.ajouterCandidat(data);
          } catch (_) {}
        }
    }
  }

  /// Conversation directe possédant une session avec cet appareil.
  Conversation? _convPourDevice(String device) {
    for (final c in _conversations.values) {
      if (!c.isGroup && !c.isChannel && c.sessions.containsKey(device)) return c;
    }
    return null;
  }

  Uint8List _octetsAleatoires(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  /// Analyse un lien `ziacrypte://canal/<id>#<secret>.<nom>`.
  (String, Uint8List, String)? _analyserLien(String lien) {
    if (!lien.startsWith(_schemeCanal)) return null;
    final reste = lien.substring(_schemeCanal.length);
    final diese = reste.indexOf('#');
    if (diese <= 0) return null;
    final id = reste.substring(0, diese);
    final frag = reste.substring(diese + 1);
    final point = frag.indexOf('.');
    if (point <= 0) return null;
    try {
      final secret = base64Url.decode(frag.substring(0, point));
      final nom = utf8.decode(base64Url.decode(frag.substring(point + 1)));
      if (secret.length != 32) return null;
      return (id, secret, nom);
    } catch (_) {
      return null;
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

  /// Réaction emoji à un message, par son identifiant. Voyage chiffrée, comme
  /// l'édition ; le serveur ne voit qu'un blob. `on` distingue pose et retrait.
  static const _prefixeReaction = '__zia_react__:';

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

  /// Réglage de la durée de vie des messages.
  ///
  /// Passe par le canal chiffré : le serveur ne doit pas apprendre qu'une
  /// conversation est éphémère, ce qui désignerait justement celles qui
  /// méritent son attention.
  static const _prefixeTtl = '__zia_ttl__:';

  /// Jeton de remise, annoncé aux correspondants.
  ///
  /// Il ne circule QUE dans le canal chiffré, donc uniquement vers des
  /// appareils avec qui une session existe déjà. Le détenir prouve qu'on a été
  /// en contact — c'est exactement l'autorisation qu'on veut donner pour un
  /// dépôt anonyme, sans révéler d'identité au serveur.
  static const _prefixeJeton = '__zia_dtok__:';

  /// Distribution d'une clé d'expéditeur de groupe (phase 37).
  static const _prefixeCleGroupe = '__zia_skey__:';

  /// Statut personnel (« Disponible », « En réunion »…).
  ///
  /// ## Pourquoi il ne va pas dans la table des comptes
  ///
  /// C'est le chemin qu'ont pris toutes les autres messageries : une colonne
  /// `status` à côté du pseudo, lisible par l'hébergeur. Une phrase écrite
  /// par soi-même sur soi-même en dit souvent plus long qu'un carnet
  /// d'adresses — « à l'hôpital jusqu'à vendredi », « nouveau numéro », un
  /// prénom, une ville. Elle suit donc le chemin de la photo de profil : le
  /// canal chiffré, et rien d'autre.
  ///
  /// Conséquence assumée, la même que pour l'avatar : seules les personnes
  /// avec qui une conversation est ouverte voient le statut. Un annuaire
  /// consultable par tous supposerait de le livrer au serveur.
  static const _prefixeStatut = '__zia_status__:';

  /// Un texte est-il un message de CONTRÔLE plutôt qu'un message à afficher ?
  ///
  /// Exposé aux tests parce que l'oubli d'un préfixe dans cette liste est un
  /// défaut silencieux au pire endroit : le message de contrôle brut
  /// s'afficherait tel quel dans la conversation du correspondant — sous les
  /// yeux de tout le monde, sans qu'aucune exception ne soit levée.
  @visibleForTesting
  static bool estControle(String t) => _estControle(t);

  /// Préfixes de contrôle, pour que les tests puissent les vérifier tous sans
  /// avoir à les recopier — une liste recopiée dérive.
  @visibleForTesting
  static const prefixesControle = <String>[
    _prefixeEdit,
    _prefixeSuppr,
    _prefixeLu,
    _prefixeAvatar,
    _prefixeTtl,
    // Ces deux-là manquaient : _estControle les connaissait, mais pas cette
    // liste — le test qui parcourt les préfixes ne les couvrait donc pas.
    _prefixeJeton,
    _prefixeCleGroupe,
    _prefixeStatut,
    _prefixeReaction,
  ];

  /// Encode l'annonce d'une photo de profil. Exposé aux tests : c'est la
  /// sérialisation qui casse en silence, pas l'envoi.
  @visibleForTesting
  static String encoderAvatar(AttachmentRef ref) =>
      '$_prefixeAvatar${jsonEncode(ref.toJson())}';

  /// Décode une annonce de photo de profil.
  @visibleForTesting
  static AttachmentRef decoderAvatar(String charge) => AttachmentRef.fromJson(
      (jsonDecode(charge.substring(_prefixeAvatar.length)) as Map)
          .cast<String, Object?>());

  static bool _estControle(String t) =>
      t.startsWith(_prefixeEdit) ||
      t.startsWith(_prefixeSuppr) ||
      t.startsWith(_prefixeLu) ||
      t.startsWith(_prefixeAvatar) ||
      t.startsWith(_prefixeTtl) ||
      t.startsWith(_prefixeJeton) ||
      t.startsWith(_prefixeCleGroupe) ||
      t.startsWith(_prefixeStatut) ||
      t.startsWith(_prefixeReaction);

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

  /// Statuts personnels connus, par identifiant de compte — le sien compris.
  ///
  /// Dans le coffre chiffré du moteur, pas dans les préférences : c'est du
  /// contenu reçu de correspondants, au même titre qu'un message, et les
  /// préférences sont un simple fichier JSON en clair.
  final Map<String, String> statuts = {};
  static const _cleCoffreStatuts = 'statuts_contacts';

  /// Longueur maximale d'un statut.
  ///
  /// Une phrase, pas un billet : au-delà, l'affichage tronque de toute façon,
  /// et un champ long invite à y mettre ce qui devrait rester dans un message.
  static const statutMax = 80;

  /// Statut d'un compte, ou null s'il n'en a pas annoncé.
  String? statutDe(String? user) {
    if (user == null) return null;
    final s = statuts[user];
    return (s == null || s.isEmpty) ? null : s;
  }

  /// Définit son statut et l'annonce à ses correspondants.
  ///
  /// Une chaîne vide efface le statut : l'annonce part quand même, sinon les
  /// correspondants continueraient d'afficher l'ancien indéfiniment.
  Future<void> definirStatut(String texte) async {
    final moi = userId;
    if (moi == null) return;
    final propre = texte.trim().replaceAll(RegExp(r'\s+'), ' ');
    final borne = propre.length > statutMax
        ? propre.substring(0, statutMax)
        : propre;
    if (borne == (statuts[moi] ?? '')) return;

    if (borne.isEmpty) {
      statuts.remove(moi);
    } else {
      statuts[moi] = borne;
    }
    await _sauverStatuts();
    notifyListeners();

    final charge = '$_prefixeStatut${jsonEncode({'t': borne})}';
    for (final conv in _conversations.values) {
      await _diffuserControle(conv, charge);
    }
  }

  Future<void> _chargerStatuts() async {
    final gateway = _gateway;
    if (gateway == null) return;
    try {
      final brut = await gateway.vaultRead(_cleCoffreStatuts);
      if (brut == null || brut.isEmpty) return;
      final json = jsonDecode(utf8.decode(brut)) as Map<String, dynamic>;
      statuts.clear();
      json.forEach((user, texte) {
        if (texte is String && texte.isNotEmpty) statuts[user] = texte;
      });
      notifyListeners();
    } catch (_) {
      // Registre illisible : on repart à vide. Les statuts réapparaîtront à la
      // prochaine annonce, comme les avatars.
      statuts.clear();
    }
  }

  Future<void> _sauverStatuts() async {
    final gateway = _gateway;
    if (gateway == null) return;
    await gateway.vaultWrite(_cleCoffreStatuts,
        Uint8List.fromList(utf8.encode(jsonEncode(statuts))));
  }

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

  /// Garantit que NOTRE clé d'expéditeur est en place pour ce groupe et que
  /// tous les appareils courants l'ont reçue.
  ///
  /// Renvoie false si le chemin groupé n'est pas utilisable — l'appelant
  /// retombe alors sur l'envoi pair-à-pair, qui fonctionne toujours. Une
  /// dégradation vaut mieux qu'un message que personne ne peut lire.
  ///
  /// ## Pourquoi on fait tourner la clé à toute entrée ET toute sortie
  ///
  /// À la sortie, c'est évident : sans rotation, un partant continuerait de
  /// déchiffrer la suite. À l'ENTRÉE aussi, et c'est moins intuitif : la
  /// distribution contient la chaîne à son origine, donc un arrivant pourrait
  /// dériver les clés de TOUS les messages précédents. Repartir d'une chaîne
  /// neuve est ce qui garantit qu'on ne lit pas l'avant de son arrivée.
  Future<bool> _assurerCleGroupe(Conversation conv) async {
    final gateway = _gateway;
    if (gateway == null || !conv.isGroup) return false;

    final cibles = conv.sessions.keys.toSet();
    if (cibles.isEmpty) return false;

    final servis = _cleGroupeDistribuee[conv.id];
    // Composition inchangée : la clé en place reste valable.
    if (servis != null &&
        servis.length == cibles.length &&
        servis.containsAll(cibles)) {
      return true;
    }

    final Uint8List distribution;
    try {
      distribution = await gateway.engine.senderKeyCreate(conv.id);
    } catch (_) {
      return false;
    }

    final charge =
        '$_prefixeCleGroupe${jsonEncode({'k': base64Encode(distribution)})}';
    final ok = <String>{};
    for (final device in cibles) {
      try {
        await _sendToDevice(conv, device, charge);
        ok.add(device);
      } catch (_) {
        // Appareil injoignable : voir juste en dessous.
      }
    }

    // Distribution INCOMPLÈTE : on ne bascule pas. Chiffrer une seule fois
    // alors qu'un membre n'a pas la clé lui rendrait le message illisible
    // sans qu'il puisse rien y faire.
    if (ok.length != cibles.length) {
      _cleGroupeDistribuee.remove(conv.id);
      return false;
    }
    _cleGroupeDistribuee[conv.id] = ok;
    return true;
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
      Conversation conv, String texte, bool deMoi,
      {String? expediteurDevice, String? reacteurUserId}) async {
    try {
      // Réaction emoji : posée ou retirée par n'importe qui, pas seulement
      // l'auteur du message. On identifie le réacteur — moi, ou l'expéditeur du
      // contrôle — pour compter et savoir qui a réagi.
      if (texte.startsWith(_prefixeReaction)) {
        final json = jsonDecode(texte.substring(_prefixeReaction.length))
            as Map<String, dynamic>;
        final cible = json['id'] as String?;
        final emoji = json['e'] as String?;
        final pose = json['on'] as bool? ?? true;
        final qui = deMoi ? userId : reacteurUserId;
        if (cible == null || emoji == null || qui == null) return;
        for (final m in conv.messages) {
          if (m.id != cible) continue;
          final set = m.reactions.putIfAbsent(emoji, () => <String>{});
          if (pose) {
            set.add(qui);
          } else {
            set.remove(qui);
            if (set.isEmpty) m.reactions.remove(emoji);
          }
          await _saveHistory(conv);
          notifyListeners();
          return;
        }
        return;
      }
      // Distribution d'une clé d'expéditeur de groupe.
      //
      // L'émetteur est celui du TRANSPORT — la session pair-à-pair qui a porté
      // ce contrôle — jamais un identifiant annoncé dans la charge. Sinon un
      // membre du groupe pourrait enregistrer une clé au nom d'un autre et
      // signer des messages en se faisant passer pour lui.
      if (texte.startsWith(_prefixeCleGroupe)) {
        if (expediteurDevice == null) return;
        final json = jsonDecode(texte.substring(_prefixeCleGroupe.length))
            as Map<String, dynamic>;
        final k = json['k'] as String?;
        if (k == null) return;
        try {
          await _gateway?.engine
              .senderKeyProcess(conv.id, expediteurDevice, base64Decode(k));
        } catch (_) {
          // Distribution illisible : ses messages resteront indéchiffrables
          // jusqu'à la prochaine, ce qui est préférable à un état incohérent.
        }
        return;
      }

      // Jeton de remise d'un correspondant : c'est ce qui permet de lui
      // écrire ensuite SANS que le serveur sache que c'est nous.
      if (texte.startsWith(_prefixeJeton)) {
        final json = jsonDecode(texte.substring(_prefixeJeton.length))
            as Map<String, dynamic>;
        final appareil = json['d'] as String?;
        final jeton = json['t'] as String?;
        if (appareil != null && jeton != null) {
          jetonsRemise[appareil] = jeton;
          await _sauverJetons();
        }
        return;
      }

      // Durée de vie modifiée par l'un ou l'autre.
      if (texte.startsWith(_prefixeTtl)) {
        final json = jsonDecode(texte.substring(_prefixeTtl.length))
            as Map<String, dynamic>;
        final secondes = (json['s'] as num?)?.toInt() ?? 0;
        if (secondes != conv.ttlSecondes) {
          conv.ttlSecondes = secondes;
          // Annoncé dans le fil, jamais en silence : quelqu'un qui rallonge la
          // durée à l'insu de l'autre garderait des messages que celui-ci
          // croit condamnés. Un réglage partagé doit être visible des deux.
          _annoncerTtl(conv, secondes, deMoi);
          await _saveHistory(conv);
          notifyListeners();
        }
        return;
      }

      // Statut personnel annoncé par un correspondant (ou par un de mes
      // propres appareils, pour que le mien me suive d'un appareil à l'autre).
      if (texte.startsWith(_prefixeStatut)) {
        final json = jsonDecode(texte.substring(_prefixeStatut.length))
            as Map<String, dynamic>;
        final valeur = (json['t'] as String? ?? '').trim();
        final proprietaire = deMoi ? userId : conv.peerUserId;
        if (proprietaire != null) {
          // Borné à la réception AUSSI : la longueur envoyée est décidée par
          // l'appareil d'en face, dont on ne contrôle pas le code.
          final borne = valeur.length > statutMax
              ? valeur.substring(0, statutMax)
              : valeur;
          if (borne.isEmpty) {
            statuts.remove(proprietaire);
          } else {
            statuts[proprietaire] = borne;
          }
          await _sauverStatuts();
          notifyListeners();
        }
        return;
      }

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
    final entete = Envelope.packHeader(enc.header, handshake);

    // Chemin SCELLÉ quand il est possible : le serveur n'apprend alors ni qui
    // écrit, ni dans quelle conversation. Il faut pour cela connaître le jeton
    // de remise du destinataire ET sa clé d'identité — donc avoir déjà été en
    // contact. À défaut on retombe sur le chemin authentifié, qui fonctionne
    // toujours : une dégradation vaut mieux qu'un message non remis.
    final jeton = jetonsRemise[device];
    final identite = _pinning?.forDevice(device)?.identityKey;
    if (jeton != null && identite != null) {
      try {
        final interieur = utf8.encode(jsonEncode({
          // L'expéditeur voyage À L'INTÉRIEUR : le destinataire doit savoir qui
          // lui parle, c'est le serveur seul qu'on aveugle.
          'sd': deviceId,
          'su': userId,
          'cv': conv.id,
          'h': base64Encode(entete),
          'c': base64Encode(enc.ciphertext),
        }));
        final scelle = await gateway.engine
            .sealedSeal(identite, Uint8List.fromList(interieur));
        await api.deposerScelle(
          deliveryToken: jeton,
          recipientDeviceId: device,
          clientMessageId: _uuidV4(),
          sealedB64: base64Encode(scelle),
        );
        _pendingHandshakes.remove('${conv.id}-$device');
        await _saveSessions(conv);
        return;
      } catch (_) {
        // Un échec du chemin scellé ne doit pas faire perdre le message : on
        // reprend par le chemin authentifié ci-dessous. Le prix est que le
        // serveur voit ce message-là — mais il arrive.
      }
    }

    await api.sendMessage(
      conversationId: conv.id,
      recipientDeviceId: device,
      clientMessageId: _uuidV4(),
      headerB64: base64Encode(entete),
      ciphertextB64: base64Encode(enc.ciphertext),
    );
    _pendingHandshakes.remove('${conv.id}-$device');
    await _saveSessions(conv);
  }

  /// Ouvre une enveloppe scellée et la remet à la forme d'un message ordinaire.
  ///
  /// Renvoie null si l'enveloppe ne nous est pas destinée ou a été altérée —
  /// les deux sont indiscernables, et c'est correct : l'authentification ne dit
  /// pas laquelle des deux causes s'applique. On l'ignore en silence plutôt que
  /// d'afficher une alerte, un tiers pouvant déposer n'importe quoi sur cette
  /// route sans s'authentifier.
  Future<Map<String, dynamic>?> _ouvrirScelle(Map<String, dynamic> brut) async {
    final gateway = _gateway;
    if (gateway == null) return null;
    try {
      final scelle = base64Decode(brut['ciphertext'] as String);
      final clair = await gateway.engine.sealedOpen(scelle);
      final json = jsonDecode(utf8.decode(clair)) as Map<String, dynamic>;
      return {
        ...brut,
        'senderDeviceId': json['sd'],
        'senderUserId': json['su'],
        'conversationId': json['cv'],
        'header': json['h'],
        'ciphertext': json['c'],
      };
    } catch (_) {
      return null;
    }
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

  /// Emoji proposés à la réaction. Peu nombreux à dessein : un clavier emoji
  /// complet transforme un geste d'un tap en une recherche.
  static const reactionsProposees = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  /// Pose ou retire une réaction sur un message (bascule).
  ///
  /// Appliquée tout de suite localement, puis diffusée dans le canal chiffré.
  /// Indisponible sur un canal : un abonné n'a pas de session retour vers
  /// l'admin, une réaction n'aurait nulle part où aller.
  Future<void> reagir(ChatMessage m, String emoji) async {
    final conv = active;
    final moi = userId;
    if (conv == null || moi == null || m.id == null) return;
    if (conv.isChannel) return;

    final set = m.reactions.putIfAbsent(emoji, () => <String>{});
    final pose = !set.contains(moi); // pas encore réagi → on pose
    if (pose) {
      set.add(moi);
    } else {
      set.remove(moi);
      if (set.isEmpty) m.reactions.remove(emoji);
    }
    notifyListeners();
    await _saveHistory(conv);

    await _diffuserControle(
      conv,
      '$_prefixeReaction${jsonEncode({'id': m.id, 'e': emoji, 'on': pose})}',
    );
  }

  /// Réémet un message dont l'envoi avait totalement échoué. On retire la bulle
  /// ratée et on relance l'envoi de son contenu : en cas de nouveau succès,
  /// elle réapparaît en état normal ; en cas de nouvel échec, de nouveau ratée.
  Future<void> renvoyer(ChatMessage m) async {
    if (!m.sendFailed) return;
    Conversation? conv;
    for (final c in _conversations.values) {
      if (c.messages.contains(m)) {
        conv = c;
        break;
      }
    }
    if (conv == null) return;
    conv.messages.remove(m);
    activeConversationId = conv.id; // _sendPayload agit sur la conversation active
    notifyListeners();
    await _sendPayload(m.text, m.attachment);
  }

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

      // Chemin GROUPÉ : un seul chiffrement pour tout le groupe (clé
      // d'expéditeur). Tenté d'abord ; en cas d'échec on retombe sur la boucle
      // pair-à-pair ci-dessous, qui fonctionne toujours.
      if (conv.isGroup && await _assurerCleGroupe(conv)) {
        final cibles = conv.sessions.keys.toList();
        try {
          final chiffre = await gateway.engine.senderKeyEncrypt(conv.id, clearText);
          final clientMessageId = _uuidV4();
          await api.sendGroupMessage(
            conversationId: conv.id,
            clientMessageId: clientMessageId,
            recipientDeviceIds: cibles,
            headerB64: base64Encode(Envelope.packGroupHeader()),
            ciphertextB64: base64Encode(chiffre),
          );
          receiptIds.add(clientMessageId);
          delivered = cibles.length;
        } catch (e) {
          // On repart de zéro sur le chemin pair-à-pair.
          delivered = 0;
          error = 'Envoi groupé impossible, repli : ${_humanize(e)}';
        }
      }

      // Chaque appareil a sa propre session : le message est chiffré autant de
      // fois qu'il y a de destinataires. Le serveur ne voit que des blobs.
      for (final device in delivered > 0 ? const <String>[] : conv.sessions.keys.toList()) {
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
      // Échec total : aucun appareil n'a reçu. On n'abandonne plus en silence
      // — le message disparaissait alors du fil, laissant croire qu'il était
      // parti. Il reste affiché, marqué en échec, avec un « réessayer ».
      final echec = delivered == 0;

      // Une annonce interne (nom de groupe) n'est pas un message : elle ne
      // s'affiche pas, même ratée — elle sera renvoyée par le mécanisme normal.
      if (_estAnnonceInterne(text)) {
        if (replyingTo != null) replyingTo = null;
        notifyListeners();
        return;
      }

      if (echec) error = null; // le marqueur en ligne suffit, pas de bandeau en plus
      conv.messages.add(ChatMessage(
        text: text,
        mine: true,
        at: DateTime.now(),
        expiresAt: _echeance(conv),
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
        sendFailed: echec,
      ));
      if (replyingTo != null) {
        replyingTo = null;
      }
      conv.lastActivity = DateTime.now();
      notifyListeners();

      // En échec, on ne persiste rien : au redémarrage on repart propre, sans
      // promettre un renvoi qu'on ne relancerait pas. Le ratchet a avancé en
      // mémoire, mais le pair n'a rien reçu — les clés sautées couvriront
      // l'écart au prochain envoi réussi.
      if (echec) return;

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
    // Bourré à un palier fixe : c'est le SEUL point de passage de tout ce qui
    // est chiffré — messages, contrôles, distributions de clé de groupe — donc
    // le seul endroit où la taille peut être uniformisée une fois pour toutes.
    // Voir padding.dart pour ce que la taille révélait.
    return bourrer(utf8.encode(jsonEncode({
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
    final bytes = await _lireFichier(filePath, 'Fichier introuvable');
    if (bytes == null) return;
    final fileName = filePath.split(Platform.pathSeparator).last;
    await _uploadAndSend(bytes, fileName, label: '📎 $fileName');
  }

  /// Envoie un message vocal : mêmes chiffrement et transport qu'une pièce
  /// jointe (chemin déjà éprouvé), avec une durée qui voyage dans le message
  /// chiffré. L'octet audio ne touche le réseau que chiffré.
  Future<void> sendVoiceMessage(String filePath, int durationMs) async {
    final bytes = await _lireFichier(
        filePath, 'Enregistrement vocal introuvable — micro refusé ?');
    if (bytes == null) return;
    final fileName = filePath.split(Platform.pathSeparator).last;
    await _uploadAndSend(bytes, fileName,
        label: '🎤 Message vocal', voiceDurationMs: durationMs);
  }

  /// Lit un fichier local, ou signale une erreur lisible et renvoie null.
  ///
  /// Ces lectures se faisaient à nu, HORS de tout try/catch : un fichier absent
  /// — un enregistrement vocal qui n'a pas abouti, une pièce jointe déplacée —
  /// remontait en FileSystemException non capturée et affichait l'écran
  /// d'erreur rouge. Mieux vaut un message et un envoi annulé.
  Future<Uint8List?> _lireFichier(String filePath, String messageSiAbsent) async {
    try {
      final f = File(filePath);
      if (!await f.exists()) {
        _setBusy(false, err: messageSiAbsent);
        return null;
      }
      return await f.readAsBytes();
    } catch (e) {
      _setBusy(false, err: '$messageSiAbsent (${_humanize(e)})');
      return null;
    }
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
      _rafraichirAbonnementPresence();
      _balayerExpires();
      // Jeton de remise en attente : diffusé dès qu'une session existe. Passé
      // par la boucle plutôt qu'appelé au milieu de l'ouverture des sessions,
      // où la session n'est pas encore enregistrée.
      _viderFileJeton();
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

      // Présence : on déclare d'abord ce que l'on accepte de montrer, puis on
      // demande ce que l'on veut voir. L'ordre importe peu au serveur, mais il
      // dit l'intention — rien n'est observé sans que le sien soit tranché.
      _declarerPresence();
      _abonnementPresence = {};
      _rafraichirAbonnementPresence();

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
    // Sans canal, on n'apprendra plus qu'un correspondant s'est déconnecté :
    // mieux vaut ne rien afficher qu'afficher une présence périmée.
    _enLigne.clear();
    _abonnementPresence = {};
    statuts.clear();
    notifyListeners();
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (_api != null && _socket == null) _connectRealtime();
    });
  }

  /// Traite un signal éphémère reçu (indicateur d'écriture, présence).
  void _traiterSignalEphemere(String brut) {
    try {
      final json = jsonDecode(brut) as Map<String, dynamic>;
      final type = json['type'] as String?;

      if (type == 'call.signal') {
        unawaited(_recevoirSignalAppel(json));
        return;
      }

      if (type == 'presence.snapshot') {
        // L'instantané fait autorité : il remplace ce qu'on croyait savoir,
        // sinon un appareil déconnecté pendant une coupure resterait allumé.
        _enLigne
          ..clear()
          ..addAll((json['online'] as List<dynamic>? ?? const [])
              .whereType<String>());
        notifyListeners();
        return;
      }
      if (type == 'presence') {
        final device = json['device'] as String?;
        if (device == null) return;
        if (json['state'] == 'online') {
          _enLigne.add(device);
        } else {
          _enLigne.remove(device);
        }
        notifyListeners();
        return;
      }

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
      for (final brut in incoming) {
        // Message SCELLÉ : le serveur ne sait pas qui l'a déposé. On ouvre
        // l'enveloppe pour retrouver l'expéditeur, la conversation et
        // l'en-tête, puis on reprend exactement le même chemin qu'un message
        // ordinaire — le reste du traitement n'a pas à savoir lequel des deux
        // transports a été emprunté.
        final m = brut['sealed'] == true
            ? await _ouvrirScelle(brut)
            : brut;
        if (m == null) continue; // enveloppe illisible : déjà signalée

        // Post de CANAL : reconnu à channelId, routé vers la clé du canal. Il
        // ne passe pas par la résolution de conversation pair-à-pair.
        if (m['channelId'] != null) {
          final c = await _recevoirCanal(m);
          if (c != null) touched.add(c);
          continue;
        }

        final conv = await _resolveConversation(m);
        final sender = m['senderDeviceId'] as String;
        final enteteBrute = base64Decode(m['header'] as String);
        Uint8List? clair;

        // Message de GROUPE chiffré une seule fois : il ne passe par aucune
        // session pair-à-pair. On le déchiffre avec la chaîne de l'appareil
        // émetteur ; sa signature est vérifiée côté moteur AVANT tout
        // déchiffrement, ce qui empêche un membre d'écrire au nom d'un autre.
        if (Envelope.estGroupe(enteteBrute)) {
          try {
            clair = await gateway.engine.senderKeyDecrypt(
                conv.id, sender, base64Decode(m['ciphertext'] as String));
          } catch (_) {
            // Clé d'expéditeur pas encore reçue, ou message antérieur à la
            // dernière rotation : indéchiffrable, et le rester est correct.
            continue;
          }
        } else {

          final unpacked = Envelope.unpackHeader(enteteBrute);

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
            try {
              conv.sessions[sender] =
                  await gateway.acceptSession(unpacked.handshake!);
            } catch (_) {
              continue; // poignée de main invalide/rejouée : on saute ce message
            }
            conv.targetDeviceIds.add(sender);
            // Côté répondeur aussi : c'est ici qu'on découvre l'appareil d'en
            // face, donc ici qu'on peut commencer à observer sa présence.
            _rafraichirAbonnementPresence();
          }
          final sessionId = conv.sessions[sender];
          if (sessionId == null) continue;

          try {
            clair = await gateway.decrypt(
              sessionId,
              unpacked.ratchetHeader,
              base64Decode(m['ciphertext'] as String),
            );
          } catch (_) {
            // Message indéchiffrable : session désynchronisée (typiquement après
            // qu'un côté a réinstallé), doublon, ou en-tête altéré. On saute ce
            // message plutôt que d'abandonner TOUT le lot et d'afficher une
            // « erreur cryptographique ». La conversation se rétablit dès que
            // l'expéditeur relance une poignée de main. Comme pour les messages
            // de groupe indéchiffrables, rester silencieux est le bon choix.
            continue;
          }
        }
        final plain = clair;

        // Un message émis par un autre de mes appareils est un message que
        // j'ai écrit : il s'affiche comme tel plutôt que comme reçu.
        final fromMyself = (m['senderUsername'] as String?) == username;
        final payload = _decodePayload(plain);

        // Message de contrôle : édition ou suppression d'un message existant.
        if (_estControle(payload.text)) {
          await _appliquerControle(conv, payload.text, fromMyself,
              expediteurDevice: sender,
              reacteurUserId: m['senderUserId'] as String?);
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
          // On RETIENT toujours le pseudo de l'auteur d'un message reçu ;
          // l'affichage, lui, est réservé aux groupes (côté UI). Le stocker
          // sans condition évite une course : le drapeau `isGroup` peut n'être
          // posé qu'à l'annonce de nom, parfois APRÈS le premier message.
          author: fromMyself ? null : (m['senderUsername'] as String?),
          // L'échéance est calculée chez CHAQUE partie à partir du réglage
          // partagé, plutôt que transportée par l'expéditeur : sinon celui-ci
          // pourrait annoncer une échéance longue tout en affichant courte
          // chez lui, et le destinataire garderait un message qu'il croit
          // condamné.
          expiresAt: _echeance(conv),
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
        // Non-lu : un message reçu dans une conversation qu'on ne regarde pas.
        // Ses propres messages (rétro-remis d'un autre appareil) ne comptent pas.
        if (!fromMyself && conv.id != activeConversationId) conv.unread++;
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

/// État d'un appel, du point de vue local.
enum CallEtat {
  /// Aucun appel.
  aucun,

  /// On appelle et ça sonne chez le correspondant.
  sortant,

  /// Le correspondant nous appelle et ça sonne ici.
  entrant,

  /// Appel accepté des deux côtés (média établi en phase 3b).
  connecte,
}
