// Test d'intégration du pont FFI : exerce le vrai moteur natif depuis Dart,
// à travers toute la pile (FfiCryptoGateway -> isolate -> NativeCryptoEngine).
//
// Nécessite la bibliothèque native compilée. Indiquer son chemin via la variable
// d'environnement ZIA_CRYPTO_LIB (sinon le test est ignoré) :
//
//   cd crypto-engine && cmake --preset linux-system && cmake --build --preset linux-system
//   ZIA_CRYPTO_LIB=$PWD/build/linux-system/src/libzia_crypto.so \
//     flutter test test/ffi_roundtrip_test.dart
//
// La partie sérialisation nécessite en plus un coffre-fort de clés disponible
// (Secret Service/Keychain/DPAPI) ; elle est ignorée proprement si absent.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ziacrypte/core/ffi/zia_crypto_exceptions.dart';
import 'package:ziacrypte/features/chat/data/ffi_crypto_gateway.dart';

Uint8List _s(String s) => Uint8List.fromList(utf8.encode(s));
String _d(Uint8List b) => utf8.decode(b);

void main() {
  final libPath = Platform.environment['ZIA_CRYPTO_LIB'];
  final available = libPath != null && File(libPath).existsSync();

  group('Pont FFI ZiaCrypte', skip: available ? false : 'ZIA_CRYPTO_LIB absent', () {
    late FfiCryptoGateway alice;
    late FfiCryptoGateway bob;

    setUp(() async {
      alice = await FfiCryptoGateway.open('/tmp/zia_test_a', libraryPath: libPath);
      bob = await FfiCryptoGateway.open('/tmp/zia_test_b', libraryPath: libPath);
      await alice.generateIdentity();
      await bob.generateIdentity();
    });

    tearDown(() async {
      await alice.dispose();
      await bob.dispose();
    });

    test('signature vérifiée et falsification rejetée', () async {
      final msg = _s('à signer');
      final pub = await alice.identityPublicKey();
      final sig = await alice.sign(msg);
      expect(await bob.verify(pub, msg, sig), isTrue);
      final tampered = Uint8List.fromList(msg)..[0] ^= 0xFF;
      expect(await bob.verify(pub, tampered, sig), isFalse);
    });

    test('handshake X3DH + Double Ratchet bidirectionnel', () async {
      final bundle = await bob.generatePrekeyBundle();
      final init = await alice.startSession(bundle);
      final enc1 = await alice.encrypt(init.sessionId, _s('Bonjour Bob'));
      final bSession = await bob.acceptSession(init.handshake);
      expect(_d(await bob.decrypt(bSession, enc1.header, enc1.ciphertext)),
          'Bonjour Bob');

      final enc2 = await bob.encrypt(bSession, _s('Salut Alice'));
      expect(_d(await alice.decrypt(init.sessionId, enc2.header, enc2.ciphertext)),
          'Salut Alice');
    });

    test('livraison hors-ordre puis rejeu et falsification rejetés', () async {
      final bundle = await bob.generatePrekeyBundle();
      final init = await alice.startSession(bundle);
      final first = await alice.encrypt(init.sessionId, _s('init'));
      final bSession = await bob.acceptSession(init.handshake);
      await bob.decrypt(bSession, first.header, first.ciphertext);

      final a = await alice.encrypt(init.sessionId, _s('A'));
      final b = await alice.encrypt(init.sessionId, _s('B'));
      final c = await alice.encrypt(init.sessionId, _s('C'));
      expect(_d(await bob.decrypt(bSession, c.header, c.ciphertext)), 'C');
      expect(_d(await bob.decrypt(bSession, a.header, a.ciphertext)), 'A');
      expect(_d(await bob.decrypt(bSession, b.header, b.ciphertext)), 'B');

      // Rejeu de C
      expect(() => bob.decrypt(bSession, c.header, c.ciphertext),
          throwsA(isA<ZiaReplayDetectedException>()));

      // Ciphertext falsifié
      final d = await alice.encrypt(init.sessionId, _s('intègre'));
      final forged = Uint8List.fromList(d.ciphertext)..[0] ^= 0xFF;
      expect(() => bob.decrypt(bSession, d.header, forged),
          throwsA(isA<ZiaCryptoFailureException>()));
    });
  });
}
