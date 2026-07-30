import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Client REST du serveur ZiaCrypte.
///
/// Ne transporte que des données déjà chiffrées par le moteur natif : ce client
/// ne fait aucune cryptographie, il sérialise et route.
class ApiClient {
  ApiClient(this.baseUrl)
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
        )) {
    // Rafraîchissement automatique du jeton d'accès sur 401. Sans lui, le jeton
    // (15 min) expirait et l'application paraissait « déconnectée » : toutes
    // les requêtes échouaient alors qu'une session valide existait encore.
    _dio.interceptors.add(InterceptorsWrapper(onError: _surErreur));
  }

  /// Racine de l'API, réutilisée pour construire l'URL du WebSocket.
  final String baseUrl;
  final Dio _dio;
  String? _accessToken;

  /// Jeton de renouvellement (longue durée). Permet de reprendre un nouveau
  /// jeton d'accès sans redemander le mot de passe. En mémoire seulement.
  String? refreshToken;

  /// Appelé après un renouvellement réussi des jetons : laisse le reste de
  /// l'application réagir (reconnecter le WebSocket avec le jeton frais).
  void Function()? onTokensRenewed;

  Future<void>? _renouvellementEnCours;

  set accessToken(String? token) {
    _accessToken = token;
    _dio.options.headers['Authorization'] = token != null ? 'Bearer $token' : null;
  }

  String? get accessToken => _accessToken;

  /// Intercepte les 401 pour tenter un renouvellement puis rejouer la requête.
  Future<void> _surErreur(
      DioException e, ErrorInterceptorHandler handler) async {
    final req = e.requestOptions;
    final estExpire = e.response?.statusCode == 401;
    // On ne tente rien si : ce n'est pas un 401 ; pas de refresh token ; la
    // requête a DÉJÀ été rejouée (évite la boucle) ; ou c'est l'appel de
    // renouvellement lui-même. Une révocation (device_revoked) échouera au
    // renouvellement et retombera sur le 401 d'origine — le comportement voulu.
    if (!estExpire ||
        refreshToken == null ||
        req.extra['zia_retried'] == true ||
        req.path.contains('/auth/refresh')) {
      return handler.next(e);
    }

    try {
      await _renouveler();
    } catch (_) {
      return handler.next(e); // renouvellement raté : on remonte le 401 d'origine
    }

    req.extra['zia_retried'] = true;
    req.headers['Authorization'] = 'Bearer $_accessToken';
    try {
      handler.resolve(await _dio.fetch<dynamic>(req));
    } on DioException catch (e2) {
      handler.next(e2);
    }
  }

  /// Un seul renouvellement à la fois : plusieurs requêtes qui expirent
  /// ensemble le partagent au lieu d'en déclencher un chacune (ce qui ferait
  /// tourner le refresh token en course et invaliderait les autres).
  Future<void> _renouveler() {
    final enCours = _renouvellementEnCours;
    if (enCours != null) return enCours;
    final f = _faireRenouvellement();
    _renouvellementEnCours = f;
    f.whenComplete(() => _renouvellementEnCours = null);
    return f;
  }

  /// Reprend une session à partir du seul refresh token (au lancement, sans
  /// redemander le mot de passe). Échoue si le token est expiré/révoqué.
  Future<void> reprendreSession() => _renouveler();

  Future<void> _faireRenouvellement() async {
    final rt = refreshToken;
    if (rt == null) throw StateError('pas de refresh token');
    // Un Dio neuf, sans l'intercepteur : le renouvellement ne doit pas pouvoir
    // se re-déclencher lui-même.
    final brut = Dio(BaseOptions(baseUrl: baseUrl));
    final res = await brut.post<Map<String, dynamic>>(
        '/v1/auth/refresh', data: {'refreshToken': rt});
    accessToken = res.data!['accessToken'] as String;
    refreshToken = res.data!['refreshToken'] as String?;
    onTokensRenewed?.call();
  }

  Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    required Map<String, dynamic> device,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/auth/register', data: {
      'username': username,
      'password': password,
      'device': device,
    });
    return res.data!;
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
    required String deviceId,
    String? totp,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/auth/login', data: {
      'username': username,
      'password': password,
      'deviceId': deviceId,
      if (totp != null) 'totp': totp,
    });
    return res.data!;
  }

  Future<Map<String, dynamic>> lookupUser(String username) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/users/lookup',
      queryParameters: {'username': username},
    );
    return res.data!;
  }

  /// Appareils actifs d'un utilisateur (clé publique + date de création).
  Future<List<Map<String, dynamic>>> userDevices(String userId) async {
    final res = await _dio.get<List<dynamic>>('/v1/devices/$userId');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }

  /// Bundles de tous les appareils actifs d'un utilisateur (multi-appareils).
  Future<List<Map<String, dynamic>>> prekeyBundles(String userId) async {
    final res =
        await _dio.get<List<dynamic>>('/v1/users/$userId/prekey-bundles');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }

  /// Rattache un nouvel appareil à un compte existant.
  Future<Map<String, dynamic>> addDevice({
    required String username,
    required String password,
    required Map<String, dynamic> device,
    String? totp,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/auth/add-device',
        data: {
          'username': username,
          'password': password,
          'device': device,
          if (totp != null) 'totp': totp,
        });
    return res.data!;
  }

  /// État du second facteur pour le compte courant.
  Future<bool> twoFactorEnabled() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/auth/2fa');
    return res.data?['enabled'] as bool? ?? false;
  }

  /// Démarre l'enrôlement : renvoie le secret et l'URI otpauth à scanner.
  Future<Map<String, dynamic>> twoFactorSetup() async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/auth/2fa/setup');
    return res.data!;
  }

  Future<void> twoFactorEnable(String code) async {
    await _dio.post<void>('/v1/auth/2fa/enable', data: {'code': code});
  }

  Future<void> twoFactorDisable(String password, String code) async {
    await _dio.post<void>('/v1/auth/2fa/disable',
        data: {'password': password, 'code': code});
  }

  /// Appareils liés au compte courant, y compris ceux déjà révoqués — pour que
  /// l'utilisateur garde la trace de ce qu'il a coupé.
  Future<List<Map<String, dynamic>>> mesAppareils() async {
    final res = await _dio.get<List<dynamic>>('/v1/devices/me');
    return (res.data ?? const []).cast<Map<String, dynamic>>();
  }

  /// Révoque un appareil : il perd l'accès à l'API, sa session, et disparaît
  /// des bundles X3DH — plus personne ne chiffrera à son intention.
  Future<void> revoquerAppareil(String deviceId) async {
    await _dio.delete<void>('/v1/devices/$deviceId');
  }

  /// Publie (ou fait tourner) le jeton de remise de cet appareil.
  ///
  /// Le clair n'est rendu qu'ici, une seule fois : c'est au client de le
  /// distribuer par le canal chiffré. Le serveur n'en garde que l'empreinte.
  Future<String> publierJetonRemise() async {
    final res =
        await _dio.post<Map<String, dynamic>>('/v1/messages/delivery-token');
    return res.data!['deliveryToken'] as String;
  }

  /// Dépose une enveloppe SCELLÉE. Aucune authentification n'est envoyée :
  /// c'est tout l'objet — le serveur ne doit pas savoir qui dépose.
  Future<void> deposerScelle({
    required String deliveryToken,
    required String recipientDeviceId,
    required String clientMessageId,
    required String sealedB64,
  }) async {
    // Client distinct, sans l'en-tête d'autorisation : le Dio partagé le
    // joindrait automatiquement et trahirait l'expéditeur.
    final anonyme = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));
    await anonyme.post<void>('/v1/messages/sealed', data: {
      'deliveryToken': deliveryToken,
      'recipientDeviceId': recipientDeviceId,
      'clientMessageId': clientMessageId,
      'sealed': sealedB64,
    });
  }

  /// Comptes bloqués par l'utilisateur courant.
  Future<List<Map<String, dynamic>>> blocages() async {
    final res = await _dio.get<List<dynamic>>('/v1/blocks');
    return (res.data ?? const []).cast<Map<String, dynamic>>();
  }

  /// Bloque un compte. Le serveur cesse de remettre ses messages ; l'intéressé
  /// ne l'apprend pas — il reçoit la même réponse qu'un envoi normal.
  Future<void> bloquer(String userId) async {
    await _dio.post<void>('/v1/blocks', data: {'userId': userId});
  }

  Future<void> debloquer(String userId) async {
    await _dio.delete<void>('/v1/blocks/$userId');
  }

  /// Supprime le compte courant (mot de passe redemandé côté serveur).
  Future<void> deleteAccount(String password) async {
    await _dio.delete<void>('/v1/users/me', data: {'password': password});
  }

  Future<Map<String, dynamic>> prekeyBundle(String userId) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/users/$userId/prekey-bundle');
    return res.data!;
  }

  Future<String> createConversation(String peerUserId) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/conversations', data: {
      'type': 'direct',
      'participantIds': [peerUserId],
    });
    return res.data!['id'] as String;
  }

  /// Crée un groupe. Le serveur ne connaît QUE la composition — nécessaire pour
  /// router — jamais le nom, qui circule dans les messages chiffrés.
  Future<String> createGroup(List<String> memberUserIds) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/conversations', data: {
      'type': 'group',
      'participantIds': memberUserIds,
    });
    return res.data!['id'] as String;
  }

  /// Membres actifs d'une conversation (réservé à ses membres).
  Future<List<Map<String, dynamic>>> conversationMembers(String id) async {
    final res = await _dio.get<List<dynamic>>('/v1/conversations/$id/members');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }

  Future<void> addMember(String conversationId, String userId) async {
    await _dio.post<void>('/v1/conversations/$conversationId/members',
        data: {'userId': userId});
  }

  Future<void> removeMember(String conversationId, String userId) async {
    await _dio.delete<void>('/v1/conversations/$conversationId/members/$userId');
  }

  Future<void> sendMessage({
    required String conversationId,
    required String recipientDeviceId,
    required String clientMessageId,
    required String headerB64,
    required String ciphertextB64,
  }) async {
    await _dio.post<Map<String, dynamic>>('/v1/messages', data: {
      'conversationId': conversationId,
      'recipientDeviceId': recipientDeviceId,
      'clientMessageId': clientMessageId,
      'header': headerB64,
      'ciphertext': ciphertextB64,
    });
  }

  /// Dépose UN message de groupe chiffré une seule fois, pour tous les
  /// appareils listés. Remplace autant d'appels à sendMessage qu'il y avait
  /// d'appareils.
  Future<void> sendGroupMessage({
    required String conversationId,
    required String clientMessageId,
    required List<String> recipientDeviceIds,
    required String headerB64,
    required String ciphertextB64,
  }) async {
    await _dio.post<Map<String, dynamic>>('/v1/messages/group', data: {
      'conversationId': conversationId,
      'clientMessageId': clientMessageId,
      'recipientDeviceIds': recipientDeviceIds,
      'header': headerB64,
      'ciphertext': ciphertextB64,
    });
  }

  /// Identifiants TURN à durée limitée pour un appel. Null si le serveur
  /// n'a pas de relais configuré (503) — pas d'appels sur ce déploiement.
  Future<Map<String, dynamic>?> turnCredentials() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/v1/turn-credentials');
      return res.data;
    } on DioException catch (e) {
      if (e.response?.statusCode == 503) return null;
      rethrow;
    }
  }

  // ---- Canaux de diffusion ----

  /// Crée un canal en déposant sa clé de lecture scellée. Renvoie l'id du canal
  /// et l'appareil admin (le nôtre), qui sert d'identifiant d'expéditeur.
  Future<Map<String, dynamic>> createChannel([String? sealedKeyB64]) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/channels',
        data: {if (sealedKeyB64 != null) 'sealedKey': sealedKeyB64});
    return res.data!;
  }

  /// Métadonnées d'un canal (compteur d'abonnés, suis-je admin/abonné…).
  Future<Map<String, dynamic>> channelInfo(String id) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/channels/$id');
    return res.data!;
  }

  /// Clé de lecture scellée d'un canal. Inutilisable sans le secret du lien.
  Future<String> channelKey(String id) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/channels/$id/key');
    return res.data!['sealedKey'] as String;
  }

  /// Dépose (ou fait tourner) la clé scellée. Réservé à l'admin côté serveur.
  Future<void> putChannelKey(String id, String sealedKeyB64) async {
    await _dio.put<void>('/v1/channels/$id/key', data: {'sealedKey': sealedKeyB64});
  }

  /// Abonne l'appareil courant à un canal.
  Future<void> subscribeChannel(String id) async {
    await _dio.post<void>('/v1/channels/$id/subscribers');
  }

  /// Désabonne un appareil (le sien, ou n'importe lequel si l'on est admin).
  Future<void> unsubscribeChannel(String id, String deviceId) async {
    await _dio.delete<void>('/v1/channels/$id/subscribers/$deviceId');
  }

  /// Publie un message dans un canal (admin). Le serveur recopie à tous les
  /// abonnés ; renvoie le nombre servi.
  Future<int> postChannel({
    required String id,
    required String clientMessageId,
    required String headerB64,
    required String ciphertextB64,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/channels/$id/messages',
        data: {
          'clientMessageId': clientMessageId,
          'header': headerB64,
          'ciphertext': ciphertextB64,
        });
    return (res.data?['delivered'] as num?)?.toInt() ?? 0;
  }

  /// Canaux administrés et suivis par cet appareil.
  Future<Map<String, dynamic>> myChannels() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/channels');
    return res.data!;
  }

  /// Nombre de one-time prekeys encore disponibles pour cet appareil.
  Future<int> oneTimePrekeyCount(String deviceId) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/devices/$deviceId/prekeys');
    return (res.data?['oneTimePrekeysRemaining'] as num?)?.toInt() ?? 0;
  }

  /// Publie de nouvelles prekeys (clés publiques uniquement).
  Future<void> uploadPrekeys(
    String deviceId, {
    List<String> oneTimePrekeys = const [],
    String? signedPrekey,
    String? signedPrekeySignature,
  }) async {
    await _dio.post<void>('/v1/devices/$deviceId/prekeys', data: {
      'oneTimePrekeys': oneTimePrekeys,
      if (signedPrekey != null) 'signedPrekey': signedPrekey,
      if (signedPrekeySignature != null)
        'signedPrekeySignature': signedPrekeySignature,
    });
  }

  /// Réserve une pièce jointe et obtient l'URL de dépôt (pré-signée).
  /// [conversationId] absent pour une photo de profil : elle n'appartient à
  /// aucune conversation, ne doit pas disparaître avec elle, et n'expire pas.
  Future<Map<String, dynamic>> createAttachment({
    String? conversationId,
    required int ciphertextSize,
    required String encryptedMetadataB64,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/attachments', data: {
      if (conversationId != null) 'conversationId': conversationId,
      'ciphertextSize': ciphertextSize,
      'encryptedMetadata': encryptedMetadataB64,
    });
    return res.data!;
  }

  /// URL de téléchargement d'une pièce jointe.
  Future<Map<String, dynamic>> attachment(String id) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/attachments/$id');
    return res.data!;
  }

  /// Dépose ou récupère le contenu chiffré directement sur le stockage objet,
  /// sans passer par l'API (URL pré-signée, aucun jeton envoyé à l'hébergeur).
  Future<void> uploadToStorage(String url, Uint8List ciphertext) async {
    await Dio().put<void>(url,
        data: Stream.fromIterable([ciphertext]),
        options: Options(headers: {
          Headers.contentLengthHeader: ciphertext.length,
        }));
  }

  Future<Uint8List> downloadFromStorage(String url) async {
    final res = await Dio().get<List<int>>(url,
        options: Options(responseType: ResponseType.bytes));
    return Uint8List.fromList(res.data ?? const []);
  }

  /// Identifiants (parmi ceux fournis) de messages ENVOYÉS déjà remis à un
  /// appareil du correspondant. Le serveur ne renvoie que ceux de cet appareil.
  Future<List<String>> deliveredAmong(List<String> clientMessageIds) async {
    if (clientMessageIds.isEmpty) return const [];
    final res = await _dio.get<Map<String, dynamic>>('/v1/messages/status',
        queryParameters: {'ids': clientMessageIds.join(',')});
    return ((res.data?['delivered'] as List?) ?? const []).cast<String>();
  }

  /// Relève les blobs chiffrés en attente pour l'appareil courant.
  Future<List<Map<String, dynamic>>> fetchMessages() async {
    final res = await _dio.get<List<dynamic>>('/v1/messages');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }
  /// Signale un contenu abusif. Le clair transmis est celui que le destinataire
  /// a DÉJÀ déchiffré et choisit de révéler : le serveur ne casse rien, c'est
  /// l'utilisateur qui lève le voile sur son propre message.
  Future<void> signaler({
    required String reportedUsername,
    required String reason,
    String? note,
    String? content,
    String? context,
  }) async {
    await _dio.post<void>('/v1/reports', data: {
      'reportedUsername': reportedUsername,
      'reason': reason,
      if (note != null) 'note': note,
      if (content != null) 'content': content,
      if (context != null) 'context': context,
    });
  }

  // ----------------------------------------------------------- administration
  //
  // Chaque appel joint un code TOTP frais dans l'en-tête `X-Admin-Totp` : le
  // serveur l'exige à CHAQUE action, pas seulement à la connexion. Un jeton
  // d'accès volé ne suffit donc pas — il faudrait aussi le générateur de codes.

  Options _admin(String totp) => Options(headers: {'X-Admin-Totp': totp});

  Future<List<Map<String, dynamic>>> adminUsers(String totp, {String? q}) async {
    final res = await _dio.get<List<dynamic>>('/v1/admin/users',
        queryParameters: {if (q != null && q.isNotEmpty) 'q': q},
        options: _admin(totp));
    return (res.data ?? const []).cast<Map<String, dynamic>>();
  }

  /// Émet un jeton de réinitialisation à la demande du titulaire. L'admin ne
  /// fixe aucun mot de passe et n'en apprend aucun : il transmet le jeton.
  Future<Map<String, dynamic>> adminIssuePasswordReset(String userId, String totp,
      {String? reason}) async {
    final res = await _dio.post<Map<String, dynamic>>(
        '/v1/admin/users/$userId/password-reset',
        data: {if (reason != null) 'reason': reason},
        options: _admin(totp));
    return res.data!;
  }

  Future<void> adminDeleteUser(String userId, String totp, String reason) async {
    await _dio.delete<void>('/v1/admin/users/$userId',
        data: {'reason': reason}, options: _admin(totp));
  }

  Future<List<Map<String, dynamic>>> adminActions(String totp, {int limit = 50}) async {
    final res = await _dio.get<List<dynamic>>('/v1/admin/actions',
        queryParameters: {'limit': limit}, options: _admin(totp));
    return (res.data ?? const []).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> adminReports(String totp,
      {String status = 'open'}) async {
    final res = await _dio.get<List<dynamic>>('/v1/admin/reports',
        queryParameters: {'status': status}, options: _admin(totp));
    return (res.data ?? const []).cast<Map<String, dynamic>>();
  }

  Future<void> adminResolveReport(String id, String totp,
      {required String status, String? resolution}) async {
    await _dio.post<void>('/v1/admin/reports/$id/resolve',
        data: {'status': status, if (resolution != null) 'resolution': resolution},
        options: _admin(totp));
  }
}
