import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/config/app_settings.dart';
import '../../settings/presentation/settings_screen.dart';
import '../data/chat_service.dart';
import 'identity_avatar.dart';
import 'search_sheet.dart';
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
              tooltip: 'Rechercher',
              onPressed: () => SearchSheet.show(context, s),
              icon: const Icon(Icons.search),
            ),
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
                      // Avatar dérivé de la clé d'identité : si la clé change,
                      // l'apparence change. Indice visuel qui double la
                      // bannière d'alerte, pour qui ne lit pas les bannières.
                      leading: IdentityAvatar(
                        label: c.peerUsername,
                        identityKey: _cleDuPair(c),
                        isGroup: c.isGroup,
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
  // ------------------------------------------------ rendu d'un message

  /// Une ligne de la conversation : séparateur de jour éventuel, avatar,
  /// citation, bulle et statut.
  ///
  /// Les messages consécutifs d'un même auteur, à moins de cinq minutes
  /// d'écart, sont GROUPÉS : l'avatar n'apparaît qu'une fois et les bulles se
  /// resserrent. C'est ce qui distingue une liste de bulles d'une vraie
  /// conversation lisible.
  Widget _ligneMessage(ThemeData theme, Conversation conv, ChatMessage m,
      ChatMessage? precedent, ChatMessage? suivant) {
    final nouveauJour =
        precedent == null || !_memeJour(precedent.at, m.at);

    final memeAuteurAvant = precedent != null &&
        precedent.mine == m.mine &&
        !nouveauJour &&
        m.at.difference(precedent.at).inMinutes < 5;
    final memeAuteurApres = suivant != null &&
        suivant.mine == m.mine &&
        _memeJour(m.at, suivant.at) &&
        suivant.at.difference(m.at).inMinutes < 5;

    // Dernier d'un groupe : c'est lui qui porte l'avatar et l'heure.
    final finDeGroupe = !memeAuteurApres;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (nouveauJour) _separateurJour(theme, m.at),
        Padding(
          padding: EdgeInsets.only(top: memeAuteurAvant ? 2 : 10),
          child: Row(
            mainAxisAlignment:
                m.mine ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!m.mine)
                SizedBox(
                  width: 36,
                  child: finDeGroupe
                      ? IdentityAvatar(
                          label: conv.peerUsername,
                          identityKey: _cleDuPair(conv),
                          size: 30,
                          isGroup: conv.isGroup,
                        )
                      : null,
                ),
              Flexible(
                child: GestureDetector(
                  onLongPress: () => _menuMessage(m),
                  onSecondaryTap: () => _menuMessage(m),
                  child: Column(
                    crossAxisAlignment: m.mine
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _bulle(theme, m, memeAuteurAvant, memeAuteurApres),
                      if (finDeGroupe) _piedDeMessage(theme, m),
                    ],
                  ),
                ),
              ),
              if (m.mine) const SizedBox(width: 8),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bulle(ThemeData theme, ChatMessage m, bool suiteAvant, bool suiteApres) {
    final mien = m.mine;
    final fond = mien
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final encre =
        mien ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    // Coins : arrondis partout, sauf du côté de l'auteur au milieu d'un groupe.
    const grand = Radius.circular(18);
    const petit = Radius.circular(6);
    final rayons = BorderRadius.only(
      topLeft: mien ? grand : (suiteAvant ? petit : grand),
      topRight: mien ? (suiteAvant ? petit : grand) : grand,
      bottomLeft: mien ? grand : (suiteApres ? petit : grand),
      bottomRight: mien ? (suiteApres ? petit : grand) : grand,
    );

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      constraints: const BoxConstraints(maxWidth: 520),
      decoration: BoxDecoration(color: fond, borderRadius: rayons),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (m.hasReply) _citation(theme, m, encre),
          if (m.deletedForEveryone)
            // On garde la place du message plutôt que de l'effacer : un trou
            // silencieux dans une conversation est trompeur.
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.block, size: 14, color: encre.withValues(alpha: 0.7)),
              const SizedBox(width: 6),
              Text('Message supprimé',
                  style: TextStyle(
                      color: encre.withValues(alpha: 0.7),
                      fontStyle: FontStyle.italic)),
            ])
          else if (m.hasAttachment)
            (m.attachment!.isVoice
                ? VoiceMessageBubble(
                    service: widget.service,
                    attachment: m.attachment!,
                    mine: mien)
                : _attachmentBubble(theme, m))
          else
            Text(m.text, style: TextStyle(color: encre, height: 1.3)),
          if (m.isEdited && !m.deletedForEveryone)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('modifié',
                  style: TextStyle(
                      fontSize: 10,
                      fontStyle: FontStyle.italic,
                      color: encre.withValues(alpha: 0.7))),
            ),
        ],
      ),
    );
  }

  /// Extrait du message cité, affiché au-dessus de la réponse.
  Widget _citation(ThemeData theme, ChatMessage m, Color encre) => Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.only(left: 8),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: encre.withValues(alpha: 0.6), width: 3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              m.replyToMine == true ? 'Toi' : 'Réponse',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: encre.withValues(alpha: 0.85)),
            ),
            Text(
              m.replyToText ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: encre.withValues(alpha: 0.75)),
            ),
          ],
        ),
      );

  /// Heure et statut de remise, sous le dernier message d'un groupe.
  Widget _piedDeMessage(ThemeData theme, ChatMessage m) {
    final couleur = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 3, left: 8, right: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_heure(m.at),
              style: TextStyle(fontSize: 11, color: couleur)),
          if (m.mine && m.pendingReceiptIds.isNotEmpty) ...[
            const SizedBox(width: 5),
            Icon(
              m.delivered || m.readByPeer ? Icons.done_all : Icons.done,
              size: 13,
              // Lu : la double coche passe en couleur d'accent. Le
              // correspondant doit avoir activé les accusés — sans quoi
              // l'état s'arrête à « remis », ce qui est honnête.
              color: m.readByPeer ? theme.colorScheme.primary : couleur,
            ),
          ],
        ],
      ),
    );
  }

  /// Bandeau au-dessus du composeur indiquant à quoi l'on répond.
  Widget _barreCitation(ThemeData theme, ChatService s) {
    final m = s.replyingTo!;
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 34,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Réponse à ${m.mine ? "toi-même" : "ce message"}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary)),
                Text(
                  m.hasAttachment ? 'Pièce jointe' : m.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Annuler la réponse',
            icon: const Icon(Icons.close, size: 18),
            onPressed: s.cancelReply,
          ),
        ],
      ),
    );
  }

  Widget _separateurJour(ThemeData theme, DateTime jour) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Expanded(child: Divider(color: theme.dividerColor)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _libelleJour(jour),
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(child: Divider(color: theme.dividerColor)),
          ],
        ),
      );

  /// Menu d'un message : répondre, copier.
  void _menuMessage(ChatMessage m) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Répondre'),
              onTap: () {
                Navigator.of(ctx).pop();
                widget.service.startReply(m);
              },
            ),
            if (!m.hasAttachment && !m.deletedForEveryone)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('Copier le texte'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: m.text));
                  Navigator.of(ctx).pop();
                },
              ),
            // Modifier et supprimer pour tous n'ont de sens que sur ses PROPRES
            // messages : on ne réécrit pas les propos d'autrui.
            if (m.mine && m.id != null && !m.deletedForEveryone) ...[
              if (!m.hasAttachment)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Modifier'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _modifierMessage(m);
                  },
                ),
              ListTile(
                leading: Icon(Icons.delete_outline,
                    color: Theme.of(ctx).colorScheme.error),
                title: const Text('Supprimer pour tout le monde'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.service.deleteForEveryone(m);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _modifierMessage(ChatMessage m) async {
    final controleur = TextEditingController(text: m.text);
    final nouveau = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Modifier le message'),
        content: TextField(
          controller: controleur,
          autofocus: true,
          maxLines: null,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controleur.text),
              child: const Text('Enregistrer')),
        ],
      ),
    );
    if (nouveau != null) await widget.service.editMessage(m, nouveau);
  }

  Uint8List? _cleDuPair(Conversation conv) {
    final pinning = widget.service.pinning;
    if (pinning == null) return null;
    for (final d in conv.targetDeviceIds) {
      final identite = pinning.forDevice(d);
      if (identite != null) return identite.identityKey;
    }
    return null;
  }

  static bool _memeJour(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _heure(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  static String _libelleJour(DateTime d) {
    final now = DateTime.now();
    final hier = now.subtract(const Duration(days: 1));
    if (_memeJour(d, now)) return "Aujourd'hui";
    if (_memeJour(d, hier)) return 'Hier';
    const mois = [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
      'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'
    ];
    return '${d.day} ${mois[d.month - 1]}'
        '${d.year != now.year ? ' ${d.year}' : ''}';
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
                    final precedent = i > 0 ? conv.messages[i - 1] : null;
                    final suivant = i + 1 < conv.messages.length
                        ? conv.messages[i + 1]
                        : null;
                    return _ligneMessage(theme, conv, m, precedent, suivant);
                  },
                ),
        ),
        if (s.ecritDans(conv.id))
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Row(children: [
              SizedBox(
                height: 10, width: 10,
                child: CircularProgressIndicator(
                    strokeWidth: 1.6, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 8),
              Text('${conv.peerUsername} écrit…',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.primary)),
            ]),
          ),
        if (s.replyingTo != null) _barreCitation(theme, s),
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
                    onChanged: (_) => widget.service.signalerEcriture(),
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
