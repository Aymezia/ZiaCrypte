import 'package:flutter/material.dart';

import '../data/chat_service.dart';

/// Écran principal : liste des conversations à gauche, conversation active à
/// droite. Sur fenêtre étroite, la liste et la conversation s'alternent.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.service});

  final ChatService service;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _lastMessageCount = 0;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await widget.service.send(text);
  }

  void _scrollToEndIfNeeded(int count) {
    if (count == _lastMessageCount) return;
    _lastMessageCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _promptNewConversation() async {
    final controller = TextEditingController();
    final peer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nouvelle conversation'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Pseudo du correspondant',
            prefixIcon: Icon(Icons.alternate_email),
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Démarrer'),
          ),
        ],
      ),
    );
    if (peer != null && peer.isNotEmpty) {
      await widget.service.startChatWith(peer);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final s = widget.service;
        final wide = MediaQuery.of(context).size.width >= 720;
        final conv = s.active;
        _scrollToEndIfNeeded(conv?.messages.length ?? 0);

        // Fenêtre étroite : on affiche soit la liste, soit la conversation.
        if (!wide) {
          return conv == null
              ? _listScaffold(theme, s)
              : _conversationScaffold(theme, s, showBack: true);
        }

        return Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 300,
                child: _conversationList(theme, s),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: conv == null
                    ? _emptyState(theme)
                    : _conversationPane(theme, s),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- liste

  Widget _listScaffold(ThemeData theme, ChatService s) => Scaffold(
        body: _conversationList(theme, s),
      );

  Widget _conversationList(ThemeData theme, ChatService s) {
    final convs = s.conversations;
    return Column(
      children: [
        AppBar(
          automaticallyImplyLeading: false,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.username ?? 'ZiaCrypte'),
              Row(
                children: [
                  Icon(
                    s.realtime ? Icons.bolt_rounded : Icons.schedule_rounded,
                    size: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    s.realtime ? 'Temps réel' : 'Reconnexion…',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Nouvelle conversation',
              onPressed: s.busy ? null : _promptNewConversation,
              icon: const Icon(Icons.edit_square),
            ),
            IconButton(
              tooltip: 'Se déconnecter',
              onPressed: () => s.logout(),
              icon: const Icon(Icons.logout_rounded),
            ),
          ],
        ),
        if (s.error != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            color: theme.colorScheme.errorContainer,
            child: Text(s.error!,
                style: TextStyle(
                    fontSize: 12, color: theme.colorScheme.onErrorContainer)),
          ),
        Expanded(
          child: convs.isEmpty
              ? _noConversations(theme)
              : ListView.builder(
                  itemCount: convs.length,
                  itemBuilder: (context, i) {
                    final c = convs[i];
                    final selected = c.id == s.activeConversationId;
                    final last = c.lastMessage;
                    return ListTile(
                      selected: selected,
                      selectedTileColor: theme.colorScheme.surfaceContainerHighest,
                      leading: CircleAvatar(
                        backgroundColor: theme.colorScheme.primaryContainer,
                        child: Text(
                          c.peerUsername.characters.first.toUpperCase(),
                          style: TextStyle(
                              color: theme.colorScheme.onPrimaryContainer),
                        ),
                      ),
                      title: Text(c.peerUsername,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        last == null
                            ? 'Aucun message'
                            : '${last.mine ? "Vous : " : ""}${last.text}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => s.openConversation(c.id),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _noConversations(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forum_outlined,
                  size: 40, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text('Aucune conversation',
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(
                'Démarres-en une, ou attends qu’on t’écrive.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );

  Widget _emptyState(ThemeData theme) => Center(
        child: Text('Sélectionne une conversation',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );

  // --------------------------------------------------------- conversation

  Widget _conversationScaffold(ThemeData theme, ChatService s,
          {bool showBack = false}) =>
      Scaffold(
        appBar: AppBar(
          leading: showBack
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: s.closeConversation,
                )
              : null,
          title: _conversationTitle(theme, s),
        ),
        body: _messagesAndComposer(theme, s),
      );

  Widget _conversationPane(ThemeData theme, ChatService s) => Column(
        children: [
          AppBar(
            automaticallyImplyLeading: false,
            title: _conversationTitle(theme, s),
          ),
          Expanded(child: _messagesAndComposer(theme, s)),
        ],
      );

  Widget _conversationTitle(ThemeData theme, ChatService s) {
    final conv = s.active!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(conv.peerUsername),
        Row(
          children: [
            Icon(Icons.lock_rounded,
                size: 11, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text('Chiffré de bout en bout', style: theme.textTheme.bodySmall),
          ],
        ),
      ],
    );
  }

  Widget _messagesAndComposer(ThemeData theme, ChatService s) {
    final conv = s.active!;
    return Column(
      children: [
        Expanded(
          child: conv.messages.isEmpty
              ? Center(
                  child: Text('Aucun message pour l’instant',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: conv.messages.length,
                  itemBuilder: (context, i) {
                    final m = conv.messages[i];
                    return Align(
                      alignment:
                          m.mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        constraints: const BoxConstraints(maxWidth: 480),
                        decoration: BoxDecoration(
                          color: m.mine
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          m.text,
                          style: TextStyle(
                            color: m.mine
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    onSubmitted: (_) => _send(),
                    enabled: conv.ready,
                    decoration: InputDecoration(
                      hintText: conv.ready
                          ? 'Message chiffré…'
                          : 'Session en cours d’ouverture…',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: conv.ready ? _send : null,
                  icon: const Icon(Icons.send_rounded),
                  padding: const EdgeInsets.all(14),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
