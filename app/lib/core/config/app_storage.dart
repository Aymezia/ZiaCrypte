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
  ///
  /// Le repli ne doit JAMAIS produire un chemin relatif : `HOME` absent donnait
  /// autrefois `./.local/share`, dont la création échoue si le répertoire
  /// courant est en lecture seule (montage, service sans HOME). En dernier
  /// recours on prend donc le dossier temporaire système, toujours absolu et
  /// inscriptible — les données n'y survivent pas forcément à un redémarrage,
  /// mais l'application démarre au lieu de planter.
  static Directory get dataDirectory {
    if (Platform.isWindows) {
      final base = _premierNonVide([
        Platform.environment['APPDATA'],
        () {
          final up = Platform.environment['USERPROFILE'];
          return (up != null && up.isNotEmpty) ? '$up\\AppData\\Roaming' : null;
        }(),
      ]);
      return Directory('${base ?? Directory.systemTemp.path}\\ZiaCrypte');
    }

    final home = Platform.environment['HOME'];
    final hasHome = home != null && home.isNotEmpty;

    if (Platform.isMacOS) {
      final base =
          hasHome ? '$home/Library/Application Support' : Directory.systemTemp.path;
      return Directory('$base/ZiaCrypte');
    }

    final base = _premierNonVide([
          Platform.environment['XDG_DATA_HOME'],
          hasHome ? '$home/.local/share' : null,
        ]) ??
        Directory.systemTemp.path;
    return Directory('$base/ZiaCrypte');
  }

  /// Première valeur non nulle et non vide d'une liste, ou null.
  static String? _premierNonVide(List<String?> valeurs) {
    for (final v in valeurs) {
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  /// Dossier confié au moteur natif pour un compte donné.
  ///
  /// **Un dossier par compte.** L'identité de l'appareil (la paire Ed25519) vit
  /// dans ce dossier ; la partager entre deux comptes leur ferait publier la
  /// MÊME clé publique, ce qui permettrait au serveur de prouver qu'ils
  /// appartiennent à la même personne — exactement ce qu'on cherche à éviter en
  /// permettant des comptes séparés. Le handshake X3DH entre ces deux comptes
  /// serait de surcroît dégénéré (un DH d'une clé avec elle-même).
  ///
  /// [storageKey] est un identifiant local tiré au hasard à la création du
  /// compte, sans lien avec le pseudo ni l'identifiant serveur : le nom du
  /// dossier ne doit rien révéler à qui inspecte le disque.
  static String engineStoragePathFor(String storageKey) =>
      '${dataDirectory.path}${Platform.pathSeparator}accounts'
      '${Platform.pathSeparator}$storageKey';

  /// Emplacement historique, à la racine du dossier de données.
  ///
  /// Les comptes créés avant l'introduction des dossiers par compte y ont leur
  /// identité. On continue de les servir depuis là plutôt que de déplacer des
  /// fichiers : perdre `identity.zia` rendrait le compte définitivement
  /// inutilisable, sa clé privée étant irremplaçable.
  static String get legacyEngineStoragePath => dataDirectory.path;

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
        // Absent des comptes antérieurs aux dossiers par compte : ils gardent
        // l'emplacement historique.
        storageKey: json['storageKey'] as String?,
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
      if (account.storageKey != null) 'storageKey': account.storageKey,
    }));
  }

  /// Oublie le compte local.
  ///
  /// L'identité du moteur reste sur disque, dans le dossier de ce compte : on
  /// ne la détruit pas, l'utilisateur pouvant vouloir y revenir. Un compte créé
  /// ensuite recevra son propre dossier, donc sa propre identité.
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
    this.storageKey,
  });

  final String username;
  final String userId;
  final String deviceId;

  /// Dossier moteur de ce compte. `null` pour les comptes antérieurs, qui
  /// utilisent l'emplacement historique.
  final String? storageKey;

  String get enginePath => storageKey == null
      ? AppStorage.legacyEngineStoragePath
      : AppStorage.engineStoragePathFor(storageKey!);
}
