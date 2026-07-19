import 'dart:convert';
import 'dart:typed_data';

import '../../../core/ffi/crypto_isolate.dart';
import '../domain/contact_identity.dart';

/// Registre local des clés d'identité déjà rencontrées (« confiance au premier
/// contact »).
///
/// ## Ce que ça protège, et ce que ça ne protège pas
///
/// L'épinglage détecte tout changement de clé APRÈS le premier contact : si le
/// serveur substitue une clé en cours de route, l'application le voit et refuse
/// d'ouvrir la session.
///
/// Il ne protège PAS du serveur qui mentirait dès le tout premier échange —
/// l'application n'a alors aucun point de comparaison. Seule la confrontation
/// du numéro de sécurité hors bande couvre ce cas. Les deux mécanismes sont
/// complémentaires et aucun ne remplace l'autre : c'est pourquoi les deux sont
/// présents.
///
/// Le registre vit dans le coffre local chiffré du moteur natif, jamais sur le
/// serveur — c'est précisément le serveur dont il faut se prémunir.
class IdentityPinning {
  IdentityPinning(this._engine);

  final ZiaCryptoEngine _engine;
  static const _vaultKey = 'contact_identities';

  final Map<String, ContactIdentity> _known = {};

  Map<String, ContactIdentity> get known => Map.unmodifiable(_known);

  ContactIdentity? forDevice(String deviceId) => _known[deviceId];

  /// Identités connues pour un utilisateur, tous appareils confondus.
  List<ContactIdentity> forUser(String userId) =>
      _known.values.where((i) => i.userId == userId).toList();

  Future<void> load() async {
    final raw = await _engine.vaultRead(_vaultKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(utf8.decode(raw)) as List<dynamic>;
      _known.clear();
      for (final entry in list) {
        final identity =
            ContactIdentity.fromJson((entry as Map).cast<String, Object?>());
        _known[identity.deviceId] = identity;
      }
    } catch (_) {
      // Registre illisible (format changé, fichier tronqué). On repart à vide
      // plutôt que d'empêcher l'application de démarrer : le pire effet est de
      // réépingler au prochain contact, ce que l'utilisateur verra puisque le
      // contact repassera en « non vérifié ».
      _known.clear();
    }
  }

  Future<void> _save() async {
    final data = jsonEncode(_known.values.map((i) => i.toJson()).toList());
    await _engine.vaultWrite(_vaultKey, Uint8List.fromList(utf8.encode(data)));
  }

  /// Confronte une clé annoncée par le serveur à celle déjà connue.
  ///
  /// - Appareil inconnu : la clé est épinglée et acceptée (premier contact).
  /// - Clé identique : rien à faire.
  /// - Clé différente : lève [IdentityChangedException]. L'appelant NE DOIT PAS
  ///   ouvrir de session — c'est le seul moment où une substitution est
  ///   détectable.
  Future<ContactIdentity> checkAndPin({
    required String deviceId,
    required String userId,
    required Uint8List identityKey,
  }) async {
    final existing = _known[deviceId];

    if (existing == null) {
      final pinned = ContactIdentity(
        deviceId: deviceId,
        userId: userId,
        identityKey: identityKey,
        firstSeen: DateTime.now(),
      );
      _known[deviceId] = pinned;
      await _save();
      return pinned;
    }

    if (!existing.hasSameKey(identityKey)) {
      throw IdentityChangedException(
        deviceId: deviceId,
        userId: userId,
        previous: existing.identityKey,
        current: identityKey,
      );
    }

    return existing;
  }

  /// Accepte une nouvelle clé pour un appareil connu, après décision explicite
  /// de l'utilisateur.
  ///
  /// Remet `verified` à faux : la vérification portait sur l'ancienne clé et ne
  /// dit rien de la nouvelle. Reconduire le statut vérifié serait mensonger.
  Future<void> acceptChange({
    required String deviceId,
    required String userId,
    required Uint8List identityKey,
  }) async {
    _known[deviceId] = ContactIdentity(
      deviceId: deviceId,
      userId: userId,
      identityKey: identityKey,
      firstSeen: DateTime.now(),
    );
    await _save();
  }

  /// Enregistre que l'utilisateur a comparé le numéro de sécurité hors bande.
  Future<void> markVerified(String deviceId, {bool verified = true}) async {
    final existing = _known[deviceId];
    if (existing == null) return;
    _known[deviceId] = existing.copyWith(verified: verified);
    await _save();
  }

  /// Numéro de sécurité entre notre identité et celle d'un appareil épinglé.
  ///
  /// Le calcul est délégué au moteur natif : aucune cryptographie en Dart.
  Future<String?> safetyNumber({
    required Uint8List myIdentityKey,
    required String myUserId,
    required String peerDeviceId,
    required String peerUserId,
  }) async {
    final peer = _known[peerDeviceId];
    if (peer == null) return null;
    return _engine.safetyNumber(
      localKey: myIdentityKey,
      localId: myUserId,
      remoteKey: peer.identityKey,
      remoteId: peerUserId,
    );
  }

  Future<void> forget(String deviceId) async {
    if (_known.remove(deviceId) != null) await _save();
  }
}
