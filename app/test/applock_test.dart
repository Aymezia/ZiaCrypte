// Code de verrouillage, éprouvé à travers le pont FFI.
//
// Ce que ces cas attrapent : une chaîne mal terminée entre Dart et C, un code
// accepté à tort, un état de verrouillage qui ne survit pas au coffre. Rien de
// tout cela n'apparaît dans un test C++ pur.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ziacrypte/features/chat/data/ffi_crypto_gateway.dart';

void main() {
  final libPath = Platform.environment['ZIA_CRYPTO_LIB'];
  final available = libPath != null && File(libPath).existsSync();

  group('Code de verrouillage',
      skip: available ? false : 'ZIA_CRYPTO_LIB absent', () {
    late FfiCryptoGateway g;

    setUp(() async {
      final u = DateTime.now().microsecondsSinceEpoch;
      g = await FfiCryptoGateway.open('${Directory.systemTemp.path}/zia_lock_$u',
          libraryPath: libPath);
      await g.generateIdentity();
    });

    tearDown(() async => g.dispose());

    test('aucun code au départ', () async {
      expect(await g.engine.appLockIsSet(), isFalse);
    });

    test('code posé, bon code accepté, mauvais refusé', () async {
      await g.engine.appLockSet('147258');
      expect(await g.engine.appLockIsSet(), isTrue);
      expect(await g.engine.appLockVerify('147258'), isTrue);
      expect(await g.engine.appLockVerify('147259'), isFalse);
      // Un préfixe ne doit pas passer : ce serait le signe d'une comparaison
      // tronquée par une chaîne mal terminée à la traversée FFI.
      expect(await g.engine.appLockVerify('1472'), isFalse);
      expect(await g.engine.appLockVerify(''), isFalse);
    });

    test('code trop court refusé', () async {
      await expectLater(g.engine.appLockSet('12'), throwsA(anything));
      expect(await g.engine.appLockIsSet(), isFalse);
    });

    test('code retiré', () async {
      await g.engine.appLockSet('147258');
      await g.engine.appLockClear();
      expect(await g.engine.appLockIsSet(), isFalse);
    });

    test('une phrase entière fonctionne aussi', () async {
      await g.engine.appLockSet('ma-phrase-de-verrouillage');
      expect(await g.engine.appLockVerify('ma-phrase-de-verrouillage'), isTrue);
      expect(await g.engine.appLockVerify('ma-phrase-de-verrouillag'), isFalse);
    });
  });
}
