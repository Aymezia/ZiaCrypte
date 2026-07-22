/// Bourrage des messages, avant chiffrement.
///
/// ## Ce que la taille raconte
///
/// Le serveur ne peut rien déchiffrer, et depuis l'expéditeur scellé il ne sait
/// même plus toujours qui écrit à qui. Il continue pourtant de voir une chose :
/// **la taille de chaque blob**. Et une taille en dit beaucoup.
///
/// Un accusé de lecture, une annonce de jeton, une distribution de clé de
/// groupe et un « ok » ont chacun une longueur caractéristique, stable, qui les
/// distingue au premier coup d'œil sans rien déchiffrer. Sur un échange suivi,
/// la suite des tailles dessine la forme de la conversation : qui répond court,
/// qui écrit long, où se trouvent les pièces jointes, à quel moment un appareil
/// rejoint le groupe.
///
/// Bourrer à des paliers fixes efface cette granularité. Le coût est borné :
/// **159 octets au pire**, quelle que soit la taille du message.
///
/// ## Pourquoi des espaces plutôt qu'un remplissage classique
///
/// Le remplissage habituel (ISO 7816-4 : un octet `0x80` puis des zéros)
/// oblige le destinataire à savoir le retirer. Les clients déjà installés ne le
/// savent pas : ils afficheraient les octets parasites, ou échoueraient à
/// décoder. Il faudrait alors négocier la capacité entre appareils, donc un
/// aller-retour, donc du code qui ne sert qu'à la transition.
///
/// La charge utile est du JSON, et le JSON autorise le blanc autour de la
/// valeur (RFC 8259, §2). Bourrer avec des espaces produit donc un message que
/// **tout client existant lit déjà correctement**, sans rien savoir du
/// bourrage : `jsonDecode` ignore le blanc de fin. Aucune négociation, aucun
/// changement de format de fil, aucune version à propager.
///
/// Le remplissage voyage à l'intérieur du chiffré : personne d'autre que le
/// destinataire ne peut distinguer un espace de bourrage d'un caractère du
/// message.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Taille du palier, en octets.
///
/// 160, comme Signal. Assez grand pour que les messages de contrôle et les
/// réponses courtes — l'écrasante majorité du trafic — tombent tous dans le
/// même palier ; assez petit pour que le surcoût reste invisible sur une
/// conversation réelle.
const int palierBourrage = 160;

/// Taille visée pour une charge utile de `longueur` octets.
int taillePaliee(int longueur) {
  if (longueur <= 0) return palierBourrage;
  return ((longueur + palierBourrage - 1) ~/ palierBourrage) * palierBourrage;
}

/// Bourre une charge utile JSON jusqu'au palier supérieur.
///
/// L'entrée DOIT être du JSON encodé en UTF-8 : le bourrage n'est transparent
/// que parce que le décodeur JSON ignore le blanc de fin. Appliqué à autre
/// chose — des octets bruts, une image — il corromprait la charge.
Uint8List bourrer(List<int> chargeJsonUtf8) {
  final cible = taillePaliee(chargeJsonUtf8.length);
  final manque = cible - chargeJsonUtf8.length;
  if (manque <= 0) return Uint8List.fromList(chargeJsonUtf8);
  return Uint8List.fromList([
    ...chargeJsonUtf8,
    // L'espace est un octet unique en UTF-8 : le compte d'octets ajoutés est
    // exactement le compte de caractères, sans surprise d'encodage.
    ...utf8.encode(' ' * manque),
  ]);
}
