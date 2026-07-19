import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_storage.dart';

/// Préférences locales de l'application.
///
/// Ne contient rien de sensible : uniquement des choix d'affichage et de confort
/// propres à cet appareil. Les secrets restent dans le coffre chiffré du moteur.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._themeMode, this._enterToSend);

  ThemeMode _themeMode;
  bool _enterToSend;

  ThemeMode get themeMode => _themeMode;
  bool get enterToSend => _enterToSend;

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
        );
      }
    } catch (_) {
      // on retombe sur les valeurs par défaut
    }
    return AppSettings._(ThemeMode.system, true);
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

  void _save() {
    try {
      final dir = AppStorage.dataDirectory;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode({
        'theme': _themeMode.name,
        'enterToSend': _enterToSend,
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
