// Sauvegarde chiffrée exportable, éprouvée à travers TOUTE la pile Dart :
// FfiCryptoGateway -> isolat -> NativeCryptoEngine -> moteur C++.
//
// Le moteur a déjà son propre test en C++. Celui-ci vérifie autre chose, et
// c'est le motif d'un défaut réel de ce projet : la traversée FFI. Une taille
// mal transmise, un pointeur libéré trop tôt, une chaîne non terminée par un
// octet nul — rien de tout cela n'apparaît dans un test C++, et tout casse en
// production.
//
//   cd crypto-engine && cmake --preset linux-system && cmake --build --preset linux-system
//   ZIA_CRYPTO_LIB=$PWD/build/linux-system/src/libzia_crypto.so \
//     flutter test test/backup_roundtrip_test.dart
//
// Nécessite un coffre-fort de clés disponible (Secret Service / Keychain /
// DPAPI) : sans lui, l'identité ne peut pas être écrite.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ziacrypte/features/chat/data/ffi_crypto_gateway.dart';

void main() {
  final libPath = Platform.environment['ZIA_CRYPTO_LIB'];
  final available = libPath != null && File(libPath).existsSync();

  group('Sauvegarde exportable',
      skip: available ? false : 'ZIA_CRYPTO_LIB absent', () {
    late FfiCryptoGateway source;
    late String dossierSource;

    setUp(() async {
      final u = DateTime.now().microsecondsSinceEpoch;
      dossierSource = '${Directory.systemTemp.path}/zia_bk_src_$u';
      source = await FfiCryptoGateway.open(dossierSource, libraryPath: libPath);
      await source.generateIdentity();
    });

    tearDown(() async {
      await source.dispose();
    });

    test('restaurée sur un AUTRE moteur, identité et coffre retrouvés',
        () async {
      const phrase = 'phrase-de-passe-solide';
      final contenu = Uint8List.fromList(utf8.encode('historique-secret'));
      await source.engine.vaultWrite('historique', contenu);

      final identiteSource = await source.identityPublicKey();
      final sauvegarde = await source.engine.backupExport(phrase);
      expect(sauvegarde.length, greaterThan(100));

      // Deux moteurs distincts : un aller-retour dans le même réussirait même
      // si la clé de l'appareil s'était glissée dans le fichier.
      final u = DateTime.now().microsecondsSinceEpoch;
      final cible = await FfiCryptoGateway.open(
          '${Directory.systemTemp.path}/zia_bk_dst_$u',
          libraryPath: libPath);
      try {
        await cible.engine.backupImport(phrase, sauvegarde);
        expect(await cible.identityPublicKey(), equals(identiteSource),
            reason: 'la cible doit avoir repris l’identité de la source');
        expect(await cible.engine.vaultRead('historique'), equals(contenu),
            reason: 'le coffre doit être restauré à l’identique');
      } finally {
        await cible.dispose();
      }
    });

    test('phrase de passe erronée refusée', () async {
      final sauvegarde =
          await source.engine.backupExport('phrase-de-passe-solide');
      final u = DateTime.now().microsecondsSinceEpoch;
      final cible = await FfiCryptoGateway.open(
          '${Directory.systemTemp.path}/zia_bk_bad_$u',
          libraryPath: libPath);
      try {
        await expectLater(
          cible.engine.backupImport('phrase-de-passe-fausse', sauvegarde),
          throwsA(anything),
        );
      } finally {
        await cible.dispose();
      }
    });

    test('fichier altéré refusé', () async {
      const phrase = 'phrase-de-passe-solide';
      final sauvegarde = await source.engine.backupExport(phrase);
      final altere = Uint8List.fromList(sauvegarde);
      altere[altere.length ~/ 2] ^= 0xFF;

      final u = DateTime.now().microsecondsSinceEpoch;
      final cible = await FfiCryptoGateway.open(
          '${Directory.systemTemp.path}/zia_bk_alt_$u',
          libraryPath: libPath);
      try {
        await expectLater(
            cible.engine.backupImport(phrase, altere), throwsA(anything));
      } finally {
        await cible.dispose();
      }
    });

    test('phrase trop courte refusée à l’export', () async {
      await expectLater(source.engine.backupExport('court'), throwsA(anything));
    });
  });
}
