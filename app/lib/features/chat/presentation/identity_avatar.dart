import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Avatar dérivé de la clé d'identité d'un contact.
///
/// La couleur et le motif viennent des octets de la clé publique, pas du pseudo.
/// Conséquence utile : **si la clé change, l'avatar change**. Un contact dont
/// l'apparence se transforme du jour au lendemain est un signal visuel — il
/// double la bannière d'alerte, pour les gens qui ne lisent pas les bannières.
///
/// Ce n'est pas une preuve : deux clés peuvent tomber sur des couleurs proches.
/// C'est un indice, à côté du numéro de sécurité qui, lui, prouve.
class IdentityAvatar extends StatelessWidget {
  const IdentityAvatar({
    super.key,
    required this.label,
    this.identityKey,
    this.size = 40,
    this.isGroup = false,
  });

  /// Sert à l'initiale affichée.
  final String label;

  /// Clé publique du contact. Null (contact inconnu) : on retombe sur le
  /// pseudo, qui n'a pas la propriété de détection mais reste lisible.
  final Uint8List? identityKey;

  final double size;
  final bool isGroup;

  /// Deux couleurs stables tirées de la clé, pour un dégradé reconnaissable.
  (Color, Color) get _couleurs {
    final source = identityKey;
    int h1, h2;
    if (source != null && source.length >= 4) {
      h1 = (source[0] << 8) | source[1];
      h2 = (source[2] << 8) | source[3];
    } else {
      // Repli sur le pseudo : somme simple, suffisante pour distinguer.
      var acc = 0;
      for (final c in label.codeUnits) {
        acc = (acc * 31 + c) & 0xffff;
      }
      h1 = acc;
      h2 = (acc * 7) & 0xffff;
    }
    // Teintes bien séparées, saturation et luminosité contenues pour rester
    // lisible en clair comme en sombre.
    final teinte1 = (h1 % 360).toDouble();
    final teinte2 = ((teinte1 + 25 + (h2 % 40)) % 360).toDouble();
    return (
      HSLColor.fromAHSL(1, teinte1, 0.55, 0.45).toColor(),
      HSLColor.fromAHSL(1, teinte2, 0.60, 0.35).toColor(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final (c1, c2) = _couleurs;
    final initiale = label.trim().isEmpty
        ? '?'
        : label.trim().characters.first.toUpperCase();

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [c1, c2],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: isGroup
          ? Icon(Icons.groups_rounded, size: size * 0.5, color: Colors.white)
          : Text(
              initiale,
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.42,
                fontWeight: FontWeight.w600,
              ),
            ),
    );
  }
}
