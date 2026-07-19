import 'package:flutter/material.dart';

import 'core/config/app_settings.dart';
import 'features/authentication/presentation/connect_screen.dart';
import 'features/chat/data/chat_service.dart';
import 'features/chat/presentation/chat_screen.dart';

void main() {
  runApp(const ZiaCrypteApp());
}

class ZiaCrypteApp extends StatefulWidget {
  const ZiaCrypteApp({super.key});

  @override
  State<ZiaCrypteApp> createState() => _ZiaCrypteAppState();
}

class _ZiaCrypteAppState extends State<ZiaCrypteApp> {
  final ChatService _service = ChatService();
  final AppSettings _settings = AppSettings.load();

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
          builder: (context, _) => _service.connected
              ? ChatScreen(service: _service, settings: _settings)
              : ConnectScreen(service: _service),
        ),
      ),
    );
  }
}
