import 'package:flutter/material.dart';

import '../../chat/data/chat_service.dart';

/// Comptes bloqués.
///
/// Le blocage est appliqué par le SERVEUR : les messages d'un compte bloqué ne
/// sont pas stockés du tout. La personne bloquée ne l'apprend pas — vu d'elle,
/// ses messages partent et ne sont jamais remis, ce qui est indiscernable d'un
/// destinataire qui ne relève pas. C'est délibéré : un refus explicite se paie,
/// en situation de harcèlement, par une escalade ou un nouveau compte.
class BlockedScreen extends StatefulWidget {
  const BlockedScreen({super.key, required this.service});

  final ChatService service;

  @override
  State<BlockedScreen> createState() => _BlockedScreenState();
}

class _BlockedScreenState extends State<BlockedScreen> {
  List<Map<String, dynamic>>? _liste;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    setState(() => _erreur = null);
    try {
      final l = await widget.service.listerBlocages();
      if (mounted) setState(() => _liste = l);
    } catch (e) {
      if (mounted) setState(() => _erreur = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final liste = _liste;

    return Scaffold(
      appBar: AppBar(title: const Text('Comptes bloqués')),
      body: _erreur != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_erreur!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error)),
                  const SizedBox(height: 16),
                  OutlinedButton(
                      onPressed: _charger, child: const Text('Réessayer')),
                ]),
              ),
            )
          : liste == null
              ? const Center(child: CircularProgressIndicator())
              : liste.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'Personne n’est bloqué.\n\nTu peux bloquer un compte '
                          'depuis sa conversation. Ses messages cesseront '
                          'd’arriver, et il ne saura pas qu’il est bloqué.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final b in liste)
                          ListTile(
                            leading: const Icon(Icons.block),
                            title: Text(b['username'] as String? ?? '—'),
                            subtitle: Text('Bloqué le ${_date(b['depuis'])}'),
                            trailing: TextButton(
                              onPressed: () async {
                                await widget.service
                                    .debloquer(b['userId'] as String);
                                await _charger();
                              },
                              child: const Text('Débloquer'),
                            ),
                          ),
                      ],
                    ),
    );
  }

  static String _date(Object? iso) {
    final d = DateTime.tryParse('$iso')?.toLocal();
    if (d == null) return 'date inconnue';
    return '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/${d.year}';
  }
}
