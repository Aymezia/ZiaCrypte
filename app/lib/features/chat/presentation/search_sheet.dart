import 'package:flutter/material.dart';

import '../data/chat_service.dart';
import 'identity_avatar.dart';

/// Recherche dans les conversations et les messages.
///
/// **Entièrement locale.** Les messages ne sont en clair que sur cet appareil ;
/// la recherche se fait donc en mémoire, sur l'historique déjà déchiffré.
/// Aucune requête ne part vers le serveur — il ne peut ni voir ce qu'on
/// cherche, ni en déduire quoi que ce soit. Une recherche côté serveur serait
/// d'ailleurs impossible : il ne détient que du chiffré.
class SearchSheet extends StatefulWidget {
  const SearchSheet({super.key, required this.service});

  final ChatService service;

  static Future<void> show(BuildContext context, ChatService service) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.8,
            child: SearchSheet(service: service),
          ),
        ),
      );

  @override
  State<SearchSheet> createState() => _SearchSheetState();
}

/// Un message trouvé, avec la conversation d'où il vient.
class _Resultat {
  const _Resultat(this.conv, this.message);
  final Conversation conv;
  final ChatMessage message;
}

class _SearchSheetState extends State<SearchSheet> {
  final _controleur = TextEditingController();
  String _requete = '';

  @override
  void dispose() {
    _controleur.dispose();
    super.dispose();
  }

  List<Conversation> get _conversationsTrouvees {
    if (_requete.isEmpty) return const [];
    final q = _requete.toLowerCase();
    return widget.service.conversations
        .where((c) => c.peerUsername.toLowerCase().contains(q))
        .toList();
  }

  List<_Resultat> get _messagesTrouves {
    if (_requete.isEmpty) return const [];
    final q = _requete.toLowerCase();
    final out = <_Resultat>[];
    for (final conv in widget.service.conversations) {
      for (final m in conv.messages) {
        if (m.text.toLowerCase().contains(q)) out.add(_Resultat(conv, m));
      }
    }
    // Les plus récents d'abord, et on borne : au-delà, la liste n'aide plus.
    out.sort((a, b) => b.message.at.compareTo(a.message.at));
    return out.length > 100 ? out.sublist(0, 100) : out;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final convs = _conversationsTrouvees;
    final messages = _messagesTrouves;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controleur,
            autofocus: true,
            onChanged: (v) => setState(() => _requete = v.trim()),
            decoration: InputDecoration(
              hintText: 'Rechercher…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _requete.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _controleur.clear();
                        setState(() => _requete = '');
                      },
                    ),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24)),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'La recherche se fait sur cet appareil. Rien n’est envoyé au '
            'serveur — il ne détient que du chiffré.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _requete.isEmpty
                ? const SizedBox.shrink()
                : (convs.isEmpty && messages.isEmpty)
                    ? Center(
                        child: Text('Aucun résultat',
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      )
                    : ListView(
                        children: [
                          if (convs.isNotEmpty) ...[
                            _titre(theme, 'Conversations'),
                            for (final c in convs)
                              ListTile(
                                leading: IdentityAvatar(
                                    label: c.peerUsername,
                                    isGroup: c.isGroup,
                                    size: 36),
                                title: Text(c.peerUsername),
                                onTap: () => _ouvrir(c),
                              ),
                          ],
                          if (messages.isNotEmpty) ...[
                            _titre(theme, 'Messages (${messages.length})'),
                            for (final r in messages)
                              ListTile(
                                leading: IdentityAvatar(
                                    label: r.conv.peerUsername,
                                    isGroup: r.conv.isGroup,
                                    size: 36),
                                title: Text(r.conv.peerUsername,
                                    style: theme.textTheme.labelLarge),
                                subtitle: _extraitSurligne(theme, r.message.text),
                                trailing: Text(_dateCourte(r.message.at),
                                    style: theme.textTheme.bodySmall),
                                onTap: () => _ouvrir(r.conv),
                              ),
                          ],
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  void _ouvrir(Conversation c) {
    widget.service.openConversation(c.id);
    Navigator.of(context).pop();
  }

  Widget _titre(ThemeData theme, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Text(t.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700)),
      );

  /// Met en évidence la partie trouvée : sans ça, on ne voit pas POURQUOI un
  /// message ressort.
  Widget _extraitSurligne(ThemeData theme, String texte) {
    final index = texte.toLowerCase().indexOf(_requete.toLowerCase());
    if (index < 0) {
      return Text(texte, maxLines: 2, overflow: TextOverflow.ellipsis);
    }
    // On recadre autour du mot trouvé pour qu'il soit visible même loin
    // dans un long message.
    final debut = index > 30 ? index - 30 : 0;
    final prefixe = debut > 0 ? '…' : '';
    final coupe = texte.substring(debut);
    final pos = index - debut;

    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: theme.textTheme.bodySmall,
        children: [
          TextSpan(text: prefixe + coupe.substring(0, pos)),
          TextSpan(
            text: coupe.substring(pos, pos + _requete.length),
            style: TextStyle(
                fontWeight: FontWeight.w700, color: theme.colorScheme.primary),
          ),
          TextSpan(text: coupe.substring(pos + _requete.length)),
        ],
      ),
    );
  }

  static String _dateCourte(DateTime d) {
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return '${d.hour.toString().padLeft(2, '0')}:'
          '${d.minute.toString().padLeft(2, '0')}';
    }
    return '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}';
  }
}
