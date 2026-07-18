import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../chat/data/chat_service.dart';

/// Écran d'entrée : adresse du serveur + création de compte.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.service});

  final ChatService service;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _server = TextEditingController(text: AppConfig.serverUrl);
  final _username = TextEditingController();
  final _password = TextEditingController(text: 'password123');
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    try {
      await widget.service.registerAndConnect(
        serverUrl: _server.text.trim(),
        user: _username.text.trim(),
        password: _password.text,
      );
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
                      Text('Messagerie chiffrée de bout en bout',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 32),
                      // L'adresse du serveur est fixée à la compilation : le
                      // champ n'apparaît qu'en mode développement.
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
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.tertiaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.warning_amber_rounded,
                                  size: 20,
                                  color: theme.colorScheme.onTertiaryContainer),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Liaison non chiffrée (HTTP) : tes messages restent '
                                  'chiffrés, mais ton mot de passe circule en clair.',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: theme.colorScheme.onTertiaryContainer),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
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
                      TextFormField(
                        controller: _password,
                        obscureText: true,
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
                            : const Text('Créer mon compte'),
                      ),
                      if (s.error != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(s.error!,
                              style: TextStyle(
                                  color: theme.colorScheme.onErrorContainer)),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Text(
                        'Les clés privées sont générées et conservées par le moteur '
                        'natif ; le serveur ne relaie que du chiffré.',
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
}
