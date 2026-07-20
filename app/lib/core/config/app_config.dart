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

  /// Version de cette compilation, au format x.y.z.
  ///
  /// Posée par les scripts d'empaquetage depuis pubspec.yaml. Le vérificateur
  /// de mise à jour la compare à la dernière version publiée ; sans elle il ne
  /// saurait pas s'il est à jour.
  static const String version = String.fromEnvironment(
    'ZIA_VERSION',
    defaultValue: '0.0.0-dev',
  );

  /// Dépôt consulté pour les mises à jour.
  static const String updateRepo = String.fromEnvironment(
    'ZIA_UPDATE_REPO',
    defaultValue: 'Aymezia/ZiaCrypte',
  );

  /// Racine de l'API consultée pour les mises à jour.
  ///
  /// Fixée à la compilation, donc hors de portée d'un attaquant : la changer
  /// suppose de reconstruire le binaire. Et même alors, elle ne donne aucun
  /// pouvoir — la sécurité de la mise à jour ne repose PAS sur l'hôte
  /// consulté, mais sur la signature Ed25519 vérifiée par le moteur natif.
  /// Un miroir hostile ne peut que servir des fichiers qui seront refusés.
  ///
  /// C'est ce qui permet d'éprouver la chaîne complète en local, et plus tard
  /// de servir les mises à jour ailleurs que sur GitHub.
  static const String updateApiBase = String.fromEnvironment(
    'ZIA_UPDATE_API',
    defaultValue: 'https://api.github.com',
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
