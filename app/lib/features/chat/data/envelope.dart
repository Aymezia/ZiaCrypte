import 'dart:typed_data';

import '../domain/crypto_models.dart';

/// Cadrage de l'en-tête d'enveloppe, purement côté client.
///
/// Le serveur ne voit qu'un blob opaque. Le tout premier message d'une session
/// doit transporter le matériel de handshake X3DH (sans quoi le destinataire ne
/// peut pas dériver le secret partagé) ; les suivants n'ont que l'en-tête du
/// ratchet.
///
///   1er message : [1][IK 32][EK 32][hasOtpk 1][OTPK 32][ratchetHeader]
///   suivants    : [0][ratchetHeader]
class Envelope {
  static Uint8List packHeader(Uint8List ratchetHeader, HandshakeMaterial? handshake) {
    final out = BytesBuilder();
    if (handshake == null) {
      out.addByte(0);
    } else {
      out.addByte(1);
      out.add(handshake.initiatorIdentityKey);
      out.add(handshake.initiatorEphemeralKey);
      out.addByte(handshake.usedOneTimePrekey != null ? 1 : 0);
      out.add(handshake.usedOneTimePrekey ?? Uint8List(32));
    }
    out.add(ratchetHeader);
    return out.toBytes();
  }

  static ({HandshakeMaterial? handshake, Uint8List ratchetHeader}) unpackHeader(
      Uint8List packed) {
    if (packed.isEmpty) {
      throw const FormatException('en-tête d’enveloppe vide');
    }
    if (packed[0] == 0) {
      return (
        handshake: null,
        ratchetHeader: Uint8List.fromList(Uint8List.sublistView(packed, 1)),
      );
    }
    if (packed.length < 98) {
      throw const FormatException('en-tête de handshake tronqué');
    }
    final hasOtpk = packed[65] == 1;
    return (
      handshake: HandshakeMaterial(
        initiatorIdentityKey: Uint8List.fromList(Uint8List.sublistView(packed, 1, 33)),
        initiatorEphemeralKey: Uint8List.fromList(Uint8List.sublistView(packed, 33, 65)),
        usedOneTimePrekey:
            hasOtpk ? Uint8List.fromList(Uint8List.sublistView(packed, 66, 98)) : null,
      ),
      ratchetHeader: Uint8List.fromList(Uint8List.sublistView(packed, 98)),
    );
  }
}
