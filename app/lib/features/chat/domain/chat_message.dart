/// Un message affiché dans une conversation, déjà déchiffré.
///
/// N'existe en clair qu'en mémoire et dans le coffre local chiffré : il ne
/// traverse jamais le réseau sous cette forme.
class ChatMessage {
  ChatMessage({
    required this.text,
    required this.mine,
    required this.at,
    this.attachment,
    this.pendingReceiptIds = const [],
    this.delivered = false,
  });

  final String text;
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

  Map<String, Object?> toJson() => {
        't': text,
        'm': mine,
        'a': at.millisecondsSinceEpoch,
        if (attachment != null) 'f': attachment!.toJson(),
        if (pendingReceiptIds.isNotEmpty) 'r': pendingReceiptIds,
        if (delivered) 'd': true,
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
  });

  final String id;
  final String keyBase64;
  final String fileName;
  final int size;

  Map<String, Object?> toJson() =>
      {'id': id, 'k': keyBase64, 'n': fileName, 's': size};

  static AttachmentRef fromJson(Map<String, Object?> json) => AttachmentRef(
        id: json['id'] as String,
        keyBase64: json['k'] as String,
        fileName: json['n'] as String,
        size: (json['s'] as num).toInt(),
      );
}
