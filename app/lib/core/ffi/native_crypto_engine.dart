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
        pqPrekey: b.has_pq_prekey != 0
            ? _arrayToList(b.pq_prekey, ziaPqPublicKeyLen)
            : null,
        pqPrekeySignature: b.has_pq_prekey != 0
            ? _arrayToList(b.pq_prekey_signature, ziaSignatureLen)
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
      // Les deux champs PQ vont ensemble : une clé sans sa signature ne peut
      // pas être vérifiée, et le moteur la refuserait de toute façon.
      if (theirBundle.pqPrekey != null && theirBundle.pqPrekeySignature != null) {
        _listToArray(theirBundle.pqPrekey!, b.pq_prekey, ziaPqPublicKeyLen);
        _listToArray(theirBundle.pqPrekeySignature!, b.pq_prekey_signature,
            ziaSignatureLen);
        b.has_pq_prekey = 1;
      } else {
        b.has_pq_prekey = 0;
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
        pqCiphertext: h.has_pq != 0
            ? _arrayToList(h.pq_ciphertext, ziaPqCiphertextLen)
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
      if (handshake.pqCiphertext != null) {
        _listToArray(handshake.pqCiphertext!, h.pq_ciphertext, ziaPqCiphertextLen);
        h.has_pq = 1;
      } else {
        h.has_pq = 0;
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

  // ---- Mise à jour signée ----

  /// Vrai si [filePath] porte bien la signature de [publicKey].
  ///
  /// Le hachage se fait en flux dans le moteur : un artefact de plusieurs
  /// dizaines de mégaoctets n'est jamais chargé en mémoire côté Dart, et
  /// aucune cryptographie n'y est faite.
  bool verifyFileSignature({
    required Uint8List publicKey,
    required String filePath,
    required Uint8List signature,
  }) {
    final pk = _toNative(publicKey);
    final sig = _toNative(signature);
    final path = filePath.toNativeUtf8();
    try {
      final status = _b.verifyFileSignature(pk, path.cast<Char>(), sig);
      return status == 0; // ZIA_OK
    } finally {
      calloc.free(pk);
      calloc.free(sig);
      malloc.free(path);
    }
  }

  // ---- Sauvegarde exportable ----

  /// Produit une sauvegarde chiffrée sous [passphrase] (Argon2id).
  ///
  /// Contient l'identité, les prekeys et le coffre local. Le fichier peut être
  /// copié et emporté : sa solidité ne tient plus qu'à la phrase choisie, et
  /// l'interface doit le dire sans détour.
  Uint8List backupExport(String passphrase) {
    final phrase = passphrase.toNativeUtf8();
    final outPtr = calloc<Pointer<Uint8>>();
    final outLen = calloc<Size>();
    try {
      _check(_b.backupExport(_engine, phrase.cast<Char>(), outPtr, outLen));
      return _copyAndFree(outPtr.value, outLen.value);
    } finally {
      malloc.free(phrase);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  /// Restaure une sauvegarde dans CE moteur.
  ///
  /// Échoue si la phrase est incorrecte OU si le fichier a été altéré : les
  /// deux sont indiscernables, et c'est voulu — l'authentification du chiffré
  /// ne dit pas laquelle des deux causes s'applique.
  void backupImport(String passphrase, Uint8List data) {
    final phrase = passphrase.toNativeUtf8();
    final input = _toNative(data);
    try {
      _check(_b.backupImport(_engine, phrase.cast<Char>(), input, data.length));
    } finally {
      malloc.free(phrase);
      calloc.free(input);
    }
  }

  // ---- Expéditeur scellé ----

  /// Scelle [plaintext] à destination de [recipientIdentity].
  ///
  /// Rien dans le résultat ne désigne l'expéditeur, et deux appels sur le même
  /// contenu donnent des octets différents — sans quoi le serveur relierait
  /// les messages entre eux.
  Uint8List sealedSeal(Uint8List recipientIdentity, Uint8List plaintext) {
    final pk = _toNative(recipientIdentity);
    final input = _toNative(plaintext);
    final outPtr = calloc<Pointer<Uint8>>();
    final outLen = calloc<Size>();
    try {
      _check(_b.sealedSeal(pk, input, plaintext.length, outPtr, outLen));
      return _copyAndFree(outPtr.value, outLen.value);
    } finally {
      calloc.free(pk);
      calloc.free(input);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  // ------------------------------------------------- clés d'expéditeur (groupes)

  /// Crée (ou fait tourner) notre clé d'expéditeur pour [groupId] et renvoie le
  /// message de distribution à transmettre à chaque membre par le canal chiffré.
  ///
  /// À rappeler quand un membre part : sans rotation, il continuerait de lire.
  Uint8List senderKeyCreate(String groupId) {
    final g = groupId.toNativeUtf8();
    final outPtr = calloc<Pointer<Uint8>>();
    final outLen = calloc<Size>();
    try {
      _check(_b.senderKeyCreate(_engine, g.cast<Char>(), outPtr, outLen));
      return _copyAndFree(outPtr.value, outLen.value);
    } finally {
      calloc.free(g);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  /// Enregistre la clé d'expéditeur d'un membre, reçue par le canal chiffré.
  void senderKeyProcess(String groupId, String senderId, Uint8List distribution) {
    final g = groupId.toNativeUtf8();
    final sid = senderId.toNativeUtf8();
    final input = _toNative(distribution);
    try {
      _check(_b.senderKeyProcess(
          _engine, g.cast<Char>(), sid.cast<Char>(), input, distribution.length));
    } finally {
      calloc.free(g);
      calloc.free(sid);
      calloc.free(input);
    }
  }

  /// Chiffre UNE seule fois pour tout le groupe.
  Uint8List senderKeyEncrypt(String groupId, Uint8List plaintext) {
    final g = groupId.toNativeUtf8();
    final input = _toNative(plaintext);
    final outPtr = calloc<Pointer<Uint8>>();
    final outLen = calloc<Size>();
    try {
      _check(_b.senderKeyEncrypt(
          _engine, g.cast<Char>(), input, plaintext.length, outPtr, outLen));
      return _copyAndFree(outPtr.value, outLen.value);
    } finally {
      calloc.free(g);
      calloc.free(input);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  /// Déchiffre un message de groupe. La signature de l'auteur est vérifiée
  /// côté moteur AVANT tout déchiffrement.
  Uint8List senderKeyDecrypt(String groupId, String senderId, Uint8List message) {
    final g = groupId.toNativeUtf8();
    final sid = senderId.toNativeUtf8();
    final input = _toNative(message);
    final outPtr = calloc<Pointer<Uint8>>();
    final outLen = calloc<Size>();
    try {
      _check(_b.senderKeyDecrypt(_engine, g.cast<Char>(), sid.cast<Char>(), input,
          message.length, outPtr, outLen));
      return _copyAndFree(outPtr.value, outLen.value);
    } finally {
      calloc.free(g);
      calloc.free(sid);
      calloc.free(input);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  /// Ouvre une enveloppe scellée qui nous est destinée. Échoue si elle vise un
  /// autre appareil OU si elle a été altérée — indiscernables, et c'est correct.
  Uint8List sealedOpen(Uint8List sealed) {
    final input = _toNative(sealed);
    final outPtr = calloc<Pointer<Uint8>>();
    final outLen = calloc<Size>();
    try {
      _check(_b.sealedOpen(_engine, input, sealed.length, outPtr, outLen));
      return _copyAndFree(outPtr.value, outLen.value);
    } finally {
      calloc.free(input);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  // ---- Code de verrouillage ----

  void appLockSet(String code) {
    final c = code.toNativeUtf8();
    try {
      _check(_b.appLockSet(_engine, c.cast<Char>()));
    } finally {
      malloc.free(c);
    }
  }

  /// Vrai si le code correspond. La comparaison se fait en temps constant dans
  /// le moteur : en Dart, elle fuirait par le temps de réponse.
  bool appLockVerify(String code) {
    final c = code.toNativeUtf8();
    try {
      return _b.appLockVerify(_engine, c.cast<Char>()) == 0;
    } finally {
      malloc.free(c);
    }
  }

  bool appLockIsSet() {
    final out = calloc<Int32>();
    try {
      _check(_b.appLockStatus(_engine, out));
      return out.value != 0;
    } finally {
      calloc.free(out);
    }
  }

  void appLockClear() => _check(_b.appLockClear(_engine));

  // ---- Vérification de contact ----

  /// Empreinte à 60 chiffres des deux clés d'identité.
  ///
  /// Calculée par le moteur natif, jamais en Dart. Le résultat est symétrique :
  /// les deux correspondants obtiennent la même chaîne et peuvent la comparer
  /// hors bande, par un canal que le serveur ne contrôle pas.
  String safetyNumber({
    required Uint8List localKey,
    required String localId,
    required Uint8List remoteKey,
    required String remoteId,
  }) {
    final localPtr = _toNative(localKey);
    final remotePtr = _toNative(remoteKey);
    final localIdPtr = localId.toNativeUtf8();
    final remoteIdPtr = remoteId.toNativeUtf8();
    // 60 chiffres + l'octet nul terminal.
    final out = calloc<Uint8>(61);
    try {
      _check(_b.safetyNumber(localPtr, localIdPtr.cast<Char>(), remotePtr,
          remoteIdPtr.cast<Char>(), out.cast<Char>()));
      return out.cast<Utf8>().toDartString();
    } finally {
      calloc.free(localPtr);
      calloc.free(remotePtr);
      malloc.free(localIdPtr);
      malloc.free(remoteIdPtr);
      calloc.free(out);
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
