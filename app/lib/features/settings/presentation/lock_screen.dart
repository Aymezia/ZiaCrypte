import 'package:flutter/material.dart';

import '../../chat/data/chat_service.dart';

/// Écran de déverrouillage.
///
/// S'interpose devant les conversations quand l'application revient au
/// premier plan après une absence. Il ne déchiffre rien et ne détient rien :
/// la vérification est faite par le moteur natif, qui compare en temps
/// constant une empreinte Argon2id.
///
/// Il ne protège pas d'un adversaire qui possède l'appareil — les clés restent
/// déchiffrables par le coffre-fort du système. Il protège de qui passe devant
/// un appareil déverrouillé, ce qui est de très loin le cas le plus fréquent.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.service, required this.onOuvert});

  final ChatService service;
  final VoidCallback onOuvert;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _code = TextEditingController();
  bool _verification = false;
  String? _erreur;
  int _echecs = 0;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _valider() async {
    if (_verification || _code.text.isEmpty) return;
    setState(() {
      _verification = true;
      _erreur = null;
    });
    try {
      final ok = await widget.service.verifierVerrouillage(_code.text);
      if (!mounted) return;
      if (ok) {
        widget.onOuvert();
        return;
      }
      setState(() {
        _echecs++;
        _verification = false;
        _code.clear();
        // On compte les échecs sans jamais bloquer l'accès : un verrouillage
        // définitif après N essais transformerait une faute de frappe répétée
        // en perte du compte, alors que le contenu reste de toute façon
        // accessible à qui possède l'appareil et sait faire.
        _erreur = 'Code incorrect.'
            '${_echecs >= 3 ? ' Le code n’est pas récupérable : si tu l’as oublié, déconnecte-toi et reconnecte-toi.' : ''}';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _verification = false;
          _erreur = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_rounded,
                    size: 48, color: theme.colorScheme.primary),
                const SizedBox(height: 20),
                Text('ZiaCrypte est verrouillé',
                    style: theme.textTheme.titleLarge),
                const SizedBox(height: 24),
                TextField(
                  controller: _code,
                  obscureText: true,
                  autofocus: true,
                  enabled: !_verification,
                  onSubmitted: (_) => _valider(),
                  decoration: const InputDecoration(
                    labelText: 'Code de verrouillage',
                    prefixIcon: Icon(Icons.key),
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_erreur != null) ...[
                  const SizedBox(height: 12),
                  Text(_erreur!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _verification ? null : _valider,
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16)),
                    child: _verification
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Déverrouiller'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
