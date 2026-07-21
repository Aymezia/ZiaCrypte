#include "zia/zia_crypto.h"
#include "engine_internal.hpp"

#include <sodium.h>

#include <cstdlib>
#include <cstring>
#include <vector>

/**
 * Expediteur scelle.
 *
 * ## Ce que le serveur voit aujourd'hui, et pourquoi ca compte
 *
 * Le contenu des messages lui est inaccessible, mais il sait QUI ecrit a QUI,
 * quand, et a quelle frequence. Ce graphe suffit tres souvent a en apprendre
 * plus que le contenu : qui parle a un journaliste, a un avocat, a un medecin,
 * et a quelle heure.
 *
 * Pire, le premier message d'une session transporte la cle d'identite de
 * l'expediteur dans son en-tete, en clair pour le serveur. Masquer seulement
 * l'identifiant d'appareil n'aurait donc rien change : il faut envelopper le
 * tout.
 *
 * ## Le choix de la primitive
 *
 * crypto_box_seal de libsodium fait exactement cela : chiffrer a destination
 * d'une cle publique SANS reveler l'expediteur. Elle tire une paire ephemere,
 * en derive un secret partage avec le destinataire, chiffre, puis joint la cle
 * publique ephemere. Rien dans le resultat ne designe son auteur, et deux
 * envois du meme contenu au meme destinataire donnent des octets differents.
 *
 * L'expediteur reste identifie A L'INTERIEUR de l'enveloppe, une fois
 * dechiffree : le destinataire doit savoir qui lui parle. C'est bien le
 * serveur, et lui seul, qu'on aveugle.
 *
 * ## La conversion de cle
 *
 * L'identite est une paire Ed25519, faite pour signer. crypto_box demande du
 * X25519. libsodium fournit la conversion officielle entre les deux, sur la
 * meme courbe sous-jacente : on ne reinvente rien, et surtout on n'introduit
 * pas une seconde identite qu'il faudrait publier, faire verifier et revoquer
 * separement.
 */

using namespace zia::crypto;

ZIA_API ZiaStatus zia_sealed_seal(const uint8_t recipient_identity[ZIA_PUBLIC_KEY_LEN],
                                  const uint8_t* plaintext, size_t plaintext_len,
                                  uint8_t** out, size_t* out_len) {
  if (!recipient_identity || (plaintext_len > 0 && !plaintext) || !out || !out_len) {
    return ZIA_ERR_INVALID_ARG;
  }

  uint8_t curve_pk[crypto_box_PUBLICKEYBYTES];
  if (crypto_sign_ed25519_pk_to_curve25519(curve_pk, recipient_identity) != 0) {
    // Cle publique invalide (hors courbe, ou d'ordre faible) : refusee ici
    // plutot que de produire un chiffre que personne ne pourra ouvrir.
    return ZIA_ERR_INVALID_ARG;
  }

  const size_t sealed_len = plaintext_len + crypto_box_SEALBYTES;
  auto* buffer = static_cast<uint8_t*>(malloc(sealed_len));
  if (!buffer) return ZIA_ERR_OUT_OF_MEMORY;

  if (crypto_box_seal(buffer, plaintext, plaintext_len, curve_pk) != 0) {
    free(buffer);
    return ZIA_ERR_CRYPTO_FAILURE;
  }

  *out = buffer;
  *out_len = sealed_len;
  return ZIA_OK;
}

ZIA_API ZiaStatus zia_sealed_open(ZiaEngine* engine, const uint8_t* sealed,
                                  size_t sealed_len, uint8_t** out,
                                  size_t* out_len) {
  if (!engine || !sealed || !out || !out_len) return ZIA_ERR_INVALID_ARG;
  if (!engine->has_identity) {
    engine->last_error = "aucune identite sur cet appareil";
    return ZIA_ERR_NOT_INITIALIZED;
  }
  if (sealed_len < crypto_box_SEALBYTES) {
    engine->last_error = "enveloppe scellee tronquee";
    return ZIA_ERR_INVALID_ARG;
  }

  uint8_t curve_pk[crypto_box_PUBLICKEYBYTES];
  SecureBuffer curve_sk(crypto_box_SECRETKEYBYTES);
  if (crypto_sign_ed25519_pk_to_curve25519(curve_pk, engine->identity_public) != 0 ||
      crypto_sign_ed25519_sk_to_curve25519(curve_sk.data(),
                                           engine->identity_private.data()) != 0) {
    return ZIA_ERR_CRYPTO_FAILURE;
  }

  const size_t plain_len = sealed_len - crypto_box_SEALBYTES;
  auto* buffer = static_cast<uint8_t*>(malloc(plain_len == 0 ? 1 : plain_len));
  if (!buffer) return ZIA_ERR_OUT_OF_MEMORY;

  if (crypto_box_seal_open(buffer, sealed, sealed_len, curve_pk,
                           curve_sk.data()) != 0) {
    free(buffer);
    // Enveloppe destinee a quelqu'un d'autre, ou alteree. Les deux cas sont
    // indiscernables, et c'est correct : l'authentification ne dit pas
    // laquelle des deux causes s'applique.
    engine->last_error = "enveloppe scellee non destinee a cet appareil, ou alteree";
    return ZIA_ERR_CRYPTO_FAILURE;
  }

  *out = buffer;
  *out_len = plain_len;
  return ZIA_OK;
}
