// Test d'intégration : les statuts, entre DEUX clients réels.
//
// Deux choses sous ce nom : la présence (« en ligne »), qui passe par la
// passerelle, et le statut personnel (« En réunion »), qui passe par le canal
// chiffré. Elles partagent ce banc d'essai parce qu'elles partagent la même
// promesse : rien ne sort sans que l'utilisateur l'ait voulu, et le serveur
// n'apprend rien de plus qu'il ne savait déjà.
//
// ## Pourquoi ce test existe
//
// La présence traverse quatre couches : le réglage local, la passerelle
// WebSocket, l'autorisation en base, puis l'affichage. Chacune peut être juste
// isolément pendant que la chaîne ne fonctionne pas — c'est exactement la
// panne de la phase 33, où un chemin correct n'était jamais emprunté. Les
// épreuves du serveur (server/test/presence.test.ts) parlent du protocole ;
// celle-ci parle de l'application.
//
// Elle affirme deux choses qu'aucun test unitaire ne peut dire : « quand Bob
// accepte d'être vu, Alice le voit », et surtout « tant que Bob n'a rien
// accepté, Alice ne voit rien » — le défaut par défaut, celui qui doit tenir.
//
// Prérequis : serveur local dédié, ZIA_CRYPTO_LIB, trousseau.
// Lanceur : scripts/run-integration-tests.sh.

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
    await Future<void>.delayed(const Duration(milliseconds: 250));
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

  group('Statuts de bout en bout (deux clients)', () {
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
    });

    test('la pastille suit le consentement de Bob, et rien d’autre', () async {
      if (!moteurDispo) {
        markTestSkipped('ZIA_CRYPTO_LIB absent');
        return;
      }
      if (!_dedie) {
        markTestSkipped(
            'lance scripts/run-integration-tests.sh (serveur dédié requis)');
        return;
      }
      if (!pret) {
        markTestSkipped('serveur d’essai injoignable sur $_serveur');
        return;
      }

      final suffixe = DateTime.now().microsecondsSinceEpoch;
      final nomAlice = 'prs_a_$suffixe';
      final nomBob = 'prs_b_$suffixe';

      await alice.registerAndConnect(
          user: nomAlice, password: 'password123', serverUrl: _serveur);
      await bob.registerAndConnect(
          user: nomBob, password: 'password123', serverUrl: _serveur);
      expect(alice.connected, isTrue, reason: alice.error ?? '');
      expect(bob.connected, isTrue, reason: bob.error ?? '');

      await alice.startChatWith(nomBob);
      final conv = alice.active;
      expect(conv, isNotNull, reason: 'conversation non ouverte : ${alice.error}');
      expect(await _attendre(() => conv!.sessions.isNotEmpty), isTrue,
          reason: 'aucune session ouverte avec Bob');

      // Bob est connecté, mais n'a rien accepté : c'est l'état par défaut, et
      // celui de tous les clients antérieurs à la fonctionnalité.
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(alice.enLigneDans(conv!.id), isFalse,
          reason: 'Bob apparaît en ligne SANS avoir accepté de se montrer — '
              'le réglage par défaut ne protège pas');

      // Bob accepte.
      bob.partagePresenceActif = true;
      expect(await _attendre(() => alice.enLigneDans(conv.id)), isTrue,
          reason: 'Bob a accepté d’être vu et n’apparaît pas : la chaîne '
              'réglage → passerelle → affichage est rompue');

      // Bob se ravise : la pastille doit s'éteindre sans qu'il se déconnecte.
      bob.partagePresenceActif = false;
      expect(await _attendre(() => !alice.enLigneDans(conv.id)), isTrue,
          reason: 'le retrait du consentement ne s’applique pas');

      await alice.logout();
      await bob.logout();
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('le statut personnel voyage chiffré, et s’efface', () async {
      if (!moteurDispo) {
        markTestSkipped('ZIA_CRYPTO_LIB absent');
        return;
      }
      if (!_dedie) {
        markTestSkipped(
            'lance scripts/run-integration-tests.sh (serveur dédié requis)');
        return;
      }
      if (!pret) {
        markTestSkipped('serveur d’essai injoignable sur $_serveur');
        return;
      }

      final suffixe = DateTime.now().microsecondsSinceEpoch;
      final nomAlice = 'sta_a_$suffixe';
      final nomBob = 'sta_b_$suffixe';

      await alice.registerAndConnect(
          user: nomAlice, password: 'password123', serverUrl: _serveur);
      await bob.registerAndConnect(
          user: nomBob, password: 'password123', serverUrl: _serveur);
      expect(alice.connected, isTrue, reason: alice.error ?? '');
      expect(bob.connected, isTrue, reason: bob.error ?? '');
      final idAlice = alice.userId!;

      await alice.startChatWith(nomBob);
      final conv = alice.active;
      expect(await _attendre(() => conv!.sessions.isNotEmpty), isTrue,
          reason: 'aucune session ouverte avec Bob');

      await alice.definirStatut('En réunion');
      expect(await _attendre(() => bob.statutDe(idAlice) == 'En réunion'), isTrue,
          reason: 'le statut n’a pas traversé le canal chiffré');

      // Le statut ne doit JAMAIS apparaître comme un message dans le fil : il
      // porte un préfixe de contrôle, et un préfixe oublié se voit ici.
      final convBob = bob.conversations.firstWhere((c) => c.messages.isNotEmpty,
          orElse: () => bob.conversations.first);
      expect(convBob.messages.any((m) => m.text.contains('__zia_status__')),
          isFalse,
          reason: 'le message de contrôle brut s’affiche dans la conversation');

      // Longueur bornée à la RÉCEPTION : l'appareil d'en face décide ce qu'il
      // envoie, et on ne veut pas d'un statut de dix lignes dans un en-tête.
      await alice.definirStatut('x' * 200);
      expect(
          await _attendre(
              () => (bob.statutDe(idAlice)?.length ?? 0) == ChatService.statutMax),
          isTrue,
          reason: 'statut reçu non borné : ${bob.statutDe(idAlice)?.length}');

      await alice.definirStatut('');
      expect(await _attendre(() => bob.statutDe(idAlice) == null), isTrue,
          reason: 'effacer son statut ne l’efface pas chez le correspondant');

      await alice.logout();
      await bob.logout();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
