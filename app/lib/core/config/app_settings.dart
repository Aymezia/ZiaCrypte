import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_storage.dart';

/// Préférences locales de l'application.
///
/// Ne contient rien de sensible : uniquement des choix d'affichage et de confort
/// propres à cet appareil. Les secrets restent dans le coffre chiffré du moteur.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._themeMode, this._enterToSend, this._onboardingVu,
      this._indicateurEcriture, this._accusesLecture, this._partagePresence,
      this._versionEcartee, this._delaiVerrouillage, this._protectionEcran);

  ThemeMode _themeMode;
  bool _enterToSend;
  bool _onboardingVu;
  bool _indicateurEcriture;
  bool _accusesLecture;
  bool _partagePresence;
  String? _versionEcartee;
  int _delaiVerrouillage;
  bool _protectionEcran;

  ThemeMode get themeMode => _themeMode;
  bool get enterToSend => _enterToSend;

  /// Les écrans d'accueil ont-ils déjà été montrés ? On ne les impose qu'une
  /// fois : les revoir à chaque lancement serait une punition, pas une aide.
  bool get onboardingVu => _onboardingVu;

  /// Signaler à son correspondant qu'on est en train d'écrire.
  bool get indicateurEcriture => _indicateurEcriture;

  /// Confirmer à son correspondant qu'on a lu ses messages.
  ///
  /// DÉSACTIVÉ par défaut. Un accusé de lecture révèle quand on ouvre un
  /// message — une information que personne ne doit donner sans l'avoir choisi.
  bool get accusesLecture => _accusesLecture;

  /// Apparaître « en ligne » auprès de ses correspondants.
  ///
  /// DÉSACTIVÉ par défaut, pour la même raison que les accusés de lecture :
  /// l'heure à laquelle on ouvre l'application dit quand on dort et quand on
  /// travaille. On peut voir les autres sans se montrer — la réciprocité
  /// imposée ailleurs est une convention, pas une protection.
  bool get partagePresence => _partagePresence;

  /// Secondes d'absence avant que l'application se reverrouille.
  ///
  /// Un verrouillage immédiat à chaque bascule d'application rendrait
  /// l'utilisation pénible au point qu'on le désactive — et un verrou
  /// désactivé ne protège de rien.
  int get delaiVerrouillage => _delaiVerrouillage;

  /// Bloquer les captures d'écran et l'aperçu dans les tâches récentes.
  ///
  /// Actif par défaut : l'aperçu que le système garde après une bascule
  /// survit à la fermeture et entre dans les sauvegardes. N'empêche pas de
  /// photographier l'écran avec un autre appareil.
  bool get protectionEcran => _protectionEcran;

  /// Version de mise à jour écartée par l'utilisateur, s'il y en a une.
  ///
  /// On la retient pour ne pas répéter la même bannière à chaque lancement,
  /// mais une version PLUS récente la fera réapparaître : écarter une mise à
  /// jour ne doit pas revenir à les désactiver toutes en silence.
  String? get versionEcartee => _versionEcartee;

  /// Préférences en mémoire, pour les tests.
  ///
  /// Permet de choisir l'état de départ — notamment si les écrans d'accueil ont
  /// déjà été vus — au lieu de dépendre de ce qui traîne sur le disque de la
  /// machine qui exécute les tests.
  @visibleForTesting
  factory AppSettings.pourTests({
    ThemeMode themeMode = ThemeMode.system,
    bool enterToSend = true,
    bool onboardingVu = true,
    bool indicateurEcriture = true,
    bool accusesLecture = false,
    bool partagePresence = false,
    String? versionEcartee,
    int delaiVerrouillage = 60,
    bool protectionEcran = true,
  }) =>
      AppSettings._(themeMode, enterToSend, onboardingVu, indicateurEcriture,
          accusesLecture, partagePresence, versionEcartee, delaiVerrouillage,
          protectionEcran);

  static File get _file => File('${AppStorage.dataDirectory.path}/settings.json');

  /// Charge les préférences, ou les valeurs par défaut si le fichier est absent
  /// ou illisible — jamais d'échec bloquant pour un simple réglage d'affichage.
  static AppSettings load() {
    try {
      final f = _file;
      if (f.existsSync()) {
        final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        return AppSettings._(
          _themeFromString(json['theme'] as String?),
          json['enterToSend'] as bool? ?? true,
          json['onboardingVu'] as bool? ?? false,
          json['indicateurEcriture'] as bool? ?? true,
          json['accusesLecture'] as bool? ?? false,
          json['partagePresence'] as bool? ?? false,
          json['versionEcartee'] as String?,
          (json['delaiVerrouillage'] as num?)?.toInt() ?? 60,
          json['protectionEcran'] as bool? ?? true,
        );
      }
    } catch (_) {
      // on retombe sur les valeurs par défaut
    }
    return AppSettings._(
        ThemeMode.system, true, false, true, false, false, null, 60, true);
  }

  void setThemeMode(ThemeMode mode) {
    if (mode == _themeMode) return;
    _themeMode = mode;
    _save();
    notifyListeners();
  }

  void setEnterToSend(bool value) {
    if (value == _enterToSend) return;
    _enterToSend = value;
    _save();
    notifyListeners();
  }

  void setIndicateurEcriture(bool v) {
    if (v == _indicateurEcriture) return;
    _indicateurEcriture = v;
    _save();
    notifyListeners();
  }

  void setAccusesLecture(bool v) {
    if (v == _accusesLecture) return;
    _accusesLecture = v;
    _save();
    notifyListeners();
  }

  void setPartagePresence(bool v) {
    if (v == _partagePresence) return;
    _partagePresence = v;
    _save();
    notifyListeners();
  }

  void ecarterVersion(String version) {
    if (version == _versionEcartee) return;
    _versionEcartee = version;
    _save();
    notifyListeners();
  }

  void setDelaiVerrouillage(int secondes) {
    if (secondes == _delaiVerrouillage) return;
    _delaiVerrouillage = secondes;
    _save();
    notifyListeners();
  }

  void setProtectionEcran(bool v) {
    if (v == _protectionEcran) return;
    _protectionEcran = v;
    _save();
    notifyListeners();
  }

  void marquerOnboardingVu() {
    if (_onboardingVu) return;
    _onboardingVu = true;
    _save();
    notifyListeners();
  }

  void _save() {
    try {
      final dir = AppStorage.dataDirectory;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode({
        'theme': _themeMode.name,
        'enterToSend': _enterToSend,
        'onboardingVu': _onboardingVu,
        'indicateurEcriture': _indicateurEcriture,
        'accusesLecture': _accusesLecture,
        'partagePresence': _partagePresence,
        'versionEcartee': _versionEcartee,
        'delaiVerrouillage': _delaiVerrouillage,
        'protectionEcran': _protectionEcran,
      }));
    } catch (_) {
      // écriture best-effort : une préférence non persistée n'est pas critique
    }
  }

  static ThemeMode _themeFromString(String? s) => switch (s) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
}
