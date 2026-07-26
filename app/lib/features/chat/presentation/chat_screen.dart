import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/config/app_settings.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/update/update_notifier.dart';
import '../../../core/update/update_service.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../settings/presentation/update_sheet.dart';
import '../data/chat_service.dart';
import 'identity_avatar.dart';
import 'media_bubble.dart';
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
  UpdateNotifier? _maj;

  @override
  void initState() {
    super.initState();
    // Vérification discrète au lancement : une mise à jour qu'il faut penser à
    // aller chercher dans un menu n'est pas installée, et ce sont les
    // corrections de sécurité qui en pâtissent en premier.
    final engine = widget.service.engine;
    if (engine != null) {
      final maj = UpdateNotifier(UpdateService(engine), widget.settings);
      _maj = maj;
      maj.verifier();
    }
  }

  @override
  void dispose() {
    _maj?.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final conv = widget.service.active;
    // Dans un canal, publier passe par le chemin dédié (chiffrement unique,
    // recopie serveur). Un abonné n'arrive jamais ici : son composeur est masqué.
    if (conv != null && conv.isChannel) {
      await widget.service.publierDansCanal(text);
    } else {
      await widget.service.send(text);
    }
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

  /// Création d'un canal : un nom, puis on montre le lien à partager.
  Future<void> _promptNewChannel() async {
    final nom = TextEditingController();
    final creer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nouveau canal'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nom,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Nom du canal',
                prefixIcon: Icon(Icons.campaign_outlined),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 10),
            Text(
              'Tu publies, tes abonnés lisent. Le lien d’invitation contient la '
              'clé de lecture : qui l’a peut lire, le serveur non. Ni le nom ni '
              'les messages ne lui sont visibles.',
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
    if (creer != true || nom.text.trim().isEmpty) return;
    final lien = await widget.service.creerCanal(nom.text.trim());
    if (lien != null && mounted) _montrerLien(lien);
  }

  /// Affiche le lien d'invitation d'un canal, avec un bouton copier.
  void _montrerLien(String lien) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Lien du canal'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(lien, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            Text(
              'Partage-le à qui tu veux abonner. Le posséder suffit à lire le '
              'canal — traite-le comme un secret.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: lien));
              Navigator.of(context).pop();
            },
            child: const Text('Copier'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }

  /// Rejoindre un canal en collant son lien.
  Future<void> _promptJoinChannel() async {
    final champ = TextEditingController();
    final lien = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rejoindre un canal'),
        content: TextField(
          controller: champ,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Lien d’invitation',
            prefixIcon: Icon(Icons.link),
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
            onPressed: () => Navigator.of(context).pop(champ.text.trim()),
            child: const Text('Rejoindre'),
          ),
        ],
      ),
    );
    if (lien != null && lien.isNotEmpty) {
      await widget.service.rejoindreCanalParLien(lien);
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

  /// Bandeau discret quand une version plus récente est publiée.
  ///
  /// Informatif, jamais bloquant : rien ne se télécharge tant que l'utilisateur
  /// n'a pas ouvert le panneau, et « Plus tard » retire le bandeau pour cette
  /// version. Une messagerie qui harcèle est une messagerie qu'on quitte.
  Widget _banniereMaj(ThemeData theme) {
    final maj = _maj;
    if (maj == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: maj,
      builder: (context, _) {
        final info = maj.disponible;
        if (info == null) return const SizedBox.shrink();
        return Material(
          color: theme.colorScheme.primaryContainer,
          child: InkWell(
            onTap: () {
              final engine = widget.service.engine;
              if (engine != null) {
                UpdateSheet.show(context, UpdateService(engine));
              }
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
              child: Row(
                children: [
                  Icon(Icons.system_update_alt,
                      size: 18, color: theme.colorScheme.onPrimaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Version ${info.version} disponible',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton(
                    onPressed: maj.ecarter,
                    child: Text('Plus tard',
                        style: TextStyle(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

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
                  // Pastille en ligne : verte et nimbée quand la liaison temps
                  // réel est établie, orangée sinon. Un point qui respire en dit
                  // plus long qu'une icône, du premier coup d'œil.
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: s.realtime
                          ? theme.colorScheme.primary
                          : theme.colorScheme.tertiary,
                      boxShadow: s.realtime
                          ? ZiaTheme.glow(theme.colorScheme.primary,
                              opacity: 0.6, blur: 8)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 6),
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
            PopupMenuButton<int>(
              tooltip: 'Nouveau',
              enabled: !s.busy,
              icon: const Icon(Icons.add),
              onSelected: (v) {
                switch (v) {
                  case 0:
                    _promptNewConversation();
                  case 1:
                    _promptNewGroup();
                  case 2:
                    _promptNewChannel();
                  case 3:
                    _promptJoinChannel();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 0, child: ListTile(
                    leading: Icon(Icons.edit_square), title: Text('Conversation'))),
                PopupMenuItem(value: 1, child: ListTile(
                    leading: Icon(Icons.group_add_outlined), title: Text('Groupe'))),
                PopupMenuItem(value: 2, child: ListTile(
                    leading: Icon(Icons.campaign_outlined), title: Text('Canal'))),
                PopupMenuItem(value: 3, child: ListTile(
                    leading: Icon(Icons.link), title: Text('Rejoindre un canal'))),
              ],
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
        _banniereMaj(theme),
        Expanded(
          child: convs.isEmpty
              ? _noConversations(theme)
              : ListView.builder(
                  itemCount: convs.length,
                  itemBuilder: (context, i) {
                    final c = convs[i];
                    final selected = c.id == s.activeConversationId;
                    final last = c.lastMessage;
                    // Avatar dérivé de la clé d'identité : si la clé change,
                    // l'apparence change. Indice visuel qui double la
                    // bannière d'alerte, pour qui ne lit pas les bannières.
                    final avatar = IdentityAvatar(
                      label: c.peerUsername,
                      identityKey: _cleDuPair(c),
                      isGroup: c.isGroup,
                      photo: s.photoDe(c.peerUserId),
                    );
                    return ListTile(
                      selected: selected,
                      selectedTileColor: theme.colorScheme.surfaceContainerHighest,
                      leading: c.isChannel
                          // Un canal se distingue d'un contact au premier
                          // coup d'œil : une pastille de diffusion, pas un avatar.
                          ? CircleAvatar(
                              backgroundColor: theme.colorScheme.primaryContainer,
                              child: Icon(Icons.campaign,
                                  color: theme.colorScheme.onPrimaryContainer),
                            )
                          : c.isGroup || !s.enLigneDans(c.id)
                          ? avatar
                          : Stack(
                              clipBehavior: Clip.none,
                              children: [
                                avatar,
                                Positioned(
                                  right: -1,
                                  bottom: -1,
                                  child: _pastilleEnLigne(theme,
                                      taille: 13,
                                      bordure: theme.colorScheme.surface),
                                ),
                              ],
                            ),
                      title: Text(c.peerUsername,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        last == null
                            // Une conversation sans message montre le statut
                            // du correspondant plutôt qu'une ligne vide — sans
                            // jamais recouvrir un vrai message.
                            ? (s.statutDe(c.peerUserId) ?? 'Aucun message')
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
          actions: [
            if (!(s.active?.isChannel ?? false)) _boutonEphemere(theme, s),
            _menuConversation(theme, s),
          ],
        ),
        body: _messagesAndComposer(theme, s),
      );

  Widget _conversationPane(ThemeData theme, ChatService s) => Column(
        children: [
          AppBar(
            automaticallyImplyLeading: false,
            title: _conversationTitle(theme, s),
            actions: [
              if (!(s.active?.isChannel ?? false)) _boutonEphemere(theme, s),
              _menuConversation(theme, s),
            ],
          ),
          Expanded(child: _messagesAndComposer(theme, s)),
        ],
      );

  /// Réglage des messages éphémères, dans l'en-tête de la conversation.
  ///
  /// Visible en permanence quand il est actif : un minuteur caché dans un
  /// sous-menu laisse écrire des choses en croyant qu'elles vont disparaître,
  /// ou l'inverse.
  Widget _boutonEphemere(ThemeData theme, ChatService s) {
    final conv = s.active!;
    final actif = conv.ttlSecondes > 0;
    return PopupMenuButton<int>(
      tooltip: 'Messages éphémères',
      icon: Icon(actif ? Icons.timer_outlined : Icons.timer_off_outlined,
          color: actif ? theme.colorScheme.primary : null),
      onSelected: (v) => s.definirTtl(conv, v),
      itemBuilder: (context) => [
        for (final e in ChatService.dureesEphemeres.entries)
          PopupMenuItem(
            value: e.key,
            child: Row(children: [
              Icon(
                e.key == conv.ttlSecondes
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
              ),
              const SizedBox(width: 10),
              Text(e.value),
            ]),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          enabled: false,
          child: SizedBox(
            width: 230,
            child: Text(
              'Le compte démarre à l’envoi. Ce n’est pas une garantie : '
              'l’écran peut être photographié.',
              style: TextStyle(fontSize: 11),
            ),
          ),
        ),
      ],
    );
  }

  /// Menu de la conversation : pour l'instant, le blocage.
  Widget _menuConversation(ThemeData theme, ChatService s) {
    final conv = s.active!;

    // Canal : partager le lien (admin), et quitter.
    if (conv.isChannel) {
      return PopupMenuButton<String>(
        tooltip: 'Plus',
        onSelected: (v) {
          if (v == 'lien') {
            final lien = s.lienDuCanal(conv);
            if (lien != null) _montrerLien(lien);
          } else if (v == 'quitter') {
            s.quitterCanal(conv);
          }
        },
        itemBuilder: (context) => [
          if (conv.channelIsAdmin)
            const PopupMenuItem(
              value: 'lien',
              child: ListTile(leading: Icon(Icons.link), title: Text('Partager le lien')),
            ),
          PopupMenuItem(
            value: 'quitter',
            child: ListTile(
              leading: Icon(Icons.logout, color: theme.colorScheme.error),
              title: Text(conv.channelIsAdmin ? 'Fermer pour moi' : 'Quitter'),
            ),
          ),
        ],
      );
    }

    final peer = conv.peerUserId;
    // Rien à proposer sur un groupe : bloquer un groupe reviendrait à bloquer
    // des gens qu'on n'a pas choisi de bloquer.
    if (peer == null || conv.isGroup) return const SizedBox.shrink();
    final bloque = s.bloques.contains(peer);

    return PopupMenuButton<String>(
      tooltip: 'Plus',
      onSelected: (v) async {
        if (v != 'bloquer') return;
        if (bloque) {
          await s.debloquer(peer);
          return;
        }
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Bloquer ${conv.peerUsername} ?'),
            content: const Text(
              'Ses messages cesseront d’arriver, et le serveur ne les stockera '
              'même pas.\n\n'
              'Il ne saura pas qu’il est bloqué : vu de lui, ses messages '
              'partent sans jamais être remis. C’est voulu — un refus '
              'explicite pousse souvent à recommencer depuis un autre compte.',
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Annuler')),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Bloquer'),
              ),
            ],
          ),
        );
        if (ok == true) await s.bloquer(peer);
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'bloquer',
          child: Row(children: [
            Icon(bloque ? Icons.lock_open : Icons.block,
                size: 18, color: bloque ? null : theme.colorScheme.error),
            const SizedBox(width: 10),
            Text(bloque ? 'Débloquer' : 'Bloquer'),
          ]),
        ),
      ],
    );
  }

  /// Pastille « en ligne ».
  ///
  /// À l'accent du thème plutôt qu'au vert convenu : le vert de disponibilité
  /// vient des messageries d'entreprise, et l'accent cyan reste lisible sur les
  /// deux modes sans introduire une couleur qui n'appartient à rien d'autre.
  Widget _pastilleEnLigne(ThemeData theme, {double taille = 10, Color? bordure}) =>
      Container(
        width: taille,
        height: taille,
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          shape: BoxShape.circle,
          border: bordure == null ? null : Border.all(color: bordure, width: 2),
          boxShadow: ZiaTheme.glow(theme.colorScheme.primary,
              opacity: 0.55, blur: 6),
        ),
      );

  Widget _conversationTitle(ThemeData theme, ChatService s) {
    final conv = s.active!;

    // Un canal n'a ni contact vérifié ni statut : il a un nom et un rôle.
    if (conv.isChannel) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(conv.peerUsername, maxLines: 1, overflow: TextOverflow.ellipsis),
          Row(children: [
            Icon(Icons.campaign_outlined,
                size: 11, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              conv.channelIsAdmin ? 'Canal · vous publiez' : 'Canal · lecture seule',
              style: theme.textTheme.bodySmall,
            ),
          ]),
        ],
      );
    }

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
    // Pas de statut sur un groupe : il en faudrait un par membre, et la place
    // d'un en-tête n'en porte qu'un.
    final statut = conv.isGroup ? null : s.statutDe(conv.peerUserId);

    return InkWell(
      onTap: () => VerificationSheet.show(context, s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                  child: Text(conv.peerUsername,
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
              // Présence : une pastille, sans « vu à telle heure ». L'horaire
              // de dernière connexion dit quand on dort et quand on travaille —
              // le projet n'a aucune raison de le reconstituer.
              if (!conv.isGroup && s.enLigneDans(conv.id)) ...[
                const SizedBox(width: 8),
                _pastilleEnLigne(theme, taille: 8),
              ],
            ],
          ),
          Row(
            children: [
              Icon(verified ? Icons.verified_user_rounded : Icons.lock_rounded,
                  size: 11,
                  color: verified
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              // Le statut du correspondant prend la place du rappel de
              // chiffrement quand il y en a un : la ligne ne peut pas porter
              // les deux, et le cadenas — qui reste — dit déjà l'essentiel. Le
              // texte complet revient dès que le statut disparaît.
              Flexible(
                child: Text(
                  statut ??
                      (verified
                          ? 'Chiffré · contact vérifié'
                          : 'Chiffré de bout en bout · appuyer pour vérifier'),
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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

    // Un avis de l'application n'est pas un message : ni bulle, ni auteur, ni
    // groupement. Lui donner l'apparence d'un message laisserait croire qu'il
    // vient de quelqu'un — donc qu'on peut le fabriquer.
    if (m.systeme) {
      return Column(children: [
        if (nouveauJour) _separateurJour(theme, m.at),
        _avisSysteme(theme, m),
      ]);
    }

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
                          photo: widget.service.photoDe(conv.peerUserId),
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

  Widget _avisSysteme(ThemeData theme, ChatMessage m) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.devices_other,
                  size: 18, color: theme.colorScheme.onTertiaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(m.text,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                        height: 1.35)),
              ),
            ],
          ),
        ),
      );

  Widget _bulle(ThemeData theme, ChatMessage m, bool suiteAvant, bool suiteApres) {
    final mien = m.mine;
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

    // Mes messages portent le dégradé d'accent et un halo discret ; ceux reçus
    // gardent une surface neutre pour que la conversation reste lisible et que
    // ce soit MON propos qui ressorte, pas un mur lumineux des deux côtés.
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      constraints: const BoxConstraints(maxWidth: 520),
      decoration: BoxDecoration(
        color: mien ? null : theme.colorScheme.surfaceContainerHighest,
        gradient: mien ? ZiaTheme.accentGradient(theme.colorScheme) : null,
        borderRadius: rayons,
        boxShadow: mien
            ? ZiaTheme.glow(theme.colorScheme.primary, opacity: 0.22, blur: 12)
            : null,
      ),
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
                // Clé indispensable : c'est le seul widget à état de la liste.
                // Sans elle, Flutter recycle l'état d'une bulle sur une autre
                // dès que l'ordre change — et l'historique remonté depuis un
                // appareil frère insère des messages AVANT les existants. On se
                // retrouvait alors à lire le vocal d'un message en en affichant
                // un autre.
                ? VoiceMessageBubble(
                    key: ValueKey(m.attachment!.id),
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
            // Signaler ne vaut que pour un message REÇU, et en conversation
            // directe où l'auteur est sans ambiguïté le correspondant. Sur ses
            // propres messages, ça n'a pas de sens.
            if (!m.mine &&
                !m.systeme &&
                !m.deletedForEveryone &&
                widget.service.active?.isGroup == false &&
                widget.service.active?.peerUserId != null)
              ListTile(
                leading: Icon(Icons.flag_outlined,
                    color: Theme.of(ctx).colorScheme.error),
                title: const Text('Signaler'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _signalerMessage(m);
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

  /// Feuille de signalement : motif, note facultative, et rappel honnête de ce
  /// qui est transmis. Rien ne part sans confirmation explicite.
  Future<void> _signalerMessage(ChatMessage m) async {
    final conv = widget.service.active;
    if (conv == null) return;
    String motif = ChatService.motifsSignalement.keys.first;
    final note = TextEditingController();

    final envoyer = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: StatefulBuilder(
          builder: (ctx, setSheet) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Signaler ce message',
                  style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Tu transmets à la modération une copie de CE message, que ton '
                'appareil a déchiffrée. Le serveur ne l’a jamais lu ; c’est toi '
                'qui choisis de le révéler.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              for (final e in ChatService.motifsSignalement.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    motif == e.key
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: motif == e.key
                        ? Theme.of(ctx).colorScheme.primary
                        : Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                  title: Text(e.value),
                  onTap: () => setSheet(() => motif = e.key),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: note,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Précisions (facultatif)',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Annuler')),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(ctx).colorScheme.error),
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('Signaler'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (envoyer != true) return;
    try {
      await widget.service.signaler(conv, m, motif: motif, note: note.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Signalement transmis. Merci.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Échec du signalement : $e')));
    }
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

    // Photos et vidéos se montrent dans le fil. Obliger à télécharger pour
    // savoir ce qu'on a reçu est le comportement d'un client de courriel, pas
    // d'une messagerie. Le type se déduit du nom de fichier — qui voyage
    // chiffré : le serveur ignore toujours ce qu'il relaie.
    if (typeDe(ref.fileName) != TypeMedia.fichier) {
      return MediaBubble(
          key: ValueKey('media-${ref.id}'),
          service: widget.service,
          attachment: ref,
          mine: m.mine);
    }

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

  /// Bouton d'envoi : disque en dégradé d'accent, halo quand il est actif —
  /// éteint et neutre tant que la session n'est pas prête, pour ne pas inviter
  /// à cliquer sur un envoi qui n'aboutirait pas.
  Widget _boutonEnvoi(ThemeData theme, bool actif) {
    final c = theme.colorScheme;
    return Semantics(
      button: true,
      label: 'Envoyer',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: actif ? _send : null,
          child: Ink(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: actif ? ZiaTheme.accentGradient(c) : null,
              color: actif ? null : c.surfaceContainerHighest,
              boxShadow: actif ? ZiaTheme.glow(c.primary, opacity: 0.4) : null,
            ),
            child: Icon(Icons.send_rounded,
                size: 20,
                color: actif ? c.onPrimary : c.onSurfaceVariant),
          ),
        ),
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
        if (s.replyingTo != null && !conv.isChannel) _barreCitation(theme, s),
        // Canal en lecture seule : un abonné ne publie pas. On le dit clairement
        // plutôt que d'afficher un composeur qui n'aboutirait à rien.
        if (conv.isChannel && !conv.channelIsAdmin)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Row(children: [
                Icon(Icons.lock_outline,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Canal en lecture seule',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
                TextButton.icon(
                  onPressed: () => widget.service.quitterCanal(conv),
                  icon: const Icon(Icons.logout, size: 16),
                  label: const Text('Quitter'),
                ),
              ]),
            ),
          )
        // Canal dont je suis l'admin : un composeur de texte seul (pas de pièce
        // jointe ni de voix pour l'instant), qui publie.
        else if (conv.isChannel)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: 'Publier dans le canal…',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _boutonEnvoi(theme, true),
              ]),
            ),
          )
        else
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
                _boutonEnvoi(theme, conv.ready),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
