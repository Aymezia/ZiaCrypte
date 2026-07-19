// Correspondant de test : s'inscrit sur le serveur, puis attend et déchiffre
// les messages reçus. Sert à valider manuellement l'application graphique —
// on écrit depuis l'app, ce programme affiche le texte déchiffré.
//
//   dart run bin/peer_receiver.dart <serveur> <lib native> <pseudo> [secondes]

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../app/lib/features/chat/data/envelope.dart';
import '../../app/lib/features/chat/data/ffi_crypto_gateway.dart';

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
  final baseUrl = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3210';
  final soPath = args.length > 1 ? args[1] : 'libzia_crypto.so';
  final username = args.length > 2 ? args[2] : 'bob_gui';
  final seconds = args.length > 3 ? int.parse(args[3]) : 60;
  // « add » rattache un SECOND appareil au compte existant au lieu d'en créer
  // un nouveau : c'est ainsi qu'on teste le multi-appareils.
  final addDevice = args.length > 4 && args[4] == 'add';
  final storageSuffix = addDevice ? '${username}_2' : username;

  final gateway = await FfiCryptoGateway.open(
    '${Directory.systemTemp.path}/zia_peer_$storageSuffix',
    libraryPath: soPath,
  );
  await gateway.generateIdentity();
  final bundle = await gateway.generatePrekeyBundle();

  final reg = await http.post(
    Uri.parse('$baseUrl/v1/auth/${addDevice ? 'add-device' : 'register'}'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'username': username,
      'password': 'password123',
      'device': {
        'platform': 'linux',
        'deviceName': 'peer',
        'identityPublicKey': base64Encode(bundle.identityKey),
        'signedPrekey': base64Encode(bundle.signedPrekey),
        'signedPrekeySignature': base64Encode(bundle.signedPrekeySignature),
        'oneTimePrekeys': [base64Encode(bundle.oneTimePrekey!)],
      },
    }),
  );
  if (reg.statusCode >= 400) {
    stderr.writeln('inscription échouée: ${reg.statusCode} ${reg.body}');
    exit(1);
  }
  final token = (jsonDecode(reg.body) as Map)['accessToken'] as String;
  stdout.writeln('PRET: $username ${addDevice ? '(2e appareil)' : '(1er appareil)'}'
      ' inscrit, en attente de messages…');

  int? sessionId;
  final deadline = DateTime.now().add(Duration(seconds: seconds));

  while (DateTime.now().isBefore(deadline)) {
    final res = await http.get(
      Uri.parse('$baseUrl/v1/messages'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final list = jsonDecode(res.body) as List;
    for (final m in list) {
      final unpacked = Envelope.unpackHeader(base64Decode(m['header'] as String));
      if (unpacked.handshake != null && sessionId == null) {
        sessionId = await gateway.acceptSession(unpacked.handshake!);
      }
      if (sessionId == null) continue;
      final plain = await gateway.decrypt(
        sessionId,
        unpacked.ratchetHeader,
        base64Decode(m['ciphertext'] as String),
      );
      stdout.writeln('RECU_DECHIFFRE: ${utf8.decode(plain)}');

      // Répond immédiatement : permet de mesurer la latence de bout en bout
      // côté application (WebSocket vs relevé périodique).
      final reply = 'echo: ${utf8.decode(plain)}';
      final enc = await gateway.encrypt(sessionId, Uint8List.fromList(utf8.encode(reply)));
      await http.post(
        Uri.parse('$baseUrl/v1/messages'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'conversationId': m['conversationId'],
          'recipientDeviceId': m['senderDeviceId'],
          'clientMessageId': _uuidV4(),
          'header': base64Encode(Envelope.packHeader(enc.header, null)),
          'ciphertext': base64Encode(enc.ciphertext),
        }),
      );
      stdout.writeln('REPONSE_ENVOYEE: $reply');
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }

  await gateway.dispose();
  stdout.writeln('FIN');
}
