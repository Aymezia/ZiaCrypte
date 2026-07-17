import 'zia_bindings.dart';

/// Exception de base pour toute erreur remontée par le moteur natif.
///
/// Chaque `ZiaStatus` non-`ok` est traduit en sous-type dédié, pour que le code
/// métier fasse un `catch on` ciblé plutôt que de comparer des entiers.
sealed class ZiaCryptoException implements Exception {
  const ZiaCryptoException(this.status, [this.detail]);

  final int status;

  /// Message non sensible fourni par le moteur (jamais un secret).
  final String? detail;

  @override
  String toString() =>
      '$runtimeType(status: $status${detail != null ? ', $detail' : ''})';

  /// Convertit un code de statut natif en exception typée. Ne jamais appeler
  /// avec `ZiaStatus.ok`.
  static ZiaCryptoException fromStatus(int status, [String? detail]) {
    return switch (status) {
      ZiaStatus.errInvalidArg => ZiaInvalidArgumentException(detail),
      ZiaStatus.errOutOfMemory => ZiaOutOfMemoryException(detail),
      ZiaStatus.errNotInitialized => ZiaNotInitializedException(detail),
      ZiaStatus.errAlreadyInitialized => ZiaAlreadyInitializedException(detail),
      ZiaStatus.errStorageIo => ZiaStorageException(detail),
      ZiaStatus.errCryptoFailure => ZiaCryptoFailureException(detail),
      ZiaStatus.errSessionNotFound => ZiaSessionNotFoundException(detail),
      ZiaStatus.errSignatureInvalid => ZiaSignatureInvalidException(detail),
      ZiaStatus.errReplayDetected => ZiaReplayDetectedException(detail),
      ZiaStatus.errSkippedKeyLimit => ZiaSkippedKeyLimitException(detail),
      ZiaStatus.errBundleExhausted => ZiaBundleExhaustedException(detail),
      ZiaStatus.errNotImplemented => ZiaNotImplementedException(detail),
      _ => ZiaUnknownException(status, detail),
    };
  }
}

final class ZiaInvalidArgumentException extends ZiaCryptoException {
  const ZiaInvalidArgumentException([String? d])
      : super(ZiaStatus.errInvalidArg, d);
}

final class ZiaOutOfMemoryException extends ZiaCryptoException {
  const ZiaOutOfMemoryException([String? d]) : super(ZiaStatus.errOutOfMemory, d);
}

final class ZiaNotInitializedException extends ZiaCryptoException {
  const ZiaNotInitializedException([String? d])
      : super(ZiaStatus.errNotInitialized, d);
}

final class ZiaAlreadyInitializedException extends ZiaCryptoException {
  const ZiaAlreadyInitializedException([String? d])
      : super(ZiaStatus.errAlreadyInitialized, d);
}

final class ZiaStorageException extends ZiaCryptoException {
  const ZiaStorageException([String? d]) : super(ZiaStatus.errStorageIo, d);
}

final class ZiaCryptoFailureException extends ZiaCryptoException {
  const ZiaCryptoFailureException([String? d])
      : super(ZiaStatus.errCryptoFailure, d);
}

final class ZiaSessionNotFoundException extends ZiaCryptoException {
  const ZiaSessionNotFoundException([String? d])
      : super(ZiaStatus.errSessionNotFound, d);
}

final class ZiaSignatureInvalidException extends ZiaCryptoException {
  const ZiaSignatureInvalidException([String? d])
      : super(ZiaStatus.errSignatureInvalid, d);
}

final class ZiaReplayDetectedException extends ZiaCryptoException {
  const ZiaReplayDetectedException([String? d])
      : super(ZiaStatus.errReplayDetected, d);
}

final class ZiaSkippedKeyLimitException extends ZiaCryptoException {
  const ZiaSkippedKeyLimitException([String? d])
      : super(ZiaStatus.errSkippedKeyLimit, d);
}

final class ZiaBundleExhaustedException extends ZiaCryptoException {
  const ZiaBundleExhaustedException([String? d])
      : super(ZiaStatus.errBundleExhausted, d);
}

final class ZiaNotImplementedException extends ZiaCryptoException {
  const ZiaNotImplementedException([String? d])
      : super(ZiaStatus.errNotImplemented, d);
}

final class ZiaUnknownException extends ZiaCryptoException {
  const ZiaUnknownException(super.status, [super.detail]);
}
