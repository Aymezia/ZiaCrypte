#include "zia/zia_crypto.h"
#include "engine_internal.hpp"
#include "primitives/primitives.hpp"

#include <sodium.h>
#include <cstdlib>
#include <cstring>

/*
 * Canaux de diffusion : sceller la clé de lecture sous le secret du lien.
 *
 * Un canal réutilise entièrement le mécanisme des clés d'expéditeur (cf.
 * sender_keys.cpp). La seule pièce propre au canal est ici : permettre à
 * quiconque détient le lien d'invitation d'obtenir la clé de LECTURE sans avoir
 * jamais eu de session avec l'admin.
 *
 * Le secret du lien joue le rôle de capacité : le posséder suffit à lire, ne
 * pas le posséder rend le blob stocké sur le serveur inexploitable. Le serveur,
 * qui ne voit que ce blob, ne peut donc rien lire — c'est ce qui préserve le
 * zéro-connaissance malgré l'ouverture du canal.
 *
 * On ne réimplémente aucune primitive : dérivation par le HKDF déjà utilisé
 * partout, chiffrement par le XChaCha20-Poly1305 de libsodium (nonce de 192
 * bits, sûr en aléatoire — indispensable puisqu'une rotation re-scelle sous le
 * MÊME secret de lien, et qu'un nonce répété y serait fatal).
 */

using namespace zia::crypto;

namespace {

constexpr size_t kNonceLen = crypto_aead_xchacha20poly1305_ietf_NPUBBYTES; // 24
constexpr size_t kTagLen = crypto_aead_xchacha20poly1305_ietf_ABYTES;      // 16
constexpr size_t kWrapKeyLen = crypto_aead_xchacha20poly1305_ietf_KEYBYTES; // 32

/* Clé de chiffrement du blob, dérivée du secret du lien.
 *
 * On passe par HKDF plutôt que d'employer le secret du lien tel quel : cela
 * sépare l'usage « clé d'enveloppe » de toute autre dérivation qu'on voudrait
 * un jour faire du même secret, et fixe une étiquette de domaine claire. */
void derive_wrap_key(const uint8_t link_secret[ZIA_CHANNEL_LINK_SECRET_LEN],
                     uint8_t out_key[kWrapKeyLen]) {
    const uint8_t salt[32] = {0};
    primitives::hkdf_sha256(salt, sizeof(salt),
                            link_secret, ZIA_CHANNEL_LINK_SECRET_LEN,
                            "ZiaCrypteChannelKeyWrap", out_key, kWrapKeyLen);
}

} // namespace

ZIA_API ZiaStatus zia_channel_seal_key(const uint8_t link_secret[ZIA_CHANNEL_LINK_SECRET_LEN],
                                       const uint8_t* distribution, size_t distribution_len,
                                       uint8_t** out_sealed, size_t* out_len) {
    if (!link_secret || !distribution || !out_sealed || !out_len) return ZIA_ERR_INVALID_ARG;
    if (distribution_len == 0) return ZIA_ERR_INVALID_ARG;

    uint8_t wrap_key[kWrapKeyLen];
    derive_wrap_key(link_secret, wrap_key);

    const size_t total = kNonceLen + distribution_len + kTagLen;
    auto* buf = static_cast<uint8_t*>(malloc(total));
    if (!buf) {
        sodium_memzero(wrap_key, sizeof(wrap_key));
        return ZIA_ERR_OUT_OF_MEMORY;
    }

    // Nonce aléatoire, préfixé au blob : c'est lui qui rend une rotation sous le
    // même secret de lien sûre — deux scellements du même contenu ne se
    // ressemblent pas, et aucun nonce n'est jamais réutilisé.
    randombytes_buf(buf, kNonceLen);

    unsigned long long clen = 0;
    const int rc = crypto_aead_xchacha20poly1305_ietf_encrypt(
        buf + kNonceLen, &clen,
        distribution, distribution_len,
        nullptr, 0,           // pas de données associées
        nullptr, buf /*nonce*/, wrap_key);
    sodium_memzero(wrap_key, sizeof(wrap_key));
    if (rc != 0) {
        free(buf);
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    *out_sealed = buf;
    *out_len = kNonceLen + static_cast<size_t>(clen);
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_channel_open_key(const uint8_t link_secret[ZIA_CHANNEL_LINK_SECRET_LEN],
                                       const uint8_t* sealed, size_t sealed_len,
                                       uint8_t** out_distribution, size_t* out_len) {
    if (!link_secret || !sealed || !out_distribution || !out_len) return ZIA_ERR_INVALID_ARG;
    // Il faut au moins un nonce et un tag ; en dessous, le blob est tronqué et
    // ne peut pas être authentifié.
    if (sealed_len < kNonceLen + kTagLen) return ZIA_ERR_CRYPTO_FAILURE;

    uint8_t wrap_key[kWrapKeyLen];
    derive_wrap_key(link_secret, wrap_key);

    const size_t cipher_len = sealed_len - kNonceLen;
    const size_t plain_max = cipher_len - kTagLen;
    auto* buf = static_cast<uint8_t*>(malloc(plain_max > 0 ? plain_max : 1));
    if (!buf) {
        sodium_memzero(wrap_key, sizeof(wrap_key));
        return ZIA_ERR_OUT_OF_MEMORY;
    }

    unsigned long long mlen = 0;
    const int rc = crypto_aead_xchacha20poly1305_ietf_decrypt(
        buf, &mlen, nullptr,
        sealed + kNonceLen, cipher_len,
        nullptr, 0,
        sealed /*nonce*/, wrap_key);
    sodium_memzero(wrap_key, sizeof(wrap_key));
    if (rc != 0) {
        // Secret erroné, ou blob altéré : dans les deux cas indistinguables, et
        // c'est voulu — on ne dit pas au porteur d'un mauvais lien POURQUOI il
        // échoue. Le tampon partiel est effacé avant d'être libéré.
        sodium_memzero(buf, plain_max);
        free(buf);
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    *out_distribution = buf;
    *out_len = static_cast<size_t>(mlen);
    return ZIA_OK;
}
