// Preuve END-TO-END du système assemblé :
//   moteur cryptographique C++ (via FFI)  <->  app cliente Dart  <->  serveur
//   Fastify réel (HTTP)  <->  PostgreSQL réel
//
// Alice et Bob sont deux clients indépendants, chacun avec sa propre instance du
// moteur natif. Ils s'inscrivent, publient leurs prekeys, font un handshake
// X3DH via le serveur, puis échangent des messages CHIFFRÉS que le serveur se
// contente de relayer sans jamais pouvoir les lire.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import '../../app/lib/features/chat/data/ffi_crypto_gateway.dart';
import '../../app/lib/features/chat/domain/crypto_models.dart';

late final String baseUrl;
late final String soPath;

int _checks = 0;
void ok(String label) {
  _checks++;
  stdout.writeln('[OK] $label');
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

/// Client HTTP minimal de l'API ZiaCrypte.
class Api {
  Api(this.base);
  final String base;
  String? token;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<dynamic> post(String path, Object body) async {
    final r = await http.post(Uri.parse('$base$path'),
        headers: _headers, body: jsonEncode(body));
    if (r.statusCode >= 400) {
      throw 'POST $path -> ${r.statusCode} ${r.body}';
    }
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }

  Future<dynamic> get(String path) async {
    final r = await http.get(Uri.parse('$base$path'), headers: _headers);
    if (r.statusCode >= 400) throw 'GET $path -> ${r.statusCode} ${r.body}';
    return jsonDecode(r.body);
  }
}

// ---- Cadrage de l'enveloppe (côté client uniquement ; le serveur ne voit que des octets) ----
// 1er message : [1][IK 32][EK 32][hasOtpk 1][OTPK 32][ratchetHeader 40]
// suivants    : [0][ratchetHeader 40]

Uint8List packHeader(Uint8List ratchetHeader, HandshakeMaterial? hs) {
  final out = BytesBuilder();
  if (hs == null) {
    out.addByte(0);
  } else {
    out.addByte(1);
    out.add(hs.initiatorIdentityKey);
    out.add(hs.initiatorEphemeralKey);
    out.addByte(hs.usedOneTimePrekey != null ? 1 : 0);
    out.add(hs.usedOneTimePrekey ?? Uint8List(32));
  }
  out.add(ratchetHeader);
  return out.toBytes();
}

({HandshakeMaterial? handshake, Uint8List ratchetHeader}) unpackHeader(Uint8List packed) {
  if (packed[0] == 0) {
    return (handshake: null, ratchetHeader: Uint8List.sublistView(packed, 1));
  }
  final ik = Uint8List.sublistView(packed, 1, 33);
  final ek = Uint8List.sublistView(packed, 33, 65);
  final hasOtpk = packed[65] == 1;
  final otpk = Uint8List.sublistView(packed, 66, 98);
  return (
    handshake: HandshakeMaterial(
      initiatorIdentityKey: Uint8List.fromList(ik),
      initiatorEphemeralKey: Uint8List.fromList(ek),
      usedOneTimePrekey: hasOtpk ? Uint8List.fromList(otpk) : null,
    ),
    ratchetHeader: Uint8List.sublistView(packed, 98),
  );
}

/// Un client complet : moteur natif + API.
class Client {
  Client(this.name, this.gateway, this.api);
  final String name;
  final FfiCryptoGateway gateway;
  final Api api;
  late String userId;
  late String deviceId;

  static Future<Client> create(String name) async {
    final gw = await FfiCryptoGateway.open('/tmp/zia_e2e_$name', libraryPath: soPath);
    return Client(name, gw, Api(baseUrl));
  }

  Future<void> register(String username) async {
    await gateway.generateIdentity();
    final bundle = await gateway.generatePrekeyBundle();
    final res = await api.post('/v1/auth/register', {
      'username': username,
      'password': 'password123',
      'device': {
        'platform': 'linux',
        'deviceName': name,
        'identityPublicKey': base64Encode(bundle.identityKey),
        'signedPrekey': base64Encode(bundle.signedPrekey),
        'signedPrekeySignature': base64Encode(bundle.signedPrekeySignature),
        'oneTimePrekeys': [base64Encode(bundle.oneTimePrekey!)],
      },
    });
    userId = res['userId'];
    deviceId = res['deviceId'];
    api.token = res['accessToken'];
  }
}

Future<void> main(List<String> args) async {
  baseUrl = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3210';
  soPath = args.length > 1 ? args[1] : 'libzia_crypto.so';

  final suffix = DateTime.now().millisecondsSinceEpoch;
  final alice = await Client.create('alice');
  final bob = await Client.create('bob');

  await alice.register('alice_e2e_$suffix');
  await bob.register('bob_e2e_$suffix');
  ok('Alice et Bob inscrits, prekeys publiées sur le serveur');

  // Alice crée la conversation
  final conv = await alice.api.post('/v1/conversations', {
    'type': 'direct',
    'participantIds': [bob.userId],
  });
  final conversationId = conv['id'];
  ok('Conversation créée côté serveur');

  // Alice récupère le bundle X3DH de Bob et ouvre une session
  final bundleJson = await alice.api.get('/v1/users/${bob.userId}/prekey-bundle');
  final theirBundle = PrekeyBundle(
    identityKey: base64Decode(bundleJson['identityKey']),
    signedPrekey: base64Decode(bundleJson['signedPrekey']),
    signedPrekeySignature: base64Decode(bundleJson['signedPrekeySignature']),
    oneTimePrekey: bundleJson['oneTimePrekey'] != null
        ? base64Decode(bundleJson['oneTimePrekey'])
        : null,
  );
  final init = await alice.gateway.startSession(theirBundle);
  ok('Handshake X3DH d\'Alice à partir du bundle servi par l\'API');

  // Alice chiffre et envoie via le serveur
  const secret = 'Message secret : le serveur ne doit jamais lire ceci.';
  final enc = await alice.gateway.encrypt(init.sessionId, utf8.encode(secret));
  await alice.api.post('/v1/messages', {
    'conversationId': conversationId,
    'recipientDeviceId': bundleJson['deviceId'],
    'clientMessageId': uuidV4(),
    'header': base64Encode(packHeader(enc.header, init.handshake)),
    'ciphertext': base64Encode(enc.ciphertext),
  });
  ok('Alice a chiffré puis déposé le blob sur le serveur');

  // Bob relève ses messages et déchiffre
  final inbox = await bob.api.get('/v1/messages') as List;
  if (inbox.length != 1) throw 'boîte de réception inattendue: ${inbox.length}';
  final msg = inbox.first;
  final unpacked = unpackHeader(base64Decode(msg['header']));
  final bobSession = await bob.gateway.acceptSession(unpacked.handshake!);
  final plain = await bob.gateway.decrypt(
      bobSession, unpacked.ratchetHeader, base64Decode(msg['ciphertext']));
  if (utf8.decode(plain) != secret) throw 'déchiffrement incorrect';
  ok('Bob a relevé le blob et l\'a déchiffré : "${utf8.decode(plain)}"');

  // Réponse de Bob à Alice (sens inverse, via le serveur)
  const reply = 'Bien reçu Alice, chiffré de bout en bout.';
  final encReply = await bob.gateway.encrypt(bobSession, utf8.encode(reply));
  await bob.api.post('/v1/messages', {
    'conversationId': conversationId,
    'recipientDeviceId': msg['senderDeviceId'],
    'clientMessageId': uuidV4(),
    'header': base64Encode(packHeader(encReply.header, null)),
    'ciphertext': base64Encode(encReply.ciphertext),
  });
  final aliceInbox = await alice.api.get('/v1/messages') as List;
  final rmsg = aliceInbox.first;
  final runpacked = unpackHeader(base64Decode(rmsg['header']));
  final rplain = await alice.gateway.decrypt(
      init.sessionId, runpacked.ratchetHeader, base64Decode(rmsg['ciphertext']));
  if (utf8.decode(rplain) != reply) throw 'réponse incorrecte';
  ok('Alice a déchiffré la réponse de Bob : "${utf8.decode(rplain)}"');

  // Plusieurs allers-retours à travers le serveur
  for (var i = 0; i < 3; i++) {
    final m = 'ping $i';
    final e = await alice.gateway.encrypt(init.sessionId, utf8.encode(m));
    await alice.api.post('/v1/messages', {
      'conversationId': conversationId,
      'recipientDeviceId': bundleJson['deviceId'],
      'clientMessageId': uuidV4(),
      'header': base64Encode(packHeader(e.header, null)),
      'ciphertext': base64Encode(e.ciphertext),
    });
    final box = await bob.api.get('/v1/messages') as List;
    final u = unpackHeader(base64Decode(box.first['header']));
    final p = await bob.gateway.decrypt(
        bobSession, u.ratchetHeader, base64Decode(box.first['ciphertext']));
    if (utf8.decode(p) != m) throw 'aller-retour $i incorrect';
  }
  ok('3 allers-retours supplémentaires via le serveur (ratchet qui avance)');

  await alice.gateway.dispose();
  await bob.gateway.dispose();

  stdout.writeln('\n$_checks/$_checks étapes réussies — chaîne complète '
      'moteur C++ <-> client Dart <-> serveur <-> PostgreSQL validée.');
  stdout.writeln('SECRET_ATTENDU_EN_BASE=$secret');
}
