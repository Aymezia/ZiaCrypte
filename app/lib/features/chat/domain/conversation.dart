import 'chat_message.dart';

/// Une conversation en cours avec un correspondant.
///
/// La session Double Ratchet vit dans l'isolate du moteur ; on ne conserve ici
/// que son identifiant opaque. Tout le reste (pseudo, appareil destinataire) est
/// nécessaire pour router les messages et se reconnecter après redémarrage.
class Conversation {
  Conversation({
    required this.id,
    required this.peerUsername,
    required this.peerDeviceId,
    this.sessionId,
    List<ChatMessage>? messages,
    DateTime? lastActivity,
  })  : messages = messages ?? [],
        lastActivity = lastActivity ?? DateTime.now();

  final String id;
  String peerUsername;
  String peerDeviceId;

  /// Session du moteur, absente tant qu'elle n'a pas été ouverte ou restaurée.
  int? sessionId;

  final List<ChatMessage> messages;
  DateTime lastActivity;

  /// Vrai tant que le matériel X3DH n'a pas encore été envoyé au correspondant
  /// (il n'accompagne que le tout premier message d'une session).
  bool handshakePending = false;

  bool get ready => sessionId != null;

  ChatMessage? get lastMessage => messages.isEmpty ? null : messages.last;

  /// Métadonnées persistées : ni clé, ni message (l'historique a sa propre
  /// entrée dans le coffre, et la session la sienne).
  Map<String, Object?> toJson() => {
        'id': id,
        'peer': peerUsername,
        'device': peerDeviceId,
        'at': lastActivity.millisecondsSinceEpoch,
      };

  static Conversation fromJson(Map<String, Object?> json) => Conversation(
        id: json['id'] as String,
        peerUsername: json['peer'] as String,
        peerDeviceId: json['device'] as String,
        lastActivity:
            DateTime.fromMillisecondsSinceEpoch((json['at'] as num).toInt()),
      );
}
