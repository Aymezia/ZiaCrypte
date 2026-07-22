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

/* SK = HKDF(DH1 || DH2 || DH3 [|| DH4] [|| SS]) — X3DH, étendu par PQXDH.
 *
 * Le sel est fixé à zéro : l'entropie provient entièrement des sorties DH, pas
 * du sel (X3DH standard).
 *
 * `ss` est le secret encapsulé par ML-KEM quand la composante post-quantique
 * est présente. Il s'AJOUTE aux échanges Diffie-Hellman, il ne remplace rien :
 *   - si ML-KEM tombe, il reste exactement la sécurité du X3DH d'aujourd'hui ;
 *   - si X25519 tombe (machine quantique), la composante PQ tient encore.
 * C'est tout l'intérêt d'un schéma hybride, et c'est pourquoi le mode « PQ
 * seul » n'existe pas ici.
 *
 * L'étiquette HKDF diffère selon le mode. Cette séparation de domaine n'est pas
 * cosmétique : elle garantit qu'un handshake classique et un handshake hybride
 * ne peuvent jamais produire la même clé, même si un attaquant parvenait à
 * faire coïncider les entrées. */
void derive_shared_secret(const uint8_t* dh1, const uint8_t* dh2, const uint8_t* dh3,
                           const uint8_t* dh4 /* nullable */,
                           const uint8_t* ss /* nullable */, uint8_t out_sk[32]) {
    uint8_t ikm[160];
    size_t offset = 0;
    std::memcpy(ikm + offset, dh1, 32); offset += 32;
    std::memcpy(ikm + offset, dh2, 32); offset += 32;
    std::memcpy(ikm + offset, dh3, 32); offset += 32;
    if (dh4) {
        std::memcpy(ikm + offset, dh4, 32);
        offset += 32;
    }
    if (ss) {
        std::memcpy(ikm + offset, ss, 32);
        offset += 32;
    }
    uint8_t salt[32] = {0};
    primitives::hkdf_sha256(salt, sizeof(salt), ikm, offset,
                             ss ? "ZiaCryptePQXDH" : "ZiaCrypteX3DH", out_sk, 32);
    sodium_memzero(ikm, sizeof(ikm));
}

} // namespace

ZIA_API ZiaStatus zia_session_require_pq(ZiaEngine* engine, int required) {
    if (!engine) return ZIA_ERR_INVALID_ARG;
    engine->require_pq = required != 0;
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_prekey_bundle_rotate(ZiaEngine* engine) {
    if (!engine) return ZIA_ERR_INVALID_ARG;
    if (!engine->has_identity) return ZIA_ERR_NOT_INITIALIZED;

    ZiaSignedPrekey spk;
    primitives::x25519_keypair(spk.public_key, spk.private_key);
    primitives::ed25519_sign(engine->identity_private, spk.public_key, ZIA_PUBLIC_KEY_LEN, spk.signature);
    engine->signed_prekey = std::move(spk);

    /* La prekey post-quantique suit le même rythme de rotation que le signed
       prekey : deux cadences différentes n'apporteraient rien et donneraient
       deux fenêtres de compromission à raisonner au lieu d'une. */
    ZiaPqPrekey pq;
    primitives::mlkem768_keypair(pq.public_key, pq.private_key);
    if (pq.private_key.size() != primitives::kPqSecretKeyLen) {
        return ZIA_ERR_CRYPTO_FAILURE; // aléa indisponible : on ne publie rien
    }
    primitives::ed25519_sign(engine->identity_private, pq.public_key,
                              primitives::kPqPublicKeyLen, pq.signature);
    engine->pq_prekey = std::move(pq);

    storage::save_identity(*engine);
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_prekey_bundle_generate(ZiaEngine* engine, ZiaPrekeyBundle* out_bundle) {
    if (!engine || !out_bundle) return ZIA_ERR_INVALID_ARG;
    if (!engine->has_identity) return ZIA_ERR_NOT_INITIALIZED;

    if (!engine->signed_prekey.has_value() || !engine->pq_prekey.has_value()) {
        // Couvre aussi la migration d'une identité créée avant PQXDH : elle a
        // un signed prekey mais pas de clé PQ, et la rotation lui en donne une.
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

    std::memcpy(out_bundle->pq_prekey, engine->pq_prekey->public_key,
                primitives::kPqPublicKeyLen);
    std::memcpy(out_bundle->pq_prekey_signature, engine->pq_prekey->signature, ZIA_SIGNATURE_LEN);
    out_bundle->has_pq_prekey = 1;
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

    /* Composante post-quantique. La prekey PQ est vérifiée AVANT d'être
       utilisée : une clé d'encapsulation non signée par l'identité annoncée
       serait exactement le moyen, pour le serveur, de lire ce que le PQ est
       censé protéger. */
    const bool use_pq = their_bundle->has_pq_prekey != 0;
    uint8_t pq_ct[ZIA_PQ_CIPHERTEXT_LEN];
    uint8_t pq_ss[32] = {0};
    if (use_pq) {
        if (!primitives::ed25519_verify(their_bundle->identity_key, their_bundle->pq_prekey,
                                         primitives::kPqPublicKeyLen,
                                         their_bundle->pq_prekey_signature)) {
            return ZIA_ERR_SIGNATURE_INVALID;
        }
        if (!primitives::mlkem768_encapsulate(their_bundle->pq_prekey, pq_ct, pq_ss)) {
            return ZIA_ERR_CRYPTO_FAILURE;
        }
    } else if (engine->require_pq) {
        // Le pair annonce un bundle sans clé PQ alors qu'on exige l'hybride :
        // c'est soit un client non migré, soit un serveur qui a retiré la clé.
        // Les deux se traitent pareil — on n'ouvre pas la session.
        return ZIA_ERR_SIGNATURE_INVALID;
    }

    uint8_t sk[32];
    derive_shared_secret(dh1, dh2, dh3, use_otpk ? dh4 : nullptr, use_pq ? pq_ss : nullptr, sk);

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
    if (use_pq) {
        std::memcpy(out_handshake->pq_ciphertext, pq_ct, ZIA_PQ_CIPHERTEXT_LEN);
    } else {
        std::memset(out_handshake->pq_ciphertext, 0, ZIA_PQ_CIPHERTEXT_LEN);
    }
    out_handshake->has_pq = use_pq ? 1 : 0;

    sodium_memzero(pq_ss, sizeof(pq_ss));
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

    /* Décapsulation post-quantique. ML-KEM ne signale pas un chiffré invalide :
       il rend un secret pseudo-aléatoire, et c'est le déchiffrement du premier
       message qui échouera. Ce silence est celui du schéma, pas du nôtre. */
    const bool use_pq = handshake->has_pq != 0;
    uint8_t pq_ss[32] = {0};
    if (use_pq) {
        if (!engine->pq_prekey.has_value()) return ZIA_ERR_NOT_INITIALIZED;
        if (!primitives::mlkem768_decapsulate(engine->pq_prekey->private_key,
                                               handshake->pq_ciphertext, pq_ss)) {
            return ZIA_ERR_CRYPTO_FAILURE;
        }
    } else if (engine->require_pq) {
        // Repli classique refusé : voir zia_session_require_pq.
        return ZIA_ERR_SIGNATURE_INVALID;
    }

    uint8_t sk[32];
    derive_shared_secret(dh1, dh2, dh3, use_otpk ? dh4 : nullptr, use_pq ? pq_ss : nullptr, sk);
    sodium_memzero(pq_ss, sizeof(pq_ss));

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
