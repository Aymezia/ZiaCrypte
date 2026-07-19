import 'chat_message.dart';

/// Une conversation avec un correspondant.
///
/// Un correspondant peut avoir **plusieurs appareils**, et chaque appareil a sa
/// propre session Double Ratchet : un message doit être chiffré séparément pour
/// chacun. Les sessions vivent dans l'isolate du moteur ; on ne garde ici que
/// leurs identifiants opaques, indexés par appareil.
class Conversation {
  Conversation({
    required this.id,
    required this.peerUsername,
    this.peerUserId,
    Set<String>? targetDeviceIds,
    Map<String, int>? sessions,
    List<ChatMessage>? messages,
    DateTime? lastActivity,
  })  : targetDeviceIds = targetDeviceIds ?? {},
        sessions = sessions ?? {},
        messages = messages ?? [],
        lastActivity = lastActivity ?? DateTime.now();

  final String id;
  String peerUsername;

  /// Identifiant de compte du correspondant. Nécessaire au calcul du numéro de
  /// sécurité, qui doit reposer sur un ancrage stable — un pseudo peut être
  /// réattribué après suppression d'un compte.
  ///
  /// Nullable : les conversations enregistrées avant l'ajout de ce champ n'en
  /// ont pas. Il est renseigné à la première réception d'un message.
  String? peerUserId;

  /// Appareils auxquels envoyer : ceux du correspondant, plus les autres
  /// appareils de l'utilisateur lui-même (pour qu'il retrouve ses propres
  /// messages partout).
  final Set<String> targetDeviceIds;

  /// deviceId -> identifiant de session dans le moteur.
  final Map<String, int> sessions;

  final List<ChatMessage> messages;
  DateTime lastActivity;

  /// Une conversation est utilisable dès qu'au moins un appareil est joignable.
  bool get ready => sessions.isNotEmpty;

  ChatMessage? get lastMessage => messages.isEmpty ? null : messages.last;

  /// Métadonnées persistées : ni clé, ni message (historique et sessions ont
  /// chacun leur entrée dans le coffre chiffré).
  Map<String, Object?> toJson() => {
        'id': id,
        'peer': peerUsername,
        if (peerUserId != null) 'peerId': peerUserId,
        'devices': targetDeviceIds.toList(),
        'at': lastActivity.millisecondsSinceEpoch,
      };

  static Conversation fromJson(Map<String, Object?> json) => Conversation(
        id: json['id'] as String,
        peerUsername: json['peer'] as String,
        peerUserId: json['peerId'] as String?,
        targetDeviceIds: ((json['devices'] as List?) ?? const [])
            .cast<String>()
            .toSet(),
        lastActivity:
            DateTime.fromMillisecondsSinceEpoch((json['at'] as num).toInt()),
      );
}
