/// Un message affiché dans une conversation, déjà déchiffré.
///
/// N'existe en clair qu'en mémoire et dans le coffre local chiffré : il ne
/// traverse jamais le réseau sous cette forme.
class ChatMessage {
  ChatMessage({required this.text, required this.mine, required this.at});

  final String text;
  final bool mine;
  final DateTime at;

  Map<String, Object?> toJson() => {
        't': text,
        'm': mine,
        'a': at.millisecondsSinceEpoch,
      };

  static ChatMessage fromJson(Map<String, Object?> json) => ChatMessage(
        text: json['t'] as String,
        mine: json['m'] as bool,
        at: DateTime.fromMillisecondsSinceEpoch((json['a'] as num).toInt()),
      );
}
