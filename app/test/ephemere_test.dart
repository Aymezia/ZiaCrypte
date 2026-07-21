// Messages éphémères : sérialisation de l'échéance et règle d'expiration.
//
// Ces cas sont volontairement testés sur les modèles plutôt que sur un
// scénario réseau complet : c'est là que se logent les défauts silencieux —
// une échéance perdue à la relecture du coffre ferait réapparaître des
// messages qu'on croyait effacés, sans que rien ne le signale.

import 'package:flutter_test/flutter_test.dart';
import 'package:ziacrypte/features/chat/data/chat_service.dart';

void main() {
  group('Messages éphémères', () {
    test('l’échéance survit à un aller-retour dans le coffre', () {
      final echeance = DateTime.fromMillisecondsSinceEpoch(1800000000000);
      final m = ChatMessage(
        text: 'à effacer',
        mine: true,
        at: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        expiresAt: echeance,
      );
      final relu = ChatMessage.fromJson(m.toJson());
      expect(relu.expiresAt, equals(echeance));
      expect(relu.text, equals('à effacer'));
    });

    test('un message sans échéance n’en gagne pas à la relecture', () {
      final m = ChatMessage(
        text: 'permanent',
        mine: false,
        at: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      expect(ChatMessage.fromJson(m.toJson()).expiresAt, isNull);
    });

    test('le réglage de la conversation survit au coffre', () {
      final c = Conversation(
        id: 'c1',
        peerUsername: 'bob',
        lastActivity: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ttlSecondes: 86400,
      );
      expect(Conversation.fromJson(c.toJson()).ttlSecondes, equals(86400));
    });

    test('une conversation sans réglage relit 0, pas null', () {
      final c = Conversation(
        id: 'c2',
        peerUsername: 'bob',
        lastActivity: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final json = c.toJson();
      expect(json.containsKey('ttl'), isFalse,
          reason: 'un réglage désactivé ne doit pas alourdir le coffre');
      expect(Conversation.fromJson(json).ttlSecondes, equals(0));
    });

    test('les durées proposées sont cohérentes', () {
      final d = ChatService.dureesEphemeres;
      expect(d[0], equals('Désactivé'));
      expect(d[3600], equals('1 heure'));
      expect(d[86400], equals('1 jour'));
      // Croissantes : un menu désordonné se lit mal et se clique de travers.
      final cles = d.keys.toList();
      expect(cles, orderedEquals([...cles]..sort()));
    });
  });
}
