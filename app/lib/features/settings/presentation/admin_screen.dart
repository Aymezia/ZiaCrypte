import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/data/chat_service.dart';

/// Écran d'administration.
///
/// ## Ce qu'il permet, et ce qu'il ne permet pas
///
/// Traiter des signalements, chercher un compte, émettre un jeton de
/// réinitialisation, supprimer un compte. Il ne montre JAMAIS de message : le
/// serveur n'a pas les clés, et la seule route qui expose un contenu — les
/// signalements — ne rend que ce qu'une victime a CHOISI de transmettre.
///
/// ## Le code à chaque action
///
/// Le serveur réclame un code TOTP frais sur CHAQUE requête d'administration,
/// pas seulement à la connexion. Un jeton d'accès volé ne suffit donc pas. Le
/// code vit dans un champ en tête d'écran ; comme il tourne toutes les 30 s,
/// une requête refusée (403) demande simplement de le retaper.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key, required this.service});

  final ChatService service;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final _code = TextEditingController();

  @override
  void dispose() {
    _tabs.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _codeValue => _code.text.trim();

  bool _exigerCode() {
    if (_codeValue.length >= 6) return true;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Entre d’abord ton code à 6 chiffres.')));
    return false;
  }

  /// Traduit une erreur réseau en message lisible, en isolant le cas du code.
  String _messageErreur(Object e) {
    if (e is DioException) {
      final code = e.response?.statusCode;
      if (code == 403) return 'Code invalide ou expiré — retape-le.';
      if (code == 404) return 'Introuvable, ou compte sans droits d’administration.';
      final msg = e.response?.data;
      if (msg is Map && msg['error'] is String) return msg['error'] as String;
    }
    return e.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Administration'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(112),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Code de vérification (2FA)',
                    helperText: 'Redemandé à chaque action — le serveur l’exige',
                    prefixIcon: Icon(Icons.pin_outlined),
                    counterText: '',
                  ),
                ),
              ),
              TabBar(
                controller: _tabs,
                labelColor: theme.colorScheme.primary,
                tabs: const [
                  Tab(text: 'Signalements'),
                  Tab(text: 'Comptes'),
                  Tab(text: 'Journal'),
                ],
              ),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _OngletSignalements(parent: this),
          _OngletComptes(parent: this),
          _OngletJournal(parent: this),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- Signalements

class _OngletSignalements extends StatefulWidget {
  const _OngletSignalements({required this.parent});
  final _AdminScreenState parent;
  @override
  State<_OngletSignalements> createState() => _OngletSignalementsState();
}

class _OngletSignalementsState extends State<_OngletSignalements> {
  List<Map<String, dynamic>>? _items;
  bool _charge = false;
  String _statut = 'open';

  _AdminScreenState get p => widget.parent;

  Future<void> _charger() async {
    if (!p._exigerCode()) return;
    setState(() => _charge = true);
    try {
      final r = await p.widget.service
          .adminSignalements(p._codeValue, statut: _statut);
      if (mounted) setState(() => _items = r);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(p._messageErreur(e))));
      }
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  Future<void> _resoudre(Map<String, dynamic> r, String statut) async {
    if (!p._exigerCode()) return;
    try {
      await p.widget.service.adminResoudreSignalement(
        r['id'] as String,
        p._codeValue,
        statut: statut,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(statut == 'resolved'
                ? 'Signalement marqué traité.'
                : 'Signalement écarté.')));
        _charger();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(p._messageErreur(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'open', label: Text('À traiter')),
                    ButtonSegment(value: 'all', label: Text('Tous')),
                  ],
                  selected: {_statut},
                  onSelectionChanged: (s) => setState(() => _statut = s.first),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _charge ? null : _charger,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Charger'),
              ),
            ],
          ),
        ),
        Expanded(
          child: items == null
              ? Center(
                  child: Text('Entre ton code puis « Charger ».',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)))
              : items.isEmpty
                  ? const Center(child: Text('Aucun signalement.'))
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: items.length,
                      itemBuilder: (context, i) =>
                          _carte(theme, items[i]),
                    ),
        ),
      ],
    );
  }

  Widget _carte(ThemeData theme, Map<String, dynamic> r) {
    final ouvert = r['statut'] == 'open';
    final contenu = r['contenu'] as String?;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.flag,
                    size: 16, color: theme.colorScheme.error),
                const SizedBox(width: 6),
                Text(
                  ChatService.motifsSignalement[r['motif']] ??
                      (r['motif']?.toString() ?? '—'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (!ouvert)
                  Text(r['statut'] == 'resolved' ? 'traité' : 'écarté',
                      style: theme.textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: 6),
            Text('Compte visé : ${r['compteVise'] ?? '—'}',
                style: theme.textTheme.bodySmall),
            Text('Signalé par : ${r['signalePar'] ?? '—'}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            if (r['note'] != null && (r['note'] as String).isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Note : ${r['note']}', style: theme.textTheme.bodySmall),
            ],
            if (contenu != null && contenu.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(contenu, style: theme.textTheme.bodyMedium),
              ),
            ],
            if (ouvert) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => _resoudre(r, 'dismissed'),
                      child: const Text('Écarter')),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: () => _resoudre(r, 'resolved'),
                      child: const Text('Traité')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------- Comptes

class _OngletComptes extends StatefulWidget {
  const _OngletComptes({required this.parent});
  final _AdminScreenState parent;
  @override
  State<_OngletComptes> createState() => _OngletComptesState();
}

class _OngletComptesState extends State<_OngletComptes> {
  final _q = TextEditingController();
  List<Map<String, dynamic>>? _items;
  bool _charge = false;

  _AdminScreenState get p => widget.parent;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _chercher() async {
    if (!p._exigerCode()) return;
    setState(() => _charge = true);
    try {
      final r = await p.widget.service
          .adminRechercherComptes(p._codeValue, q: _q.text.trim());
      if (mounted) setState(() => _items = r);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(p._messageErreur(e))));
      }
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  Future<void> _reinitialiser(Map<String, dynamic> u) async {
    if (!p._exigerCode()) return;
    try {
      final res = await p.widget.service
          .adminReinitMotDePasse(u['id'] as String, p._codeValue);
      final jeton = res['jeton'] as String? ?? '';
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Jeton de réinitialisation'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'À transmettre au titulaire par un canal sûr. Il l’échange lui-'
                'même contre le mot de passe de son choix. Tu ne fixes rien et '
                'n’apprends rien ; ça n’ouvre AUCUN message.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              SelectableText(jeton,
                  style: const TextStyle(fontFamily: 'monospace')),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: jeton));
                Navigator.of(ctx).pop();
              },
              child: const Text('Copier'),
            ),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Fermer')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(p._messageErreur(e))));
      }
    }
  }

  Future<void> _supprimer(Map<String, dynamic> u) async {
    final motif = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Supprimer ${u['username']} ?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Efface le compte, ses appareils et ses clés publiques. Les '
              'messages déjà reçus chez ses correspondants restent chez eux — '
              'hors de portée du serveur. Un motif est obligatoire : il est '
              'journalisé.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: motif,
              decoration: const InputDecoration(labelText: 'Motif'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true || motif.text.trim().length < 3) return;
    if (!p._exigerCode()) return;
    try {
      await p.widget.service
          .adminSupprimerCompte(u['id'] as String, p._codeValue, motif.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Compte supprimé.')));
        _chercher();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(p._messageErreur(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _q,
                  onSubmitted: (_) => _chercher(),
                  decoration: const InputDecoration(
                    labelText: 'Pseudo (vide = les plus récents)',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _charge ? null : _chercher,
                child: const Text('Chercher'),
              ),
            ],
          ),
        ),
        Expanded(
          child: items == null
              ? Center(
                  child: Text('Entre ton code puis cherche un compte.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)))
              : items.isEmpty
                  ? const Center(child: Text('Aucun compte.'))
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: items.length,
                      itemBuilder: (context, i) => _carte(theme, items[i]),
                    ),
        ),
      ],
    );
  }

  Widget _carte(ThemeData theme, Map<String, dynamic> u) {
    final supprime = u['supprime'] == true;
    final admin = u['role'] == 'admin';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(u['username']?.toString() ?? '—',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                if (admin)
                  _puce(theme, 'admin', theme.colorScheme.primary),
                if (supprime)
                  _puce(theme, 'supprimé', theme.colorScheme.error),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${u['appareils'] ?? 0} appareil(s) · '
              '2FA ${u['deuxFacteurs'] == true ? 'activée' : 'non'}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (!supprime && !admin) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => _reinitialiser(u),
                      child: const Text('Réinit. mot de passe')),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => _supprimer(u),
                    style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error),
                    child: const Text('Supprimer'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _puce(ThemeData theme, String texte, Color couleur) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: couleur.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(texte,
            style: TextStyle(fontSize: 11, color: couleur, fontWeight: FontWeight.w600)),
      );
}

// --------------------------------------------------------------------- Journal

class _OngletJournal extends StatefulWidget {
  const _OngletJournal({required this.parent});
  final _AdminScreenState parent;
  @override
  State<_OngletJournal> createState() => _OngletJournalState();
}

class _OngletJournalState extends State<_OngletJournal> {
  List<Map<String, dynamic>>? _items;
  bool _charge = false;

  _AdminScreenState get p => widget.parent;

  Future<void> _charger() async {
    if (!p._exigerCode()) return;
    setState(() => _charge = true);
    try {
      final r = await p.widget.service.adminJournal(p._codeValue);
      if (mounted) setState(() => _items = r);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(p._messageErreur(e))));
      }
    } finally {
      if (mounted) setState(() => _charge = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _charge ? null : _charger,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Charger'),
            ),
          ),
        ),
        Expanded(
          child: items == null
              ? Center(
                  child: Text('Entre ton code puis « Charger ».',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)))
              : items.isEmpty
                  ? const Center(child: Text('Journal vide.'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final a = items[i];
                        return ListTile(
                          dense: true,
                          title: Text('${a['action']} · ${a['cible'] ?? '—'}'),
                          subtitle: Text([
                            a['par'],
                            if (a['motif'] != null) a['motif'],
                            a['date'],
                          ].where((e) => e != null).join(' · ')),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
