import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../features/chat/domain/crypto_models.dart';
import 'zia_bindings.dart';
import 'zia_crypto_exceptions.dart';

/// Référence Dart vers une session native, avec libération garantie.
///
/// Un [NativeFinalizer] enregistré sur `zia_session_close` garantit que la
/// mémoire native est libérée même si `close()` n'est jamais appelé
/// explicitement (filet de sécurité, pas un substitut à la libération). Le
/// [Finalizable] maintient l'objet vivant tant qu'une méthode l'utilise.
class NativeSession implements Finalizable {
  NativeSession._(this.pointer, this._finalizer) {
    _finalizer.attach(this, pointer.cast(), detach: this, externalSize: 512);
  }

  final Pointer<ZiaSession> pointer;
  final NativeFinalizer _finalizer;
  bool _closed = false;

  void close(void Function(Pointer<ZiaSession>) nativeClose) {
    if (_closed) return;
    _closed = true;
    _finalizer.detach(this);
    nativeClose(pointer);
  }
}

/// Moteur cryptographique natif, **synchrone**. Détient le `ZiaEngine*` et
/// réalise tout le marshalling `Uint8List` <-> pointeurs natifs, en effaçant
/// les buffers de sortie natifs après copie. Cette classe est conçue pour vivre
/// à l'intérieur d'un isolate dédié (cf. crypto_isolate.dart) : le reste de
/// l'app ne l'utilise jamais directement, mais elle est directement testable.
class NativeCryptoEngine {
  NativeCryptoEngine._(this._b, this._engine, this._finalizer);

  final ZiaBindings _b;
  final Pointer<ZiaEngine> _engine;
  final NativeFinalizer _finalizer;

  /// Charge la bibliothèque native et initialise le moteur.
  factory NativeCryptoEngine.open(String storagePath, {String? libraryPath}) {
    final lib = DynamicLibrary.open(libraryPath ?? _defaultLibraryName());
    final bindings = ZiaBindings(lib);
    final finalizer = NativeFinalizer(bindings.sessionClosePtr);

    final storagePtr = storagePath.toNativeUtf8();
    final statusPtr = calloc<Int32>();
    try {
      final engine = bindings.engineInit(storagePtr.cast<Char>(), statusPtr);
      final status = statusPtr.value;
      if (engine == nullptr || status != ZiaStatus.ok) {
        throw ZiaCryptoException.fromStatus(
            status == ZiaStatus.ok ? ZiaStatus.errCryptoFailure : status,
            'zia_engine_init a échoué');
      }
      return NativeCryptoEngine._(bindings, engine, finalizer);
    } finally {
      malloc.free(storagePtr);
      calloc.free(statusPtr);
    }
  }

  static String _defaultLibraryName() {
    if (Platform.isWindows) return 'zia_crypto.dll';
    if (Platform.isMacOS) return 'libzia_crypto.dylib';
    return 'libzia_crypto.so';
  }

  // ---- Identité ----

  Uint8List generateIdentity() {
    final out = calloc<Uint8>(ziaPublicKeyLen);
    try {
      _check(_b.identityGenerate(_engine, out));
      return _copyOut(out, ziaPublicKeyLen);
    } finally {
      calloc.free(out);
    }
  }

  Uint8List identityPublicKey() {
    final out = calloc<Uint8>(ziaPublicKeyLen);
    try {
      _check(_b.identityGetPublicKey(_engine, out));
      return _copyOut(out, ziaPublicKeyLen);
    } finally {
      calloc.free(out);
    }
  }

  Uint8List sign(Uint8List message) {
    final msg = _toNative(message);
    final sig = calloc<Uint8>(ziaSignatureLen);
    try {
      _check(_b.identitySign(_engine, msg, message.length, sig));
      return _copyOut(sig, ziaSignatureLen);
    } finally {
      calloc.free(msg);
      calloc.free(sig);
    }
  }

  bool verify(Uint8List publicKey, Uint8List message, Uint8List signature) {
    final pub = _toNative(publicKey);
    final msg = _toNative(message);
    final sig = _toNative(signature);
    try {
      final status = _b.verifySignature(pub, msg, message.length, sig);
      if (status == ZiaStatus.ok) return true;
      if (status == ZiaStatus.errSignatureInvalid) return false;
      throw ZiaCryptoException.fromStatus(status);
    } finally {
      calloc.free(pub);
      calloc.free(msg);
      calloc.free(sig);
    }
  }

  // ---- X3DH ----

  PrekeyBundle generatePrekeyBundle() {
    final bundle = calloc<ZiaPrekeyBundle>();
    try {
      _check(_b.prekeyBundleGenerate(_engine, bundle));
      final b = bundle.ref;
      return PrekeyBundle(
        identityKey: _arrayToList(b.identity_key, ziaPublicKeyLen),
        signedPrekey: _arrayToList(b.signed_prekey, ziaPublicKeyLen),
        signedPrekeySignature:
            _arrayToList(b.signed_prekey_signature, ziaSignatureLen),
        oneTimePrekey: b.has_one_time_prekey != 0
            ? _arrayToList(b.one_time_prekey, ziaPublicKeyLen)
            : null,
      );
    } finally {
      calloc.free(bundle);
    }
  }

  void rotatePrekeys() => _check(_b.prekeyBundleRotate(_engine));

  ({NativeSession session, HandshakeMaterial handshake}) sessionFromBundle(
      PrekeyBundle theirBundle) {
    final bundle = calloc<ZiaPrekeyBundle>();
    final hs = calloc<ZiaHandshakeMaterial>();
    final sessionOut = calloc<Pointer<ZiaSession>>();
    try {
      final b = bundle.ref;
      _listToArray(theirBundle.identityKey, b.identity_key, ziaPublicKeyLen);
      _listToArray(theirBundle.signedPrekey, b.signed_prekey, ziaPublicKeyLen);
      _listToArray(theirBundle.signedPrekeySignature,
          b.signed_prekey_signature, ziaSignatureLen);
      if (theirBundle.oneTimePrekey != null) {
        _listToArray(
            theirBundle.oneTimePrekey!, b.one_time_prekey, ziaPublicKeyLen);
        b.has_one_time_prekey = 1;
      } else {
        b.has_one_time_prekey = 0;
      }

      _check(_b.sessionFromBundle(_engine, bundle, sessionOut, hs));

      final h = hs.ref;
      final handshake = HandshakeMaterial(
        initiatorIdentityKey:
            _arrayToList(h.initiator_identity_key, ziaPublicKeyLen),
        initiatorEphemeralKey:
            _arrayToList(h.initiator_ephemeral_key, ziaPublicKeyLen),
        usedOneTimePrekey: h.has_one_time_prekey != 0
            ? _arrayToList(h.used_one_time_prekey, ziaPublicKeyLen)
            : null,
      );
      return (session: _wrapSession(sessionOut.value), handshake: handshake);
    } finally {
      calloc.free(bundle);
      calloc.free(hs);
      calloc.free(sessionOut);
    }
  }

  NativeSession acceptHandshake(HandshakeMaterial handshake) {
    final hs = calloc<ZiaHandshakeMaterial>();
    final sessionOut = calloc<Pointer<ZiaSession>>();
    try {
      final h = hs.ref;
      _listToArray(handshake.initiatorIdentityKey, h.initiator_identity_key,
          ziaPublicKeyLen);
      _listToArray(handshake.initiatorEphemeralKey, h.initiator_ephemeral_key,
          ziaPublicKeyLen);
      if (handshake.usedOneTimePrekey != null) {
        _listToArray(handshake.usedOneTimePrekey!, h.used_one_time_prekey,
            ziaPublicKeyLen);
        h.has_one_time_prekey = 1;
      } else {
        h.has_one_time_prekey = 0;
      }

      _check(_b.sessionAcceptHandshake(_engine, hs, sessionOut));
      return _wrapSession(sessionOut.value);
    } finally {
      calloc.free(hs);
      calloc.free(sessionOut);
    }
  }

  // ---- Double Ratchet ----

  EncryptedMessage encrypt(NativeSession session, Uint8List plaintext) {
    final pt = _toNative(plaintext);
    final headerPtr = calloc<Pointer<Uint8>>();
    final headerLen = calloc<Size>();
    final ctPtr = calloc<Pointer<Uint8>>();
    final ctLen = calloc<Size>();
    try {
      _check(_b.sessionEncrypt(session.pointer, pt, plaintext.length, headerPtr,
          headerLen, ctPtr, ctLen));
      final header = _copyAndFree(headerPtr.value, headerLen.value);
      final ciphertext = _copyAndFree(ctPtr.value, ctLen.value);
      return EncryptedMessage(header: header, ciphertext: ciphertext);
    } finally {
      calloc.free(pt);
      calloc.free(headerPtr);
      calloc.free(headerLen);
      calloc.free(ctPtr);
      calloc.free(ctLen);
    }
  }

  Uint8List decrypt(NativeSession session, Uint8List header, Uint8List ciphertext) {
    final hdr = _toNative(header);
    final ct = _toNative(ciphertext);
    final ptPtr = calloc<Pointer<Uint8>>();
    final ptLen = calloc<Size>();
    try {
      _check(_b.sessionDecrypt(session.pointer, hdr, header.length, ct,
          ciphertext.length, ptPtr, ptLen));
      return _copyAndFree(ptPtr.value, ptLen.value);
    } finally {
      calloc.free(hdr);
      calloc.free(ct);
      calloc.free(ptPtr);
      calloc.free(ptLen);
    }
  }

  // ---- Persistance ----

  Uint8List serializeSession(NativeSession session) {
    final outPtr = calloc<Pointer<Uint8>>();
    final outLen = calloc<Size>();
    try {
      _check(_b.sessionSerialize(session.pointer, outPtr, outLen));
      return _copyAndFree(outPtr.value, outLen.value);
    } finally {
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  NativeSession deserializeSession(Uint8List data) {
    final buf = _toNative(data);
    final sessionOut = calloc<Pointer<ZiaSession>>();
    try {
      _check(_b.sessionDeserialize(_engine, buf, data.length, sessionOut));
      return _wrapSession(sessionOut.value);
    } finally {
      calloc.free(buf);
      calloc.free(sessionOut);
    }
  }

  // ---- Pièces jointes ----

  /// Chiffre un fichier sous une clé tirée au hasard, renvoyée avec le
  /// ciphertext. La clé voyagera dans le message chiffré ; l'hébergeur du
  /// stockage ne reçoit que le ciphertext.
  ({Uint8List key, Uint8List ciphertext}) attachmentEncrypt(Uint8List data) {
    final input = _toNative(data);
    final key = calloc<Uint8>(ziaAttachmentKeyLen);
    final outPtr = calloc<Pointer<Uint8>>();
    final outLen = calloc<Size>();
    try {
      _check(_b.attachmentEncrypt(input, data.length, key, outPtr, outLen));
      return (
        key: _copyOut(key, ziaAttachmentKeyLen),
        ciphertext: _copyAndFree(outPtr.value, outLen.value),
      );
    } finally {
      calloc.free(input);
      calloc.free(key);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  /// Déchiffre une pièce jointe. Échoue si la clé est fausse ou le fichier
  /// altéré (l'authentification AEAD le détecte).
  Uint8List attachmentDecrypt(Uint8List key, Uint8List ciphertext) {
    final keyPtr = _toNative(key);
    final input = _toNative(ciphertext);
    final outPtr = calloc<Pointer<Uint8>>();
    final outLen = calloc<Size>();
    try {
      _check(_b.attachmentDecrypt(
          keyPtr, input, ciphertext.length, outPtr, outLen));
      return _copyAndFree(outPtr.value, outLen.value);
    } finally {
      calloc.free(keyPtr);
      calloc.free(input);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  // ---- Coffre local chiffré ----

  /// Range [data] chiffré sous la clé maîtresse de l'appareil.
  void vaultWrite(String name, Uint8List data) {
    final namePtr = name.toNativeUtf8();
    final buf = _toNative(data);
    try {
      _check(_b.secureWrite(_engine, namePtr.cast<Char>(), buf, data.length));
    } finally {
      malloc.free(namePtr);
      calloc.free(buf);
    }
  }

  /// Relit une entrée du coffre, ou `null` si elle n'existe pas.
  Uint8List? vaultRead(String name) {
    final namePtr = name.toNativeUtf8();
    final outPtr = calloc<Pointer<Uint8>>();
    final outLen = calloc<Size>();
    try {
      final status = _b.secureRead(_engine, namePtr.cast<Char>(), outPtr, outLen);
      if (status == ZiaStatus.errSessionNotFound) return null; // jamais écrit
      if (status != ZiaStatus.ok) {
        throw ZiaCryptoException.fromStatus(status, _lastError());
      }
      return _copyAndFree(outPtr.value, outLen.value);
    } finally {
      malloc.free(namePtr);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  void closeSession(NativeSession session) => session.close(_b.sessionClose);

  void dispose() => _b.engineShutdown(_engine);

  // ---- Helpers de marshalling ----

  NativeSession _wrapSession(Pointer<ZiaSession> p) =>
      NativeSession._(p, _finalizer);

  void _check(int status) {
    if (status != ZiaStatus.ok) {
      throw ZiaCryptoException.fromStatus(status, _lastError());
    }
  }

  String? _lastError() {
    final p = _b.lastError(_engine);
    if (p == nullptr) return null;
    final msg = p.cast<Utf8>().toDartString();
    return msg.isEmpty ? null : msg;
  }

  Pointer<Uint8> _toNative(Uint8List data) {
    final ptr = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    if (data.isNotEmpty) ptr.asTypedList(data.length).setAll(0, data);
    return ptr;
  }

  /// Copie un buffer natif dans une [Uint8List] Dart détachée de la mémoire native.
  Uint8List _copyOut(Pointer<Uint8> ptr, int len) =>
      Uint8List.fromList(ptr.asTypedList(len));

  /// Copie un buffer alloué par le moteur, puis le libère via `zia_free_buffer`
  /// (qui efface la mémoire avant de la rendre).
  Uint8List _copyAndFree(Pointer<Uint8> ptr, int len) {
    final copy = Uint8List.fromList(ptr.asTypedList(len));
    _b.freeBuffer(ptr, len);
    return copy;
  }

  Uint8List _arrayToList(Array<Uint8> arr, int len) {
    final out = Uint8List(len);
    for (var i = 0; i < len; i++) {
      out[i] = arr[i];
    }
    return out;
  }

  void _listToArray(Uint8List list, Array<Uint8> arr, int len) {
    for (var i = 0; i < len; i++) {
      arr[i] = list[i];
    }
  }
}
