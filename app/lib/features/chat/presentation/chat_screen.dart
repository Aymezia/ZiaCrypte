import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/config/app_settings.dart';
import '../../settings/presentation/settings_screen.dart';
import '../data/chat_service.dart';
import 'verification_sheet.dart';
import 'voice_message_bubble.dart';
import 'voice_recorder_button.dart';

/// Écran principal : liste des conversations à gauche, conversation active à
/// droite. Sur fenêtre étroite, la liste et la conversation s'alternent.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.service, required this.settings});

  final ChatService service;
  final AppSettings settings;

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

  Future<void> _pickAndSendFile() async {
    String? path;
    try {
      final result = await FilePicker.pickFiles(withData: false);
      path = result?.files.single.path;
    } catch (_) {
      // Le sélecteur passe par le portail XDG, absent de certains
      // environnements (gestionnaire de fenêtres minimal, session distante).
      // Plutôt que de ne rien faire, on demande le chemin à la main.
      path = await _askFilePath();
    }
    if (path == null) return;

    final file = File(path);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fichier introuvable : $path')),
      );
      return;
    }
    final size = await file.length();
    // Le serveur refuse au-delà : autant le dire avant de chiffrer.
    if (size > 64 * 1024 * 1024) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fichier trop volumineux (64 Mo maximum)')),
      );
      return;
    }
    await widget.service.sendAttachment(path);
  }

  Future<void> _openAttachment(AttachmentRef ref) async {
    String? dir;
    try {
      dir = await FilePicker.getDirectoryPath();
    } catch (_) {
      dir = await _askFilePath(
        title: 'Enregistrer dans',
        label: 'Chemin du dossier',
        initial: Platform.environment['HOME'] ?? '/tmp',
      );
    }
    if (dir == null) return;

    final saved = await widget.service.downloadAttachment(ref, dir);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(saved == null
          ? 'Téléchargement impossible'
          : 'Enregistré : $saved'),
    ));
  }

  /// Repli quand aucun sélecteur graphique n'est disponible : saisie du chemin.
  Future<String?> _askFilePath({
    String title = 'Choisir un fichier',
    String label = 'Chemin du fichier',
    String initial = '',
  }) async {
    // Texte pré-sélectionné : le chemin proposé sert de suggestion, pas de
    // préfixe. Sans ça, taper un chemin l'ajoute à la suite du précédent.
    final controller = TextEditingController(text: initial)
      ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Aucun sélecteur de fichiers n’est disponible sur ce système.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: label,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Valider'),
          ),
        ],
      ),
    );
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

  /// Création d'un groupe : un nom, et des pseudos séparés par des virgules.
  Future<void> _promptNewGroup() async {
    final nom = TextEditingController();
    final membres = TextEditingController();
    final cree = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nouveau groupe'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nom,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Nom du groupe',
                prefixIcon: Icon(Icons.groups_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: membres,
              decoration: const InputDecoration(
                labelText: 'Pseudos, séparés par des virgules',
                prefixIcon: Icon(Icons.person_add_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Le nom du groupe ne quitte pas le canal chiffré : le serveur ne '
              'connaît que la liste des membres, dont il a besoin pour '
              'acheminer les messages.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Créer'),
          ),
        ],
      ),
    );
    if (cree != true) return;

    final liste = membres.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (liste.isEmpty || nom.text.trim().isEmpty) return;
    await widget.service.createGroup(
      name: nom.text.trim(),
      memberUsernames: liste,
    );
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
              tooltip: 'Nouveau groupe',
              onPressed: s.busy ? null : _promptNewGroup,
              icon: const Icon(Icons.group_add_outlined),
            ),
            IconButton(
              tooltip: 'Options',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SettingsScreen(
                    service: widget.service, settings: widget.settings),
              )),
              icon: const Icon(Icons.settings_outlined),
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
                        // Un groupe se reconnaît d'un coup d'œil : une
                        // initiale seule ne dit pas à combien de personnes on
                        // s'apprête à écrire.
                        child: c.isGroup
                            ? Icon(Icons.groups_rounded,
                                size: 20,
                                color: theme.colorScheme.onPrimaryContainer)
                            : Text(
                                c.peerUsername.characters.first.toUpperCase(),
                                style: TextStyle(
                                    color:
                                        theme.colorScheme.onPrimaryContainer),
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
    // Un contact est « vérifié » seulement si TOUS ses appareils connus le
    // sont : en vérifier un et l'afficher comme sûr laisserait les autres
    // passer pour vérifiés sans l'être.
    final identities = conv.peerUserId == null
        ? const []
        : (s.pinning?.forUser(conv.peerUserId!) ?? const []);
    // Une alerte non tranchée annule le badge : afficher « vérifié » à côté
    // d'un bandeau disant que la clé a changé serait contradictoire, et la
    // contradiction se résoudrait dans la tête de l'utilisateur en faveur du
    // badge rassurant. Le statut vérifié porte sur l'ancienne clé, pas sur
    // celle que le serveur sert maintenant.
    final hasPendingAlert = identities
        .any((i) => s.identityAlerts.containsKey(i.deviceId));
    final verified = identities.isNotEmpty &&
        identities.every((i) => i.verified) &&
        !hasPendingAlert;

    return InkWell(
      onTap: () => VerificationSheet.show(context, s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(conv.peerUsername),
          Row(
            children: [
              Icon(verified ? Icons.verified_user_rounded : Icons.lock_rounded,
                  size: 11,
                  color: verified
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                verified
                    ? 'Chiffré · contact vérifié'
                    : 'Chiffré de bout en bout · appuyer pour vérifier',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Bandeau affiché quand la clé d'identité d'un appareil a changé.
  ///
  /// Volontairement impossible à ignorer : c'est le seul moment où une
  /// substitution de clé par le serveur devient visible, et le message ne
  /// prétend pas trancher à la place de l'utilisateur.
  Widget _identityAlertBanner(ThemeData theme, ChatService s) {
    final entries = s.identityAlerts.entries.toList();
    if (entries.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gpp_maybe_rounded,
                  size: 18, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'La clé d’identité de ce contact a changé',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Cela arrive après une réinstallation, mais c’est aussi ce qu’on '
            'observerait si quelqu’un s’intercalait. Les messages vers cet '
            'appareil sont suspendus. Compare le nouveau numéro de sécurité '
            'avant d’accepter.',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => VerificationSheet.show(context, s),
                child: const Text('Voir le numéro'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: () => s.acceptIdentityChange(entries.first.key),
                child: const Text('Accepter la nouvelle clé'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Un message contenant un fichier : cliquer le télécharge et le déchiffre.
  /// Petit indicateur sous un message envoyé : une coche « envoyé », deux
  /// coches « remis à un appareil du correspondant ». Volontairement discret —
  /// c'est une confirmation, pas un contenu.
  Widget _deliveryTick(ThemeData theme, ChatMessage m) {
    final couleur = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 2, right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(m.delivered ? Icons.done_all : Icons.done, size: 13, color: couleur),
          const SizedBox(width: 3),
          Text(
            m.delivered ? 'Remis' : 'Envoyé',
            style: TextStyle(fontSize: 10, color: couleur),
          ),
        ],
      ),
    );
  }

  Widget _attachmentBubble(ThemeData theme, ChatMessage m) {
    final ref = m.attachment!;
    final color = m.mine
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;
    return InkWell(
      onTap: () => _openAttachment(ref),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file_outlined, size: 20, color: color),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(ref.fileName,
                    style: TextStyle(color: color, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis),
                Text(
                  '${(ref.size / 1024).toStringAsFixed(0)} Ko · appuyer pour enregistrer',
                  style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.75)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _messagesAndComposer(ThemeData theme, ChatService s) {
    final conv = s.active!;
    return Column(
      children: [
        // En tête de conversation : impossible de manquer une alerte de
        // changement de clé.
        _identityAlertBanner(theme, s),
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            margin: const EdgeInsets.only(top: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            constraints: const BoxConstraints(maxWidth: 480),
                            decoration: BoxDecoration(
                              color: m.mine
                                  ? theme.colorScheme.primaryContainer
                                  : theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: m.hasAttachment
                                ? (m.attachment!.isVoice
                                    ? VoiceMessageBubble(
                                        service: widget.service,
                                        attachment: m.attachment!,
                                        mine: m.mine)
                                    : _attachmentBubble(theme, m))
                                : Text(
                                    m.text,
                                    style: TextStyle(
                                      color: m.mine
                                          ? theme.colorScheme.onPrimaryContainer
                                          : theme.colorScheme.onSurface,
                                    ),
                                  ),
                          ),
                          if (m.mine && m.pendingReceiptIds.isNotEmpty)
                            _deliveryTick(theme, m),
                        ],
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
                IconButton(
                  tooltip: 'Joindre un fichier',
                  onPressed: conv.ready && !s.busy ? _pickAndSendFile : null,
                  icon: s.busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.attach_file_rounded),
                ),
                VoiceRecorderButton(
                  enabled: conv.ready && !s.busy,
                  onRecorded: (path, durationMs) =>
                      widget.service.sendVoiceMessage(path, durationMs),
                ),
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
