/// Un message affiché dans une conversation, déjà déchiffré.
///
/// N'existe en clair qu'en mémoire et dans le coffre local chiffré : il ne
/// traverse jamais le réseau sous cette forme.
class ChatMessage {
  ChatMessage({
    required this.text,
    required this.mine,
    required this.at,
    this.id,
    this.replyToId,
    this.replyToText,
    this.replyToMine,
    this.attachment,
    this.pendingReceiptIds = const [],
    this.delivered = false,
    this.editedAt,
    this.deletedForEveryone = false,
    this.readByPeer = false,
    this.readAckSent = false,
    this.systeme = false,
    this.expiresAt,
  });

  /// Instant après lequel ce message doit disparaître, si la conversation a
  /// une durée de vie active. Calculé à l'arrivée du message et conservé avec
  /// lui : changer le réglage ensuite ne doit pas rallonger la vie de ce qui a
  /// déjà été envoyé sous l'ancien.
  final DateTime? expiresAt;

  /// Avis produit par l'application elle-même, pas par un correspondant.
  ///
  /// Sert aux évènements qui doivent rester consultables dans le fil — « un
  /// appareil vient d'être lié à ce compte ». Affiché sans bulle ni auteur :
  /// le faire ressembler à un message donnerait à croire qu'il a été envoyé
  /// par quelqu'un, et donc qu'il peut être falsifié par ce quelqu'un.
  final bool systeme;

  /// Message envoyé, confirmé lu par le correspondant (si celui-ci a activé
  /// les accusés de lecture — ils sont facultatifs des deux côtés).
  bool readByPeer;

  /// Message reçu dont on a déjà envoyé l'accusé : évite de le renvoyer à
  /// chaque ouverture de la conversation.
  bool readAckSent;

  /// Date de la dernière modification, si le message a été édité.
  DateTime? editedAt;

  /// Retiré par son auteur pour tout le monde.
  ///
  /// On conserve la ligne plutôt que de l'effacer : un trou silencieux dans une
  /// conversation est trompeur. On affiche « message supprimé », comme le font
  /// les messageries qui prennent la question au sérieux.
  bool deletedForEveryone;

  /// Identifiant stable, créé à l'émission et transmis dans le message chiffré.
  /// Permet de citer un message précis. Absent des messages d'avant son
  /// introduction — l'affichage doit y survivre.
  final String? id;

  /// Message cité, s'il y en a un.
  final String? replyToId;

  /// Extrait du message cité, transporté avec la réponse.
  ///
  /// Redondant en apparence, mais indispensable : le destinataire peut ne pas
  /// posséder l'original (appareil lié après coup, historique purgé). Sans cet
  /// extrait, la citation s'afficherait vide chez lui.
  final String? replyToText;
  final bool? replyToMine;

  String text;
  final bool mine;
  final DateTime at;

  /// Renseigné si le message porte un fichier. La clé permet de le déchiffrer
  /// après téléchargement ; elle n'a jamais quitté le canal chiffré.
  final AttachmentRef? attachment;

  /// Pour un message envoyé : les identifiants de blob à confirmer, un par
  /// appareil du correspondant (mes propres appareils sont exclus — leur
  /// relève ne prouve pas que le destinataire a reçu). Vide sinon.
  final List<String> pendingReceiptIds;

  /// Vrai dès qu'au moins un appareil du correspondant a relevé le message.
  /// Mutable : le passage de « envoyé » à « remis » se fait en place.
  bool delivered;

  bool get hasAttachment => attachment != null;

  bool get hasReply => replyToId != null || replyToText != null;
  bool get isEdited => editedAt != null;

  Map<String, Object?> toJson() => {
        't': text,
        'm': mine,
        'a': at.millisecondsSinceEpoch,
        if (id != null) 'i': id,
        if (replyToId != null) 'q': replyToId,
        if (replyToText != null) 'qt': replyToText,
        if (replyToMine != null) 'qm': replyToMine,
        if (attachment != null) 'f': attachment!.toJson(),
        if (pendingReceiptIds.isNotEmpty) 'r': pendingReceiptIds,
        if (delivered) 'd': true,
        if (editedAt != null) 'e': editedAt!.millisecondsSinceEpoch,
        if (deletedForEveryone) 'x': true,
        if (readByPeer) 'lu': true,
        if (readAckSent) 'la': true,
        if (systeme) 'sys': true,
        if (expiresAt != null) 'exp': expiresAt!.millisecondsSinceEpoch,
      };

  static ChatMessage fromJson(Map<String, Object?> json) => ChatMessage(
        text: json['t'] as String,
        mine: json['m'] as bool,
        at: DateTime.fromMillisecondsSinceEpoch((json['a'] as num).toInt()),
        attachment: json['f'] == null
            ? null
            : AttachmentRef.fromJson((json['f'] as Map).cast<String, Object?>()),
        pendingReceiptIds:
            ((json['r'] as List?) ?? const []).cast<String>(),
        delivered: json['d'] as bool? ?? false,
        id: json['i'] as String?,
        replyToId: json['q'] as String?,
        replyToText: json['qt'] as String?,
        replyToMine: json['qm'] as bool?,
        editedAt: json['e'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((json['e'] as num).toInt()),
        deletedForEveryone: json['x'] as bool? ?? false,
        readByPeer: json['lu'] as bool? ?? false,
        readAckSent: json['la'] as bool? ?? false,
        systeme: json['sys'] as bool? ?? false,
        expiresAt: json['exp'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((json['exp'] as num).toInt()),
      );
}

/// Référence vers un fichier déposé sur le stockage objet.
///
/// La clé est celle du fichier : elle ne transite que dans le message chiffré
/// de bout en bout, jamais vers l'hébergeur du stockage.
class AttachmentRef {
  const AttachmentRef({
    required this.id,
    required this.keyBase64,
    required this.fileName,
    required this.size,
    this.voiceDurationMs,
  });

  final String id;
  final String keyBase64;
  final String fileName;
  final int size;

  /// Durée en millisecondes si c'est un message vocal ; null pour un fichier.
  /// Voyage dans le message chiffré : le serveur ne l'apprend pas.
  final int? voiceDurationMs;

  bool get isVoice => voiceDurationMs != null;

  Map<String, Object?> toJson() => {
        'id': id,
        'k': keyBase64,
        'n': fileName,
        's': size,
        if (voiceDurationMs != null) 'vd': voiceDurationMs,
      };

  static AttachmentRef fromJson(Map<String, Object?> json) => AttachmentRef(
        id: json['id'] as String,
        keyBase64: json['k'] as String,
        fileName: json['n'] as String,
        size: (json['s'] as num).toInt(),
        voiceDurationMs: (json['vd'] as num?)?.toInt(),
      );
}
