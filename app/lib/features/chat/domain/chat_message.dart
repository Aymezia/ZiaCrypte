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
  });

  final String text;
  final bool mine;
  final DateTime at;

  /// Renseigné si le message porte un fichier. La clé permet de le déchiffrer
  /// après téléchargement ; elle n'a jamais quitté le canal chiffré.
  final AttachmentRef? attachment;

  bool get hasAttachment => attachment != null;

  Map<String, Object?> toJson() => {
        't': text,
        'm': mine,
        'a': at.millisecondsSinceEpoch,
        if (attachment != null) 'f': attachment!.toJson(),
      };

  static ChatMessage fromJson(Map<String, Object?> json) => ChatMessage(
        text: json['t'] as String,
        mine: json['m'] as bool,
        at: DateTime.fromMillisecondsSinceEpoch((json['a'] as num).toInt()),
        attachment: json['f'] == null
            ? null
            : AttachmentRef.fromJson((json['f'] as Map).cast<String, Object?>()),
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
