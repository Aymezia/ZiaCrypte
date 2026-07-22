// Bourrage : ce que la taille des blobs raconte au serveur.
//
// Deux façons pour ce code de casser, toutes deux silencieuses :
//
// 1. Le bourrage ne bourre pas assez — deux messages de longueurs différentes
//    sortent à des tailles différentes, et le serveur retrouve exactement ce
//    qu'on voulait lui cacher. Rien ne lève d'exception : les messages
//    arrivent, la fonctionnalité paraît marcher.
// 2. Le bourrage casse la charge utile — le JSON ne se relit plus, et c'est
//    TOUT le trafic qui tombe, y compris chez les clients déjà installés qui
//    n'ont jamais entendu parler de bourrage.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ziacrypte/features/chat/data/padding.dart';

void main() {
  group('Bourrage', () {
    test('tout ce qui est court sort à la même taille', () {
      // Un accusé de lecture, un « ok », une annonce de jeton : autant de
      // longueurs caractéristiques qui doivent devenir indiscernables.
      final charges = [
        jsonEncode({'t': 'ok'}),
        jsonEncode({'t': 'oui'}),
        jsonEncode({'t': 'à tout à l’heure, je te rappelle'}),
        '__zia_lu__:${jsonEncode({
              'ids': ['3f2a1b4c-0000-4444-8888-abcdefabcdef']
            })}',
      ];
      final tailles =
          charges.map((c) => bourrer(utf8.encode(c)).length).toSet();
      expect(tailles, equals({palierBourrage}),
          reason: 'des messages courts sortent à des tailles différentes : '
              'le serveur les distingue toujours');
    });

    test('la taille est toujours un multiple du palier', () {
      for (final n in [0, 1, 159, 160, 161, 320, 1000, 5000]) {
        final sortie = bourrer(utf8.encode('x' * n));
        expect(sortie.length % palierBourrage, 0, reason: 'longueur $n');
        expect(sortie.length, greaterThanOrEqualTo(n), reason: 'longueur $n');
      }
    });

    test('le surcoût ne dépasse jamais un palier', () {
      for (final n in [1, 200, 4321, 100000]) {
        final sortie = bourrer(utf8.encode('x' * n));
        expect(sortie.length - n, lessThan(palierBourrage), reason: 'longueur $n');
      }
    });

    test('un JSON bourré reste lisible — y compris par un client qui l’ignore',
        () {
      // C'est le point qui autorise à déployer sans négociation : le blanc de
      // fin est permis par la RFC 8259, donc les versions déjà installées
      // relisent la charge sans rien savoir du bourrage.
      final charge = jsonEncode({
        't': 'bonjour à toi',
        'i': '3f2a1b4c-0000-4444-8888-abcdefabcdef',
      });
      final bourre = bourrer(utf8.encode(charge));

      final relu = jsonDecode(utf8.decode(bourre)) as Map<String, dynamic>;
      expect(relu['t'], equals('bonjour à toi'));
      expect(relu['i'], equals('3f2a1b4c-0000-4444-8888-abcdefabcdef'));
    });

    test('les caractères non latins ne faussent pas le compte d’octets', () {
      // Le palier se compte en OCTETS, pas en caractères : un texte en
      // cyrillique ou avec des emoji doit atterrir sur le palier exactement
      // comme un texte latin, sinon la longueur reste distinctive.
      for (final texte in ['привет', '😀😀😀😀', 'こんにちは世界']) {
        final bourre = bourrer(utf8.encode(jsonEncode({'t': texte})));
        expect(bourre.length, equals(palierBourrage), reason: texte);
        expect((jsonDecode(utf8.decode(bourre)) as Map)['t'], equals(texte),
            reason: texte);
      }
    });

    test('un message long ne perd rien au passage', () {
      final texte = List.generate(500, (i) => 'ligne $i').join(' ');
      final bourre = bourrer(utf8.encode(jsonEncode({'t': texte})));
      expect((jsonDecode(utf8.decode(bourre)) as Map)['t'], equals(texte));
    });
  });
}
