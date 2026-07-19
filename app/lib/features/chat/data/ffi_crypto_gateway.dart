import 'dart:typed_data';

import '../../../core/ffi/crypto_isolate.dart';
import '../domain/crypto_gateway.dart';
import '../domain/crypto_models.dart';

/// Implémentation FFI du [CryptoGateway] : délègue à l'isolate crypto natif.
///
/// C'est la seule classe qui relie le domaine au moteur natif. La substituer par
/// un mock dans les tests, ou par une autre implémentation, ne touche à rien
/// d'autre dans l'app.
class FfiCryptoGateway implements CryptoGateway {
  FfiCryptoGateway(this._engine);

  final ZiaCryptoEngine _engine;

  /// Ouvre le moteur natif (démarre l'isolate) et renvoie le gateway prêt.
  static Future<FfiCryptoGateway> open(String storagePath,
      {String? libraryPath}) async {
    final engine =
        await ZiaCryptoEngine.spawn(storagePath, libraryPath: libraryPath);
    return FfiCryptoGateway(engine);
  }

  @override
  Future<Uint8List> generateIdentity() => _engine.generateIdentity();

  @override
  Future<Uint8List> identityPublicKey() => _engine.identityPublicKey();

  @override
  Future<Uint8List> sign(Uint8List message) => _engine.sign(message);

  @override
  Future<bool> verify(
          Uint8List publicKey, Uint8List message, Uint8List signature) =>
      _engine.verify(publicKey, message, signature);

  @override
  Future<PrekeyBundle> generatePrekeyBundle() =>
      _engine.generatePrekeyBundle();

  @override
  Future<void> rotatePrekeys() => _engine.rotatePrekeys();

  @override
  Future<InitiatedSession> startSession(PrekeyBundle theirBundle) =>
      _engine.sessionFromBundle(theirBundle);

  @override
  Future<int> acceptSession(HandshakeMaterial handshake) =>
      _engine.acceptHandshake(handshake);

  @override
  Future<EncryptedMessage> encrypt(int sessionId, Uint8List plaintext) =>
      _engine.encrypt(sessionId, plaintext);

  @override
  Future<Uint8List> decrypt(
          int sessionId, Uint8List header, Uint8List ciphertext) =>
      _engine.decrypt(sessionId, header, ciphertext);

  /// Chiffrement des pièces jointes (clé aléatoire par fichier).
  Future<({Uint8List key, Uint8List ciphertext})> attachmentEncrypt(
          Uint8List data) =>
      _engine.attachmentEncrypt(data);

  Future<Uint8List> attachmentDecrypt(Uint8List key, Uint8List ciphertext) =>
      _engine.attachmentDecrypt(key, ciphertext);

  /// Coffre local chiffré (historique des conversations, etc.).
  Future<void> vaultWrite(String name, Uint8List data) =>
      _engine.vaultWrite(name, data);

  Future<Uint8List?> vaultRead(String name) => _engine.vaultRead(name);

  @override
  Future<Uint8List> exportSession(int sessionId) =>
      _engine.serializeSession(sessionId);

  @override
  Future<int> importSession(Uint8List data) =>
      _engine.deserializeSession(data);

  @override
  Future<void> closeSession(int sessionId) => _engine.closeSession(sessionId);

  Future<void> dispose() => _engine.dispose();
}
