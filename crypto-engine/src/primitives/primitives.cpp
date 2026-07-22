#include "primitives.hpp"

#include <sodium.h>
#include <oqs/oqs.h>
#include <cstring>
#include <algorithm>

namespace zia::crypto::primitives {

void ed25519_keypair(uint8_t out_pub[kPublicKeyLen], SecureBuffer& out_priv) {
    out_priv = SecureBuffer(crypto_sign_SECRETKEYBYTES);
    crypto_sign_keypair(out_pub, out_priv.data());
}

void ed25519_sign(const SecureBuffer& priv, const uint8_t* msg, size_t msg_len,
                   uint8_t out_sig[kSignatureLen]) {
    crypto_sign_detached(out_sig, nullptr, msg, msg_len, priv.data());
}

bool ed25519_verify(const uint8_t pub[kPublicKeyLen], const uint8_t* msg, size_t msg_len,
                     const uint8_t sig[kSignatureLen]) {
    return crypto_sign_verify_detached(sig, msg, msg_len, pub) == 0;
}

void x25519_keypair(uint8_t out_pub[kPublicKeyLen], SecureBuffer& out_priv) {
    out_priv = SecureBuffer(crypto_box_SECRETKEYBYTES);
    crypto_box_keypair(out_pub, out_priv.data());
}

bool x25519_scalarmult(const SecureBuffer& priv, const uint8_t pub[kPublicKeyLen],
                        uint8_t out_shared[kSharedSecretLen]) {
    return crypto_scalarmult(out_shared, priv.data(), pub) == 0;
}

bool ed25519_to_x25519_public(const uint8_t ed_pub[kPublicKeyLen], uint8_t out_x_pub[kPublicKeyLen]) {
    return crypto_sign_ed25519_pk_to_curve25519(out_x_pub, ed_pub) == 0;
}

bool ed25519_to_x25519_private(const SecureBuffer& ed_priv, SecureBuffer& out_x_priv) {
    out_x_priv = SecureBuffer(crypto_box_SECRETKEYBYTES);
    return crypto_sign_ed25519_sk_to_curve25519(out_x_priv.data(), ed_priv.data()) == 0;
}

// RFC 5869 (HKDF), construit à la main à partir de HMAC-SHA256 (crypto_auth_hmacsha256_*) :
// crypto_kdf_hkdf_sha256_* n'est pas disponible sur toutes les versions/distributions
// de libsodium ciblées par le projet (absent de la 1.0.18 empaquetée par certaines
// distros), alors que HMAC-SHA256 est stable depuis la toute première version.
// HKDF n'est pas une primitive en soi : c'est un usage normalisé de HMAC (RFC 5869),
// exactement comme le Double Ratchet est une orchestration d'AEAD/DH — rien n'est
// « inventé » ici, seule la primitive HMAC vient de libsodium.
void hkdf_sha256(const uint8_t* salt, size_t salt_len, const uint8_t* ikm, size_t ikm_len,
                  const char* info, uint8_t* out, size_t out_len) {
    // Extract : PRK = HMAC-SHA256(salt, IKM)
    uint8_t prk[crypto_auth_hmacsha256_BYTES];
    crypto_auth_hmacsha256_state extract_state;
    crypto_auth_hmacsha256_init(&extract_state, salt, salt_len);
    crypto_auth_hmacsha256_update(&extract_state, ikm, ikm_len);
    crypto_auth_hmacsha256_final(&extract_state, prk);

    // Expand : T(i) = HMAC-SHA256(PRK, T(i-1) || info || i), OKM = T(1) || T(2) || ...
    const size_t info_len = std::strlen(info);
    uint8_t t_prev[crypto_auth_hmacsha256_BYTES];
    size_t t_prev_len = 0;
    size_t generated = 0;
    uint8_t counter = 1;

    while (generated < out_len) {
        crypto_auth_hmacsha256_state expand_state;
        crypto_auth_hmacsha256_init(&expand_state, prk, sizeof(prk));
        if (t_prev_len > 0) {
            crypto_auth_hmacsha256_update(&expand_state, t_prev, t_prev_len);
        }
        crypto_auth_hmacsha256_update(&expand_state, reinterpret_cast<const unsigned char*>(info), info_len);
        crypto_auth_hmacsha256_update(&expand_state, &counter, 1);

        uint8_t t_cur[crypto_auth_hmacsha256_BYTES];
        crypto_auth_hmacsha256_final(&expand_state, t_cur);

        size_t chunk = std::min<size_t>(sizeof(t_cur), out_len - generated);
        std::memcpy(out + generated, t_cur, chunk);
        generated += chunk;

        std::memcpy(t_prev, t_cur, sizeof(t_cur));
        t_prev_len = sizeof(t_cur);
        counter += 1;
        sodium_memzero(t_cur, sizeof(t_cur));
    }

    sodium_memzero(prk, sizeof(prk));
    sodium_memzero(t_prev, sizeof(t_prev));
}

void hmac_sha256(const SecureBuffer& key, uint8_t single_byte_input, uint8_t out[32]) {
    crypto_auth_hmacsha256(out, &single_byte_input, 1, key.data());
}

bool aead_encrypt(const SecureBuffer& key, const uint8_t nonce[kAeadNonceLen],
                   const uint8_t* plaintext, size_t plaintext_len,
                   const uint8_t* ad, size_t ad_len,
                   uint8_t* out_ciphertext) {
    unsigned long long clen = 0;
    int rc = crypto_aead_chacha20poly1305_ietf_encrypt(
        out_ciphertext, &clen, plaintext, plaintext_len, ad, ad_len, nullptr, nonce, key.data());
    return rc == 0;
}

bool aead_decrypt(const SecureBuffer& key, const uint8_t nonce[kAeadNonceLen],
                   const uint8_t* ciphertext, size_t ciphertext_len,
                   const uint8_t* ad, size_t ad_len,
                   uint8_t* out_plaintext) {
    unsigned long long mlen = 0;
    int rc = crypto_aead_chacha20poly1305_ietf_decrypt(
        out_plaintext, &mlen, nullptr, ciphertext, ciphertext_len, ad, ad_len, nonce, key.data());
    return rc == 0;
}

/* ---- ML-KEM-768, via liboqs ----
   Les tailles sont vérifiées à la compilation contre celles annoncées par
   liboqs : si une version future les changeait, le code refuserait de compiler
   plutôt que de tronquer une clé en silence. */
static_assert(kPqPublicKeyLen == OQS_KEM_ml_kem_768_length_public_key);
static_assert(kPqSecretKeyLen == OQS_KEM_ml_kem_768_length_secret_key);
static_assert(kPqCiphertextLen == OQS_KEM_ml_kem_768_length_ciphertext);
static_assert(kSharedSecretLen == OQS_KEM_ml_kem_768_length_shared_secret);

void mlkem768_keypair(uint8_t out_pub[kPqPublicKeyLen], SecureBuffer& out_priv) {
    out_priv = SecureBuffer(kPqSecretKeyLen);
    if (OQS_KEM_ml_kem_768_keypair(out_pub, out_priv.data()) != OQS_SUCCESS) {
        // Un échec ici signifie que la source d'aléa est indisponible : il ne
        // faut SURTOUT pas laisser une clé à moitié écrite passer pour valide.
        sodium_memzero(out_pub, kPqPublicKeyLen);
        out_priv = SecureBuffer();
    }
}

bool mlkem768_encapsulate(const uint8_t pub[kPqPublicKeyLen],
                           uint8_t out_ciphertext[kPqCiphertextLen],
                           uint8_t out_shared[kSharedSecretLen]) {
    return OQS_KEM_ml_kem_768_encaps(out_ciphertext, out_shared, pub) == OQS_SUCCESS;
}

bool mlkem768_decapsulate(const SecureBuffer& priv,
                           const uint8_t ciphertext[kPqCiphertextLen],
                           uint8_t out_shared[kSharedSecretLen]) {
    if (priv.size() != kPqSecretKeyLen) return false;
    // ML-KEM ne signale PAS un chiffré invalide : par construction (FO
    // implicite), il renvoie un secret pseudo-aléatoire différent. C'est voulu
    // — l'échec se manifeste plus loin, quand les deux côtés ne dérivent pas la
    // même clé et que le déchiffrement du premier message rate.
    return OQS_KEM_ml_kem_768_decaps(out_shared, ciphertext, priv.data()) == OQS_SUCCESS;
}

} // namespace zia::crypto::primitives
