import 'dart:convert';
import 'dart:io';

/// Emplacement de stockage local et mémorisation du compte de l'appareil.
///
/// Ne contient AUCUN secret : les clés privées restent dans le fichier chiffré
/// géré par le moteur natif (`identity.zia`, protégé par le coffre-fort du
/// système). Ici on ne garde que de quoi savoir à quel compte se reconnecter.
class AppStorage {
  const AppStorage._();

  /// Répertoire de données de l'application, conforme aux usages de chaque OS.
  static Directory get dataDirectory {
    String base;
    if (Platform.isWindows) {
      base = Platform.environment['APPDATA'] ??
          '${Platform.environment['USERPROFILE']}\\AppData\\Roaming';
      return Directory('$base\\ZiaCrypte');
    }
    final home = Platform.environment['HOME'] ?? '.';
    if (Platform.isMacOS) {
      return Directory('$home/Library/Application Support/ZiaCrypte');
    }
    base = Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
    return Directory('$base/ZiaCrypte');
  }

  /// Dossier confié au moteur natif (il y écrit son identité chiffrée).
  static String get engineStoragePath => dataDirectory.path;

  static File get _accountFile => File('${dataDirectory.path}/account.json');

  /// Compte associé à cet appareil, s'il y en a un.
  static SavedAccount? loadAccount() {
    try {
      final file = _accountFile;
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return SavedAccount(
        username: json['username'] as String,
        userId: json['userId'] as String,
        deviceId: json['deviceId'] as String,
      );
    } catch (_) {
      return null; // fichier absent ou illisible : on repart d'un compte neuf
    }
  }

  static void saveAccount(SavedAccount account) {
    final dir = dataDirectory;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _accountFile.writeAsStringSync(jsonEncode({
      'username': account.username,
      'userId': account.userId,
      'deviceId': account.deviceId,
    }));
  }

  /// Oublie le compte local (l'identité du moteur reste, elle, sur disque).
  static void clearAccount() {
    final file = _accountFile;
    if (file.existsSync()) file.deleteSync();
  }
}

class SavedAccount {
  const SavedAccount({
    required this.username,
    required this.userId,
    required this.deviceId,
  });

  final String username;
  final String userId;
  final String deviceId;
}
