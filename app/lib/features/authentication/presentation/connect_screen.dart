import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../chat/data/chat_service.dart';

/// Écran d'entrée : reconnexion au compte de l'appareil, ou création d'un compte.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.service});

  final ChatService service;

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
    try {
      switch (_mode) {
        case _Mode.creation:
          await widget.service.registerAndConnect(
            user: _username.text.trim(),
            password: _password.text,
            serverUrl: serverUrl,
          );
        case _Mode.compteExistant:
          await widget.service.addDeviceAndConnect(
            user: _username.text.trim(),
            password: _password.text,
            totp: _codeOrNull,
            serverUrl: serverUrl,
          );
        case _Mode.reconnexion:
          await widget.service.loginAndConnect(
            password: _password.text,
            totp: _codeOrNull,
            serverUrl: serverUrl,
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
      body: Center(
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
                      Icon(Icons.lock_rounded,
                          size: 56, color: theme.colorScheme.primary),
                      const SizedBox(height: 16),
                      Text('ZiaCrypte',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
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
                        obscureText: true,
                        autofocus: !_needsUsername,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: const InputDecoration(
                          labelText: 'Mot de passe',
                          prefixIcon: Icon(Icons.key_outlined),
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => (v == null || v.length < 8)
                            ? '8 caractères minimum'
                            : null,
                      ),

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
                      const SizedBox(height: 24),

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
