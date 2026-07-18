import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ziacrypte/main.dart';

void main() {
  testWidgets('l’écran d’accueil s’affiche au démarrage', (tester) async {
    await tester.pumpWidget(const ZiaCrypteApp());

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
    await tester.pumpWidget(const ZiaCrypteApp());

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Mot de passe'), 'court');
    final bouton = find.byType(FilledButton);
    await tester.tap(bouton);
    await tester.pump();

    expect(find.text('8 caractères minimum'), findsOneWidget);
  });
}
