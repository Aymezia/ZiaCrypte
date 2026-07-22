import 'dart:typed_data';

/// Bundle de prekeys public d'un correspondant (aucun secret).
/// Publié par le serveur, consommé par l'initiateur pour démarrer une session.
class PrekeyBundle {
  const PrekeyBundle({
    required this.identityKey,
    required this.signedPrekey,
    required this.signedPrekeySignature,
    this.oneTimePrekey,
    this.pqPrekey,
    this.pqPrekeySignature,
  });

  final Uint8List identityKey;
  final Uint8List signedPrekey;
  final Uint8List signedPrekeySignature;
  final Uint8List? oneTimePrekey;

  /// Clé d'encapsulation ML-KEM-768 et sa signature (PQXDH).
  ///
  /// Nulles pour un correspondant dont l'application n'a pas encore migré, ou
  /// tant que le serveur ne relaie pas ce champ : le moteur retombe alors sur
  /// le X3DH classique.
  final Uint8List? pqPrekey;
  final Uint8List? pqPrekeySignature;
}

/// Matériel de handshake X3DH joint au tout premier message d'une session.
/// Transporté en clair (ce ne sont que des clés publiques) via l'enveloppe.
class HandshakeMaterial {
  const HandshakeMaterial({
    required this.initiatorIdentityKey,
    required this.initiatorEphemeralKey,
    this.usedOneTimePrekey,
    this.pqCiphertext,
  });

  final Uint8List initiatorIdentityKey;
  final Uint8List initiatorEphemeralKey;
  final Uint8List? usedOneTimePrekey;

  /// Chiffré ML-KEM à transmettre au répondeur. Null = handshake classique.
  final Uint8List? pqCiphertext;
}

/// Résultat d'un chiffrement : l'en-tête du ratchet et le ciphertext, qui
/// correspondent 1:1 aux champs `ratchet_header` / `ciphertext` de l'enveloppe.
class EncryptedMessage {
  const EncryptedMessage({required this.header, required this.ciphertext});

  final Uint8List header;
  final Uint8List ciphertext;
}

/// Résultat de l'initiation d'une session côté initiateur : la référence de
/// session (à réutiliser pour chiffrer/déchiffrer) et le matériel de handshake
/// à joindre au premier message.
class InitiatedSession {
  const InitiatedSession({required this.sessionId, required this.handshake});

  final int sessionId;
  final HandshakeMaterial handshake;
}
