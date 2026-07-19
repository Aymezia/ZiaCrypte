import 'package:flutter/material.dart';

import '../data/chat_service.dart';
import '../domain/contact_identity.dart';

/// Écran de vérification d'un contact.
///
/// Affiche le numéro de sécurité de chaque appareil du correspondant. Le texte
/// explique **pourquoi** comparer : sans cette compréhension, l'utilisateur
/// coche « vérifié » sans rien avoir comparé, et le mécanisme ne protège plus
/// de rien tout en donnant l'impression du contraire.
class VerificationSheet extends StatefulWidget {
  const VerificationSheet({super.key, required this.service});

  final ChatService service;

  static Future<void> show(BuildContext context, ChatService service) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => VerificationSheet(service: service),
      );

  @override
  State<VerificationSheet> createState() => _VerificationSheetState();
}

class _VerificationSheetState extends State<VerificationSheet> {
  List<DeviceVerification>? _devices;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final devices = await widget.service.safetyNumbers();
      if (mounted) setState(() => _devices = devices);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peer = widget.service.active?.peerUsername ?? '';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Vérifier $peer', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(
                'Compare ces chiffres avec $peer par un autre moyen que '
                'ZiaCrypte : de vive voix, en personne, ou par un appel que tu '
                'sais authentique.\n\n'
                'S’ils sont identiques des deux côtés, personne ne s’est '
                'intercalé. S’ils diffèrent, quelqu’un intercepte vos '
                'messages — n’écris rien de sensible.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              if (_error != null)
                Text(_error!, style: TextStyle(color: theme.colorScheme.error))
              else if (_devices == null)
                const Center(child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ))
              else if (_devices!.isEmpty)
                Text(
                  'Aucun appareil connu pour ce contact. Échange un message '
                  'd’abord.',
                  style: theme.textTheme.bodyMedium,
                )
              else
                for (final d in _devices!) _deviceCard(theme, d),
            ],
          ),
        ),
      ),
    );
  }

  Widget _deviceCard(ThemeData theme, DeviceVerification d) {
    if (!d.usable) return _unusableCard(theme, d);
    final verified = d.identity.verified;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  verified ? Icons.verified_user_rounded : Icons.shield_outlined,
                  size: 18,
                  color: verified
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  verified ? 'Vérifié' : 'Non vérifié',
                  style: theme.textTheme.labelLarge,
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Groupes de 5 chiffres : lire soixante chiffres d'affilée au
            // téléphone est une source d'erreurs.
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                for (final g in d.groups)
                  Text(g,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 17,
                        letterSpacing: 1.5,
                      )),
              ],
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: verified
                  ? TextButton(
                      onPressed: () => _setVerified(d, false),
                      child: const Text('Retirer la vérification'),
                    )
                  : FilledButton(
                      onPressed: () => _setVerified(d, true),
                      child: const Text('Les chiffres correspondent'),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Aucun numéro calculable : on explique pourquoi au lieu de laisser une
  /// case vide ou une exception à l'écran.
  Widget _unusableCard(ThemeData theme, DeviceVerification d) => Card(
        margin: const EdgeInsets.only(bottom: 16),
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.gpp_maybe_rounded,
                  size: 18, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  d.problem!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      );

  Future<void> _setVerified(DeviceVerification d, bool verified) async {
    await widget.service.markVerified(d.identity.deviceId, verified: verified);
    await _load();
  }
}
