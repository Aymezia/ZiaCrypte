// Correspondant de test : s'inscrit sur le serveur, puis attend et déchiffre
// les messages reçus. Sert à valider manuellement l'application graphique —
// on écrit depuis l'app, ce programme affiche le texte déchiffré.
//
//   dart run bin/peer_receiver.dart <serveur> <lib native> <pseudo> [secondes]

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../app/lib/features/chat/data/envelope.dart';
import '../../app/lib/features/chat/data/ffi_crypto_gateway.dart';

Future<void> main(List<String> args) async {
  final baseUrl = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3210';
  final soPath = args.length > 1 ? args[1] : 'libzia_crypto.so';
  final username = args.length > 2 ? args[2] : 'bob_gui';
  final seconds = args.length > 3 ? int.parse(args[3]) : 60;

  final gateway = await FfiCryptoGateway.open(
    '${Directory.systemTemp.path}/zia_peer_$username',
    libraryPath: soPath,
  );
  await gateway.generateIdentity();
  final bundle = await gateway.generatePrekeyBundle();

  final reg = await http.post(
    Uri.parse('$baseUrl/v1/auth/register'),
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
  stdout.writeln('PRET: $username inscrit, en attente de messages…');

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
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }

  await gateway.dispose();
  stdout.writeln('FIN');
}
