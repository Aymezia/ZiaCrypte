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
    this.isGroup = false,
    Set<String>? memberUserIds,
    Set<String>? targetDeviceIds,
    Map<String, int>? sessions,
    List<ChatMessage>? messages,
    DateTime? lastActivity,
  })  : memberUserIds = memberUserIds ?? {},
        targetDeviceIds = targetDeviceIds ?? {},
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

  /// Conversation de groupe plutôt que dialogue à deux.
  ///
  /// Renseigné à la réception de l'annonce de nom : le destinataire découvre
  /// le groupe par le canal chiffré, pas par le serveur.
  bool isGroup;

  /// Membres du groupe, par identifiant de compte.
  ///
  /// Le NOM du groupe ne figure pas ici et n'est pas connu du serveur : il
  /// circule dans les messages chiffrés de bout en bout, au même titre que le
  /// reste. Le serveur n'a besoin que de la composition, pour router.
  final Set<String> memberUserIds;

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
        if (isGroup) 'group': true,
        if (memberUserIds.isNotEmpty) 'members': memberUserIds.toList(),
        'devices': targetDeviceIds.toList(),
        'at': lastActivity.millisecondsSinceEpoch,
      };

  static Conversation fromJson(Map<String, Object?> json) => Conversation(
        id: json['id'] as String,
        peerUsername: json['peer'] as String,
        peerUserId: json['peerId'] as String?,
        isGroup: json['group'] as bool? ?? false,
        memberUserIds:
            ((json['members'] as List?) ?? const []).cast<String>().toSet(),
        targetDeviceIds: ((json['devices'] as List?) ?? const [])
            .cast<String>()
            .toSet(),
        lastActivity:
            DateTime.fromMillisecondsSinceEpoch((json['at'] as num).toInt()),
      );
}
