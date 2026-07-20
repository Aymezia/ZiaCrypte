import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_storage.dart';

/// Préférences locales de l'application.
///
/// Ne contient rien de sensible : uniquement des choix d'affichage et de confort
/// propres à cet appareil. Les secrets restent dans le coffre chiffré du moteur.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._themeMode, this._enterToSend, this._onboardingVu);

  ThemeMode _themeMode;
  bool _enterToSend;
  bool _onboardingVu;

  ThemeMode get themeMode => _themeMode;
  bool get enterToSend => _enterToSend;

  /// Les écrans d'accueil ont-ils déjà été montrés ? On ne les impose qu'une
  /// fois : les revoir à chaque lancement serait une punition, pas une aide.
  bool get onboardingVu => _onboardingVu;

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
  }) =>
      AppSettings._(themeMode, enterToSend, onboardingVu);

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
        );
      }
    } catch (_) {
      // on retombe sur les valeurs par défaut
    }
    return AppSettings._(ThemeMode.system, true, false);
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
