import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/update/update_installer.dart';
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

enum _Etape {
  recherche,
  aJour,
  disponible,
  telechargement,
  prete,
  installation,
  refusee,
  erreur
}

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

  /// Applique le fichier vérifié.
  ///
  /// Sur le bureau, l'appel ne revient pas : le processus se termine pour
  /// libérer ses fichiers, et un script relais relance la nouvelle version.
  Future<void> _installer() async {
    setState(() => _etape = _Etape.installation);
    try {
      await UpdateInstaller.appliquer(_fichierVerifie!);
      // Android uniquement : l'installateur du système a pris la main.
      if (mounted) setState(() => _etape = _Etape.prete);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = 'Installation impossible : $e\n'
            'Le fichier vérifié reste disponible ici :\n$_fichierVerifie';
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
            if (!UpdateInstaller.peutInstaller) ...[
              const SizedBox(height: 8),
              SelectableText(_fichierVerifie ?? '',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ],
            const SizedBox(height: 16),
            Row(children: [
              if (UpdateInstaller.peutInstaller)
                FilledButton.icon(
                  onPressed: _installer,
                  icon: const Icon(Icons.download_done),
                  label: Text(Platform.isAndroid
                      ? 'Installer'
                      : 'Installer et redémarrer'),
                ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Plus tard'),
              ),
            ]),
          ],
        _Etape.installation => [
            const Row(children: [
              SizedBox(
                  height: 18, width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Expanded(child: Text('Installation en cours…')),
            ]),
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

  /// Ce qui va se passer maintenant, qui dépend de la plateforme.
  ///
  /// On ne promet une installation automatique que là où elle est réellement
  /// possible. Si le dossier d'installation n'est pas inscriptible, la recopie
  /// échouerait à mi-parcours — bien pire qu'un refus net : on rend alors la
  /// main avec le fichier déjà vérifié.
  String _instructions() {
    if (Platform.isAndroid) {
      return 'L’installateur d’Android va s’ouvrir et demander ta '
          'confirmation — c’est le système qui l’impose, aucune application '
          'ne peut s’en passer.';
    }
    if (!UpdateInstaller.peutInstaller) {
      return 'ZiaCrypte est installé dans un dossier où il n’a pas le droit '
          'd’écrire : l’installation automatique est impossible. Extrais cette '
          'archive par-dessus ton installation, application fermée.';
    }
    return 'ZiaCrypte va se fermer, se remplacer par cette version, puis se '
        'relancer. Tes clés et tes messages ne sont pas touchés — ils sont '
        'ailleurs, dans ton dossier de données.';
  }
}
