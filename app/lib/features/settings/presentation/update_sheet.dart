import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/update/update_service.dart';

/// Panneau de mise à jour : recherche, vérification de signature, application.
class UpdateSheet extends StatefulWidget {
  const UpdateSheet({super.key, required this.service});

  final UpdateService service;

  static Future<void> show(BuildContext context, UpdateService service) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => UpdateSheet(service: service),
      );

  @override
  State<UpdateSheet> createState() => _UpdateSheetState();
}

enum _Etape { recherche, aJour, disponible, telechargement, prete, refusee, erreur }

class _UpdateSheetState extends State<UpdateSheet> {
  _Etape _etape = _Etape.recherche;
  UpdateInfo? _info;
  String? _message;
  String? _fichierVerifie;
  double _progres = 0;

  @override
  void initState() {
    super.initState();
    _chercher();
  }

  Future<void> _chercher() async {
    setState(() => _etape = _Etape.recherche);
    final info = await widget.service.check();
    if (!mounted) return;
    setState(() {
      _info = info;
      _etape = info == null ? _Etape.aJour : _Etape.disponible;
    });
  }

  Future<void> _telecharger() async {
    setState(() {
      _etape = _Etape.telechargement;
      _progres = 0;
    });
    try {
      final chemin = await widget.service.downloadAndVerify(
        _info!,
        onProgress: (p) {
          if (mounted) setState(() => _progres = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _fichierVerifie = chemin;
        _etape = _Etape.prete;
      });
    } on UpdateRefused catch (e) {
      if (!mounted) return;
      setState(() {
        _message = e.message;
        _etape = _Etape.refusee;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = 'Téléchargement impossible : $e';
        _etape = _Etape.erreur;
      });
    }
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
              Text('Mise à jour', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text('Version installée : ${AppConfig.version}',
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 20),
              ..._corps(theme),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _corps(ThemeData theme) => switch (_etape) {
        _Etape.recherche => [
            const Row(children: [
              SizedBox(
                  height: 18, width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('Recherche d’une nouvelle version…'),
            ]),
          ],
        _Etape.aJour => [
            Row(children: [
              Icon(Icons.check_circle_outline, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              const Expanded(child: Text('Tu es à jour.')),
            ]),
            const SizedBox(height: 16),
            OutlinedButton(
                onPressed: _chercher, child: const Text('Vérifier à nouveau')),
          ],
        _Etape.disponible => [
            Text('Version ${_info!.version} disponible',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            if (_info!.notes.isNotEmpty)
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: Text(_info!.notes, style: theme.textTheme.bodySmall),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              'Le fichier sera vérifié par signature avant toute installation. '
              'Sans signature valide, la mise à jour est refusée.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton(
                onPressed: _telecharger, child: const Text('Télécharger')),
          ],
        _Etape.telechargement => [
            Text('Téléchargement… ${(_progres * 100).round()} %'),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _progres > 0 ? _progres : null),
          ],
        _Etape.prete => [
            Row(children: [
              Icon(Icons.verified, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              const Expanded(child: Text('Signature vérifiée.')),
            ]),
            const SizedBox(height: 12),
            Text(_instructions(), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            SelectableText(_fichierVerifie ?? '',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Fermer'),
            ),
          ],
        _Etape.refusee => [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Icon(Icons.gpp_bad, color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(_message ?? '',
                      style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                ),
              ]),
            ),
          ],
        _Etape.erreur => [
            Text(_message ?? '', style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _chercher, child: const Text('Réessayer')),
          ],
      };

  /// Ce qu'il reste à faire, qui dépend de la plateforme.
  ///
  /// L'installation silencieuse diffère radicalement d'un système à l'autre —
  /// Android exige le consentement de l'utilisateur, Windows une élévation de
  /// privilèges. Plutôt que de prétendre l'automatiser partout, on indique
  /// clairement l'étape restante avec le fichier DÉJÀ vérifié.
  String _instructions() {
    if (Platform.isAndroid) {
      return 'Ouvre le fichier pour lancer l’installation. Android demandera '
          'ta confirmation — c’est lui qui l’impose, pas l’application.';
    }
    if (Platform.isLinux) {
      return 'Extrais cette archive par-dessus ton installation, puis relance '
          'l’application.';
    }
    if (Platform.isWindows) {
      return 'Extrais cette archive par-dessus ton dossier ZiaCrypte, '
          'application fermée, puis relance-la.';
    }
    return 'Remplace l’application par le fichier téléchargé, puis relance-la.';
  }
}
