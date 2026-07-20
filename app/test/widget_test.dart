import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ziacrypte/core/config/app_settings.dart';
import 'package:ziacrypte/main.dart';

void main() {
  testWidgets('les écrans d’accueil s’affichent au tout premier lancement',
      (tester) async {
    await tester.pumpWidget(ZiaCrypteApp(
      settingsOverride: AppSettings.pourTests(onboardingVu: false),
    ));

    // Ce qu'on promet, et ce qu'on ne promet pas, avant tout formulaire.
    expect(find.text('Personne ne peut lire tes messages'), findsOneWidget);
    expect(find.text('Suivant'), findsOneWidget);

    await tester.tap(find.text('Suivant'));
    await tester.pumpAndSettle();

    expect(find.text('Tes clés n’existent que chez toi'), findsOneWidget);
    expect(find.text('Commencer'), findsOneWidget);
  });

  testWidgets('l’écran de connexion s’affiche une fois l’accueil vu',
      (tester) async {
    await tester.pumpWidget(ZiaCrypteApp(
      settingsOverride: AppSettings.pourTests(onboardingVu: true),
    ));

    expect(find.text('ZiaCrypte'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Mot de passe'), findsOneWidget);

    // Selon qu'un compte existe déjà sur la machine, l'écran propose la
    // création ou la reconnexion : l'un des deux doit être présent.
    final creer = find.text('Créer mon compte');
    final reconnecter = find.text('Se reconnecter');
    expect(creer.evaluate().length + reconnecter.evaluate().length, 1);

    // L'adresse du serveur est intégrée à la compilation : jamais demandée.
    expect(find.widgetWithText(TextFormField, 'Adresse du serveur'), findsNothing);
  });

  testWidgets('le mot de passe trop court est refusé', (tester) async {
    await tester.pumpWidget(ZiaCrypteApp(
      settingsOverride: AppSettings.pourTests(onboardingVu: true),
    ));

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Mot de passe'), 'court');
    await tester.tap(find.byType(FilledButton).first);
    await tester.pump();

    expect(find.text('8 caractères minimum'), findsOneWidget);
  });
}
