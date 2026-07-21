import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../chat/data/chat_service.dart';

/// Sauvegarde chiffrée : export et restauration.
///
/// ## Ce que l'écran doit dire, et que la plupart des applications taisent
///
/// Une sauvegarde déplace le risque. Tant que les clés restent dans le
/// coffre-fort du système, elles ne sortent pas de l'appareil. Dès qu'un
/// fichier existe, il peut être copié, oublié sur une clé USB, envoyé par
/// courriel — et tout ce qui le protège est la phrase choisie.
///
/// L'écran l'écrit noir sur blanc plutôt que de laisser croire à une
/// protection automatique. Il refuse aussi le stockage sur nos serveurs, parce
/// que la question ne se pose même pas : ce serait confier au serveur ce que
/// le chiffrement de bout en bout lui refuse.
class BackupSheet extends StatefulWidget {
  const BackupSheet({super.key, required this.service});

  final ChatService service;

  static Future<void> show(BuildContext context, ChatService service) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: BackupSheet(service: service),
        ),
      );

  @override
  State<BackupSheet> createState() => _BackupSheetState();
}

enum _Etape { choix, phraseExport, phraseImport, travail, fait, erreur }

class _BackupSheetState extends State<BackupSheet> {
  _Etape _etape = _Etape.choix;
  final _phrase = TextEditingController();
  final _confirmation = TextEditingController();
  String? _message;
  String? _cheminEcrit;

  @override
  void dispose() {
    _phrase.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _exporter() async {
    final phrase = _phrase.text;
    if (phrase.length < 12) {
      setState(() => _message = 'Douze caractères minimum.');
      return;
    }
    if (phrase != _confirmation.text) {
      // Une faute de frappe dans une phrase qu'on ne reverra jamais rend la
      // sauvegarde définitivement illisible : mieux vaut la saisir deux fois.
      setState(() => _message = 'Les deux phrases ne correspondent pas.');
      return;
    }

    setState(() {
      _etape = _Etape.travail;
      _message = null;
    });
    try {
      final octets = await widget.service.exporterSauvegarde(phrase);
      final dossier = await _choisirDossier();
      if (dossier == null) {
        if (mounted) setState(() => _etape = _Etape.choix);
        return;
      }
      final horodatage = DateTime.now().toIso8601String().split('T').first;
      final chemin =
          '$dossier${Platform.pathSeparator}ziacrypte-$horodatage.ziabak';
      await File(chemin).writeAsBytes(octets);
      if (!mounted) return;
      setState(() {
        _cheminEcrit = chemin;
        _etape = _Etape.fait;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = '$e';
          _etape = _Etape.erreur;
        });
      }
    }
  }

  Future<void> _importer() async {
    final phrase = _phrase.text;
    if (phrase.isEmpty) {
      setState(() => _message = 'Saisis la phrase de la sauvegarde.');
      return;
    }
    setState(() {
      _etape = _Etape.travail;
      _message = null;
    });
    try {
      final chemin = await _choisirFichier();
      if (chemin == null) {
        if (mounted) setState(() => _etape = _Etape.choix);
        return;
      }
      final octets = await File(chemin).readAsBytes();
      await widget.service.importerSauvegarde(phrase, octets);
      if (!mounted) return;
      setState(() {
        _cheminEcrit = null;
        _etape = _Etape.fait;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = '$e';
          _etape = _Etape.erreur;
        });
      }
    }
  }

  Future<String?> _choisirDossier() async {
    try {
      return await FilePicker.getDirectoryPath();
    } catch (_) {
      return _saisirChemin('Dossier où écrire la sauvegarde',
          Platform.environment['HOME'] ?? '/tmp');
    }
  }

  Future<String?> _choisirFichier() async {
    try {
      final r = await FilePicker.pickFiles(withData: false);
      return r?.files.single.path;
    } catch (_) {
      return _saisirChemin('Chemin de la sauvegarde', '');
    }
  }

  Future<String?> _saisirChemin(String titre, String initial) {
    final ctrl = TextEditingController(text: initial)
      ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titre),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Sauvegarde chiffrée', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 16),
              ..._corps(theme),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _corps(ThemeData theme) => switch (_etape) {
        _Etape.choix => [
            Text(
              'Tes clés n’existent que sur cet appareil. Sans sauvegarde, le '
              'perdre signifie perdre ton historique — personne, pas même nous, '
              'ne peut te le rendre.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Le fichier produit contient tout : identité, sessions, '
                'historique. Il n’est protégé que par la phrase que tu vas '
                'choisir. Range-le où tu veux — surtout pas chez nous, ce '
                'serait annuler tout l’intérêt du chiffrement.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => setState(() {
                _etape = _Etape.phraseExport;
                _message = null;
              }),
              icon: const Icon(Icons.save_alt),
              label: const Text('Créer une sauvegarde'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => setState(() {
                _etape = _Etape.phraseImport;
                _message = null;
              }),
              icon: const Icon(Icons.restore),
              label: const Text('Restaurer une sauvegarde'),
            ),
          ],
        _Etape.phraseExport => [
            Text('Choisis une phrase de passe', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Douze caractères minimum. Note-la : si tu l’oublies, la '
              'sauvegarde est définitivement illisible. Il n’y a aucun moyen de '
              'la récupérer — c’est ce qui fait qu’elle protège vraiment.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _phrase,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Phrase de passe', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmation,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Confirme la phrase', border: OutlineInputBorder()),
            ),
            if (_message != null) ...[
              const SizedBox(height: 10),
              Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 16),
            FilledButton(onPressed: _exporter, child: const Text('Continuer')),
          ],
        _Etape.phraseImport => [
            Text('Restaurer', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'La restauration remplace l’identité de cet appareil par celle de '
              'la sauvegarde. Les messages reçus ici depuis seront conservés, '
              'mais cet appareil deviendra celui du compte sauvegardé.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _phrase,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Phrase de la sauvegarde',
                  border: OutlineInputBorder()),
            ),
            if (_message != null) ...[
              const SizedBox(height: 10),
              Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 16),
            FilledButton(
                onPressed: _importer, child: const Text('Choisir le fichier')),
          ],
        _Etape.travail => [
            const Row(children: [
              SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Expanded(child: Text('Chiffrement en cours…')),
            ]),
            const SizedBox(height: 10),
            Text(
              'La dérivation de la clé prend volontairement du temps : c’est ce '
              'qui rend une phrase de passe coûteuse à deviner.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        _Etape.fait => [
            Row(children: [
              Icon(Icons.check_circle, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_cheminEcrit == null
                    ? 'Sauvegarde restaurée. Reconnecte-toi pour continuer.'
                    : 'Sauvegarde écrite.'),
              ),
            ]),
            if (_cheminEcrit != null) ...[
              const SizedBox(height: 10),
              SelectableText(_cheminEcrit!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              const SizedBox(height: 10),
              Text(
                'Mets-la à l’abri, et souviens-toi de la phrase : ce fichier ne '
                'vaut rien sans elle, et rien ne la remplace.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Fermer'),
            ),
          ],
        _Etape.erreur => [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_message ?? '',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer)),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => setState(() {
                _etape = _Etape.choix;
                _message = null;
              }),
              child: const Text('Revenir'),
            ),
          ],
      };
}
