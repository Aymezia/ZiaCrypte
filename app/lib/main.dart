import 'package:flutter/material.dart';

import 'core/config/app_settings.dart';
import 'features/authentication/presentation/connect_screen.dart';
import 'features/authentication/presentation/onboarding_screen.dart';
import 'features/chat/data/chat_service.dart';
import 'features/chat/presentation/chat_screen.dart';

void main() {
  runApp(const ZiaCrypteApp());
}

class ZiaCrypteApp extends StatefulWidget {
  const ZiaCrypteApp({super.key, this.settingsOverride});

  /// Préférences injectées par les tests. En production, elles sont lues sur
  /// le disque : un test ne doit pas dépendre de ce qui s'y trouve.
  final AppSettings? settingsOverride;

  @override
  State<ZiaCrypteApp> createState() => _ZiaCrypteAppState();
}

class _ZiaCrypteAppState extends State<ZiaCrypteApp> {
  final ChatService _service = ChatService();
  late final AppSettings _settings =
      widget.settingsOverride ?? AppSettings.load();

  @override
  void dispose() {
    _service.dispose();
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2F6D5C); // vert profond, sobre
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) => MaterialApp(
        title: 'ZiaCrypte',
        debugShowCheckedModeBanner: false,
        themeMode: _settings.themeMode,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: seed),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: seed,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: ListenableBuilder(
          listenable: _service,
          builder: (context, _) {
            if (_service.connected) {
              return ChatScreen(service: _service, settings: _settings);
            }
            // L'accueil n'est montré qu'avant le tout premier compte : si un
            // compte existe déjà sur cet appareil, on va droit à la connexion.
            if (!_settings.onboardingVu && _service.savedAccount == null) {
              return OnboardingScreen(
                  onTermine: _settings.marquerOnboardingVu);
            }
            return ConnectScreen(service: _service);
          },
        ),
      ),
    );
  }
}
