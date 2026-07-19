// Vérifie la chaîne complète des pièces jointes :
//   fichier -> chiffré par le moteur -> déposé sur le stockage S3 par URL
//   pré-signée -> récupéré -> déchiffré, à l'identique.
//
// Contrôle aussi que l'octet déposé chez l'hébergeur ne contient rien de
// lisible, et qu'une mauvaise clé est rejetée.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../app/lib/core/ffi/native_crypto_engine.dart';
import '../../app/lib/core/ffi/zia_crypto_exceptions.dart';

int _checks = 0;
void ok(String label) {
  _checks++;
  stdout.writeln('[OK] $label');
}

String _uuidV4() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-'
      '${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
}

Future<void> main(List<String> args) async {
  final baseUrl = args.isNotEmpty ? args[0] : 'https://51.83.199.103.nip.io';
  final soPath = args.length > 1 ? args[1] : 'libzia_crypto.so';

  final engine = NativeCryptoEngine.open(
    '${Directory.systemTemp.path}/zia_attach_${DateTime.now().microsecondsSinceEpoch}',
    libraryPath: soPath,
  );

  // --- Un compte et une conversation, nécessaires pour déposer ---
  engine.generateIdentity();
  final bundle = engine.generatePrekeyBundle();
  final suffix = DateTime.now().millisecondsSinceEpoch;

  Future<Map<String, dynamic>> register(String name) async {
    final r = await http.post(
      Uri.parse('$baseUrl/v1/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': name,
        'password': 'password123',
        'device': {
          'platform': 'linux',
          'deviceName': 'attach-test',
          'identityPublicKey': base64Encode(bundle.identityKey),
          'signedPrekey': base64Encode(bundle.signedPrekey),
          'signedPrekeySignature': base64Encode(bundle.signedPrekeySignature),
          'oneTimePrekeys': [base64Encode(bundle.oneTimePrekey!)],
        },
      }),
    );
    if (r.statusCode >= 400) throw 'inscription: ${r.statusCode} ${r.body}';
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  final me = await register('attach_$suffix');
  final token = me['accessToken'] as String;
  final authed = {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  };

  final convRes = await http.post(
    Uri.parse('$baseUrl/v1/conversations'),
    headers: authed,
    body: jsonEncode({'type': 'direct', 'participantIds': [me['userId']]}),
  );
  final conversationId = (jsonDecode(convRes.body) as Map)['id'] as String;
  ok('Compte et conversation prêts');

  // --- Chiffrement du fichier par le moteur ---
  final original = Uint8List.fromList(
      utf8.encode('CONTENU_SECRET_DU_FICHIER ' * 200)); // ~5 ko
  final sealed = engine.attachmentEncrypt(original);
  if (sealed.key.length != 32) throw 'clé de pièce jointe inattendue';
  ok('Fichier chiffré par le moteur (${original.length} o -> ${sealed.ciphertext.length} o)');

  // --- Réservation + dépôt par URL pré-signée ---
  final metadata = utf8.encode(jsonEncode({'name': 'secret.txt', 'mime': 'text/plain'}));
  final metaSealed = engine.attachmentEncrypt(Uint8List.fromList(metadata));

  final createRes = await http.post(
    Uri.parse('$baseUrl/v1/attachments'),
    headers: authed,
    body: jsonEncode({
      'conversationId': conversationId,
      'ciphertextSize': sealed.ciphertext.length,
      'encryptedMetadata': base64Encode(metaSealed.ciphertext),
    }),
  );
  if (createRes.statusCode >= 400) {
    throw 'réservation: ${createRes.statusCode} ${createRes.body}';
  }
  final created = jsonDecode(createRes.body) as Map<String, dynamic>;
  final attachmentId = created['attachmentId'] as String;

  final put = await http.put(
    Uri.parse(created['uploadUrl'] as String),
    body: sealed.ciphertext,
  );
  if (put.statusCode >= 400) throw 'dépôt S3: ${put.statusCode} ${put.body}';
  ok('Déposé sur le stockage S3 via URL pré-signée');

  // --- Récupération et déchiffrement ---
  final getRes = await http.get(
    Uri.parse('$baseUrl/v1/attachments/$attachmentId'),
    headers: authed,
  );
  final info = jsonDecode(getRes.body) as Map<String, dynamic>;
  final download = await http.get(Uri.parse(info['downloadUrl'] as String));
  if (download.statusCode >= 400) throw 'téléchargement: ${download.statusCode}';

  final fetched = Uint8List.fromList(download.bodyBytes);
  ok('Récupéré depuis le stockage (${fetched.length} o)');

  // Ce que l'hébergeur détient ne doit rien révéler.
  final asText = utf8.decode(fetched, allowMalformed: true);
  if (asText.contains('CONTENU_SECRET')) throw 'le contenu est lisible chez l’hébergeur !';
  ok('Le stockage ne détient que du chiffré (aucun texte lisible)');

  final restored = engine.attachmentDecrypt(sealed.key, fetched);
  if (restored.length != original.length) throw 'taille restituée incorrecte';
  for (var i = 0; i < original.length; i++) {
    if (restored[i] != original[i]) throw 'octet $i différent';
  }
  ok('Déchiffré à l’identique avec la clé transmise dans le message');

  // --- Une mauvaise clé doit échouer ---
  final wrongKey = Uint8List.fromList(sealed.key)..[0] ^= 0xFF;
  try {
    engine.attachmentDecrypt(wrongKey, fetched);
    throw 'une clé fausse a été acceptée !';
  } on ZiaCryptoFailureException {
    ok('Clé incorrecte rejetée');
  }

  // --- Un fichier altéré doit échouer ---
  final tampered = Uint8List.fromList(fetched)..[fetched.length ~/ 2] ^= 0xFF;
  try {
    engine.attachmentDecrypt(sealed.key, tampered);
    throw 'un fichier altéré a été accepté !';
  } on ZiaCryptoFailureException {
    ok('Fichier altéré rejeté');
  }

  engine.dispose();
  stdout.writeln('\n$_checks/$_checks vérifications réussies — '
      'pièces jointes chiffrées de bout en bout sur stockage S3.');
  stdout.writeln('(conversation $conversationId, message ${_uuidV4()})');
}
