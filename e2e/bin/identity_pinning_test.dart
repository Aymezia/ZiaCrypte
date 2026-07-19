// Preuve que l'épinglage des clés d'identité détecte une SUBSTITUTION PAR LE
// SERVEUR — l'attaque contre laquelle le chiffrement de bout en bout ne peut
// rien par lui-même.
//
// Le scénario n'est pas simulé à moitié : on modifie réellement la clé publique
// d'identité de Bob dans PostgreSQL, exactement ce que ferait un serveur
// malveillant, saisi ou compromis. Alice doit s'en apercevoir et REFUSER
// d'ouvrir une session, au lieu de parler à l'imposteur sans rien dire.
//
// Usage : dart run bin/identity_pinning_test.dart <baseUrl> <libzia_crypto.so>

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import '../../app/lib/core/ffi/crypto_isolate.dart';
import '../../app/lib/features/chat/data/identity_pinning.dart';
import '../../app/lib/features/chat/domain/contact_identity.dart';

late final String baseUrl;
late final String soPath;

int _checks = 0;
void ok(String label) {
  _checks++;
  stdout.writeln('[OK] $label');
}

Never fail(String label) {
  stdout.writeln('[ÉCHEC] $label');
  exit(1);
}

String uuidV4() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-'
      '${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
}

/// Inscrit un utilisateur avec un moteur natif qui lui est propre.
Future<({ZiaCryptoEngine engine, String userId, String deviceId, String token,
    String username, Uint8List identityKey})> newUser(String label) async {
  final dir = await Directory.systemTemp.createTemp('zia_pin_$label');
  final engine = await ZiaCryptoEngine.spawn(dir.path, libraryPath: soPath);
  await engine.generateIdentity();
  final bundle = await engine.generatePrekeyBundle();
  final identityKey = await engine.identityPublicKey();

  final username = '${label}_${DateTime.now().millisecondsSinceEpoch}';
  final res = await http.post(
    Uri.parse('$baseUrl/v1/auth/register'),
    headers: {'content-type': 'application/json'},
    body: jsonEncode({
      'username': username,
      'password': 'password123',
      'device': {
        'platform': 'linux',
        'identityPublicKey': base64Encode(identityKey),
        'signedPrekey': base64Encode(bundle.signedPrekey),
        'signedPrekeySignature': base64Encode(bundle.signedPrekeySignature),
        'oneTimePrekeys': [
          if (bundle.oneTimePrekey != null) base64Encode(bundle.oneTimePrekey!),
        ],
      },
    }),
  );
  if (res.statusCode != 201) fail('inscription $label : ${res.statusCode} ${res.body}');
  final json = jsonDecode(res.body) as Map<String, dynamic>;
  return (
    engine: engine,
    userId: json['userId'] as String,
    deviceId: json['deviceId'] as String,
    token: json['accessToken'] as String,
    username: username,
    identityKey: identityKey,
  );
}

/// Récupère les bundles publiés par le serveur pour un utilisateur.
Future<List<Map<String, dynamic>>> bundles(String token, String userId) async {
  final res = await http.get(
    Uri.parse('$baseUrl/v1/users/$userId/prekey-bundles'),
    headers: {'authorization': 'Bearer $token'},
  );
  if (res.statusCode != 200) fail('bundles : ${res.statusCode} ${res.body}');
  return (jsonDecode(res.body) as List<dynamic>).cast<Map<String, dynamic>>();
}

/// Substitue la clé d'identité d'un appareil DIRECTEMENT en base — ce que ferait
/// un serveur malveillant. Renvoie la clé imposée.
Future<Uint8List> tamperIdentityKey(String deviceId) async {
  final rnd = Random.secure();
  final forged = Uint8List.fromList(
      List<int>.generate(32, (_) => rnd.nextInt(256)));
  final hex = forged.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  final res = await Process.run('psql', [
    '-h', '127.0.0.1', '-U', 'ziacrypte', '-d', 'ziacrypte', '-tAc',
    "UPDATE devices SET identity_public_key = decode('$hex','hex') WHERE id = '$deviceId';",
  ], environment: {'PGPASSWORD': 'changeme'});
  if (res.exitCode != 0) fail('altération en base : ${res.stderr}');
  return forged;
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stdout.writeln('usage: identity_pinning_test <baseUrl> <libzia_crypto.so>');
    exit(2);
  }
  baseUrl = args[0];
  soPath = args[1];

  final alice = await newUser('pin_alice');
  final bob = await newUser('pin_bob');
  ok('Alice et Bob inscrits, chacun avec son moteur natif');

  final pinning = IdentityPinning(alice.engine);
  await pinning.load();

  // --- Premier contact : la clé de Bob est épinglée ---
  final first = await bundles(alice.token, bob.userId);
  final bobBundle = first.firstWhere((b) => b['deviceId'] == bob.deviceId);
  final announced = base64Decode(bobBundle['identityKey'] as String);

  if (!_sameBytes(announced, bob.identityKey)) {
    fail('le serveur n’a pas renvoyé la vraie clé de Bob au premier contact');
  }
  await pinning.checkAndPin(
      deviceId: bob.deviceId, userId: bob.userId, identityKey: announced);
  ok('premier contact : la clé de Bob est épinglée');

  // --- Le numéro de sécurité se calcule et il est symétrique ---
  final numberFromAlice = await pinning.safetyNumber(
    myIdentityKey: alice.identityKey,
    myUserId: alice.userId,
    peerDeviceId: bob.deviceId,
    peerUserId: bob.userId,
  );
  if (numberFromAlice == null || numberFromAlice.length != 60) {
    fail('numéro de sécurité invalide : $numberFromAlice');
  }

  // Bob calcule de son côté, avec sa propre instance du moteur et son point de
  // vue inversé. Les deux doivent lire le même nombre, sinon la comparaison
  // hors bande est impraticable.
  final numberFromBob = await bob.engine.safetyNumber(
    localKey: bob.identityKey,
    localId: bob.userId,
    remoteKey: alice.identityKey,
    remoteId: alice.userId,
  );
  if (numberFromAlice != numberFromBob) {
    fail('numéros divergents :\n  Alice: $numberFromAlice\n  Bob:   $numberFromBob');
  }
  ok('les deux correspondants lisent le même numéro : $numberFromAlice');

  // --- L'ATTAQUE : le serveur substitue la clé de Bob ---
  final forged = await tamperIdentityKey(bob.deviceId);
  final after = await bundles(alice.token, bob.userId);
  final tampered = after.firstWhere((b) => b['deviceId'] == bob.deviceId);
  final servedNow = base64Decode(tampered['identityKey'] as String);

  if (!_sameBytes(servedNow, forged)) {
    fail('l’altération n’a pas pris : le serveur sert encore l’ancienne clé');
  }
  ok('le serveur sert désormais une clé forgée pour l’appareil de Bob');

  // Sans épinglage, Alice ouvrirait ici une session avec l'imposteur.
  var detected = false;
  try {
    await pinning.checkAndPin(
        deviceId: bob.deviceId, userId: bob.userId, identityKey: servedNow);
  } on IdentityChangedException {
    detected = true;
  }
  if (!detected) fail('SUBSTITUTION NON DÉTECTÉE — la vérification est inopérante');
  ok('substitution DÉTECTÉE : la session n’est pas ouverte');

  // --- La clé épinglée n'a pas bougé ---
  final stillPinned = pinning.forDevice(bob.deviceId)!;
  if (!stillPinned.hasSameKey(bob.identityKey)) {
    fail('la clé épinglée a été écrasée par celle de l’attaquant');
  }
  ok('la clé légitime reste épinglée malgré l’attaque');

  // --- Le statut vérifié ne survit pas à un changement accepté ---
  await pinning.markVerified(bob.deviceId);
  if (!pinning.forDevice(bob.deviceId)!.verified) fail('markVerified sans effet');
  await pinning.acceptChange(
      deviceId: bob.deviceId, userId: bob.userId, identityKey: servedNow);
  if (pinning.forDevice(bob.deviceId)!.verified) {
    fail('le statut « vérifié » a survécu au changement de clé — mensonger');
  }
  ok('accepter une nouvelle clé remet le contact en « non vérifié »');

  // --- Persistance : le registre survit au redémarrage du moteur ---
  final reloaded = IdentityPinning(alice.engine);
  await reloaded.load();
  final persisted = reloaded.forDevice(bob.deviceId);
  if (persisted == null || !persisted.hasSameKey(servedNow)) {
    fail('le registre épinglé ne survit pas à un rechargement');
  }
  ok('le registre est persisté dans le coffre chiffré local');

  stdout.writeln('\n$_checks vérifications passées');
  await alice.engine.dispose();
  await bob.engine.dispose();
  exit(0);
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
