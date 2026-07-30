import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_settings.dart';
import '../../chat/data/chat_service.dart';
import '../../chat/presentation/identity_avatar.dart';
import '../../../core/update/update_service.dart';
import 'backup_sheet.dart';
import 'admin_screen.dart';
import 'blocked_screen.dart';
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

  bool _verrouillagePose = false;

  @override
  void initState() {
    super.initState();
    _refresh2fa();
    _refreshVerrou();
  }

  Future<void> _refreshVerrou() async {
    final pose = await widget.service.verrouillageActif();
    if (mounted) setState(() => _verrouillagePose = pose);
  }

  Future<void> _gererVerrouillage() async {
    if (_verrouillagePose) {
      final retirer = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Retirer le code ?'),
          content: const Text(
              'L’application ne se verrouillera plus. Tes messages restent '
              'chiffrés — ce code ne protège que d’un regard sur un appareil '
              'déjà déverrouillé.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Annuler')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Retirer')),
          ],
        ),
      );
      if (retirer != true) return;
      await widget.service.retirerVerrouillage();
      await _refreshVerrou();
      return;
    }

    final ctrl = TextEditingController();
    final confirm = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Code de verrouillage'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'Quatre caractères minimum. Il n’est pas récupérable : si tu '
            'l’oublies, il faudra te déconnecter et te reconnecter.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: 'Code', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: confirm,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: 'Confirme', border: OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(
                ctx, ctrl.text == confirm.text ? ctrl.text : null),
            child: const Text('Valider'),
          ),
        ],
      ),
    );
    if (code == null || code.length < 4) return;
    try {
      await widget.service.definirVerrouillage(code);
      await _refreshVerrou();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
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

  /// Saisit le statut personnel.
  ///
  /// Une simple boîte de dialogue : le statut est une phrase, pas un écran.
  Future<void> _modifierStatut() async {
    final s = widget.service;
    final champ = TextEditingController(text: s.statutDe(s.userId) ?? '');
    // Présences rapides façon Teams : un tap suffit. Le statut reste un texte
    // libre chiffré diffusé aux correspondants ; ces raccourcis ne font que
    // pré-remplir des valeurs parlantes (aucun changement de protocole).
    const presets = [
      '🟢 Disponible',
      '🟠 Occupé',
      '⛔ Ne pas déranger',
      '🌙 Absent',
    ];
    final valeur = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Statut'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in presets)
                  ActionChip(
                    label: Text(p),
                    onPressed: () => Navigator.pop(context, p),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: champ,
              autofocus: true,
              maxLength: ChatService.statutMax,
              decoration: const InputDecoration(
                labelText: 'Ou un statut personnalisé',
                hintText: 'en réunion, en vacances…',
                helperText: 'Chiffré : seuls tes correspondants le voient',
                helperMaxLines: 2,
              ),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ],
        ),
        actions: [
          // Effacer plutôt que « vider le champ puis valider » : retirer son
          // statut est une action à part entière, elle mérite un bouton.
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Effacer'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, champ.text),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    champ.dispose();
    if (valeur == null) return;
    await s.definirStatut(valeur);
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
          _profilHeader(theme, s),
          const Divider(height: 32),
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
                SwitchListTile(
                  value: widget.settings.partagePresence,
                  onChanged: (v) {
                    widget.settings.setPartagePresence(v);
                    widget.service.partagePresenceActif = v;
                  },
                  title: const Text('Apparaître en ligne'),
                  subtitle: const Text(
                      'Seuls tes correspondants le voient. Tu continues de les '
                      'voir même sans partager. Désactivé par défaut'),
                ),
              ],
            ),
          ),

          const Divider(height: 32),
          _section(theme, 'Compte'),
          // Avatar et statut sont désormais dans l'en-tête, en haut : on ne
          // garde ici que les informations, non modifiables.
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
            leading: Icon(_verrouillagePose ? Icons.lock : Icons.lock_open),
            title: const Text('Code de verrouillage'),
            subtitle: Text(_verrouillagePose
                ? 'Demandé au retour dans l’application'
                : 'Protège d’un regard sur un appareil déverrouillé'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _gererVerrouillage,
          ),
          if (_verrouillagePose)
            ListenableBuilder(
              listenable: widget.settings,
              builder: (context, _) => ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Verrouiller après'),
                subtitle: Text(switch (widget.settings.delaiVerrouillage) {
                  0 => 'Immédiatement',
                  60 => '1 minute d’absence',
                  300 => '5 minutes d’absence',
                  _ => '${widget.settings.delaiVerrouillage} s d’absence',
                }),
                trailing: PopupMenuButton<int>(
                  onSelected: widget.settings.setDelaiVerrouillage,
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 0, child: Text('Immédiatement')),
                    PopupMenuItem(value: 60, child: Text('1 minute')),
                    PopupMenuItem(value: 300, child: Text('5 minutes')),
                  ],
                ),
              ),
            ),
          if (Platform.isAndroid)
            ListenableBuilder(
              listenable: widget.settings,
              builder: (context, _) => SwitchListTile(
                secondary: const Icon(Icons.screenshot_monitor_outlined),
                value: widget.settings.protectionEcran,
                onChanged: widget.settings.setProtectionEcran,
                title: const Text('Bloquer les captures d’écran'),
                subtitle: const Text(
                    'Masque aussi l’aperçu dans les tâches récentes. '
                    'N’empêche pas de photographier l’écran'),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Comptes bloqués'),
            subtitle: const Text(
                'Leurs messages ne sont pas remis, et ils ne le savent pas'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => BlockedScreen(service: s),
            )),
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
          // Visible seulement pour un compte administrateur. N'ouvre aucun
          // accès aux messages : chaque action réclame ensuite un code 2FA, et
          // le serveur ne peut de toute façon rien déchiffrer.
          if (s.isAdmin) ...[
            _section(theme, 'Modération'),
            ListTile(
              leading: Icon(Icons.shield_outlined,
                  color: theme.colorScheme.primary),
              title: const Text('Administration'),
              subtitle: const Text(
                  'Signalements, comptes, journal — code 2FA à chaque action'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AdminScreen(service: s),
              )),
            ),
          ],
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

  /// En-tête de profil : l'identité en évidence plutôt qu'enfouie dans des
  /// tuiles. Grand avatar (un tap le change), pseudo, statut éditable. Écoute
  /// le service pour se rafraîchir dès qu'une photo ou un statut change.
  Widget _profilHeader(ThemeData theme, ChatService s) => ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          final statut = s.statutDe(s.userId);
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Column(
              children: [
                // Avatar + pastille appareil-photo, tappable.
                Semantics(
                  button: true,
                  label: 'Changer la photo de profil',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(48),
                    onTap: s.busy ? null : _choisirPhoto,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        IdentityAvatar(
                          label: s.username ?? '?',
                          photo: s.photoDe(s.userId),
                          size: 84,
                        ),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: theme.colorScheme.surface, width: 2),
                            ),
                            child: Icon(
                              s.busy ? Icons.hourglass_top : Icons.photo_camera,
                              size: 15,
                              color: theme.colorScheme.onPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(s.username ?? '—',
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                // Statut : éditable d'un tap. Un libellé d'invite quand il est
                // vide, pour qu'on sache qu'on peut en mettre un.
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _modifierStatut,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.mood_outlined,
                            size: 15, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            statut ?? 'Ajouter un statut',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: statut == null
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(Icons.edit_outlined,
                            size: 13, color: theme.colorScheme.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
                // Le chiffrement reste dit, mais discrètement, une fois.
                const SizedBox(height: 6),
                Text('Photo et statut chiffrés — le serveur ne les voit pas',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          );
        },
      );

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
