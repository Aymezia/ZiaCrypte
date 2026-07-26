// Test d'intégration : un canal de diffusion, entre DEUX clients réels.
//
// Toute la chaîne d'un canal traverse le moteur, le pont FFI, le serveur et
// l'affichage — et chaque maillon peut être juste isolément pendant que
// l'ensemble ne fonctionne pas. Ce test affirme ce qu'aucun test unitaire ne
// peut dire :
//
//   - l'admin crée un canal, en obtient un lien, et publie ;
//   - un second client REJOINT par ce lien seul — sans contact préalable — et
//     LIT le message ; c'est tout l'intérêt du « lien = clé » ;
//   - un lien au secret falsifié n'ouvre rien.
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

  group('Canal de bout en bout (deux clients)', () {
    late ChatService admin;
    late ChatService abonne;
    bool pret = false;

    setUpAll(() async {
      if (!moteurDispo || !_dedie) return;
      pret = await _serveurJoignable();
    });

    setUp(() {
      if (!moteurDispo || !_dedie || !pret) return;
      admin = ChatService();
      abonne = ChatService();
    });

    test('rejoindre par lien, puis lire un post ; un faux lien échoue', () async {
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
      await admin.registerAndConnect(
          user: 'cnl_a_$suffixe', password: 'password123', serverUrl: _serveur);
      await abonne.registerAndConnect(
          user: 'cnl_b_$suffixe', password: 'password123', serverUrl: _serveur);
      expect(admin.connected, isTrue, reason: admin.error ?? '');
      expect(abonne.connected, isTrue, reason: abonne.error ?? '');

      // L'admin crée le canal et récupère le lien d'invitation.
      final lien = await admin.creerCanal('Annonces');
      expect(lien, isNotNull, reason: 'création du canal échouée : ${admin.error}');
      expect(lien!.startsWith('ziacrypte://canal/'), isTrue);
      final conv = admin.active;
      expect(conv, isNotNull);
      expect(conv!.isChannel, isTrue);
      expect(conv.channelIsAdmin, isTrue);

      // Un lien au secret falsifié ne doit rien ouvrir. On abîme le fragment
      // (le secret est le premier segment après le « # »).
      final diese = lien.indexOf('#');
      final faux = '${lien.substring(0, diese + 1)}AAAA.${lien.substring(lien.indexOf('.') + 1)}';
      final rejoint = await abonne.rejoindreCanalParLien(faux);
      expect(rejoint, isFalse, reason: 'un lien falsifié n’aurait pas dû ouvrir le canal');

      // Le VRAI lien, lui, ouvre le canal.
      final ok = await abonne.rejoindreCanalParLien(lien);
      expect(ok, isTrue, reason: 'adhésion par lien échouée : ${abonne.error}');
      final convAbonne = abonne.conversations.firstWhere((c) => c.id == conv.id);
      expect(convAbonne.isChannel, isTrue);
      expect(convAbonne.channelIsAdmin, isFalse);

      // L'admin publie ; l'abonné doit le lire, remis par le tuyau commun.
      await admin.publierDansCanal('La version 0.11 est disponible.');
      // Chez l'admin, son propre post s'affiche tout de suite.
      expect(conv.messages.any((m) => m.mine && m.text.contains('0.11')), isTrue);

      final lu = await _attendre(() => abonne.conversations
          .any((c) => c.id == conv.id &&
              c.messages.any((m) => !m.mine && m.text.contains('0.11'))));
      expect(lu, isTrue, reason: 'l’abonné n’a pas lu le post : ${abonne.error}');

      // Renouvellement de clé : l'ancien lien doit cesser de fonctionner. C'est
      // ce qui retire réellement un abonné — sans ça, il garde de quoi lire.
      final nouveauLien = await admin.renouvelerCleCanal(conv);
      expect(nouveauLien, isNotNull, reason: 'renouvellement échoué : ${admin.error}');
      expect(nouveauLien, isNot(equals(lien)),
          reason: 'le nouveau lien doit différer de l’ancien');

      await admin.publierDansCanal('après rotation');
      expect(conv.messages.any((m) => m.mine && m.text.contains('après rotation')),
          isTrue);

      // L'abonné reçoit toujours le blob (encore inscrit côté serveur) mais ne
      // peut plus le DÉCHIFFRER : sa clé est périmée. Le message ne doit jamais
      // apparaître chez lui.
      await Future<void>.delayed(const Duration(seconds: 4));
      final litApres = abonne.conversations
          .expand((c) => c.messages)
          .any((m) => m.text.contains('après rotation'));
      expect(litApres, isFalse,
          reason: 'après renouvellement, l’ancien lien ne doit plus déchiffrer');

      await admin.logout();
      await abonne.logout();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
