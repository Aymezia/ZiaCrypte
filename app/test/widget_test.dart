import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ziacrypte/main.dart';

void main() {
  testWidgets('l’écran de connexion s’affiche au démarrage', (tester) async {
    await tester.pumpWidget(const ZiaCrypteApp());

    expect(find.text('ZiaCrypte'), findsOneWidget);
    expect(find.text('Créer mon compte'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Adresse du serveur'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Nom d’utilisateur'), findsOneWidget);
  });

  testWidgets('le formulaire refuse un pseudo trop court', (tester) async {
    await tester.pumpWidget(const ZiaCrypteApp());

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Nom d’utilisateur'), 'ab');
    await tester.tap(find.text('Créer mon compte'));
    await tester.pump();

    expect(find.text('3 caractères minimum'), findsOneWidget);
  });
}
