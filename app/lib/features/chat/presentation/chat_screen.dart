import 'package:flutter/material.dart';

import '../data/chat_service.dart';

/// Écran principal : choix du correspondant puis conversation chiffrée.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.service});

  final ChatService service;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _peer = TextEditingController();
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _peer.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await widget.service.send(text);
    _scrollToEnd();
  }

  void _scrollToEnd() {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final s = widget.service;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.peerUsername ?? 'ZiaCrypte'),
                Text(
                  s.chatReady
                      ? 'Chiffré de bout en bout'
                      : 'Connecté en tant que ${s.username}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              if (s.chatReady)
                const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: Icon(Icons.lock_rounded, size: 18),
                ),
            ],
          ),
          body: s.chatReady ? _conversation(theme, s) : _peerPicker(theme, s),
        );
      },
    );
  }

  Widget _peerPicker(ThemeData theme, ChatService s) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.forum_outlined,
                  size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('Démarrer une conversation',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Indique le pseudo de ton correspondant. Il doit être inscrit '
                'sur le même serveur.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _peer,
                decoration: const InputDecoration(
                  labelText: 'Pseudo du correspondant',
                  prefixIcon: Icon(Icons.alternate_email),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (v) => s.startChatWith(v.trim()),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: s.busy
                    ? null
                    : () => s.startChatWith(_peer.text.trim()),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16)),
                child: s.busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Démarrer'),
              ),
              if (s.error != null) ...[
                const SizedBox(height: 16),
                Text(s.error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 24),
              Text(
                'En attente : si quelqu’un t’écrit en premier, la conversation '
                's’ouvrira automatiquement.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _conversation(ThemeData theme, ChatService s) {
    return Column(
      children: [
        Expanded(
          child: s.messages.isEmpty
              ? Center(
                  child: Text('Aucun message pour l’instant',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: s.messages.length,
                  itemBuilder: (context, i) {
                    final m = s.messages[i];
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
                    decoration: InputDecoration(
                      hintText: 'Message chiffré…',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _send,
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
