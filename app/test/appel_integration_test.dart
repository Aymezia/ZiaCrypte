// Test d'intégration : signalisation d'appel chiffrée, entre DEUX clients.
//
// La voix (WebRTC) n'est pas encore branchée — c'est la phase 3b. Ce test
// prouve la brique dessous : la signalisation d'appel voyage chiffrée par le
// Double Ratchet (donc authentifiée : le serveur ne peut pas la forger), et la
// machine à états avance de bout en bout — sonnerie, acceptation, raccroché.
//
// Prérequis : serveur local dédié (avec TURN configuré par le lanceur),
// ZIA_CRYPTO_LIB, trousseau. Lanceur : scripts/run-integration-tests.sh.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ziacrypte/features/chat/data/chat_service.dart';

const _dedie = bool.hasEnvironment('ZIA_TEST_SERVER');
const _serveur = String.fromEnvironment('ZIA_TEST_SERVER',
    defaultValue: 'http://127.0.0.1:3210');

Future<bool> _attendre(bool Function() pret,
    {Duration limite = const Duration(seconds: 25)}) async {
  final fin = DateTime.now().add(limite);
  while (DateTime.now().isBefore(fin)) {
    if (pret()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return pret();
}

Future<bool> _serveurJoignable() async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    final req = await client.postUrl(Uri.parse('$_serveur/v1/reports'));
    req.headers.contentType = ContentType.json;
    req.write('{}');
    final res = await req.close();
    await res.drain<void>();
    client.close();
    return res.statusCode == 401;
  } catch (_) {
    return false;
  }
}

void main() {
  final libPath = Platform.environment['ZIA_CRYPTO_LIB'];
  final moteurDispo = libPath != null && File(libPath).existsSync();

  group('Signalisation d’appel (deux clients)', () {
    late ChatService alice;
    late ChatService bob;
    bool pret = false;

    setUpAll(() async {
      if (!moteurDispo || !_dedie) return;
      pret = await _serveurJoignable();
    });

    setUp(() {
      if (!moteurDispo || !_dedie || !pret) return;
      alice = ChatService();
      bob = ChatService();
      // WebRTC exige un binding natif absent d'un `flutter test` : on n'éprouve
      // ici que la SIGNALISATION. Le média se vérifie sur appareil.
      alice.activerMediaAppel = false;
      bob.activerMediaAppel = false;
    });

    test('sonnerie, acceptation, raccroché — le tout chiffré', () async {
      if (!moteurDispo) {
        markTestSkipped('ZIA_CRYPTO_LIB absent');
        return;
      }
      if (!_dedie) {
        markTestSkipped('lance scripts/run-integration-tests.sh (serveur dédié requis)');
        return;
      }
      if (!pret) {
        markTestSkipped('serveur d’essai injoignable sur $_serveur');
        return;
      }

      final suffixe = DateTime.now().microsecondsSinceEpoch;
      final nomBob = 'apl_b_$suffixe';
      await alice.registerAndConnect(
          user: 'apl_a_$suffixe', password: 'password123', serverUrl: _serveur);
      await bob.registerAndConnect(
          user: nomBob, password: 'password123', serverUrl: _serveur);
      expect(alice.connected, isTrue, reason: alice.error ?? '');
      expect(bob.connected, isTrue, reason: bob.error ?? '');

      await alice.startChatWith(nomBob);
      final conv = alice.active;
      expect(conv, isNotNull);
      expect(await _attendre(() => conv!.ready), isTrue,
          reason: 'session avec Bob non ouverte');

      // On appelle quelqu'un avec qui on discute déjà : un premier message
      // établit la session de Bob vers Alice. On attend qu'il l'ait reçu, sinon
      // le signal d'appel (temps réel) pourrait devancer le message (relevé).
      await alice.send('coucou avant l’appel');
      expect(
          await _attendre(() => bob.conversations
              .expand((c) => c.messages)
              .any((m) => m.text == 'coucou avant l’appel' && !m.mine)),
          isTrue,
          reason: 'Bob n’a pas reçu le message préalable');

      // Alice appelle : chez elle « sortant », et ça doit sonner chez Bob.
      await alice.appeler(conv!);
      expect(alice.callEtat, CallEtat.sortant,
          reason: 'l’appel n’a pas démarré : ${alice.error}');

      expect(await _attendre(() => bob.callEtat == CallEtat.entrant), isTrue,
          reason: 'l’appel ne sonne pas chez Bob (signal non déchiffré ?)');
      expect(bob.callId, equals(alice.callId));

      // L'appelant a récupéré des serveurs relais (TURN).
      expect(alice.callIceServers, isNotNull,
          reason: 'Alice n’a pas d’identifiants TURN');

      // Bob accepte : les deux passent à « connecté ».
      await bob.accepterAppel();
      expect(await _attendre(() => alice.callEtat == CallEtat.connecte), isTrue,
          reason: 'Alice n’a pas vu l’acceptation');
      expect(bob.callEtat, CallEtat.connecte);

      // …et l'appelé AUSSI : en relais forcé, sans ses propres serveurs ICE il
      // ne pourrait produire aucun candidat et l'appel resterait « en
      // connexion ». C'est le correctif : l'appelé récupère ses identifiants.
      expect(bob.callIceServers, isNotNull,
          reason: 'Bob (appelé) n’a pas récupéré ses identifiants TURN');

      // Bob raccroche : les deux reviennent à « aucun ».
      await bob.raccrocher();
      expect(await _attendre(() => alice.callEtat == CallEtat.aucun), isTrue,
          reason: 'le raccroché ne s’est pas propagé à Alice');
      expect(bob.enAppel, isFalse);

      // L'appel a accepté puis raccroché : chacun garde une trace « Appel … »
      // dans le fil, côté appelant comme côté appelé. Ici le média est
      // désactivé (WebRTC natif absent des tests), donc la trace est « Appel
      // échoué » ; avec média réel et abouti, ce serait « Appel · durée ».
      bool traceAppel(ChatService s) => s.conversations
          .expand((c) => c.messages)
          .any((m) => m.systeme && m.text.startsWith('Appel'));
      expect(await _attendre(() => traceAppel(bob)), isTrue,
          reason: 'Bob n’a pas de trace d’appel dans le fil');
      expect(await _attendre(() => traceAppel(alice)), isTrue,
          reason: 'Alice n’a pas de trace d’appel dans le fil');

      await alice.logout();
      await bob.logout();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
