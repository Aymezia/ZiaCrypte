// Messages qui se croisent autour d'un pas de ratchet.
//
// Scénario, banal dès qu'on ne parle pas chacun son tour :
//
//   1. Alice envoie A1 à Bob
//   2. Bob déchiffre A1 et répond B1
//   3. Alice envoie A2 SANS avoir lu B1
//   4. Bob reçoit A2
//
// À l'étape 4, Bob a déjà avancé son ratchet en répondant. A2 arrive chiffré
// avec l'ancienne chaîne. Un Double Ratchet correct doit le déchiffrer : c'est
// précisément ce que prévoit la spécification pour les livraisons hors-ordre.
//
// Ce cas surgit tout le temps dans un groupe, où plusieurs membres répondent
// pendant que l'émetteur continue d'écrire.
//
// Usage : dart run bin/ratchet_crossing_test.dart <lib native>

import 'dart:io';
import 'dart:typed_data';

import '../../app/lib/core/ffi/crypto_isolate.dart';
import '../../app/lib/features/chat/domain/crypto_models.dart';

int _checks = 0;
void ok(String label) {
  _checks++;
  stdout.writeln('[OK] $label');
}

Never fail(String label) {
  stdout.writeln('[ÉCHEC] $label');
  exit(1);
}

Uint8List texte(String s) => Uint8List.fromList(s.codeUnits);
String lire(Uint8List b) => String.fromCharCodes(b);

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stdout.writeln('usage: ratchet_crossing_test <libzia_crypto.so>');
    exit(2);
  }
  final so = args[0];

  final dirA = await Directory.systemTemp.createTemp('zia_cross_a');
  final dirB = await Directory.systemTemp.createTemp('zia_cross_b');
  final alice = await ZiaCryptoEngine.spawn(dirA.path, libraryPath: so);
  final bob = await ZiaCryptoEngine.spawn(dirB.path, libraryPath: so);

  await alice.generateIdentity();
  await bob.generateIdentity();

  final bundleBob = await bob.generatePrekeyBundle();
  final init = await alice.sessionFromBundle(bundleBob);
  final sessionA = init.sessionId;
  ok('session ouverte par Alice');

  // 1) Alice envoie A1 (porte le matériel X3DH).
  final a1 = await alice.encrypt(sessionA, texte('A1'));

  // 2) Bob accepte et déchiffre A1.
  final sessionB = await bob.acceptHandshake(init.handshake);
  final recu1 = await bob.decrypt(sessionB, a1.header, a1.ciphertext);
  if (lire(recu1) != 'A1') fail('A1 mal déchiffré : ${lire(recu1)}');
  ok('Bob déchiffre A1');

  // 3) Bob répond B1. Cette réponse fait avancer son ratchet.
  final b1 = await bob.encrypt(sessionB, texte('B1'));
  ok('Bob répond B1 (son ratchet avance)');

  // 4) Alice envoie A2 SANS avoir lu B1 : elle chiffre encore sur l'ancienne
  //    chaîne, ne connaissant pas la nouvelle clé publique de Bob.
  final a2 = await alice.encrypt(sessionA, texte('A2'));

  // 5) Bob reçoit A2. C'est le cas qui compte.
  try {
    final recu2 = await bob.decrypt(sessionB, a2.header, a2.ciphertext);
    if (lire(recu2) != 'A2') fail('A2 mal déchiffré : ${lire(recu2)}');
    ok('Bob déchiffre A2 arrivé APRÈS sa propre réponse');
  } catch (e) {
    fail('Bob ne déchiffre pas A2 : $e\n'
        '     Un message émis avant la réponse du correspondant, mais reçu '
        'après, doit rester déchiffrable.');
  }

  // 6) Et Alice doit toujours pouvoir lire B1, reçu en retard.
  try {
    final recuB1 = await alice.decrypt(sessionA, b1.header, b1.ciphertext);
    if (lire(recuB1) != 'B1') fail('B1 mal déchiffré : ${lire(recuB1)}');
    ok('Alice déchiffre B1 lu en retard');
  } catch (e) {
    fail('Alice ne déchiffre pas B1 : $e');
  }

  // 7) La conversation continue normalement après le croisement.
  final a3 = await alice.encrypt(sessionA, texte('A3'));
  final recu3 = await bob.decrypt(sessionB, a3.header, a3.ciphertext);
  if (lire(recu3) != 'A3') fail('A3 mal déchiffré');
  ok('la conversation reprend normalement après le croisement');

  stdout.writeln('\n$_checks vérifications passées');
  await alice.dispose();
  await bob.dispose();
  exit(0);
}
