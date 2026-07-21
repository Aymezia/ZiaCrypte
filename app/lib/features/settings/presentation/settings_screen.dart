import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_settings.dart';
import '../../chat/data/chat_service.dart';
import '../../chat/presentation/identity_avatar.dart';
import '../../../core/update/update_service.dart';
import 'backup_sheet.dart';
import 'devices_screen.dart';
import 'two_factor_sheet.dart';
import 'update_sheet.dart';

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

  /// Choisit une image et la publie comme photo de profil.
  ///
  /// Même repli que pour les pièces jointes : le sélecteur graphique passe par
  /// le portail XDG, absent de certains environnements. Plutôt que de rester
  /// inerte, on demande le chemin.
  Future<void> _choisirPhoto() async {
    String? chemin;
    try {
      final res = await FilePicker.pickFiles(withData: false);
      chemin = res?.files.single.path;
    } catch (_) {
      chemin = await _demanderChemin();
    }
    if (chemin == null || chemin.isEmpty) return;
    await widget.service.definirAvatar(chemin);
    if (!mounted) return;
    final err = widget.service.error;
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<String?> _demanderChemin() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Photo de profil'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Chemin de l’image',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('Valider')),
        ],
      ),
    );
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
                SwitchListTile(
                  value: widget.settings.indicateurEcriture,
                  onChanged: (v) {
                    widget.settings.setIndicateurEcriture(v);
                    widget.service.indicateurEcritureActif = v;
                  },
                  title: const Text('Signaler que j’écris'),
                  subtitle: const Text(
                      'Le serveur voit ce signal — il connaît déjà à qui tu '
                      'écris, mais pas quand tu tapes'),
                ),
                SwitchListTile(
                  value: widget.settings.accusesLecture,
                  onChanged: (v) {
                    widget.settings.setAccusesLecture(v);
                    widget.service.accusesLectureActifs = v;
                  },
                  title: const Text('Accusés de lecture'),
                  subtitle: const Text(
                      'Chiffrés : le serveur ne sait pas que tu as ouvert un '
                      'message. Désactivés par défaut'),
                ),
              ],
            ),
          ),

          const Divider(height: 32),
          _section(theme, 'Compte'),
          // Écoute le service : sans ça, la photo qu'on vient de choisir ne
          // s'affiche qu'au prochain passage sur cet écran — on croit que
          // l'enregistrement a échoué alors qu'il a réussi.
          ListenableBuilder(
            listenable: s,
            builder: (context, _) => ListTile(
              leading: IdentityAvatar(
                label: s.username ?? '?',
                photo: s.photoDe(s.userId),
                size: 40,
              ),
              title: const Text('Photo de profil'),
              subtitle: Text(s.busy
                  ? 'Chiffrement et envoi…'
                  : 'Chiffrée comme un message : le serveur ne la voit pas'),
              trailing: const Icon(Icons.chevron_right),
              onTap: s.busy ? null : _choisirPhoto,
            ),
          ),
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
            leading: const Icon(Icons.devices_other),
            title: const Text('Appareils liés'),
            subtitle: const Text(
                'Chacun reçoit une copie chiffrée de tes messages'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DevicesScreen(service: s),
            )),
          ),
          ListTile(
            leading: const Icon(Icons.save_alt),
            title: const Text('Sauvegarde chiffrée'),
            subtitle: const Text(
                'Sans elle, perdre cet appareil c’est perdre ton historique'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => BackupSheet.show(context, s),
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
          _section(theme, 'Application'),
          ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: const Text('Mise à jour'),
            subtitle: Text('Version ${AppConfig.version}'
                '${UpdateService.signingConfigured ? '' : ' — vérification de signature non configurée'}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              final engine = widget.service.engine;
              if (engine == null) return;
              UpdateSheet.show(context, UpdateService(engine));
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
          // L'adresse du serveur n'est plus affichée.
          //
          // À ne pas confondre avec du secret : elle reste lisible dans le
          // binaire (un `strings` la donne) et visible dans le trafic réseau de
          // n'importe quel appareil. Ce que ça change réellement, c'est qu'elle
          // ne s'expose plus d'elle-même sur une capture d'écran partagée ou
          // par-dessus l'épaule.
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Connexion'),
            subtitle: Text(AppConfig.isInsecureTransport
                ? 'Liaison NON chiffrée vers le serveur'
                : 'Liaison chiffrée (TLS) vers le serveur'),
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
