import 'dart:convert';
import 'dart:typed_data';

/// Clé d'identité d'un appareil correspondant, telle qu'observée la première
/// fois.
///
/// Épingler cette clé est ce qui donne un sens au numéro de sécurité. Sans
/// épinglage, le serveur peut substituer une clé à tout moment et l'application
/// ouvrirait sagement une session avec l'imposteur : l'utilisateur n'aurait
/// aucune raison de rouvrir l'écran de vérification, et le numéro ne servirait
/// jamais.
class ContactIdentity {
  const ContactIdentity({
    required this.deviceId,
    required this.userId,
    required this.identityKey,
    required this.firstSeen,
    this.verified = false,
  });

  final String deviceId;
  final String userId;
  final Uint8List identityKey;

  /// Vrai si l'utilisateur a comparé le numéro de sécurité hors bande et
  /// confirmé qu'il concordait. C'est une affirmation humaine, pas une preuve
  /// cryptographique — l'application ne peut que l'enregistrer.
  final bool verified;

  final DateTime firstSeen;

  ContactIdentity copyWith({bool? verified}) => ContactIdentity(
        deviceId: deviceId,
        userId: userId,
        identityKey: identityKey,
        firstSeen: firstSeen,
        verified: verified ?? this.verified,
      );

  bool hasSameKey(Uint8List other) {
    if (identityKey.length != other.length) return false;
    // Comparaison simple : ces clés sont publiques, aucun secret ne fuit par le
    // temps d'exécution.
    for (var i = 0; i < identityKey.length; i++) {
      if (identityKey[i] != other[i]) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => {
        'd': deviceId,
        'u': userId,
        'k': base64Encode(identityKey),
        'v': verified,
        't': firstSeen.millisecondsSinceEpoch,
      };

  static ContactIdentity fromJson(Map<String, Object?> json) => ContactIdentity(
        deviceId: json['d'] as String,
        userId: json['u'] as String,
        identityKey: base64Decode(json['k'] as String),
        verified: json['v'] as bool? ?? false,
        firstSeen:
            DateTime.fromMillisecondsSinceEpoch((json['t'] as num).toInt()),
      );
}

/// Levée quand la clé d'identité d'un appareil connu a changé.
///
/// Ce n'est pas forcément une attaque : réinstaller l'application régénère
/// l'identité. Mais c'est indiscernable d'une substitution par le serveur, donc
/// l'application refuse d'ouvrir la session et laisse l'utilisateur trancher
/// après comparaison du nouveau numéro de sécurité. Accepter en silence
/// reviendrait à n'avoir aucune vérification.
class IdentityChangedException implements Exception {
  const IdentityChangedException({
    required this.deviceId,
    required this.userId,
    required this.previous,
    required this.current,
  });

  final String deviceId;
  final String userId;
  final Uint8List previous;
  final Uint8List current;

  @override
  String toString() =>
      'La clé d’identité d’un appareil de ce contact a changé. '
      'Cela arrive après une réinstallation, mais c’est aussi ce qu’on '
      'observerait si quelqu’un s’intercalait. Compare le numéro de sécurité '
      'avant de continuer.';
}

/// Un appareil du correspondant, avec le numéro à comparer hors bande.
class DeviceVerification {
  const DeviceVerification({
    required this.identity,
    required this.safetyNumber,
    this.problem,
  });

  final ContactIdentity identity;

  /// 60 chiffres, vide si [problem] est renseigné.
  final String safetyNumber;

  /// Renseigné quand aucun numéro ne peut être calculé, avec l'explication à
  /// montrer. Vaut mieux qu'un numéro absent sans raison, ou qu'une exception
  /// brute affichée à l'utilisateur.
  final String? problem;

  bool get usable => problem == null && safetyNumber.isNotEmpty;

  /// Découpe en 12 groupes de 5 chiffres, comme le fait Signal : lire
  /// soixante chiffres d'affilée au téléphone est une source d'erreurs.
  List<String> get groups => [
        for (var i = 0; i < safetyNumber.length; i += 5)
          safetyNumber.substring(i, i + 5),
      ];
}
