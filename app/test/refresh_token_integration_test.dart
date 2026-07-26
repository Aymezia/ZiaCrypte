// Test d'intégration : renouvellement automatique du jeton d'accès.
//
// Le jeton d'accès dure 15 minutes. Sans renouvellement, l'application se
// retrouvait « déconnectée » passé ce délai : chaque requête tombait en 401
// alors qu'une session valide existait encore. Ce test prouve que, sur 401, le
// client reprend un nouveau jeton avec le refresh token et rejoue la requête —
// de façon transparente.
//
// On simule l'expiration en remplaçant le jeton d'accès par une valeur
// invalide, tout en gardant le refresh token : c'est exactement l'état d'une
// session dont le jeton court a expiré.
//
// Prérequis : serveur local dédié, ZIA_CRYPTO_LIB, trousseau.
// Lanceur : scripts/run-integration-tests.sh.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ziacrypte/features/chat/data/chat_service.dart';

const _dedie = bool.hasEnvironment('ZIA_TEST_SERVER');
const _serveur = String.fromEnvironment('ZIA_TEST_SERVER',
    defaultValue: 'http://127.0.0.1:3210');

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

  group('Renouvellement du jeton d’accès', () {
    late ChatService alice;
    bool pret = false;

    setUpAll(() async {
      if (!moteurDispo || !_dedie) return;
      pret = await _serveurJoignable();
    });

    setUp(() {
      if (!moteurDispo || !_dedie || !pret) return;
      alice = ChatService();
    });

    test('un jeton d’accès expiré est renouvelé, la requête aboutit', () async {
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

      final nom = 'ref_${DateTime.now().microsecondsSinceEpoch}';
      await alice.registerAndConnect(
          user: nom, password: 'password123', serverUrl: _serveur);
      expect(alice.connected, isTrue, reason: alice.error ?? '');

      final api = alice.api!;
      expect(api.refreshToken, isNotNull,
          reason: 'le refresh token doit être conservé à la connexion');

      // On casse le jeton d'accès, comme s'il avait expiré — le refresh token,
      // lui, reste valide.
      const bidon = 'eyJ.invalide.expire';
      api.accessToken = bidon;

      // Une requête authentifiée : elle prend un 401, le client renouvelle en
      // coulisse, rejoue, et réussit.
      final moi = await api.lookupUser(nom);
      expect(moi['id'], equals(alice.userId),
          reason: 'la requête aurait dû aboutir après renouvellement');

      // Le jeton d'accès a bien été remplacé par un neuf.
      expect(api.accessToken, isNot(equals(bidon)),
          reason: 'le jeton d’accès n’a pas été renouvelé');

      await alice.logout();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
