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
        ));

  /// Racine de l'API, réutilisée pour construire l'URL du WebSocket.
  final String baseUrl;
  final Dio _dio;
  String? _accessToken;

  set accessToken(String? token) {
    _accessToken = token;
    _dio.options.headers['Authorization'] = token != null ? 'Bearer $token' : null;
  }

  String? get accessToken => _accessToken;

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
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/auth/login', data: {
      'username': username,
      'password': password,
      'deviceId': deviceId,
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
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/auth/add-device',
        data: {'username': username, 'password': password, 'device': device});
    return res.data!;
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
  Future<Map<String, dynamic>> createAttachment({
    required String conversationId,
    required int ciphertextSize,
    required String encryptedMetadataB64,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>('/v1/attachments', data: {
      'conversationId': conversationId,
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

  /// Relève les blobs chiffrés en attente pour l'appareil courant.
  Future<List<Map<String, dynamic>>> fetchMessages() async {
    final res = await _dio.get<List<dynamic>>('/v1/messages');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }
}
