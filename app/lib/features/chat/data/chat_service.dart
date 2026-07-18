import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../domain/crypto_models.dart';
import 'envelope.dart';
import 'ffi_crypto_gateway.dart';

class ChatMessage {
  ChatMessage({required this.text, required this.mine, required this.at});
  final String text;
  final bool mine;
  final DateTime at;
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

  /// Crée un compte et son appareil, puis publie les prekeys.
  Future<void> registerAndConnect({
    required String serverUrl,
    required String user,
    required String password,
  }) async {
    _setBusy(true);
    try {
      final api = ApiClient(serverUrl);
      final gateway = await FfiCryptoGateway.open(
        '${Directory.systemTemp.path}/ziacrypte_$user',
        libraryPath: _resolveLibrary(),
      );

      await gateway.generateIdentity();
      final bundle = await gateway.generatePrekeyBundle();

      final res = await api.register(
        username: user,
        password: password,
        device: {
          'platform': 'linux',
          'deviceName': 'desktop',
          'identityPublicKey': base64Encode(bundle.identityKey),
          'signedPrekey': base64Encode(bundle.signedPrekey),
          'signedPrekeySignature': base64Encode(bundle.signedPrekeySignature),
          'oneTimePrekeys': [base64Encode(bundle.oneTimePrekey!)],
        },
      );

      api.accessToken = res['accessToken'] as String;
      _api = api;
      _gateway = gateway;
      username = user;
      userId = res['userId'] as String;
      deviceId = res['deviceId'] as String;

      _startPolling();
      _setBusy(false);
    } catch (e) {
      _setBusy(false, err: _humanize(e));
      rethrow;
    }
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
      if (incoming.isNotEmpty) notifyListeners();
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
