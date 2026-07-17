import 'dart:typed_data';

import 'crypto_models.dart';

/// Contrat du domaine pour toute opération cryptographique.
///
/// Défini en types Dart purs (aucune dépendance à `dart:ffi`) : les repositories
/// ne connaissent que cette interface, ce qui les rend testables avec un mock et
/// indépendants de l'implémentation FFI. L'implémentation concrète vit dans la
/// couche data ([FfiCryptoGateway]).
abstract interface class CryptoGateway {
  /// Génère la paire d'identité de l'appareil, renvoie la clé publique.
  Future<Uint8List> generateIdentity();

  /// Clé publique d'identité courante.
  Future<Uint8List> identityPublicKey();

  /// Signe [message] avec la clé d'identité.
  Future<Uint8List> sign(Uint8List message);

  /// Vérifie une signature Ed25519.
  Future<bool> verify(Uint8List publicKey, Uint8List message, Uint8List signature);

  /// Génère un bundle de prekeys à publier sur le serveur.
  Future<PrekeyBundle> generatePrekeyBundle();

  /// Fait tourner le signed prekey.
  Future<void> rotatePrekeys();

  /// Côté initiateur : démarre une session à partir du bundle du destinataire.
  Future<InitiatedSession> startSession(PrekeyBundle theirBundle);

  /// Côté destinataire : accepte le handshake reçu, renvoie l'id de session.
  Future<int> acceptSession(HandshakeMaterial handshake);

  /// Chiffre [plaintext] dans la session [sessionId].
  Future<EncryptedMessage> encrypt(int sessionId, Uint8List plaintext);

  /// Déchiffre un message de la session [sessionId].
  Future<Uint8List> decrypt(int sessionId, Uint8List header, Uint8List ciphertext);

  /// Sérialise l'état chiffré d'une session (pour persistance locale).
  Future<Uint8List> exportSession(int sessionId);

  /// Restaure une session depuis son état chiffré, renvoie le nouvel id.
  Future<int> importSession(Uint8List data);

  /// Ferme une session et efface ses secrets.
  Future<void> closeSession(int sessionId);
}
