#include "zia/zia_crypto.h"
#include "engine_internal.hpp"

#include <sodium.h>

#include <cstdlib>
#include <cstring>

/*
 * Chiffrement des pièces jointes.
 *
 * Le fichier est chiffré sous une clé tirée au hasard, propre à cette pièce
 * jointe. Le ciphertext part chez l'hébergeur de stockage ; la clé, elle, est
 * transmise DANS le message chiffré de bout en bout. L'hébergeur ne détient
 * donc jamais de quoi lire quoi que ce soit — même si le stockage est un
 * service tiers.
 */

ZIA_API ZiaStatus zia_attachment_encrypt(const uint8_t* plaintext, size_t plaintext_len,
                                         uint8_t out_key[ZIA_ATTACHMENT_KEY_LEN],
                                         uint8_t** out_ciphertext, size_t* out_len) {
    if (!out_key || !out_ciphertext || !out_len) return ZIA_ERR_INVALID_ARG;
    if (plaintext_len > 0 && !plaintext) return ZIA_ERR_INVALID_ARG;

    crypto_secretstream_xchacha20poly1305_keygen(out_key);

    uint8_t header[crypto_secretstream_xchacha20poly1305_HEADERBYTES];
    crypto_secretstream_xchacha20poly1305_state state;
    if (crypto_secretstream_xchacha20poly1305_init_push(&state, header, out_key) != 0) {
        sodium_memzero(out_key, ZIA_ATTACHMENT_KEY_LEN);
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    const size_t total =
        sizeof(header) + plaintext_len + crypto_secretstream_xchacha20poly1305_ABYTES;
    auto* buffer = static_cast<uint8_t*>(malloc(total));
    if (!buffer) {
        sodium_memzero(out_key, ZIA_ATTACHMENT_KEY_LEN);
        return ZIA_ERR_OUT_OF_MEMORY;
    }
    std::memcpy(buffer, header, sizeof(header));

    unsigned long long written = 0;
    const int rc = crypto_secretstream_xchacha20poly1305_push(
        &state, buffer + sizeof(header), &written, plaintext, plaintext_len, nullptr, 0,
        crypto_secretstream_xchacha20poly1305_TAG_FINAL);
    if (rc != 0) {
        free(buffer);
        sodium_memzero(out_key, ZIA_ATTACHMENT_KEY_LEN);
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    *out_ciphertext = buffer;
    *out_len = sizeof(header) + static_cast<size_t>(written);
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_attachment_decrypt(const uint8_t key[ZIA_ATTACHMENT_KEY_LEN],
                                         const uint8_t* ciphertext, size_t ciphertext_len,
                                         uint8_t** out_plaintext, size_t* out_len) {
    if (!key || !ciphertext || !out_plaintext || !out_len) return ZIA_ERR_INVALID_ARG;

    constexpr size_t kMin = crypto_secretstream_xchacha20poly1305_HEADERBYTES +
                            crypto_secretstream_xchacha20poly1305_ABYTES;
    if (ciphertext_len < kMin) return ZIA_ERR_INVALID_ARG;

    crypto_secretstream_xchacha20poly1305_state state;
    if (crypto_secretstream_xchacha20poly1305_init_pull(&state, ciphertext, key) != 0) {
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    const uint8_t* body = ciphertext + crypto_secretstream_xchacha20poly1305_HEADERBYTES;
    const size_t body_len =
        ciphertext_len - crypto_secretstream_xchacha20poly1305_HEADERBYTES;
    const size_t plain_capacity =
        body_len - crypto_secretstream_xchacha20poly1305_ABYTES;

    auto* buffer = static_cast<uint8_t*>(malloc(plain_capacity ? plain_capacity : 1));
    if (!buffer) return ZIA_ERR_OUT_OF_MEMORY;

    unsigned long long written = 0;
    uint8_t tag = 0;
    if (crypto_secretstream_xchacha20poly1305_pull(&state, buffer, &written, &tag, body,
                                                   body_len, nullptr, 0) != 0) {
        sodium_memzero(buffer, plain_capacity);
        free(buffer);
        return ZIA_ERR_CRYPTO_FAILURE; // clé fausse ou fichier altéré
    }

    *out_plaintext = buffer;
    *out_len = static_cast<size_t>(written);
    return ZIA_OK;
}
