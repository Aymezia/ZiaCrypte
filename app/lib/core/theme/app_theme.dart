import 'package:flutter/material.dart';

/// Le thème « Nuit néon » de ZiaCrypte.
///
/// Toute l'apparence de l'application tient dans ce fichier. Les écrans ne
/// codent aucune couleur en dur : ils lisent `Theme.of(context).colorScheme`,
/// si bien qu'ajuster une teinte ici se répercute partout d'un coup — c'est la
/// raison d'être d'un thème centralisé plutôt que de couleurs éparpillées.
///
/// Parti pris : sombre d'abord, fond presque noir bleuté, un accent cyan
/// lumineux doublé d'un bleu-violet. Le mode clair existe aussi, calé sur le
/// même accent en version soutenue pour rester lisible sur fond blanc.
class ZiaTheme {
  ZiaTheme._();

  // Accents partagés par les deux modes — l'identité de la marque.
  static const Color _cyan = Color(0xFF34E5D0); // accent principal
  static const Color _bleuViolet = Color(0xFF6E8BFF); // accent secondaire

  // ---------------------------------------------------------------- sombre

  static const ColorScheme _sombre = ColorScheme(
    brightness: Brightness.dark,
    primary: _cyan,
    onPrimary: Color(0xFF00201B),
    primaryContainer: Color(0xFF10403A),
    onPrimaryContainer: Color(0xFF9FFDEE),
    secondary: _bleuViolet,
    onSecondary: Color(0xFF001452),
    secondaryContainer: Color(0xFF232E4E),
    onSecondaryContainer: Color(0xFFC9D5FF),
    tertiary: Color(0xFFC9A6FF),
    onTertiary: Color(0xFF2A114E),
    tertiaryContainer: Color(0xFF2A2140),
    onTertiaryContainer: Color(0xFFE7DBFF),
    error: Color(0xFFFF6B7A),
    onError: Color(0xFF3A0009),
    errorContainer: Color(0xFF4A1620),
    onErrorContainer: Color(0xFFFFD9DD),
    // Fond : un dégradé de gris-bleu très sombres, du plus profond au plus clair.
    surface: Color(0xFF0B0F16),
    onSurface: Color(0xFFE4EAF2),
    surfaceDim: Color(0xFF0B0F16),
    surfaceBright: Color(0xFF222C3C),
    surfaceContainerLowest: Color(0xFF070A0F),
    surfaceContainerLow: Color(0xFF0F141C),
    surfaceContainer: Color(0xFF141A24),
    surfaceContainerHigh: Color(0xFF1B2331),
    surfaceContainerHighest: Color(0xFF222C3C),
    onSurfaceVariant: Color(0xFF9BA6B7),
    outline: Color(0xFF34404F),
    outlineVariant: Color(0xFF222C39),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFFE4EAF2),
    onInverseSurface: Color(0xFF0B0F16),
    inversePrimary: Color(0xFF006B5E),
    surfaceTint: _cyan,
  );

  // ----------------------------------------------------------------- clair

  static const ColorScheme _clair = ColorScheme(
    brightness: Brightness.light,
    // Accent soutenu : le cyan lumineux du mode sombre disparaîtrait sur blanc.
    primary: Color(0xFF0C8477),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFA6F2E5),
    onPrimaryContainer: Color(0xFF00201B),
    secondary: Color(0xFF445BD0),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFDDE1FF),
    onSecondaryContainer: Color(0xFF001352),
    tertiary: Color(0xFF6B4EA8),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFEBDDFF),
    onTertiaryContainer: Color(0xFF25005A),
    error: Color(0xFFB3261E),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFF9DEDC),
    onErrorContainer: Color(0xFF410E0B),
    surface: Color(0xFFF6F8FB),
    onSurface: Color(0xFF0C1219),
    surfaceDim: Color(0xFFDDE1E8),
    surfaceBright: Color(0xFFFCFDFF),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF1F4F8),
    surfaceContainer: Color(0xFFEBEFF4),
    surfaceContainerHigh: Color(0xFFE5EAF1),
    surfaceContainerHighest: Color(0xFFDFE5EE),
    onSurfaceVariant: Color(0xFF48525F),
    outline: Color(0xFF788290),
    outlineVariant: Color(0xFFC7CED8),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFF141A24),
    onInverseSurface: Color(0xFFEEF1F6),
    inversePrimary: _cyan,
    surfaceTint: Color(0xFF0C8477),
  );

  static ThemeData dark() => _build(_sombre);
  static ThemeData light() => _build(_clair);

  /// Dégradé de l'accent — bulles envoyées, boutons héros, icônes de titre.
  /// Le cyan glisse vers le bleu-violet : c'est ce qui donne la profondeur
  /// « néon » qu'un aplat n'a pas.
  static LinearGradient accentGradient(ColorScheme c) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: c.brightness == Brightness.dark
            ? const [_cyan, _bleuViolet]
            : const [Color(0xFF0C8477), Color(0xFF3F55C9)],
      );

  /// Halo diffus d'une couleur — la lueur discrète sous les éléments d'accent.
  /// Volontairement léger : un néon trop appuyé fatigue et fait « gadget ».
  static List<BoxShadow> glow(Color color, {double opacity = 0.35, double blur = 18}) => [
        BoxShadow(
          color: color.withValues(alpha: opacity),
          blurRadius: blur,
          spreadRadius: -4,
        ),
      ];

  /// Fond général : un dégradé radial très sombre qui décolle légèrement le
  /// contenu du bord de l'écran. Posé sous les écrans d'entrée, où il se
  /// remarque, et disponible partout ailleurs.
  static BoxDecoration backgroundDecoration(ColorScheme c) {
    if (c.brightness == Brightness.light) {
      return BoxDecoration(color: c.surface);
    }
    return BoxDecoration(
      gradient: RadialGradient(
        center: const Alignment(-0.2, -0.8),
        radius: 1.4,
        colors: [
          const Color(0xFF141C28),
          c.surface,
        ],
      ),
    );
  }

  static ThemeData _build(ColorScheme c) {
    final base = ThemeData(colorScheme: c, useMaterial3: true);
    final dark = c.brightness == Brightness.dark;

    // Typographie resserrée : un léger crénage négatif sur les titres donne le
    // côté net et « produit fini » ; le corps de texte reste au repos.
    final texte = base.textTheme.copyWith(
      headlineMedium: base.textTheme.headlineMedium
          ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineSmall: base.textTheme.headlineSmall
          ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
      titleLarge: base.textTheme.titleLarge
          ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      titleMedium: base.textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.w600),
    );

    return base.copyWith(
      textTheme: texte,
      scaffoldBackgroundColor: c.surface,
      dividerColor: c.outlineVariant,

      appBarTheme: AppBarTheme(
        backgroundColor: dark ? c.surface : c.surfaceContainerLowest,
        foregroundColor: c.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: texte.titleMedium?.copyWith(color: c.onSurface),
        iconTheme: IconThemeData(color: c.onSurfaceVariant),
      ),

      // Champs de saisie remplis et arrondis, cerclés d'accent au focus : c'est
      // le geste le plus fréquent, autant qu'il soit soigné.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceContainerHigh,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.error, width: 1.6),
        ),
        prefixIconColor: c.onSurfaceVariant,
        labelStyle: TextStyle(color: c.onSurfaceVariant),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(
              fontWeight: FontWeight.w600, letterSpacing: 0.2),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),

      cardTheme: CardThemeData(
        color: c.surfaceContainer,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),

      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        selectedColor: c.onSurface,
        selectedTileColor: c.surfaceContainerHigh,
        iconColor: c.onSurfaceVariant,
      ),

      dividerTheme: DividerThemeData(
        color: c.outlineVariant,
        thickness: 1,
        space: 1,
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: c.surfaceContainerHigh,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: c.surfaceContainerHigh,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surfaceContainer,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.surfaceContainerHighest,
        contentTextStyle: TextStyle(color: c.onSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),

      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.onPrimary : c.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? c.primary
              : c.surfaceContainerHighest,
        ),
      ),
    );
  }
}
