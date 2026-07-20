import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../ffi/crypto_isolate.dart';

/// Vérification et application des mises à jour.
///
/// ## La règle qui gouverne tout ce fichier
///
/// Une mise à jour automatique télécharge du code et le fait exécuter. Sans
/// vérification d'authenticité, quiconque prend le contrôle de l'hébergement —
/// ou s'intercale sur le réseau — obtient l'exécution de code chez TOUS les
/// utilisateurs. Ce serait une porte d'entrée bien plus large que tout ce que
/// le chiffrement des messages protège.
///
/// TLS ne suffit pas : il protège le transport, pas l'origine, et oblige à
/// faire confiance à l'hébergeur et à toute autorité de certification. Chaque
/// artefact est donc signé (Ed25519) par une clé dont la partie privée reste
/// hors de tout serveur, et la partie publique est intégrée à l'application.
///
/// **Aucun fichier n'est appliqué sans signature valide.** En l'absence de
/// signature publiée, la mise à jour est refusée — pas installée « quand
/// même ».
class UpdateService {
  UpdateService(this._engine);

  final ZiaCryptoEngine _engine;
  final Dio _dio = Dio();

  /// Clé publique de signature des releases, en base64.
  ///
  /// Vide tant qu'aucune clé n'est intégrée : la vérification échoue alors
  /// systématiquement, et la mise à jour automatique reste inactive. C'est
  /// volontaire — mieux vaut pas de mise à jour qu'une mise à jour non
  /// authentifiée.
  static const String publicKeyBase64 = String.fromEnvironment(
    'ZIA_UPDATE_PUBKEY',
    defaultValue: '',
  );

  static bool get signingConfigured => publicKeyBase64.isNotEmpty;

  /// Compare deux versions « x.y.z ». Renvoie true si [candidate] est plus
  /// récente que [current].
  @visibleForTesting
  static bool isNewer(String candidate, String current) {
    List<int> parse(String v) => v
        .replaceAll(RegExp(r'^v'), '')
        .split(RegExp(r'[.\-+]'))
        .map((p) => int.tryParse(p) ?? 0)
        .toList();
    final a = parse(candidate);
    final b = parse(current);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  /// Nom de l'artefact correspondant à cette plateforme.
  static String? get _assetName {
    if (Platform.isLinux) return 'ziacrypte-linux-x64.tar.gz';
    if (Platform.isWindows) return 'ziacrypte-windows-x64-app.zip';
    if (Platform.isMacOS) return 'ziacrypte-macos-x64-app.zip';
    if (Platform.isAndroid) return 'ziacrypte-android.apk';
    return null;
  }

  /// Interroge la dernière release publiée.
  Future<UpdateInfo?> check() async {
    final asset = _assetName;
    if (asset == null) return null;
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/${AppConfig.updateRepo}/releases/latest',
        options: Options(
          headers: {'Accept': 'application/vnd.github+json'},
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      final data = res.data;
      if (data == null) return null;

      final tag = (data['tag_name'] as String?) ?? '';
      if (!isNewer(tag, AppConfig.version)) return null;

      final assets = (data['assets'] as List?) ?? const [];
      String? url;
      String? sigUrl;
      for (final a in assets.cast<Map<String, dynamic>>()) {
        final name = a['name'] as String?;
        if (name == asset) url = a['browser_download_url'] as String?;
        if (name == '$asset.sig') sigUrl = a['browser_download_url'] as String?;
      }
      if (url == null) return null;

      return UpdateInfo(
        version: tag.replaceAll(RegExp(r'^v'), ''),
        downloadUrl: url,
        signatureUrl: sigUrl,
        notes: (data['body'] as String?) ?? '',
        assetName: asset,
      );
    } catch (_) {
      // Une vérification qui échoue ne doit jamais gêner l'usage courant.
      return null;
    }
  }

  /// Télécharge l'artefact et sa signature, puis VÉRIFIE avant tout.
  ///
  /// Renvoie le chemin local du fichier vérifié, ou lève [UpdateRefused] si
  /// quoi que ce soit cloche — signature absente, invalide, ou clé publique non
  /// intégrée.
  Future<String> downloadAndVerify(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    if (!signingConfigured) {
      throw const UpdateRefused(
        'Aucune clé de signature n’est intégrée à cette version : '
        'la mise à jour automatique est désactivée.',
      );
    }
    if (info.signatureUrl == null) {
      throw const UpdateRefused(
        'Cette release ne publie pas de signature. Mise à jour refusée : '
        'on n’installe pas du code non authentifié.',
      );
    }

    final dir = await Directory.systemTemp.createTemp('zia_update');
    final target = '${dir.path}${Platform.pathSeparator}${info.assetName}';

    await _dio.download(
      info.downloadUrl,
      target,
      onReceiveProgress: (received, total) {
        if (total > 0 && onProgress != null) onProgress(received / total);
      },
    );

    final sigResponse = await _dio.get<List<int>>(
      info.signatureUrl!,
      options: Options(responseType: ResponseType.bytes),
    );
    final signature = Uint8List.fromList(sigResponse.data ?? const []);
    if (signature.length != 64) {
      throw const UpdateRefused('Signature de taille inattendue.');
    }

    final ok = await _engine.verifyFileSignature(
      publicKey: base64Decode(publicKeyBase64),
      filePath: target,
      signature: signature,
    );
    if (!ok) {
      // On efface immédiatement : un artefact non authentifié n'a aucune raison
      // de rester sur le disque de l'utilisateur.
      try {
        await Directory(dir.path).delete(recursive: true);
      } catch (_) {}
      throw const UpdateRefused(
        'La signature du fichier téléchargé est invalide. Mise à jour '
        'ABANDONNÉE — le fichier a été supprimé.',
      );
    }
    return target;
  }
}

/// Une mise à jour disponible.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.signatureUrl,
    required this.notes,
    required this.assetName,
  });

  final String version;
  final String downloadUrl;
  final String? signatureUrl;
  final String notes;
  final String assetName;
}

/// Mise à jour refusée pour une raison d'authenticité.
class UpdateRefused implements Exception {
  const UpdateRefused(this.message);
  final String message;
  @override
  String toString() => message;
}
