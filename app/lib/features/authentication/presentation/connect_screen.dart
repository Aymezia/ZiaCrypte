import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_settings.dart';
import '../../../core/theme/app_theme.dart';
import '../../chat/data/chat_service.dart';

/// Écran d'entrée : reconnexion au compte de l'appareil, ou création d'un compte.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.service, required this.settings});

  final ChatService service;
  final AppSettings settings;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _server = TextEditingController(text: AppConfig.serverUrl);
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _totp = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  /// Les trois entrées possibles dans l'application.
  late _Mode _mode = widget.service.savedAccount == null
      ? _Mode.creation
      : _Mode.reconnexion;

  bool get _needsUsername => _mode != _Mode.reconnexion;

  /// Mot de passe masqué par défaut ; l'œil le révèle. Son absence obligeait à
  /// taper à l'aveugle, première cause d'erreur de saisie sur mobile.
  bool _obscure = true;

  /// « Rester connecté » : mémorise la préférence de l'appareil pour la
  /// reprise automatique au lancement. Pré-cochée selon le dernier choix.
  late bool _resterConnecte = widget.settings.resterConnecte;

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    _totp.dispose();
    super.dispose();
  }

  String? get _codeOrNull {
    final c = _totp.text.trim();
    return c.isEmpty ? null : c;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final serverUrl = AppConfig.allowServerOverride ? _server.text.trim() : null;
    // On mémorise le choix « rester connecté » AVANT la tentative : ainsi la
    // préférence est déjà à jour pour la reprise au prochain lancement.
    widget.settings.setResterConnecte(_resterConnecte);
    try {
      switch (_mode) {
        case _Mode.creation:
          await widget.service.registerAndConnect(
            user: _username.text.trim(),
            password: _password.text,
            serverUrl: serverUrl,
            resterConnecte: _resterConnecte,
          );
        case _Mode.compteExistant:
          await widget.service.addDeviceAndConnect(
            user: _username.text.trim(),
            password: _password.text,
            totp: _codeOrNull,
            serverUrl: serverUrl,
            resterConnecte: _resterConnecte,
          );
        case _Mode.reconnexion:
          await widget.service.loginAndConnect(
            password: _password.text,
            totp: _codeOrNull,
            serverUrl: serverUrl,
            resterConnecte: _resterConnecte,
          );
      }
    } catch (_) {
      // l'erreur est exposée par le service
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: DecoratedBox(
        decoration: ZiaTheme.backgroundDecoration(theme.colorScheme),
        child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListenableBuilder(
              listenable: widget.service,
              builder: (context, _) {
                final s = widget.service;
                final account = s.savedAccount;
                return Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(child: _logoHero(theme)),
                      const SizedBox(height: 20),
                      Text('ZiaCrypte',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                        switch (_mode) {
                          _Mode.creation => 'Messagerie chiffrée de bout en bout',
                          _Mode.compteExistant =>
                            'Ajouter cet appareil à un compte existant',
                          _Mode.reconnexion =>
                            'Content de te revoir, ${account?.username ?? ''}',
                        },
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 32),

                      if (AppConfig.allowServerOverride) ...[
                        TextFormField(
                          controller: _server,
                          decoration: const InputDecoration(
                            labelText: 'Adresse du serveur',
                            prefixIcon: Icon(Icons.dns_outlined),
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) =>
                              (v == null || v.isEmpty) ? 'Adresse requise' : null,
                        ),
                        const SizedBox(height: 16),
                      ],

                      if (AppConfig.isInsecureTransport) ...[
                        _banner(
                          theme,
                          Icons.warning_amber_rounded,
                          'Liaison non chiffrée (HTTP) : tes messages restent '
                          'chiffrés, mais ton mot de passe circule en clair.',
                          theme.colorScheme.tertiaryContainer,
                          theme.colorScheme.onTertiaryContainer,
                        ),
                        const SizedBox(height: 16),
                      ],

                      // À la reconnexion seule, l'appareil sait déjà à qui il
                      // appartient : le pseudo est inutile.
                      if (_needsUsername) ...[
                        TextFormField(
                          controller: _username,
                          // Le premier champ visible reçoit le focus : à la
                          // création, c'est le pseudo (le mot de passe le prend
                          // à la reconnexion, où le pseudo est absent).
                          autofocus: _needsUsername,
                          decoration: const InputDecoration(
                            labelText: 'Nom d’utilisateur',
                            prefixIcon: Icon(Icons.person_outline),
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) => (v == null || v.trim().length < 3)
                              ? '3 caractères minimum'
                              : null,
                        ),
                        const SizedBox(height: 16),
                      ],

                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        autofocus: !_needsUsername,
                        onFieldSubmitted: (_) => _submit(),
                        // Réévalue la jauge de robustesse à chaque frappe (mode
                        // création seulement, où elle est affichée).
                        onChanged: _mode == _Mode.creation
                            ? (_) => setState(() {})
                            : null,
                        decoration: InputDecoration(
                          labelText: 'Mot de passe',
                          prefixIcon: const Icon(Icons.key_outlined),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? 'Afficher' : 'Masquer',
                            icon: Icon(_obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (v) => (v == null || v.length < 8)
                            ? '8 caractères minimum'
                            : null,
                      ),

                      // Robustesse indiquée seulement à la création : elle guide
                      // le choix d'un mot de passe neuf. À la reconnexion, juger
                      // un mot de passe déjà choisi ne servirait qu'à inquiéter.
                      if (_mode == _Mode.creation && _password.text.isNotEmpty)
                        _jaugeRobustesse(theme, _password.text),

                      // Champ de code affiché seulement quand le serveur l'a
                      // réclamé : on ne demande pas le second facteur d'emblée,
                      // le mot de passe validé déclenche la demande.
                      if (s.needsTotp) ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _totp,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          autofocus: true,
                          onFieldSubmitted: (_) => _submit(),
                          decoration: const InputDecoration(
                            labelText: 'Code de vérification',
                            prefixIcon: Icon(Icons.pin_outlined),
                            border: OutlineInputBorder(),
                            counterText: '',
                            helperText:
                                'Le code à six chiffres de ton application',
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),

                      // Rester connecté : évite de retaper le mot de passe à
                      // chaque ouverture. Le jeton de reprise est gardé dans le
                      // coffre chiffré de l'appareil ; le verrou par code (s'il
                      // est posé) protège quand même l'accès.
                      InkWell(
                        onTap: s.busy
                            ? null
                            : () => setState(
                                () => _resterConnecte = !_resterConnecte),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Checkbox(
                                value: _resterConnecte,
                                onChanged: s.busy
                                    ? null
                                    : (v) => setState(
                                        () => _resterConnecte = v ?? false),
                              ),
                              const Expanded(child: Text('Rester connecté')),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      FilledButton(
                        onPressed: s.busy ? null : _submit,
                        style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 18)),
                        child: s.busy
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : Text(switch (_mode) {
                                _Mode.creation => 'Créer mon compte',
                                _Mode.compteExistant => 'Ajouter cet appareil',
                                _Mode.reconnexion => 'Se reconnecter',
                              }),
                      ),

                      if (s.error != null) ...[
                        const SizedBox(height: 16),
                        _banner(
                          theme,
                          Icons.error_outline,
                          s.error!,
                          theme.colorScheme.errorContainer,
                          theme.colorScheme.onErrorContainer,
                        ),
                      ],

                      const SizedBox(height: 8),
                      for (final target in _Mode.values)
                        if (target != _mode &&
                            (target != _Mode.reconnexion || account != null))
                          TextButton(
                            onPressed: s.busy
                                ? null
                                : () => setState(() => _mode = target),
                            child: Text(switch (target) {
                              _Mode.creation => 'Créer un nouveau compte',
                              _Mode.compteExistant =>
                                'J’ai déjà un compte ailleurs',
                              _Mode.reconnexion =>
                                'Revenir au compte ${account!.username}',
                            }),
                          ),

                      const SizedBox(height: 16),
                      Text(
                        switch (_mode) {
                          _Mode.creation =>
                            'Les clés privées sont générées et conservées par le '
                                'moteur natif ; le serveur ne relaie que du chiffré.',
                          // Dit franchement, sinon l'utilisateur croira que
                          // l'application a perdu ses messages : les clés du
                          // compte vivent sur l'appareil où il a été créé et le
                          // serveur ne peut pas les fournir. C'est la garantie,
                          // pas une limitation contournable.
                          _Mode.compteExistant =>
                            'Cet appareil rejoint le compte avec sa propre identité. '
                                'Il ne recevra que les messages échangés à partir de '
                                'maintenant : l’historique reste sur l’appareil '
                                'd’origine, et personne — pas même le serveur — ne '
                                'peut le lui transmettre.',
                          _Mode.reconnexion =>
                            'Tes clés sont déjà sur cet appareil, chiffrées par le '
                                'trousseau du système.',
                        },
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        ),
      ),
    );
  }

  /// Logo héros : un cadenas sur un disque en dégradé d'accent, nimbé. C'est la
  /// première chose que l'on voit ; elle donne le ton « chiffré, moderne ».
  Widget _logoHero(ThemeData theme) {
    final c = theme.colorScheme;
    return Container(
      width: 92,
      height: 92,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: ZiaTheme.accentGradient(c),
        boxShadow: ZiaTheme.glow(c.primary, opacity: 0.45, blur: 28),
      ),
      child: Icon(Icons.lock_rounded, size: 44, color: c.onPrimary),
    );
  }

  /// Jauge de robustesse du mot de passe : indicative, jamais bloquante (le
  /// seul refus reste « 8 caractères minimum »). Score simple — longueur et
  /// variété de familles de caractères — pas une mesure d'entropie exacte, mais
  /// assez pour pousser vers plus long et plus varié.
  Widget _jaugeRobustesse(ThemeData theme, String mdp) {
    var score = 0;
    if (mdp.length >= 8) score++;
    if (mdp.length >= 12) score++;
    if (RegExp(r'[A-Z]').hasMatch(mdp) && RegExp(r'[a-z]').hasMatch(mdp)) score++;
    if (RegExp(r'[0-9]').hasMatch(mdp)) score++;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(mdp)) score++;
    // 0-5 → trois paliers.
    final niveau = score <= 2 ? 0 : (score <= 3 ? 1 : 2);
    final (libelle, couleur) = switch (niveau) {
      0 => ('Faible', theme.colorScheme.error),
      1 => ('Moyen', theme.colorScheme.tertiary),
      _ => ('Fort', theme.colorScheme.primary),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          for (var i = 0; i < 3; i++) ...[
            Expanded(
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  color: i <= niveau
                      ? couleur
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            if (i < 2) const SizedBox(width: 4),
          ],
          const SizedBox(width: 10),
          Text(libelle,
              style: theme.textTheme.labelSmall?.copyWith(color: couleur)),
        ],
      ),
    );
  }

  Widget _banner(ThemeData theme, IconData icon, String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, size: 20, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: fg)),
          ),
        ],
      ),
    );
  }
}

/// Les trois façons d'entrer dans l'application.
enum _Mode {
  /// Reprendre le compte déjà installé sur cet appareil.
  reconnexion,

  /// Créer un compte neuf.
  creation,

  /// Rattacher cet appareil à un compte existant créé ailleurs.
  compteExistant,
}
