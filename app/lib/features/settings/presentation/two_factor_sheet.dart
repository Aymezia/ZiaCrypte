import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../chat/data/chat_service.dart';

/// Activation / désactivation de la vérification en deux étapes.
class TwoFactorSheet extends StatefulWidget {
  const TwoFactorSheet({
    super.key,
    required this.service,
    required this.currentlyEnabled,
  });

  final ChatService service;
  final bool currentlyEnabled;

  static Future<void> show(
    BuildContext context,
    ChatService service,
    bool enabled,
  ) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom),
          child: TwoFactorSheet(service: service, currentlyEnabled: enabled),
        ),
      );

  @override
  State<TwoFactorSheet> createState() => _TwoFactorSheetState();
}

class _TwoFactorSheetState extends State<TwoFactorSheet> {
  final _code = TextEditingController();
  final _password = TextEditingController();

  String? _secret;
  String? _otpauthUri;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.currentlyEnabled
                    ? 'Désactiver la vérification en deux étapes'
                    : 'Activer la vérification en deux étapes',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              if (widget.currentlyEnabled)
                ..._disableBody(theme)
              else
                ..._enableBody(theme),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------- activation ----------

  List<Widget> _enableBody(ThemeData theme) {
    if (_secret == null) {
      return [
        Text(
          'Un code à six chiffres, renouvelé toutes les 30 secondes, sera '
          'demandé à chaque connexion — en plus du mot de passe. Il te faut une '
          'application d’authentification (Aegis, Google Authenticator, '
          '1Password…).',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _startSetup,
          child: _busy
              ? const SizedBox(
                  height: 18, width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Commencer'),
        ),
      ];
    }

    return [
      Text('Scanne ce QR code dans ton application d’authentification :',
          style: theme.textTheme.bodyMedium),
      const SizedBox(height: 16),
      Center(
        child: Container(
          padding: const EdgeInsets.all(12),
          color: Colors.white, // un QR se lit mieux sur fond blanc franc
          child: QrImageView(
            data: _otpauthUri!,
            size: 200,
            backgroundColor: Colors.white,
          ),
        ),
      ),
      const SizedBox(height: 16),
      Text('Ou saisis cette clé à la main :', style: theme.textTheme.bodySmall),
      const SizedBox(height: 4),
      InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: _secret!));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Clé copiée')),
          );
        },
        child: Row(
          children: [
            Expanded(
              child: SelectableText(
                _secret!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
              ),
            ),
            const Icon(Icons.copy, size: 18),
          ],
        ),
      ),
      const SizedBox(height: 20),
      Text('Entre ensuite le code affiché pour confirmer :',
          style: theme.textTheme.bodyMedium),
      const SizedBox(height: 8),
      _codeField(),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy ? null : _confirmEnable,
        child: const Text('Activer'),
      ),
    ];
  }

  // ---------- désactivation ----------

  List<Widget> _disableBody(ThemeData theme) => [
        Text(
          'La désactivation exige ton mot de passe ET un code courant : ni un '
          'appareil déverrouillé ni ton seul téléphone ne doivent suffire à '
          'retirer cette protection.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Mot de passe',
            prefixIcon: Icon(Icons.key_outlined),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        _codeField(),
        const SizedBox(height: 16),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.errorContainer,
              foregroundColor: theme.colorScheme.onErrorContainer),
          onPressed: _busy ? null : _confirmDisable,
          child: const Text('Désactiver'),
        ),
      ];

  Widget _codeField() => TextField(
        controller: _code,
        keyboardType: TextInputType.number,
        maxLength: 6,
        decoration: const InputDecoration(
          labelText: 'Code à six chiffres',
          prefixIcon: Icon(Icons.pin_outlined),
          border: OutlineInputBorder(),
          counterText: '',
        ),
      );

  // ---------- actions ----------

  Future<void> _startSetup() async {
    setState(() { _busy = true; _error = null; });
    try {
      final res = await widget.service.twoFactorSetup();
      setState(() {
        _secret = res['secret'] as String;
        _otpauthUri = res['otpauthUri'] as String;
        _busy = false;
      });
    } catch (e) {
      setState(() { _busy = false; _error = 'Impossible de démarrer : $e'; });
    }
  }

  Future<void> _confirmEnable() async {
    setState(() { _busy = true; _error = null; });
    try {
      await widget.service.twoFactorEnable(_code.text.trim());
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Code refusé. Vérifie l’heure de ton téléphone et réessaie.';
      });
    }
  }

  Future<void> _confirmDisable() async {
    setState(() { _busy = true; _error = null; });
    try {
      await widget.service.twoFactorDisable(_password.text, _code.text.trim());
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Mot de passe ou code invalide.';
      });
    }
  }
}
