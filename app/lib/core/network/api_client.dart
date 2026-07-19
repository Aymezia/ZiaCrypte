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

  /// Relève les blobs chiffrés en attente pour l'appareil courant.
  Future<List<Map<String, dynamic>>> fetchMessages() async {
    final res = await _dio.get<List<dynamic>>('/v1/messages');
    return (res.data ?? []).cast<Map<String, dynamic>>();
  }
}
