import 'package:flutter/foundation.dart';

import '../config/app_settings.dart';
import 'update_service.dart';

/// Surveille discrètement la parution d'une nouvelle version.
///
/// ## Pourquoi une vérification automatique
///
/// Une mise à jour qu'il faut penser à aller chercher dans un menu n'est pas
/// installée. Or les corrections qui comptent le plus ici sont des corrections
/// de sécurité : la version que les gens exécutent réellement importe plus que
/// celle qui est publiée.
///
/// ## Ce qui est délibérément absent
///
/// Rien n'est téléchargé ni installé sans que l'utilisateur l'ait demandé. La
/// vérification ne lit qu'une page publique de GitHub — aucune donnée de compte
/// n'est envoyée, GitHub n'apprend qu'une adresse IP consultant un dépôt public.
/// Un échec est silencieux : un problème de réseau ne doit pas se transformer
/// en alerte anxiogène dans une messagerie.
class UpdateNotifier extends ChangeNotifier {
  UpdateNotifier(this._service, this._settings);

  final UpdateService _service;
  final AppSettings _settings;

  UpdateInfo? _disponible;

  /// Version plus récente trouvée, si l'utilisateur ne l'a pas déjà écartée.
  UpdateInfo? get disponible {
    final info = _disponible;
    if (info == null) return null;
    if (_settings.versionEcartee == info.version) return null;
    return info;
  }

  /// Interroge GitHub une fois. Sans effet si la signature n'est pas
  /// configurée : annoncer une mise à jour qu'on refusera ensuite d'installer
  /// n'aurait aucun sens.
  Future<void> verifier() async {
    if (!UpdateService.signingConfigured) return;
    final info = await _service.check();
    if (info == null) return;
    _disponible = info;
    notifyListeners();
  }

  /// « Pas maintenant » : la bannière ne réapparaîtra pas pour CETTE version.
  /// Une version ultérieure la fera revenir — écarter une mise à jour ne doit
  /// pas revenir à les désactiver toutes.
  void ecarter() {
    final info = _disponible;
    if (info == null) return;
    _settings.ecarterVersion(info.version);
    notifyListeners();
  }
}
