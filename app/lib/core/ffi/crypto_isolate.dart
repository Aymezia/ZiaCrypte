import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../../features/chat/domain/crypto_models.dart';
import 'native_crypto_engine.dart';

/// Façade **asynchrone** vers le moteur cryptographique natif.
///
/// Elle possède un unique isolate de longue durée qui, lui seul, détient le
/// `ZiaEngine*` natif et **sérialise tous les appels** (répond à la contrainte
/// de threading du moteur : un seul thread fait avancer l'état du ratchet). Les
/// opérations coûteuses (dérivation Argon2id à venir) restent ainsi hors de
/// l'isolate d'UI. Le reste de l'app ne connaît que cette classe.
///
/// Les sessions natives vivent dans l'isolate ; le monde extérieur les référence
/// par un identifiant entier opaque.
class ZiaCryptoEngine {
  ZiaCryptoEngine._(this._toIsolate, this._responses, this._isolate) {
    _fromIsolate.listen(_onResponse);
  }

  final SendPort _toIsolate;
  final ReceivePort _responses;
  late final Stream _fromIsolate = _responses.asBroadcastStream();
  final Isolate _isolate;

  final _pending = <int, Completer<Object?>>{};
  int _nextRequestId = 0;

  /// Démarre l'isolate et initialise le moteur.
  static Future<ZiaCryptoEngine> spawn(String storagePath,
      {String? libraryPath}) async {
    final bootstrap = ReceivePort();
    final isolate = await Isolate.spawn(
      _isolateEntry,
      _BootMessage(bootstrap.sendPort, storagePath, libraryPath),
    );

    final first = await bootstrap.first;
    bootstrap.close();
    if (first is _BootError) {
      isolate.kill(priority: Isolate.immediate);
      throw StateError('Échec init moteur natif: ${first.message}');
    }

    final sendPort = first as SendPort;
    final responses = ReceivePort();
    sendPort.send(responses.sendPort); // canal de réponses
    return ZiaCryptoEngine._(sendPort, responses, isolate);
  }

  Future<Uint8List> generateIdentity() => _call('generateIdentity');
  Future<Uint8List> identityPublicKey() => _call('identityPublicKey');
  Future<Uint8List> sign(Uint8List message) => _call('sign', {'msg': message});
  Future<bool> verify(Uint8List publicKey, Uint8List message, Uint8List sig) =>
      _call('verify', {'pub': publicKey, 'msg': message, 'sig': sig});

  Future<PrekeyBundle> generatePrekeyBundle() => _call('generatePrekeyBundle');
  Future<void> rotatePrekeys() => _call('rotatePrekeys');

  Future<InitiatedSession> sessionFromBundle(PrekeyBundle bundle) =>
      _call('sessionFromBundle', {'bundle': bundle});
  Future<int> acceptHandshake(HandshakeMaterial handshake) =>
      _call('acceptHandshake', {'handshake': handshake});

  Future<EncryptedMessage> encrypt(int sessionId, Uint8List plaintext) =>
      _call('encrypt', {'session': sessionId, 'pt': plaintext});
  Future<Uint8List> decrypt(
          int sessionId, Uint8List header, Uint8List ciphertext) =>
      _call('decrypt', {'session': sessionId, 'header': header, 'ct': ciphertext});

  /// Range une donnée chiffrée dans le coffre local de l'appareil.
  Future<void> vaultWrite(String name, Uint8List data) =>
      _call('vaultWrite', {'name': name, 'data': data});

  /// Relit une entrée du coffre local (null si absente).
  Future<Uint8List?> vaultRead(String name) =>
      _call('vaultRead', {'name': name});

  Future<Uint8List> serializeSession(int sessionId) =>
      _call('serializeSession', {'session': sessionId});
  Future<int> deserializeSession(Uint8List data) =>
      _call('deserializeSession', {'data': data});
  Future<void> closeSession(int sessionId) =>
      _call('closeSession', {'session': sessionId});

  /// Arrête proprement le moteur et l'isolate.
  Future<void> dispose() async {
    await _call('dispose');
    _responses.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  Future<T> _call<T>(String op, [Map<String, Object?> args = const {}]) {
    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _toIsolate.send(_Request(id, op, args));
    return completer.future.then((v) => v as T);
  }

  void _onResponse(dynamic message) {
    final resp = message as _Response;
    final completer = _pending.remove(resp.id);
    if (completer == null) return;
    if (resp.error != null) {
      completer.completeError(resp.error!, resp.stackTrace);
    } else {
      completer.complete(resp.result);
    }
  }

  // ============ Code exécuté DANS l'isolate ============

  static void _isolateEntry(_BootMessage boot) {
    late final NativeCryptoEngine engine;
    try {
      engine = NativeCryptoEngine.open(boot.storagePath,
          libraryPath: boot.libraryPath);
    } catch (e) {
      boot.reply.send(_BootError(e.toString()));
      return;
    }

    final commands = ReceivePort();
    boot.reply.send(commands.sendPort);

    SendPort? responsePort;
    final sessions = <int, NativeSession>{};
    var nextSessionId = 0;

    commands.listen((message) {
      if (message is SendPort) {
        responsePort = message;
        return;
      }
      final req = message as _Request;
      final reply = responsePort!;
      try {
        final result = _dispatch(req, engine, sessions, () => nextSessionId++,
            (id) => nextSessionId = id);
        reply.send(_Response(req.id, result: result));
      } catch (e, st) {
        reply.send(_Response(req.id, error: e, stackTrace: st));
      }
    });
  }

  static Object? _dispatch(
    _Request req,
    NativeCryptoEngine engine,
    Map<int, NativeSession> sessions,
    int Function() allocSessionId,
    void Function(int) _,
  ) {
    final a = req.args;
    switch (req.op) {
      case 'generateIdentity':
        return engine.generateIdentity();
      case 'identityPublicKey':
        return engine.identityPublicKey();
      case 'sign':
        return engine.sign(a['msg'] as Uint8List);
      case 'verify':
        return engine.verify(
            a['pub'] as Uint8List, a['msg'] as Uint8List, a['sig'] as Uint8List);
      case 'generatePrekeyBundle':
        return engine.generatePrekeyBundle();
      case 'rotatePrekeys':
        engine.rotatePrekeys();
        return null;
      case 'sessionFromBundle':
        final r = engine.sessionFromBundle(a['bundle'] as PrekeyBundle);
        final id = allocSessionId();
        sessions[id] = r.session;
        return InitiatedSession(sessionId: id, handshake: r.handshake);
      case 'acceptHandshake':
        final s = engine.acceptHandshake(a['handshake'] as HandshakeMaterial);
        final id = allocSessionId();
        sessions[id] = s;
        return id;
      case 'encrypt':
        return engine.encrypt(
            sessions[a['session'] as int]!, a['pt'] as Uint8List);
      case 'decrypt':
        return engine.decrypt(sessions[a['session'] as int]!,
            a['header'] as Uint8List, a['ct'] as Uint8List);
      case 'vaultWrite':
        engine.vaultWrite(a['name'] as String, a['data'] as Uint8List);
        return null;
      case 'vaultRead':
        return engine.vaultRead(a['name'] as String);
      case 'serializeSession':
        return engine.serializeSession(sessions[a['session'] as int]!);
      case 'deserializeSession':
        final s = engine.deserializeSession(a['data'] as Uint8List);
        final id = allocSessionId();
        sessions[id] = s;
        return id;
      case 'closeSession':
        final id = a['session'] as int;
        final s = sessions.remove(id);
        if (s != null) engine.closeSession(s);
        return null;
      case 'dispose':
        for (final s in sessions.values) {
          engine.closeSession(s);
        }
        sessions.clear();
        engine.dispose();
        return null;
      default:
        throw UnsupportedError('Opération inconnue: ${req.op}');
    }
  }
}

// ---- Messages internes de l'isolate ----

class _BootMessage {
  _BootMessage(this.reply, this.storagePath, this.libraryPath);
  final SendPort reply;
  final String storagePath;
  final String? libraryPath;
}

class _BootError {
  _BootError(this.message);
  final String message;
}

class _Request {
  _Request(this.id, this.op, this.args);
  final int id;
  final String op;
  final Map<String, Object?> args;
}

class _Response {
  _Response(this.id, {this.result, this.error, this.stackTrace});
  final int id;
  final Object? result;
  final Object? error;
  final StackTrace? stackTrace;
}
