import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_settings.dart';
import '../../chat/data/chat_service.dart';
import 'two_factor_sheet.dart';

/// Écran d'options : apparence, compte, sécurité, à propos.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.service,
    required this.settings,
  });

  final ChatService service;
  final AppSettings settings;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _twoFactorEnabled;

  @override
  void initState() {
    super.initState();
    _refresh2fa();
  }

  Future<void> _refresh2fa() async {
    try {
      final on = await widget.service.twoFactorEnabled();
      if (mounted) setState(() => _twoFactorEnabled = on);
    } catch (_) {
      if (mounted) setState(() => _twoFactorEnabled = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.service;

    return Scaffold(
      appBar: AppBar(title: const Text('Options')),
      body: ListView(
        children: [
          _section(theme, 'Apparence'),
          ListenableBuilder(
            listenable: widget.settings,
            builder: (context, _) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text('Système'),
                          icon: Icon(Icons.brightness_auto_outlined)),
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text('Clair'),
                          icon: Icon(Icons.light_mode_outlined)),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text('Sombre'),
                          icon: Icon(Icons.dark_mode_outlined)),
                      ],
                      selected: {widget.settings.themeMode},
                      onSelectionChanged: (set) =>
                          widget.settings.setThemeMode(set.first),
                    ),
                  ),
                ),
                SwitchListTile(
                  value: widget.settings.enterToSend,
                  onChanged: widget.settings.setEnterToSend,
                  title: const Text('Entrée pour envoyer'),
                  subtitle: const Text(
                      'Sinon, Entrée insère un retour à la ligne'),
                ),
              ],
            ),
          ),

          const Divider(height: 32),
          _section(theme, 'Compte'),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Nom d’utilisateur'),
            subtitle: Text(s.username ?? '—'),
          ),
          ListTile(
            leading: const Icon(Icons.devices_outlined),
            title: const Text('Cet appareil'),
            subtitle: Text(s.deviceId ?? '—'),
          ),

          const Divider(height: 32),
          _section(theme, 'Sécurité'),
          ListTile(
            leading: Icon(
              _twoFactorEnabled == true
                  ? Icons.verified_user
                  : Icons.shield_outlined,
              color: _twoFactorEnabled == true ? theme.colorScheme.primary : null,
            ),
            title: const Text('Vérification en deux étapes'),
            subtitle: Text(switch (_twoFactorEnabled) {
              true => 'Activée — un code est demandé à chaque connexion',
              false => 'Désactivée — un mot de passe volé suffit à entrer',
              null => 'État indisponible',
            }),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await TwoFactorSheet.show(context, s, _twoFactorEnabled == true);
              await _refresh2fa();
            },
          ),
          ListTile(
            leading: Icon(Icons.logout, color: theme.colorScheme.error),
            title: const Text('Se déconnecter'),
            subtitle: const Text('Les clés restent sur cet appareil'),
            onTap: () {
              s.logout();
              Navigator.of(context).pop();
            },
          ),

          const Divider(height: 32),
          _section(theme, 'À propos'),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Chiffrement de bout en bout'),
            subtitle: const Text(
                'Le serveur ne relaie que du chiffré. Il ne détient aucune '
                'clé privée et ne peut lire aucun message.'),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Serveur'),
            subtitle: Text(AppConfig.serverUrl),
            onTap: () {
              Clipboard.setData(ClipboardData(text: AppConfig.serverUrl));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Adresse copiée')),
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _section(ThemeData theme, String titre) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          titre.toUpperCase(),
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      );
}
