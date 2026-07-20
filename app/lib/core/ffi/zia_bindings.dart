// GÉNÉRÉ À LA MAIN en attendant ffigen (cf. ffigen.yaml) — reflète exactement
// la surface C de crypto-engine/include/zia/zia_crypto.h. Ne pas diverger du
// header : toute modification de l'API C doit être répercutée ici (ou mieux,
// régénérée via `dart run ffigen`).
//
// ignore_for_file: camel_case_types, non_constant_identifier_names

import 'dart:ffi';

// ---- Tailles fixes (miroir des #define du header) ----
const int ziaPublicKeyLen = 32;
const int ziaSignatureLen = 64;
const int ziaAttachmentKeyLen = 32;

// ---- Codes de statut (miroir de l'enum ZiaStatus) ----
abstract final class ZiaStatus {
  static const int ok = 0;
  static const int errInvalidArg = 1;
  static const int errOutOfMemory = 2;
  static const int errNotInitialized = 3;
  static const int errAlreadyInitialized = 4;
  static const int errStorageIo = 5;
  static const int errCryptoFailure = 6;
  static const int errSessionNotFound = 7;
  static const int errSignatureInvalid = 8;
  static const int errReplayDetected = 9;
  static const int errSkippedKeyLimit = 10;
  static const int errBundleExhausted = 11;
  static const int errNotImplemented = 99;
}

// ---- Handles opaques ----
final class ZiaEngine extends Opaque {}

final class ZiaSession extends Opaque {}

// ---- Structures POD ----
final class ZiaPrekeyBundle extends Struct {
  @Array<Uint8>(ziaPublicKeyLen)
  external Array<Uint8> identity_key;

  @Array<Uint8>(ziaPublicKeyLen)
  external Array<Uint8> signed_prekey;

  @Array<Uint8>(ziaSignatureLen)
  external Array<Uint8> signed_prekey_signature;

  @Array<Uint8>(ziaPublicKeyLen)
  external Array<Uint8> one_time_prekey;

  @Uint8()
  external int has_one_time_prekey;
}

final class ZiaHandshakeMaterial extends Struct {
  @Array<Uint8>(ziaPublicKeyLen)
  external Array<Uint8> initiator_identity_key;

  @Array<Uint8>(ziaPublicKeyLen)
  external Array<Uint8> initiator_ephemeral_key;

  @Array<Uint8>(ziaPublicKeyLen)
  external Array<Uint8> used_one_time_prekey;

  @Uint8()
  external int has_one_time_prekey;
}

/// Table des symboles natifs, résolue une fois à partir d'une [DynamicLibrary].
class ZiaBindings {
  ZiaBindings(DynamicLibrary lib)
      : engineInit = lib.lookupFunction<
            Pointer<ZiaEngine> Function(Pointer<Char>, Pointer<Int32>),
            Pointer<ZiaEngine> Function(
                Pointer<Char>, Pointer<Int32>)>('zia_engine_init'),
        engineShutdown = lib.lookupFunction<Void Function(Pointer<ZiaEngine>),
            void Function(Pointer<ZiaEngine>)>('zia_engine_shutdown'),
        lastError = lib.lookupFunction<
            Pointer<Char> Function(Pointer<ZiaEngine>),
            Pointer<Char> Function(Pointer<ZiaEngine>)>('zia_last_error'),
        freeBuffer = lib.lookupFunction<
            Void Function(Pointer<Uint8>, Size),
            void Function(Pointer<Uint8>, int)>('zia_free_buffer'),
        identityGenerate = lib.lookupFunction<
            Int32 Function(Pointer<ZiaEngine>, Pointer<Uint8>),
            int Function(
                Pointer<ZiaEngine>, Pointer<Uint8>)>('zia_identity_generate'),
        identityGetPublicKey = lib.lookupFunction<
            Int32 Function(Pointer<ZiaEngine>, Pointer<Uint8>),
            int Function(Pointer<ZiaEngine>,
                Pointer<Uint8>)>('zia_identity_get_public_key'),
        identitySign = lib.lookupFunction<
            Int32 Function(
                Pointer<ZiaEngine>, Pointer<Uint8>, Size, Pointer<Uint8>),
            int Function(Pointer<ZiaEngine>, Pointer<Uint8>, int,
                Pointer<Uint8>)>('zia_identity_sign'),
        verifySignature = lib.lookupFunction<
            Int32 Function(
                Pointer<Uint8>, Pointer<Uint8>, Size, Pointer<Uint8>),
            int Function(Pointer<Uint8>, Pointer<Uint8>, int,
                Pointer<Uint8>)>('zia_verify_signature'),
        prekeyBundleGenerate = lib.lookupFunction<
            Int32 Function(Pointer<ZiaEngine>, Pointer<ZiaPrekeyBundle>),
            int Function(Pointer<ZiaEngine>,
                Pointer<ZiaPrekeyBundle>)>('zia_prekey_bundle_generate'),
        prekeyBundleRotate = lib.lookupFunction<
            Int32 Function(Pointer<ZiaEngine>),
            int Function(Pointer<ZiaEngine>)>('zia_prekey_bundle_rotate'),
        sessionFromBundle = lib.lookupFunction<
            Int32 Function(Pointer<ZiaEngine>, Pointer<ZiaPrekeyBundle>,
                Pointer<Pointer<ZiaSession>>, Pointer<ZiaHandshakeMaterial>),
            int Function(
                Pointer<ZiaEngine>,
                Pointer<ZiaPrekeyBundle>,
                Pointer<Pointer<ZiaSession>>,
                Pointer<ZiaHandshakeMaterial>)>('zia_session_from_bundle'),
        sessionAcceptHandshake = lib.lookupFunction<
            Int32 Function(Pointer<ZiaEngine>, Pointer<ZiaHandshakeMaterial>,
                Pointer<Pointer<ZiaSession>>),
            int Function(
                Pointer<ZiaEngine>,
                Pointer<ZiaHandshakeMaterial>,
                Pointer<Pointer<ZiaSession>>)>('zia_session_accept_handshake'),
        sessionEncrypt = lib.lookupFunction<
            Int32 Function(
                Pointer<ZiaSession>,
                Pointer<Uint8>,
                Size,
                Pointer<Pointer<Uint8>>,
                Pointer<Size>,
                Pointer<Pointer<Uint8>>,
                Pointer<Size>),
            int Function(
                Pointer<ZiaSession>,
                Pointer<Uint8>,
                int,
                Pointer<Pointer<Uint8>>,
                Pointer<Size>,
                Pointer<Pointer<Uint8>>,
                Pointer<Size>)>('zia_session_encrypt'),
        sessionDecrypt = lib.lookupFunction<
            Int32 Function(
                Pointer<ZiaSession>,
                Pointer<Uint8>,
                Size,
                Pointer<Uint8>,
                Size,
                Pointer<Pointer<Uint8>>,
                Pointer<Size>),
            int Function(
                Pointer<ZiaSession>,
                Pointer<Uint8>,
                int,
                Pointer<Uint8>,
                int,
                Pointer<Pointer<Uint8>>,
                Pointer<Size>)>('zia_session_decrypt'),
        sessionSerialize = lib.lookupFunction<
            Int32 Function(
                Pointer<ZiaSession>, Pointer<Pointer<Uint8>>, Pointer<Size>),
            int Function(Pointer<ZiaSession>, Pointer<Pointer<Uint8>>,
                Pointer<Size>)>('zia_session_serialize'),
        sessionDeserialize = lib.lookupFunction<
            Int32 Function(Pointer<ZiaEngine>, Pointer<Uint8>, Size,
                Pointer<Pointer<ZiaSession>>),
            int Function(Pointer<ZiaEngine>, Pointer<Uint8>, int,
                Pointer<Pointer<ZiaSession>>)>('zia_session_deserialize'),
        attachmentEncrypt = lib.lookupFunction<
            Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>,
                Pointer<Pointer<Uint8>>, Pointer<Size>),
            int Function(Pointer<Uint8>, int, Pointer<Uint8>,
                Pointer<Pointer<Uint8>>, Pointer<Size>)>('zia_attachment_encrypt'),
        attachmentDecrypt = lib.lookupFunction<
            Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size,
                Pointer<Pointer<Uint8>>, Pointer<Size>),
            int Function(Pointer<Uint8>, Pointer<Uint8>, int,
                Pointer<Pointer<Uint8>>, Pointer<Size>)>('zia_attachment_decrypt'),
        verifyFileSignature = lib.lookupFunction<
            Int32 Function(Pointer<Uint8>, Pointer<Char>, Pointer<Uint8>),
            int Function(Pointer<Uint8>, Pointer<Char>,
                Pointer<Uint8>)>('zia_verify_file_signature'),
        safetyNumber = lib.lookupFunction<
            Int32 Function(Pointer<Uint8>, Pointer<Char>, Pointer<Uint8>,
                Pointer<Char>, Pointer<Char>),
            int Function(Pointer<Uint8>, Pointer<Char>, Pointer<Uint8>,
                Pointer<Char>, Pointer<Char>)>('zia_safety_number'),
        secureWrite = lib.lookupFunction<
            Int32 Function(Pointer<ZiaEngine>, Pointer<Char>, Pointer<Uint8>, Size),
            int Function(Pointer<ZiaEngine>, Pointer<Char>, Pointer<Uint8>,
                int)>('zia_secure_write'),
        secureRead = lib.lookupFunction<
            Int32 Function(Pointer<ZiaEngine>, Pointer<Char>,
                Pointer<Pointer<Uint8>>, Pointer<Size>),
            int Function(Pointer<ZiaEngine>, Pointer<Char>,
                Pointer<Pointer<Uint8>>, Pointer<Size>)>('zia_secure_read'),
        sessionClosePtr = lib.lookup<NativeFinalizerFunction>('zia_session_close'),
        sessionClose = lib.lookupFunction<Void Function(Pointer<ZiaSession>),
            void Function(Pointer<ZiaSession>)>('zia_session_close');

  final Pointer<ZiaEngine> Function(Pointer<Char>, Pointer<Int32>)
      engineInit;
  final void Function(Pointer<ZiaEngine>) engineShutdown;
  final Pointer<Char> Function(Pointer<ZiaEngine>) lastError;
  final void Function(Pointer<Uint8>, int) freeBuffer;
  final int Function(Pointer<ZiaEngine>, Pointer<Uint8>) identityGenerate;
  final int Function(Pointer<ZiaEngine>, Pointer<Uint8>) identityGetPublicKey;
  final int Function(Pointer<ZiaEngine>, Pointer<Uint8>, int, Pointer<Uint8>)
      identitySign;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>)
      verifySignature;
  final int Function(Pointer<ZiaEngine>, Pointer<ZiaPrekeyBundle>)
      prekeyBundleGenerate;
  final int Function(Pointer<ZiaEngine>) prekeyBundleRotate;
  final int Function(Pointer<ZiaEngine>, Pointer<ZiaPrekeyBundle>,
      Pointer<Pointer<ZiaSession>>, Pointer<ZiaHandshakeMaterial>) sessionFromBundle;
  final int Function(Pointer<ZiaEngine>, Pointer<ZiaHandshakeMaterial>,
      Pointer<Pointer<ZiaSession>>) sessionAcceptHandshake;
  final int Function(Pointer<ZiaSession>, Pointer<Uint8>, int,
      Pointer<Pointer<Uint8>>, Pointer<Size>, Pointer<Pointer<Uint8>>,
      Pointer<Size>) sessionEncrypt;
  final int Function(Pointer<ZiaSession>, Pointer<Uint8>, int, Pointer<Uint8>,
      int, Pointer<Pointer<Uint8>>, Pointer<Size>) sessionDecrypt;
  final int Function(
          Pointer<ZiaSession>, Pointer<Pointer<Uint8>>, Pointer<Size>)
      sessionSerialize;
  final int Function(Pointer<ZiaEngine>, Pointer<Uint8>, int,
      Pointer<Pointer<ZiaSession>>) sessionDeserialize;

  final int Function(Pointer<Uint8>, int, Pointer<Uint8>,
      Pointer<Pointer<Uint8>>, Pointer<Size>) attachmentEncrypt;
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int,
      Pointer<Pointer<Uint8>>, Pointer<Size>) attachmentDecrypt;

  /// Vérifie la signature détachée d'un fichier (mise à jour).
  final int Function(Pointer<Uint8>, Pointer<Char>, Pointer<Uint8>)
      verifyFileSignature;

  /// Empreinte des deux clés d'identité (60 chiffres + octet nul).
  final int Function(Pointer<Uint8>, Pointer<Char>, Pointer<Uint8>,
      Pointer<Char>, Pointer<Char>) safetyNumber;

  final int Function(Pointer<ZiaEngine>, Pointer<Char>, Pointer<Uint8>, int)
      secureWrite;
  final int Function(Pointer<ZiaEngine>, Pointer<Char>, Pointer<Pointer<Uint8>>,
      Pointer<Size>) secureRead;

  /// Pointeur natif de `zia_session_close`, pour l'enregistrer auprès d'un
  /// [NativeFinalizer] (libération native même si `close()` est oublié côté Dart).
  /// Typé en [NativeFinalizerFunction] : le finaliseur l'appelle avec le pointeur
  /// de session (ABI pointeur identique — `Pointer<Void>` vs `Pointer<ZiaSession>`).
  final Pointer<NativeFinalizerFunction> sessionClosePtr;
  final void Function(Pointer<ZiaSession>) sessionClose;
}
