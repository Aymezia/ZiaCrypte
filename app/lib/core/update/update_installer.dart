import 'dart:io';

import 'package:flutter/services.dart';

/// Application d'une mise à jour DÉJÀ vérifiée.
///
/// ## Ce fichier ne vérifie rien
///
/// Il n'est appelé qu'avec un chemin sorti de [UpdateService.downloadAndVerify],
/// donc après contrôle de la signature Ed25519 par le moteur natif. C'est
/// délibérément séparé : mélanger « vérifier » et « installer » dans une même
/// fonction rend facile d'ajouter plus tard un chemin d'installation qui oublie
/// la vérification. Ici, la seule entrée est un fichier authentifié.
///
/// ## Pourquoi un script relais sur le bureau
///
/// Un programme ne peut pas se remplacer lui-même pendant qu'il tourne :
/// Windows verrouille l'exécutable, et sous Linux écraser un `.so` chargé fait
/// planter le processus. On extrait donc l'archive à côté, on écrit un petit
/// script qui attend la fin du processus, recopie, puis relance — et on quitte.
/// Rien n'est téléchargé ni décidé par ce script : il déplace des fichiers déjà
/// vérifiés.
class UpdateInstaller {
  const UpdateInstaller._();

  static const MethodChannel _canal = MethodChannel('ziacrypte/update');

  /// Peut-on appliquer la mise à jour sans intervention manuelle ?
  ///
  /// Faux si l'application est installée dans un dossier où l'utilisateur n'a
  /// pas le droit d'écrire (`/opt`, `Program Files`) : la recopie échouerait à
  /// mi-parcours, ce qui est bien pire qu'un refus net. On propose alors les
  /// instructions manuelles.
  static bool get peutInstaller {
    if (Platform.isAndroid) return true;
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return _dossierInscriptible(_racineInstallation);
    }
    return false;
  }

  /// Applique [archiveVerifiee] et redémarre l'application.
  ///
  /// Sur le bureau, cette fonction **ne rend pas la main** : le processus se
  /// termine pour libérer ses fichiers. Sur Android, elle ouvre l'installateur
  /// du système et revient — c'est Android qui demande la confirmation, et
  /// aucune application ne peut s'en passer.
  static Future<void> appliquer(String archiveVerifiee) async {
    if (Platform.isAndroid) {
      await _canal.invokeMethod<void>('installerApk', {'chemin': archiveVerifiee});
      return;
    }

    final staging = await Directory.systemTemp.createTemp('zia_staging');
    await _extraire(archiveVerifiee, staging.path);

    // Le dossier qui contient l'archive téléchargée : il pèse une vingtaine de
    // mégaoctets et n'a plus aucune raison d'exister une fois la copie faite.
    final telechargement = File(archiveVerifiee).parent.path;

    final script = await _ecrireScriptRelais(staging.path, telechargement);
    // Détaché : le script doit survivre à la mort de son parent, qu'il attend.
    await Process.start(
      Platform.isWindows ? 'cmd.exe' : '/bin/sh',
      Platform.isWindows ? ['/c', script] : [script],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }

  /// Racine à remplacer.
  ///
  /// Sur macOS, l'unité d'installation est le bundle `.app` entier, pas le
  /// dossier de l'exécutable qui se trouve trois niveaux plus bas.
  static String get _racineInstallation {
    final exe = File(Platform.resolvedExecutable).absolute.path;
    final dossierExe = File(exe).parent.path;
    if (Platform.isMacOS) {
      // .../ZiaCrypte.app/Contents/MacOS/ziacrypte
      return Directory(dossierExe).parent.parent.path;
    }
    return dossierExe;
  }

  static bool _dossierInscriptible(String chemin) {
    try {
      final sonde = File('$chemin${Platform.pathSeparator}.zia_write_test');
      sonde.writeAsStringSync('');
      sonde.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Décompresse l'archive dans [destination], avec les outils du système.
  ///
  /// `tar` est présent partout sous Linux et macOS ; `Expand-Archive` fait
  /// partie de PowerShell depuis Windows 10. Décompresser en Dart aurait exigé
  /// une dépendance de plus pour un gain nul.
  static Future<void> _extraire(String archive, String destination) async {
    late ProcessResult r;
    if (Platform.isWindows) {
      r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "Expand-Archive -LiteralPath '$archive' -DestinationPath '$destination' -Force",
      ]);
    } else if (Platform.isLinux) {
      // L'archive Linux contient un dossier `linux-x64/` : on l'aplatit pour
      // que le contenu du staging corresponde exactement à l'installation.
      r = await Process.run(
          'tar', ['xzf', archive, '-C', destination, '--strip-components=1']);
    } else {
      // macOS : l'archive contient le bundle `.app`, qu'on garde entier.
      r = await Process.run('unzip', ['-q', '-o', archive, '-d', destination]);
    }
    if (r.exitCode != 0) {
      throw UpdateInstallFailed(
          'Décompression impossible : ${r.stderr.toString().trim()}');
    }
  }

  /// Écrit le script relais dans un dossier temporaire PRIVÉ.
  ///
  /// ## Pourquoi pas un nom fixe dans /tmp
  ///
  /// Ce script est exécuté. Un chemin prévisible dans un dossier partagé
  /// (`/tmp/zia_update.sh`) permettrait à un autre utilisateur de la machine d'y
  /// déposer un lien symbolique avant nous, ou de remplacer le contenu entre
  /// l'écriture et le lancement. Il obtiendrait l'exécution de code — et toute
  /// la vérification de signature faite juste avant n'aurait servi à rien : on
  /// authentifie 20 Mo avec soin, pour finir par exécuter un fichier que
  /// n'importe qui pouvait préparer.
  ///
  /// `createTemp` s'appuie sur `mkdtemp`, qui crée un dossier au nom
  /// imprévisible et accessible au seul propriétaire.
  static Future<String> _ecrireScriptRelais(
      String staging, String telechargement) async {
    final install = _racineInstallation;
    final exe = Platform.resolvedExecutable;
    final relais = await Directory.systemTemp.createTemp('zia_relay');
    final dossier = relais.path;
    final sep = Platform.pathSeparator;

    if (Platform.isWindows) {
      final chemin = '$dossier${sep}zia_update.bat';
      // `tasklist` sert de test de vie : tant que le PID répond, les fichiers
      // sont verrouillés. La boucle est bornée pour ne jamais tourner sans fin.
      await File(chemin).writeAsString('''
@echo off
setlocal
set /a n=0
:attente
tasklist /FI "PID eq $pid" 2>nul | find "$pid" >nul || goto copie
set /a n+=1
if %n% GEQ 60 goto copie
ping -n 2 127.0.0.1 >nul
goto attente
:copie
xcopy /E /Y /Q "$staging\\*" "$install\\" >nul
rmdir /S /Q "$staging"
rmdir /S /Q "$telechargement"
start "" "$exe"
''');
      return chemin;
    }

    final chemin = '$dossier${sep}zia_update.sh';
    final relance = Platform.isMacOS ? 'open "$install"' : 'exec "$exe"';
    // macOS : on remplace le bundle entier, sinon des fichiers de l'ancienne
    // version survivraient à côté des nouveaux.
    final copie = Platform.isMacOS
        ? 'rm -rf "$install" && cp -a "$staging"/*.app "$install"'
        : 'cp -a "$staging/." "$install/"';

    await File(chemin).writeAsString('''
#!/bin/sh
# Attend la fermeture de ZiaCrypte : on ne remplace pas les fichiers d'un
# processus vivant. Borné à ~20 s pour ne jamais rester bloqué.
n=0
while kill -0 $pid 2>/dev/null && [ \$n -lt 200 ]; do
  sleep 0.1
  n=\$((n+1))
done
$copie || exit 1
# Ménage : l'archive téléchargée pèse une vingtaine de mégaoctets, et ce script
# n'a plus lieu d'être. Le shell garde son descripteur ouvert, effacer son
# propre dossier ne l'interrompt donc pas.
rm -rf "$staging" "$telechargement" "$dossier"
$relance
''');
    await Process.run('chmod', ['+x', chemin]);
    return chemin;
  }
}

/// L'installation a échoué APRÈS vérification : le fichier était authentique,
/// c'est la mise en place qui n'a pas abouti.
class UpdateInstallFailed implements Exception {
  const UpdateInstallFailed(this.message);
  final String message;
  @override
  String toString() => message;
}
