import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/config/app_settings.dart';
import 'core/theme/app_theme.dart';
import 'features/authentication/presentation/connect_screen.dart';
import 'features/authentication/presentation/onboarding_screen.dart';
import 'features/chat/data/chat_service.dart';
import 'features/chat/presentation/chat_screen.dart';
import 'features/settings/presentation/lock_screen.dart';

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

class _ZiaCrypteAppState extends State<ZiaCrypteApp> with WidgetsBindingObserver {
  final ChatService _service = ChatService();
  late final AppSettings _settings =
      widget.settingsOverride ?? AppSettings.load();

  /// Verrouillé tant que le code n'a pas été saisi.
  bool _verrouille = false;

  /// Reprise de session en cours au lancement (« rester connecté ») : on
  /// affiche un écran d'attente le temps de la tentative, sans faire clignoter
  /// l'écran de connexion.
  bool _repriseEnCours = false;

  /// Instant où l'application est passée en arrière-plan.
  DateTime? _partiAu;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _partiAu = DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;

    final parti = _partiAu;
    _partiAu = null;
    if (parti == null || _verrouille) return;

    final absence = DateTime.now().difference(parti).inSeconds;
    if (absence < _settings.delaiVerrouillage) return;

    // On ne verrouille que si un code existe : sinon l'écran de
    // déverrouillage serait un mur sans porte.
    _service.verrouillageActif().then((actif) {
      if (actif && mounted) setState(() => _verrouille = true);
    });
  }

  /// Applique le blocage des captures d'écran (Android uniquement).
  ///
  /// Les bureaux n'ont pas d'équivalent : sous X11 comme sous Windows,
  /// n'importe quel programme peut lire l'écran. Le prétendre protégé là-bas
  /// serait mentir.
  void _appliquerProtectionEcran() {
    if (!Platform.isAndroid) return;
    const MethodChannel('ziacrypte/update')
        .invokeMethod<void>('protegerEcran', {'actif': _settings.protectionEcran})
        .catchError((_) {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appliquerProtectionEcran();
    _settings.addListener(_appliquerProtectionEcran);
    // Les préférences pilotent le service : sans ce report, les interrupteurs
    // n'auraient d'effet qu'après un changement manuel.
    _service.indicateurEcritureActif = _settings.indicateurEcriture;
    _service.accusesLectureActifs = _settings.accusesLecture;
    _service.partagePresenceActif = _settings.partagePresence;
    _tenterReprise();
  }

  /// « Rester connecté » : au lancement, reprend la session sans mot de passe.
  /// En cas de succès, si un code de verrouillage existe, on l'exige d'emblée
  /// (« code à l'ouverture »).
  void _tenterReprise() {
    if (!_settings.resterConnecte ||
        _service.savedAccount == null ||
        _service.connected) {
      return;
    }
    _repriseEnCours = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ok = await _service.reprendreSession();
      final verrou = ok && await _service.verrouillageActif();
      if (!mounted) return;
      setState(() {
        _verrouille = verrou;
        _repriseEnCours = false;
      });
    });
  }

  @override
  void dispose() {
    _settings.removeListener(_appliquerProtectionEcran);
    WidgetsBinding.instance.removeObserver(this);
    _service.dispose();
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) => MaterialApp(
        title: 'ZiaCrypte',
        debugShowCheckedModeBanner: false,
        themeMode: _settings.themeMode,
        theme: ZiaTheme.light(),
        darkTheme: ZiaTheme.dark(),
        home: ListenableBuilder(
          listenable: _service,
          builder: (context, _) {
            // Reprise « rester connecté » en cours : écran d'attente, pour ne
            // pas laisser clignoter l'écran de connexion avant de rentrer.
            if (_repriseEnCours) return const _EcranReprise();
            if (_service.connected) {
              if (_verrouille) {
                return LockScreen(
                  service: _service,
                  onOuvert: () => setState(() => _verrouille = false),
                );
              }
              return ChatScreen(service: _service, settings: _settings);
            }
            // L'accueil n'est montré qu'avant le tout premier compte : si un
            // compte existe déjà sur cet appareil, on va droit à la connexion.
            if (!_settings.onboardingVu && _service.savedAccount == null) {
              return OnboardingScreen(
                  onTermine: _settings.marquerOnboardingVu);
            }
            return ConnectScreen(service: _service, settings: _settings);
          },
        ),
      ),
    );
  }
}

/// Écran d'attente pendant la reprise automatique de session au lancement.
class _EcranReprise extends StatelessWidget {
  const _EcranReprise();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: DecoratedBox(
        decoration: ZiaTheme.backgroundDecoration(theme.colorScheme),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: ZiaTheme.accentGradient(theme.colorScheme),
                  boxShadow: ZiaTheme.glow(theme.colorScheme.primary,
                      opacity: 0.4, blur: 24),
                ),
                child: Icon(Icons.lock_rounded,
                    size: 40, color: theme.colorScheme.onPrimary),
              ),
              const SizedBox(height: 28),
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
