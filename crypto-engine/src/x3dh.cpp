#include "zia/zia_crypto.h"
#include "engine_internal.hpp"
#include "primitives/primitives.hpp"
#include "ratchet/ratchet_state.hpp"
#include "storage/identity_store.hpp"

#include <sodium.h>
#include <cstring>
#include <algorithm>

using namespace zia::crypto;

namespace {

/* SK = HKDF(DH1 || DH2 || DH3 [|| DH4]) — cf. spec X3DH. Le sel est fixé à zéro :
 * l'entropie provient entièrement des sorties DH, pas du sel (X3DH standard). */
void derive_shared_secret(const uint8_t* dh1, const uint8_t* dh2, const uint8_t* dh3,
                           const uint8_t* dh4 /* nullable */, uint8_t out_sk[32]) {
    uint8_t ikm[128];
    size_t offset = 0;
    std::memcpy(ikm + offset, dh1, 32); offset += 32;
    std::memcpy(ikm + offset, dh2, 32); offset += 32;
    std::memcpy(ikm + offset, dh3, 32); offset += 32;
    if (dh4) {
        std::memcpy(ikm + offset, dh4, 32);
        offset += 32;
    }
    uint8_t salt[32] = {0};
    primitives::hkdf_sha256(salt, sizeof(salt), ikm, offset, "ZiaCrypteX3DH", out_sk, 32);
    sodium_memzero(ikm, sizeof(ikm));
}

} // namespace

ZIA_API ZiaStatus zia_prekey_bundle_rotate(ZiaEngine* engine) {
    if (!engine) return ZIA_ERR_INVALID_ARG;
    if (!engine->has_identity) return ZIA_ERR_NOT_INITIALIZED;

    ZiaSignedPrekey spk;
    primitives::x25519_keypair(spk.public_key, spk.private_key);
    primitives::ed25519_sign(engine->identity_private, spk.public_key, ZIA_PUBLIC_KEY_LEN, spk.signature);
    engine->signed_prekey = std::move(spk);
    storage::save_identity(*engine);
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_prekey_bundle_generate(ZiaEngine* engine, ZiaPrekeyBundle* out_bundle) {
    if (!engine || !out_bundle) return ZIA_ERR_INVALID_ARG;
    if (!engine->has_identity) return ZIA_ERR_NOT_INITIALIZED;

    if (!engine->signed_prekey.has_value()) {
        ZiaStatus rc = zia_prekey_bundle_rotate(engine);
        if (rc != ZIA_OK) return rc;
    }

    ZiaOneTimePrekey otpk;
    primitives::x25519_keypair(otpk.public_key, otpk.private_key);
    engine->one_time_prekeys.push_back(std::move(otpk));
    // La clé privée de cette prekey sera nécessaire au handshake entrant, même
    // après un redémarrage : on la persiste avant de publier la clé publique.
    storage::save_identity(*engine);

    std::memcpy(out_bundle->identity_key, engine->identity_public, ZIA_PUBLIC_KEY_LEN);
    std::memcpy(out_bundle->signed_prekey, engine->signed_prekey->public_key, ZIA_PUBLIC_KEY_LEN);
    std::memcpy(out_bundle->signed_prekey_signature, engine->signed_prekey->signature, ZIA_SIGNATURE_LEN);
    std::memcpy(out_bundle->one_time_prekey, engine->one_time_prekeys.back().public_key, ZIA_PUBLIC_KEY_LEN);
    out_bundle->has_one_time_prekey = 1;
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_session_from_bundle(ZiaEngine* engine, const ZiaPrekeyBundle* their_bundle,
                                          ZiaSession** out_session, ZiaHandshakeMaterial* out_handshake) {
    if (!engine || !their_bundle || !out_session || !out_handshake) return ZIA_ERR_INVALID_ARG;
    if (!engine->has_identity) return ZIA_ERR_NOT_INITIALIZED;

    if (!primitives::ed25519_verify(their_bundle->identity_key, their_bundle->signed_prekey,
                                     ZIA_PUBLIC_KEY_LEN, their_bundle->signed_prekey_signature)) {
        return ZIA_ERR_SIGNATURE_INVALID;
    }

    uint8_t ik_a_x25519_pub[32];
    uint8_t ik_b_x25519_pub[32];
    SecureBuffer ik_a_x25519_priv;
    if (!primitives::ed25519_to_x25519_public(engine->identity_public, ik_a_x25519_pub) ||
        !primitives::ed25519_to_x25519_private(engine->identity_private, ik_a_x25519_priv) ||
        !primitives::ed25519_to_x25519_public(their_bundle->identity_key, ik_b_x25519_pub)) {
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    uint8_t ek_a_pub[32];
    SecureBuffer ek_a_priv;
    primitives::x25519_keypair(ek_a_pub, ek_a_priv);

    uint8_t dh1[32], dh2[32], dh3[32], dh4[32] = {0};
    bool ok = primitives::x25519_scalarmult(ik_a_x25519_priv, their_bundle->signed_prekey, dh1) &&
              primitives::x25519_scalarmult(ek_a_priv, ik_b_x25519_pub, dh2) &&
              primitives::x25519_scalarmult(ek_a_priv, their_bundle->signed_prekey, dh3);
    if (!ok) return ZIA_ERR_CRYPTO_FAILURE;

    bool use_otpk = their_bundle->has_one_time_prekey != 0;
    if (use_otpk && !primitives::x25519_scalarmult(ek_a_priv, their_bundle->one_time_prekey, dh4)) {
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    uint8_t sk[32];
    derive_shared_secret(dh1, dh2, dh3, use_otpk ? dh4 : nullptr, sk);

    auto* session = new ZiaSession();
    std::memcpy(session->ad, engine->identity_public, ZIA_PUBLIC_KEY_LEN);
    std::memcpy(session->ad + ZIA_PUBLIC_KEY_LEN, their_bundle->identity_key, ZIA_PUBLIC_KEY_LEN);
    ratchet::init_as_initiator(*session, sk, their_bundle->signed_prekey);

    std::memcpy(out_handshake->initiator_identity_key, engine->identity_public, ZIA_PUBLIC_KEY_LEN);
    std::memcpy(out_handshake->initiator_ephemeral_key, ek_a_pub, ZIA_PUBLIC_KEY_LEN);
    if (use_otpk) {
        std::memcpy(out_handshake->used_one_time_prekey, their_bundle->one_time_prekey, ZIA_PUBLIC_KEY_LEN);
    }
    out_handshake->has_one_time_prekey = use_otpk ? 1 : 0;

    sodium_memzero(dh1, sizeof(dh1));
    sodium_memzero(dh2, sizeof(dh2));
    sodium_memzero(dh3, sizeof(dh3));
    sodium_memzero(dh4, sizeof(dh4));
    sodium_memzero(sk, sizeof(sk));

    *out_session = session;
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_session_accept_handshake(ZiaEngine* engine, const ZiaHandshakeMaterial* handshake,
                                               ZiaSession** out_session) {
    if (!engine || !handshake || !out_session) return ZIA_ERR_INVALID_ARG;
    if (!engine->has_identity || !engine->signed_prekey.has_value()) return ZIA_ERR_NOT_INITIALIZED;

    uint8_t ik_b_x25519_pub[32];
    uint8_t ik_a_x25519_pub[32];
    SecureBuffer ik_b_x25519_priv;
    if (!primitives::ed25519_to_x25519_public(engine->identity_public, ik_b_x25519_pub) ||
        !primitives::ed25519_to_x25519_private(engine->identity_private, ik_b_x25519_priv) ||
        !primitives::ed25519_to_x25519_public(handshake->initiator_identity_key, ik_a_x25519_pub)) {
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    uint8_t dh1[32], dh2[32], dh3[32], dh4[32] = {0};
    bool ok = primitives::x25519_scalarmult(engine->signed_prekey->private_key, ik_a_x25519_pub, dh1) &&
              primitives::x25519_scalarmult(ik_b_x25519_priv, handshake->initiator_ephemeral_key, dh2) &&
              primitives::x25519_scalarmult(engine->signed_prekey->private_key,
                                             handshake->initiator_ephemeral_key, dh3);
    if (!ok) return ZIA_ERR_CRYPTO_FAILURE;

    bool use_otpk = handshake->has_one_time_prekey != 0;
    ZiaOneTimePrekey* otpk = nullptr;
    if (use_otpk) {
        auto it = std::find_if(engine->one_time_prekeys.begin(), engine->one_time_prekeys.end(),
            [&](const ZiaOneTimePrekey& k) {
                return !k.consumed && sodium_memcmp(k.public_key, handshake->used_one_time_prekey, 32) == 0;
            });
        if (it == engine->one_time_prekeys.end()) return ZIA_ERR_BUNDLE_EXHAUSTED;
        otpk = &(*it);
        if (!primitives::x25519_scalarmult(otpk->private_key, handshake->initiator_ephemeral_key, dh4)) {
            return ZIA_ERR_CRYPTO_FAILURE;
        }
    }

    uint8_t sk[32];
    derive_shared_secret(dh1, dh2, dh3, use_otpk ? dh4 : nullptr, sk);

    auto* session = new ZiaSession();
    std::memcpy(session->ad, handshake->initiator_identity_key, ZIA_PUBLIC_KEY_LEN);
    std::memcpy(session->ad + ZIA_PUBLIC_KEY_LEN, engine->identity_public, ZIA_PUBLIC_KEY_LEN);
    ratchet::init_as_responder(*session, sk, engine->signed_prekey->public_key,
                                engine->signed_prekey->private_key);

    if (otpk) {
        otpk->consumed = true; // jamais réutilisée, cf. Phase 1 §7.6
        storage::save_identity(*engine); // la consommation doit survivre au redémarrage
    }

    sodium_memzero(dh1, sizeof(dh1));
    sodium_memzero(dh2, sizeof(dh2));
    sodium_memzero(dh3, sizeof(dh3));
    sodium_memzero(dh4, sizeof(dh4));
    sodium_memzero(sk, sizeof(sk));

    *out_session = session;
    return ZIA_OK;
}
