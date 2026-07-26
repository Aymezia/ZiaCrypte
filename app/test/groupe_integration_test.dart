// Test d'intégration : DEUX clients réels contre le serveur local.
//
// ## Pourquoi ce test existe
//
// La phase 33 (expéditeur scellé) a été écrite, compilée, analysée et livrée —
// et elle était INERTE : le message de contrôle qui distribue le jeton n'était
// jamais émis. Rien ne l'a signalé, parce que tous les tests portaient sur des
// morceaux pris isolément. Un chemin peut être parfaitement correct et n'être
// jamais emprunté.
//
// Ce test affirme donc quelque chose qu'aucun test unitaire ne peut dire :
// « quand on envoie dans un groupe, c'est BIEN l'appel groupé qui part, une
// seule fois, et le correspondant lit le message ».
//
// Prérequis : serveur local sur 127.0.0.1:3210, ZIA_CRYPTO_LIB, trousseau.
// Le lanceur scripts/run-app-tests.sh fournit les deux derniers.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ziacrypte/core/network/api_client.dart';
import 'package:ziacrypte/features/chat/data/chat_service.dart';

// Ce test n'est PAS lancé par la suite standard : il exige une instance de
// serveur dédiée, fournie par scripts/run-integration-tests.sh via ce
// dart-define. Sans lui, il viserait le serveur en service — y créant des
// comptes d'essai, et échouant sur ses limites de débit dès la deuxième
// exécution. Un test qui échoue pour une raison étrangère au code finit par
// être ignoré ; il vaut mieux qu'il s'abstienne.
const _dedie = bool.hasEnvironment('ZIA_TEST_SERVER');
const _serveur = String.fromEnvironment('ZIA_TEST_SERVER',
    defaultValue: 'http://127.0.0.1:3210');

/// Client API qui compte ce qui part réellement.
class _ApiEspion extends ApiClient {
  _ApiEspion(super.baseUrl);

  int envoisUnitaires = 0;
  int envoisGroupes = 0;

  @override
  Future<void> sendMessage({
    required String conversationId,
    required String recipientDeviceId,
    required String clientMessageId,
    required String headerB64,
    required String ciphertextB64,
  }) {
    envoisUnitaires++;
    return super.sendMessage(
      conversationId: conversationId,
      recipientDeviceId: recipientDeviceId,
      clientMessageId: clientMessageId,
      headerB64: headerB64,
      ciphertextB64: ciphertextB64,
    );
  }

  @override
  Future<void> sendGroupMessage({
    required String conversationId,
    required String clientMessageId,
    required List<String> recipientDeviceIds,
    required String headerB64,
    required String ciphertextB64,
  }) {
    envoisGroupes++;
    return super.sendGroupMessage(
      conversationId: conversationId,
      clientMessageId: clientMessageId,
      recipientDeviceIds: recipientDeviceIds,
      headerB64: headerB64,
      ciphertextB64: ciphertextB64,
    );
  }
}

/// Attend qu'une condition devienne vraie, ou abandonne. Sans borne, un échec
/// se traduirait par un test qui pend au lieu d'un test qui échoue.
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
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);
    final uri = Uri.parse('$_serveur/v1/reports');
    final req = await client.postUrl(uri);
    req.headers.contentType = ContentType.json;
    req.write('{}');
    final res = await req.close();
    await res.drain<void>();
    client.close();
    // 401 = la route existe et exige une authentification : serveur à jour.
    return res.statusCode == 401;
  } catch (_) {
    return false;
  }
}

void main() {
  final libPath = Platform.environment['ZIA_CRYPTO_LIB'];
  final moteurDispo = libPath != null && File(libPath).existsSync();

  group('Groupe de bout en bout (deux clients)', () {
    late ChatService alice;
    late ChatService bob;
    late _ApiEspion espionAlice;
    bool pret = false;

    setUpAll(() async {
      if (!moteurDispo || !_dedie) return;
      pret = await _serveurJoignable();
    });

    setUp(() async {
      if (!moteurDispo || !_dedie || !pret) return;
      ChatService.fabriqueApi = (url) => _ApiEspion(url);
      alice = ChatService();
      bob = ChatService();
    });

    tearDown(() async {
      ChatService.fabriqueApi = ApiClient.new;
    });

    test('un envoi de groupe emprunte le chemin GROUPÉ et arrive', () async {
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
      final nomAlice = 'itg_a_$suffixe';
      final nomBob = 'itg_b_$suffixe';

      await alice.registerAndConnect(
          user: nomAlice, password: 'password123', serverUrl: _serveur);
      await bob.registerAndConnect(
          user: nomBob, password: 'password123', serverUrl: _serveur);
      expect(alice.connected, isTrue, reason: alice.error ?? '');
      expect(bob.connected, isTrue, reason: bob.error ?? '');

      espionAlice = alice.api! as _ApiEspion;

      // Alice crée un groupe avec Bob.
      await alice.createGroup(name: 'Essai', memberUsernames: [nomBob]);
      final conv = alice.active;
      expect(conv, isNotNull, reason: 'groupe non créé : ${alice.error}');
      expect(conv!.isGroup, isTrue);

      // Les sessions pair-à-pair doivent être ouvertes : c'est par elles que la
      // clé de groupe est distribuée.
      expect(await _attendre(() => conv.sessions.isNotEmpty), isTrue,
          reason: 'aucune session ouverte, la clé ne peut pas être distribuée');

      // PREMIER envoi : il porte aussi la distribution de la clé, qui passe
      // légitimement par le canal pair-à-pair (donc par des envois unitaires).
      // On ne peut donc rien conclure de son compte d'unitaires.
      final groupesAvant = espionAlice.envoisGroupes;
      await alice.send('bonjour le groupe');
      expect(espionAlice.envoisGroupes, groupesAvant + 1,
          reason: 'le chemin groupé n’a PAS été emprunté — comme la phase 33, '
              'le code serait présent mais inerte');

      // On ne mesure PAS le nombre d'envois unitaires.
      //
      // Ce serait tentant — « le message ne doit coûter aucun envoi par
      // appareil » — mais la mesure ne peut pas trancher ici : avec UN SEUL
      // appareil destinataire, une diffusion appareil-par-appareil coûterait un
      // envoi unitaire, et le trafic de contrôle légitime (accusé de lecture,
      // rotation de la clé quand un appareil rejoint) en coûte un aussi. Les
      // deux sont indiscernables. Asserter là-dessus donnerait un test qui
      // échoue pour de mauvaises raisons, donc qu'on finirait par ignorer.
      //
      // Ce qui EST démontrable, et suffit à couvrir la panne de la phase 33 :
      // le chemin groupé est réellement emprunté, et le message arrive.

      // Et Bob le lit réellement.
      final recu = await _attendre(() => bob.conversations.any((c) =>
          c.messages.any((m) => m.text == 'bonjour le groupe' && !m.mine)));
      expect(recu, isTrue,
          reason: 'Bob n’a pas déchiffré le message de groupe : ${bob.error}');

      // Le message reçu porte le pseudo de l'auteur : c'est ce qui permet
      // d'afficher qui parle dans un groupe. Sans ça, à plusieurs, les bulles
      // reçues seraient anonymes.
      final message = bob.conversations
          .expand((c) => c.messages)
          .firstWhere((m) => m.text == 'bonjour le groupe' && !m.mine);
      expect(message.author, equals(nomAlice),
          reason: 'le message de groupe reçu ne nomme pas son auteur');

      // Non-lus : Bob n'a jamais ouvert ce groupe, le message reçu doit donc
      // l'avoir marqué non-lu. L'ouvrir remet le compteur à zéro.
      final convBob =
          bob.conversations.firstWhere((c) => c.messages.contains(message));
      expect(convBob.unread, greaterThanOrEqualTo(1),
          reason: 'un message reçu hors conversation ouverte doit compter comme non-lu');
      bob.openConversation(convBob.id);
      expect(convBob.unread, equals(0),
          reason: 'ouvrir la conversation doit remettre les non-lus à zéro');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
