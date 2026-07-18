/// Configuration fixée à la compilation.
///
/// L'adresse du serveur est intégrée au binaire pour que l'utilisateur n'ait
/// rien à saisir :
///
///   flutter build windows --release \
///     --dart-define=ZIA_SERVER_URL=https://messagerie.exemple.fr
///
/// ⚠️ Intégrer l'adresse ne la rend PAS secrète : elle reste lisible dans le
/// binaire (un simple `strings` la révèle) et visible dans le trafic réseau.
/// C'est un confort d'usage, pas une mesure de sécurité.
class AppConfig {
  const AppConfig._();

  /// Serveur contacté par défaut.
  static const String serverUrl = String.fromEnvironment(
    'ZIA_SERVER_URL',
    defaultValue: 'http://127.0.0.1:3210',
  );

  /// Affiche le champ « adresse du serveur » (pratique en développement).
  ///   --dart-define=ZIA_ALLOW_SERVER_OVERRIDE=true
  static const bool allowServerOverride = bool.fromEnvironment(
    'ZIA_ALLOW_SERVER_OVERRIDE',
    defaultValue: false,
  );

  /// Vrai si la liaison n'est pas chiffrée (HTTP en clair vers un hôte distant).
  /// Les messages restent chiffrés de bout en bout, mais le mot de passe et les
  /// jetons de session circuleraient en clair : on prévient l'utilisateur.
  static bool get isInsecureTransport {
    final uri = Uri.tryParse(serverUrl);
    if (uri == null) return false;
    if (uri.scheme == 'https') return false;
    return !(uri.host == '127.0.0.1' || uri.host == 'localhost');
  }
}
