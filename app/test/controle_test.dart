// Messages de contrôle : reconnaissance et sérialisation.
//
// Ces deux points cassent EN SILENCE, et au pire endroit possible.
//
// Un préfixe oublié dans la liste des contrôles fait apparaître le message
// technique brut — « __zia_avatar__:{"id":...} » — dans la conversation du
// correspondant, sous ses yeux, sans qu'aucune exception ne soit levée.
//
// Une sérialisation qui perd un champ fait échouer la fonctionnalité sans
// erreur : la photo n'arrive pas, et rien n'indique pourquoi.

import 'package:flutter_test/flutter_test.dart';
import 'package:ziacrypte/features/chat/data/chat_service.dart';

void main() {
  group('Messages de contrôle', () {
    test('tous les préfixes déclarés sont reconnus comme contrôles', () {
      for (final p in ChatService.prefixesControle) {
        expect(ChatService.estControle('${p}charge-utile'), isTrue,
            reason: '$p n’est pas reconnu : le message brut s’afficherait '
                'dans la conversation');
      }
    });

    test('un message ordinaire n’est jamais pris pour un contrôle', () {
      for (final texte in [
        'bonjour',
        '',
        'zia_avatar',
        '__zia__',
        'je parle de __zia_avatar__: dans une phrase',
      ]) {
        expect(ChatService.estControle(texte), isFalse, reason: texte);
      }
    });

    test('l’annonce d’avatar survit à l’aller-retour', () {
      const ref = AttachmentRef(
        id: '3f2a1b4c-0000-4444-8888-abcdefabcdef',
        keyBase64: 'a2V5LWRlLXRlc3QtMzItb2N0ZXRzLWljaQ==',
        fileName: 'photo.png',
        size: 14405,
      );
      final charge = ChatService.encoderAvatar(ref);

      // C'est le point que la vérification manuelle n'avait jamais atteint.
      expect(ChatService.estControle(charge), isTrue,
          reason: 'sinon l’annonce s’afficherait comme un message');

      final relu = ChatService.decoderAvatar(charge);
      expect(relu.id, equals(ref.id));
      expect(relu.keyBase64, equals(ref.keyBase64),
          reason: 'sans la clé, la photo reçue est indéchiffrable');
      expect(relu.fileName, equals(ref.fileName));
      expect(relu.size, equals(ref.size));
    });

    test('la charge d’avatar ne contient pas d’octets bruts de la photo', () {
      const ref = AttachmentRef(
        id: '3f2a1b4c-0000-4444-8888-abcdefabcdef',
        keyBase64: 'a2V5LWRlLXRlc3QtMzItb2N0ZXRzLWljaQ==',
        fileName: 'photo.png',
        size: 14405,
      );
      // L'annonce ne transporte qu'une référence : l'image reste sur le
      // stockage, chiffrée. Une annonce qui grossirait avec la photo
      // signalerait qu'on l'a embarquée par erreur dans le canal de contrôle.
      expect(ChatService.encoderAvatar(ref).length, lessThan(300));
    });

    test('les préfixes sont distincts deux à deux', () {
      final vus = <String>{};
      for (final p in ChatService.prefixesControle) {
        expect(vus.add(p), isTrue, reason: 'préfixe en double : $p');
        // Aucun préfixe ne doit être le début d'un autre, sinon le premier
        // testé avalerait les messages du second.
        for (final autre in ChatService.prefixesControle) {
          if (identical(p, autre)) continue;
          expect(autre.startsWith(p), isFalse,
              reason: '$autre commence par $p');
        }
      }
    });
  });
}
