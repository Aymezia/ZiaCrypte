// Test d'intégration : envoi en échec puis renvoi, contre un vrai serveur.
//
// Ce que ça prouve, et qu'aucun test unitaire ne peut affirmer : quand l'envoi
// échoue pour de bon (réseau coupé), le message NE DISPARAÎT PAS — il reste
// affiché, marqué en échec — et un renvoi, une fois le réseau revenu, le fait
// réellement partir et arriver chez le correspondant.
//
// On simule la coupure avec un ApiClient dont on peut « casser » l'envoi à
// volonté, sans toucher au vrai réseau ni au serveur.
//
// Prérequis : serveur local dédié, ZIA_CRYPTO_LIB, trousseau.
// Lanceur : scripts/run-integration-tests.sh.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ziacrypte/core/network/api_client.dart';
import 'package:ziacrypte/features/chat/data/chat_service.dart';

const _dedie = bool.hasEnvironment('ZIA_TEST_SERVER');
const _serveur = String.fromEnvironment('ZIA_TEST_SERVER',
    defaultValue: 'http://127.0.0.1:3210');

/// ApiClient dont l'envoi peut être coupé, pour simuler une panne réseau.
class _ApiCassable extends ApiClient {
  _ApiCassable(super.baseUrl);
  bool casse = false;

  @override
  Future<void> sendMessage({
    required String conversationId,
    required String recipientDeviceId,
    required String clientMessageId,
    required String headerB64,
    required String ciphertextB64,
  }) {
    if (casse) throw const SocketException('réseau coupé (test)');
    return super.sendMessage(
      conversationId: conversationId,
      recipientDeviceId: recipientDeviceId,
      clientMessageId: clientMessageId,
      headerB64: headerB64,
      ciphertextB64: ciphertextB64,
    );
  }
}

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

  group('Envoi en échec puis renvoi (deux clients)', () {
    late ChatService alice;
    late ChatService bob;
    bool pret = false;

    setUpAll(() async {
      if (!moteurDispo || !_dedie) return;
      pret = await _serveurJoignable();
    });

    setUp(() {
      if (!moteurDispo || !_dedie || !pret) return;
      ChatService.fabriqueApi = (url) => _ApiCassable(url);
      alice = ChatService();
      bob = ChatService();
    });

    tearDown(() => ChatService.fabriqueApi = ApiClient.new);

    test('un envoi raté reste affiché, et le renvoi le fait arriver', () async {
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
      final nomBob = 'ech_b_$suffixe';
      await alice.registerAndConnect(
          user: 'ech_a_$suffixe', password: 'password123', serverUrl: _serveur);
      await bob.registerAndConnect(
          user: nomBob, password: 'password123', serverUrl: _serveur);
      expect(alice.connected, isTrue, reason: alice.error ?? '');
      expect(bob.connected, isTrue, reason: bob.error ?? '');

      await alice.startChatWith(nomBob);
      final conv = alice.active;
      expect(conv, isNotNull);
      expect(await _attendre(() => conv!.ready), isTrue,
          reason: 'session avec Bob non ouverte');

      // Réseau coupé : l'envoi échoue.
      final espion = alice.api! as _ApiCassable;
      espion.casse = true;
      await alice.send('message pendant la panne');

      // Le message n'a PAS disparu : il est là, marqué en échec.
      final rate = conv!.messages
          .where((m) => m.text == 'message pendant la panne' && m.mine)
          .toList();
      expect(rate, hasLength(1),
          reason: 'un envoi raté doit rester affiché, pas disparaître');
      expect(rate.single.sendFailed, isTrue,
          reason: 'le message raté doit être marqué en échec');

      // Réseau revenu : on réessaie, le message part réellement.
      espion.casse = false;
      await alice.renvoyer(rate.single);

      final envoye = conv.messages.any(
          (m) => m.text == 'message pendant la panne' && m.mine && !m.sendFailed);
      expect(envoye, isTrue, reason: 'après renvoi, le message doit être en état normal');

      // Et Bob le reçoit pour de vrai.
      final recu = await _attendre(() => bob.conversations.any((c) =>
          c.messages.any((m) => m.text == 'message pendant la panne' && !m.mine)));
      expect(recu, isTrue, reason: 'Bob n’a pas reçu le message renvoyé : ${bob.error}');

      await alice.logout();
      await bob.logout();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
