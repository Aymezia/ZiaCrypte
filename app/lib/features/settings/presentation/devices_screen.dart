import 'package:flutter/material.dart';

import '../../chat/data/chat_service.dart';

/// Écran des appareils liés au compte.
///
/// ## Pourquoi cet écran est une mesure de sécurité, pas un confort
///
/// Depuis que le compte peut vivre sur plusieurs appareils, un mot de passe
/// volé suffit à en rattacher un — qui reçoit ensuite une copie chiffrée de
/// tout ce qui arrive. Sans cette liste, cet appareil est parfaitement
/// invisible pour sa victime : rien dans l'application ne le mentionne, et il
/// n'a aucune raison de cesser.
///
/// Voir la date de liaison et la dernière activité est ce qui permet de
/// reconnaître un appareil qu'on n'a pas rattaché soi-même. La révocation est
/// ce qui permet d'y mettre fin.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.service});

  final ChatService service;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<Map<String, dynamic>>? _appareils;
  String? _erreur;
  String? _enCours;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    setState(() => _erreur = null);
    try {
      final list = await widget.service.listerAppareils();
      if (mounted) setState(() => _appareils = list);
    } catch (e) {
      if (mounted) setState(() => _erreur = '$e');
    }
  }

  Future<void> _revoquer(Map<String, dynamic> d) async {
    final estCourant = d['current'] == true;
    final confirme = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Révoquer « ${d['deviceName']} » ?'),
        content: Text(
          estCourant
              ? 'C’est l’appareil que tu utilises en ce moment. Il sera '
                  'déconnecté immédiatement et tu devras te reconnecter.\n\n'
                  'Tes messages déjà reçus restent sur cet appareil.'
              : 'Cet appareil perdra l’accès immédiatement et ne recevra plus '
                  'aucun message.\n\n'
                  'Ce qu’il a DÉJÀ reçu reste déchiffrable chez lui : la '
                  'révocation arrête l’avenir, elle ne rattrape pas le passé.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Révoquer'),
          ),
        ],
      ),
    );
    if (confirme != true) return;

    setState(() => _enCours = d['id'] as String);
    try {
      await widget.service.revoquerAppareil(d['id'] as String);
      if (!mounted) return;
      // Se révoquer soi-même revient à se déconnecter : rester sur cet écran
      // afficherait une session qui n'existe plus.
      if (estCourant) {
        widget.service.logout();
        Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      await _charger();
    } catch (e) {
      if (mounted) setState(() => _erreur = '$e');
    } finally {
      if (mounted) setState(() => _enCours = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appareils = _appareils;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Appareils liés'),
        actions: [
          IconButton(
              onPressed: _charger,
              icon: const Icon(Icons.refresh),
              tooltip: 'Actualiser'),
        ],
      ),
      body: _erreur != null
          ? _messageErreur(theme)
          : appareils == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'Chaque appareil lié reçoit une copie chiffrée de tes '
                        'messages. Si tu ne reconnais pas l’un d’eux, révoque-le '
                        'puis change ton mot de passe.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    for (final d in appareils) _tuile(theme, d),
                  ],
                ),
    );
  }

  Widget _messageErreur(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_erreur!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 16),
              OutlinedButton(
                  onPressed: _charger, child: const Text('Réessayer')),
            ],
          ),
        ),
      );

  Widget _tuile(ThemeData theme, Map<String, dynamic> d) {
    final actif = d['isActive'] == true;
    final courant = d['current'] == true;
    final nom = d['deviceName'] as String? ?? 'appareil';

    return ListTile(
      leading: Icon(_icone(d['platform'] as String?),
          color: actif
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant),
      title: Row(children: [
        Flexible(
            child: Text(nom,
                style: TextStyle(
                    decoration: actif ? null : TextDecoration.lineThrough))),
        if (courant) ...[
          const SizedBox(width: 8),
          _etiquette(theme, 'cet appareil', theme.colorScheme.primary),
        ],
        if (!actif) ...[
          const SizedBox(width: 8),
          _etiquette(theme, 'révoqué', theme.colorScheme.error),
        ],
      ]),
      subtitle: Text(
        'Lié le ${_date(d['createdAt'])}\n'
        'Dernière activité : ${_relatif(d['lastSeenAt'])}',
        style: theme.textTheme.bodySmall,
      ),
      isThreeLine: true,
      trailing: !actif
          ? null
          : _enCours == d['id']
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : IconButton(
                  tooltip: 'Révoquer',
                  icon: Icon(Icons.link_off, color: theme.colorScheme.error),
                  onPressed: () => _revoquer(d),
                ),
    );
  }

  Widget _etiquette(ThemeData theme, String texte, Color couleur) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: couleur.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(texte,
            style: TextStyle(
                fontSize: 11, color: couleur, fontWeight: FontWeight.w600)),
      );

  static IconData _icone(String? plateforme) => switch (plateforme) {
        'android' || 'ios' => Icons.smartphone,
        'windows' => Icons.desktop_windows_outlined,
        'macos' => Icons.laptop_mac,
        'linux' => Icons.computer,
        _ => Icons.devices_other,
      };

  static String _date(Object? iso) {
    final d = DateTime.tryParse('$iso')?.toLocal();
    if (d == null) return 'date inconnue';
    return '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  /// « il y a 3 heures » plutôt qu'une date brute : repérer un appareil actif
  /// à une heure où l'on ne s'en sert pas est exactement ce qu'on cherche ici.
  static String _relatif(Object? iso) {
    final d = DateTime.tryParse('$iso')?.toLocal();
    if (d == null) return 'inconnue';
    final delta = DateTime.now().difference(d);
    if (delta.inMinutes < 2) return 'à l’instant';
    if (delta.inMinutes < 60) return 'il y a ${delta.inMinutes} minutes';
    if (delta.inHours < 24) return 'il y a ${delta.inHours} heures';
    if (delta.inDays < 30) return 'il y a ${delta.inDays} jours';
    return _date(iso);
  }
}
