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
  final _formKey = GlobalKey<FormState>();

  /// Vrai si l'on crée un compte plutôt que de se reconnecter.
  late bool _creating = widget.service.savedAccount == null;

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final serverUrl = AppConfig.allowServerOverride ? _server.text.trim() : null;
    try {
      if (_creating) {
        await widget.service.registerAndConnect(
          user: _username.text.trim(),
          password: _password.text,
          serverUrl: serverUrl,
        );
      } else {
        await widget.service.loginAndConnect(
          password: _password.text,
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
                        _creating
                            ? 'Messagerie chiffrée de bout en bout'
                            : 'Content de te revoir, ${account?.username ?? ''}',
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

                      // Le pseudo n'est demandé qu'à la création : à la
                      // reconnexion, l'appareil sait déjà à qui il appartient.
                      if (_creating) ...[
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
                        autofocus: !_creating,
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
                            : Text(_creating ? 'Créer mon compte' : 'Se reconnecter'),
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

                      // Bascule entre reconnexion et création.
                      if (account != null) ...[
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: s.busy
                              ? null
                              : () => setState(() => _creating = !_creating),
                          child: Text(_creating
                              ? 'Revenir au compte ${account.username}'
                              : 'Utiliser un autre compte'),
                        ),
                      ],

                      const SizedBox(height: 16),
                      Text(
                        _creating
                            ? 'Les clés privées sont générées et conservées par le '
                                'moteur natif ; le serveur ne relaie que du chiffré.'
                            : 'Tes clés sont déjà sur cet appareil, chiffrées par le '
                                'trousseau du système.',
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
