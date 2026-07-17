#include "zia/zia_crypto.h"
#include "ratchet/ratchet_state.hpp"
#include "primitives/primitives.hpp"

#include <sodium.h>
#include <cstring>
#include <cstdlib>
#include <algorithm>

using namespace zia::crypto;

namespace {

constexpr size_t kHeaderLen = 4 + 4 + 32; // pn (u32 LE) + n (u32 LE) + dh_public

void write_u32_le(uint8_t* out, uint32_t v) {
    out[0] = static_cast<uint8_t>(v);
    out[1] = static_cast<uint8_t>(v >> 8);
    out[2] = static_cast<uint8_t>(v >> 16);
    out[3] = static_cast<uint8_t>(v >> 24);
}

uint32_t read_u32_le(const uint8_t* in) {
    return static_cast<uint32_t>(in[0]) | (static_cast<uint32_t>(in[1]) << 8) |
           (static_cast<uint32_t>(in[2]) << 16) | (static_cast<uint32_t>(in[3]) << 24);
}

/* Encodage explicite (pas de memcpy de struct) : le header traverse le réseau
 * entre architectures potentiellement différentes (ARM mobile <-> x86 serveur). */
void encode_header(uint32_t pn, uint32_t n, const uint8_t dh_public[32], uint8_t out[kHeaderLen]) {
    write_u32_le(out, pn);
    write_u32_le(out + 4, n);
    std::memcpy(out + 8, dh_public, 32);
}

void decode_header(const uint8_t* in, uint32_t& pn, uint32_t& n, uint8_t dh_public[32]) {
    pn = read_u32_le(in);
    n = read_u32_le(in + 4);
    std::memcpy(dh_public, in + 8, 32);
}

/* KDF_RK : dérive (nouvelle clé racine, clé de chaîne) depuis la sortie DH. */
void kdf_rk(const SecureBuffer& rk, const uint8_t dh_out[32], SecureBuffer& out_rk, SecureBuffer& out_ck) {
    uint8_t both[64];
    primitives::hkdf_sha256(rk.data(), rk.size(), dh_out, 32, "ZiaCrypteRatchetStep", both, 64);
    out_rk = SecureBuffer(32);
    out_ck = SecureBuffer(32);
    std::memcpy(out_rk.data(), both, 32);
    std::memcpy(out_ck.data(), both + 32, 32);
    sodium_memzero(both, sizeof(both));
}

/* KDF_CK : avance une chaîne symétrique, dérive la clé de message associée. */
void kdf_ck(const SecureBuffer& ck, SecureBuffer& out_next_ck, SecureBuffer& out_message_key) {
    uint8_t mk[32], next[32];
    primitives::hmac_sha256(ck, 0x01, mk);
    primitives::hmac_sha256(ck, 0x02, next);
    out_message_key = SecureBuffer(32);
    out_next_ck = SecureBuffer(32);
    std::memcpy(out_message_key.data(), mk, 32);
    std::memcpy(out_next_ck.data(), next, 32);
    sodium_memzero(mk, sizeof(mk));
    sodium_memzero(next, sizeof(next));
}

void store_skipped_key(ZiaSession& s, const uint8_t dh_public[32], uint32_t n, SecureBuffer&& key) {
    if (s.skipped.size() >= ratchet::kMaxSkippedKeys) {
        s.skipped.erase(s.skipped.begin()); // évince la plus ancienne
    }
    ZiaSkippedKey sk;
    std::memcpy(sk.dh_public, dh_public, 32);
    sk.n = n;
    sk.key = std::move(key);
    s.skipped.push_back(std::move(sk));
}

bool take_skipped_key(ZiaSession& s, const uint8_t dh_public[32], uint32_t n, SecureBuffer& out_key) {
    auto it = std::find_if(s.skipped.begin(), s.skipped.end(), [&](const ZiaSkippedKey& sk) {
        return sk.n == n && sodium_memcmp(sk.dh_public, dh_public, 32) == 0;
    });
    if (it == s.skipped.end()) return false;
    out_key = std::move(it->key);
    s.skipped.erase(it);
    return true;
}

/* Dérive et met de côté les clés de message de la chaîne de réception jusqu'à
 * l'index `until` (exclu), pour absorber une livraison hors-ordre. */
ZiaStatus skip_recv_chain_to(ZiaSession& s, uint32_t until) {
    if (!s.has_recv_chain) return ZIA_OK;
    if (until <= s.nr) return ZIA_OK;
    if (until - s.nr > ratchet::kMaxSkippedKeys) return ZIA_ERR_SKIPPED_KEY_LIMIT;
    while (s.nr < until) {
        SecureBuffer next_ck, mk;
        kdf_ck(s.recv_chain_key, next_ck, mk);
        store_skipped_key(s, s.dhr_public, s.nr, std::move(mk));
        s.recv_chain_key = std::move(next_ck);
        s.nr += 1;
    }
    return ZIA_OK;
}

/* Étape de ratchet DH : reçoit une nouvelle clé DH distante, referme la chaîne de
 * réception courante, génère notre propre nouvelle paire DH, referme la chaîne
 * d'envoi. C'est ce qui fournit la Post-Compromise Security. */
void dh_ratchet_step(ZiaSession& s, const uint8_t their_new_dh_public[32]) {
    uint8_t dh_out[32];
    primitives::x25519_scalarmult(s.dhs_private, their_new_dh_public, dh_out);
    SecureBuffer new_rk, new_ckr;
    kdf_rk(s.root_key, dh_out, new_rk, new_ckr);

    s.pn = s.ns;
    s.ns = 0;
    s.nr = 0;
    std::memcpy(s.dhr_public, their_new_dh_public, 32);
    s.has_dhr = true;
    s.recv_chain_key = std::move(new_ckr);
    s.has_recv_chain = true;

    uint8_t new_dhs_pub[32];
    SecureBuffer new_dhs_priv;
    primitives::x25519_keypair(new_dhs_pub, new_dhs_priv);

    uint8_t dh_out2[32];
    primitives::x25519_scalarmult(new_dhs_priv, their_new_dh_public, dh_out2);
    SecureBuffer new_rk2, new_cks;
    kdf_rk(new_rk, dh_out2, new_rk2, new_cks);

    std::memcpy(s.dhs_public, new_dhs_pub, 32);
    s.dhs_private = std::move(new_dhs_priv);
    s.root_key = std::move(new_rk2);
    s.send_chain_key = std::move(new_cks);
    s.has_send_chain = true;

    sodium_memzero(dh_out, sizeof(dh_out));
    sodium_memzero(dh_out2, sizeof(dh_out2));
}

} // namespace

namespace zia::crypto::ratchet {

void init_as_initiator(ZiaSession& session, const uint8_t sk[32], const uint8_t their_initial_dh_public[32]) {
    primitives::x25519_keypair(session.dhs_public, session.dhs_private);
    std::memcpy(session.dhr_public, their_initial_dh_public, 32);
    session.has_dhr = true;

    uint8_t dh_out[32];
    primitives::x25519_scalarmult(session.dhs_private, session.dhr_public, dh_out);

    SecureBuffer rk(32);
    std::memcpy(rk.data(), sk, 32);

    SecureBuffer new_rk, new_cks;
    kdf_rk(rk, dh_out, new_rk, new_cks);
    session.root_key = std::move(new_rk);
    session.send_chain_key = std::move(new_cks);
    session.has_send_chain = true;

    sodium_memzero(dh_out, sizeof(dh_out));
}

void init_as_responder(ZiaSession& session, const uint8_t sk[32],
                        const uint8_t my_initial_dh_public[32], const SecureBuffer& my_initial_dh_private) {
    std::memcpy(session.dhs_public, my_initial_dh_public, 32);
    session.dhs_private = my_initial_dh_private.clone();
    session.has_dhr = false;

    session.root_key = SecureBuffer(32);
    std::memcpy(session.root_key.data(), sk, 32);
    // CKs/CKr restent vides : Bob ne peut chiffrer/déchiffrer qu'après son premier
    // DH ratchet step, déclenché à la réception du premier message d'Alice.
}

} // namespace zia::crypto::ratchet

ZIA_API ZiaStatus zia_session_encrypt(ZiaSession* session, const uint8_t* plaintext, size_t plaintext_len,
                                      uint8_t** out_header, size_t* out_header_len,
                                      uint8_t** out_ciphertext, size_t* out_ciphertext_len) {
    if (!session || !out_header || !out_header_len || !out_ciphertext || !out_ciphertext_len) {
        return ZIA_ERR_INVALID_ARG;
    }
    if (!session->has_send_chain) return ZIA_ERR_SESSION_NOT_FOUND;

    SecureBuffer next_ck, mk;
    kdf_ck(session->send_chain_key, next_ck, mk);

    auto* header = static_cast<uint8_t*>(malloc(kHeaderLen));
    if (!header) return ZIA_ERR_OUT_OF_MEMORY;
    encode_header(session->pn, session->ns, session->dhs_public, header);

    size_t ciphertext_len = plaintext_len + crypto_aead_chacha20poly1305_ietf_ABYTES;
    auto* ciphertext = static_cast<uint8_t*>(malloc(ciphertext_len));
    if (!ciphertext) {
        free(header);
        return ZIA_ERR_OUT_OF_MEMORY;
    }

    // La clé de message n'est utilisée qu'une seule fois puis détruite : un nonce
    // fixe est donc sûr ici (pas de réutilisation clé+nonce possible).
    uint8_t nonce[12] = {0};
    uint8_t ad[64 + kHeaderLen];
    std::memcpy(ad, session->ad, 64);
    std::memcpy(ad + 64, header, kHeaderLen);

    bool ok = primitives::aead_encrypt(mk, nonce, plaintext, plaintext_len, ad, sizeof(ad), ciphertext);
    if (!ok) {
        free(header);
        free(ciphertext);
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    session->send_chain_key = std::move(next_ck);
    session->ns += 1;

    *out_header = header;
    *out_header_len = kHeaderLen;
    *out_ciphertext = ciphertext;
    *out_ciphertext_len = ciphertext_len;
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_session_decrypt(ZiaSession* session,
                                      const uint8_t* header, size_t header_len,
                                      const uint8_t* ciphertext, size_t ciphertext_len,
                                      uint8_t** out_plaintext, size_t* out_plaintext_len) {
    if (!session || !header || header_len != kHeaderLen || !ciphertext ||
        !out_plaintext || !out_plaintext_len) {
        return ZIA_ERR_INVALID_ARG;
    }
    if (ciphertext_len < crypto_aead_chacha20poly1305_ietf_ABYTES) return ZIA_ERR_INVALID_ARG;

    uint32_t pn, n;
    uint8_t dh_public[32];
    decode_header(header, pn, n, dh_public);

    uint8_t ad[64 + kHeaderLen];
    std::memcpy(ad, session->ad, 64);
    std::memcpy(ad + 64, header, kHeaderLen);

    size_t plaintext_len = ciphertext_len - crypto_aead_chacha20poly1305_ietf_ABYTES;
    uint8_t nonce[12] = {0};

    // 1) une clé de message déjà mise de côté (livraison hors-ordre) ?
    SecureBuffer skipped_key;
    if (take_skipped_key(*session, dh_public, n, skipped_key)) {
        auto* plaintext = static_cast<uint8_t*>(malloc(plaintext_len ? plaintext_len : 1));
        if (!plaintext) return ZIA_ERR_OUT_OF_MEMORY;
        if (!primitives::aead_decrypt(skipped_key, nonce, ciphertext, ciphertext_len, ad, sizeof(ad), plaintext)) {
            free(plaintext);
            return ZIA_ERR_CRYPTO_FAILURE;
        }
        *out_plaintext = plaintext;
        *out_plaintext_len = plaintext_len;
        return ZIA_OK;
    }

    // 2) rejeu d'un message déjà consommé normalement (index déjà dépassé) ?
    if (session->has_recv_chain && sodium_memcmp(session->dhr_public, dh_public, 32) == 0 &&
        n < session->nr) {
        return ZIA_ERR_REPLAY_DETECTED;
    }

    // 3) nouvelle clé DH distante : referme la chaîne courante, avance le ratchet
    if (!session->has_dhr || sodium_memcmp(session->dhr_public, dh_public, 32) != 0) {
        ZiaStatus rc = skip_recv_chain_to(*session, pn);
        if (rc != ZIA_OK) return rc;
        dh_ratchet_step(*session, dh_public);
    }

    ZiaStatus rc = skip_recv_chain_to(*session, n);
    if (rc != ZIA_OK) return rc;

    SecureBuffer next_ck, mk;
    kdf_ck(session->recv_chain_key, next_ck, mk);

    auto* plaintext = static_cast<uint8_t*>(malloc(plaintext_len ? plaintext_len : 1));
    if (!plaintext) return ZIA_ERR_OUT_OF_MEMORY;
    if (!primitives::aead_decrypt(mk, nonce, ciphertext, ciphertext_len, ad, sizeof(ad), plaintext)) {
        free(plaintext);
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    session->recv_chain_key = std::move(next_ck);
    session->nr += 1;

    *out_plaintext = plaintext;
    *out_plaintext_len = plaintext_len;
    return ZIA_OK;
}
