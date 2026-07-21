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
    Set<String>? ownDeviceIds,
    Set<String>? targetDeviceIds,
    Map<String, int>? sessions,
    List<ChatMessage>? messages,
    DateTime? lastActivity,
    this.ttlSecondes = 0,
  })  : memberUserIds = memberUserIds ?? {},
        ownDeviceIds = ownDeviceIds ?? {},
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

  /// Durée de vie des messages, en secondes. 0 = désactivée.
  ///
  /// Le compte démarre à l'ENVOI, pas à la lecture. Signal fait l'inverse, mais
  /// il dispose des accusés de lecture ; ici ils sont facultatifs et désactivés
  /// par défaut, et faire dépendre l'effacement d'un signal que le
  /// correspondant peut refuser d'émettre donnerait une garantie qui n'en est
  /// pas une. À l'envoi, l'échéance est la même des deux côtés et prévisible.
  int ttlSecondes;

  /// Membres du groupe, par identifiant de compte.
  ///
  /// Le NOM du groupe ne figure pas ici et n'est pas connu du serveur : il
  /// circule dans les messages chiffrés de bout en bout, au même titre que le
  /// reste. Le serveur n'a besoin que de la composition, pour router.
  final Set<String> memberUserIds;

  /// Appareils de cette conversation qui m'appartiennent (mes autres appareils).
  /// Exclus du reçu de remise : leur relève ne prouve rien sur le destinataire.
  final Set<String> ownDeviceIds;

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
        if (ownDeviceIds.isNotEmpty) 'own': ownDeviceIds.toList(),
        'devices': targetDeviceIds.toList(),
        'at': lastActivity.millisecondsSinceEpoch,
        if (ttlSecondes > 0) 'ttl': ttlSecondes,
      };

  static Conversation fromJson(Map<String, Object?> json) => Conversation(
        id: json['id'] as String,
        peerUsername: json['peer'] as String,
        peerUserId: json['peerId'] as String?,
        isGroup: json['group'] as bool? ?? false,
        memberUserIds:
            ((json['members'] as List?) ?? const []).cast<String>().toSet(),
        ownDeviceIds:
            ((json['own'] as List?) ?? const []).cast<String>().toSet(),
        targetDeviceIds: ((json['devices'] as List?) ?? const [])
            .cast<String>()
            .toSet(),
        lastActivity:
            DateTime.fromMillisecondsSinceEpoch((json['at'] as num).toInt()),
        ttlSecondes: (json['ttl'] as num?)?.toInt() ?? 0,
      );
}
