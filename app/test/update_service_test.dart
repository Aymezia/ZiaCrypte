import 'package:flutter_test/flutter_test.dart';
import 'package:ziacrypte/core/update/update_service.dart';

/// La comparaison de versions décide si l'on télécharge et installe du code.
/// Une erreur ici fait soit rater toutes les mises à jour, soit réinstaller
/// indéfiniment la même — ou pire, accepter une version PLUS ANCIENNE, ce qui
/// permettrait de faire redescendre un utilisateur vers une version vulnérable.
void main() {
  group('comparaison de versions', () {
    test('détecte une version plus récente', () {
      expect(UpdateService.isNewer('0.8.2', '0.8.1'), isTrue);
      expect(UpdateService.isNewer('0.9.0', '0.8.9'), isTrue);
      expect(UpdateService.isNewer('1.0.0', '0.99.99'), isTrue);
    });

    test('refuse une version identique ou plus ancienne', () {
      expect(UpdateService.isNewer('0.8.1', '0.8.1'), isFalse);
      expect(UpdateService.isNewer('0.8.0', '0.8.1'), isFalse);
      expect(UpdateService.isNewer('0.9.0', '1.0.0'), isFalse);
      // Le cas dangereux : une release plus ancienne ne doit JAMAIS passer.
      expect(UpdateService.isNewer('0.1.0', '0.8.1'), isFalse);
    });

    test('tolère le préfixe « v » des étiquettes git', () {
      expect(UpdateService.isNewer('v0.8.2', '0.8.1'), isTrue);
      expect(UpdateService.isNewer('v0.8.1', '0.8.1'), isFalse);
    });

    test('compare numériquement, pas alphabétiquement', () {
      // « 10 » vient après « 9 » ; une comparaison de chaînes dirait l'inverse.
      expect(UpdateService.isNewer('0.10.0', '0.9.0'), isTrue);
      expect(UpdateService.isNewer('0.9.0', '0.10.0'), isFalse);
    });

    test('gère les composants manquants ou non numériques', () {
      expect(UpdateService.isNewer('1.0', '0.9.9'), isTrue);
      expect(UpdateService.isNewer('0.8.1-beta', '0.8.1'), isFalse);
      expect(UpdateService.isNewer('', '0.8.1'), isFalse);
    });
  });

  test('sans clé publique intégrée, la signature n’est pas configurée', () {
    // Compilé sans --dart-define=ZIA_UPDATE_PUBKEY : la mise à jour
    // automatique doit rester inactive plutôt que d'installer sans vérifier.
    expect(UpdateService.signingConfigured, isFalse);
  });
}
