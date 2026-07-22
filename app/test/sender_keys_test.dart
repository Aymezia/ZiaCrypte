// Clés d'expéditeur de groupe, exercées depuis Dart à travers toute la pile
// (isolate -> NativeCryptoEngine -> moteur natif).
//
// Le test C++ prouve déjà la cryptographie ; celui-ci prouve que le PONT la
// rend utilisable : chaînes converties, tampons libérés, erreurs remontées.
//
//   ZIA_CRYPTO_LIB=<...>/libzia_crypto.so flutter test test/sender_keys_test.dart

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

  group('Clés d’expéditeur de groupe',
      skip: available ? false : 'ZIA_CRYPTO_LIB absent', () {
    late FfiCryptoGateway alice;
    late FfiCryptoGateway bob;
    late FfiCryptoGateway carol;
    const groupe = 'groupe-42';

    setUp(() async {
      final u = DateTime.now().microsecondsSinceEpoch;
      alice = await FfiCryptoGateway.open(
          '${Directory.systemTemp.path}/zia_sk_a_$u', libraryPath: libPath);
      bob = await FfiCryptoGateway.open(
          '${Directory.systemTemp.path}/zia_sk_b_$u', libraryPath: libPath);
      carol = await FfiCryptoGateway.open(
          '${Directory.systemTemp.path}/zia_sk_c_$u', libraryPath: libPath);
    });

    tearDown(() async {
      await alice.dispose();
      await bob.dispose();
      await carol.dispose();
    });

    test('un seul chiffrement, plusieurs lecteurs', () async {
      // C'est tout l'intérêt : le coût cesse de croître avec le groupe.
      final distrib = await alice.engine.senderKeyCreate(groupe);
      await bob.engine.senderKeyProcess(groupe, 'alice', distrib);
      await carol.engine.senderKeyProcess(groupe, 'alice', distrib);

      final msg = await alice.engine.senderKeyEncrypt(groupe, _s('bonjour'));

      expect(_d(await bob.engine.senderKeyDecrypt(groupe, 'alice', msg)), 'bonjour');
      expect(_d(await carol.engine.senderKeyDecrypt(groupe, 'alice', msg)), 'bonjour');
    });

    test('un non-membre ne déchiffre pas', () async {
      final distrib = await alice.engine.senderKeyCreate(groupe);
      await bob.engine.senderKeyProcess(groupe, 'alice', distrib);
      final msg = await alice.engine.senderKeyEncrypt(groupe, _s('privé'));

      // Carol n'a jamais reçu la distribution : aucun état pour cet expéditeur.
      await expectLater(
        carol.engine.senderKeyDecrypt(groupe, 'alice', msg),
        throwsA(isA<ZiaSessionNotFoundException>()),
      );
    });

    test('message altéré rejeté', () async {
      final distrib = await alice.engine.senderKeyCreate(groupe);
      await bob.engine.senderKeyProcess(groupe, 'alice', distrib);
      final msg = await alice.engine.senderKeyEncrypt(groupe, _s('intact'));

      final altere = Uint8List.fromList(msg);
      altere[altere.length ~/ 2] ^= 0xFF;
      // La signature couvre tout le message : elle tombe AVANT le déchiffrement.
      await expectLater(
        bob.engine.senderKeyDecrypt(groupe, 'alice', altere),
        throwsA(isA<ZiaSignatureInvalidException>()),
      );
    });

    test('livraison hors séquence : le retardataire reste lisible', () async {
      final distrib = await alice.engine.senderKeyCreate(groupe);
      await bob.engine.senderKeyProcess(groupe, 'alice', distrib);

      final m1 = await alice.engine.senderKeyEncrypt(groupe, _s('un'));
      final m2 = await alice.engine.senderKeyEncrypt(groupe, _s('deux'));

      // Le second arrive en premier ; le premier doit rester déchiffrable.
      expect(_d(await bob.engine.senderKeyDecrypt(groupe, 'alice', m2)), 'deux');
      expect(_d(await bob.engine.senderKeyDecrypt(groupe, 'alice', m1)), 'un');

      // Mais pas deux fois : la clé mise de côté a été consommée.
      await expectLater(
        bob.engine.senderKeyDecrypt(groupe, 'alice', m1),
        throwsA(isA<ZiaReplayDetectedException>()),
      );
    });

    test('rotation : l’ancienne clé ne lit plus la suite', () async {
      // Ce qu'on fait au départ d'un membre.
      final d1 = await alice.engine.senderKeyCreate(groupe);
      await bob.engine.senderKeyProcess(groupe, 'alice', d1);

      await alice.engine.senderKeyCreate(groupe); // rotation
      final apres = await alice.engine.senderKeyEncrypt(groupe, _s('après'));

      // Nouvelle clé de signature : Bob ne reconnaît plus l'auteur.
      await expectLater(
        bob.engine.senderKeyDecrypt(groupe, 'alice', apres),
        throwsA(isA<ZiaSignatureInvalidException>()),
      );
    });

    test('chiffrer sans clé d’expéditeur échoue', () async {
      await expectLater(
        bob.engine.senderKeyEncrypt('groupe-inconnu', _s('x')),
        throwsA(isA<ZiaSessionNotFoundException>()),
      );
    });
  });
}
