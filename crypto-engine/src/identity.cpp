#include "zia/zia_crypto.h"
#include "engine_internal.hpp"
#include "primitives/primitives.hpp"
#include "storage/identity_store.hpp"

#include <cstring>

using namespace zia::crypto;

ZIA_API ZiaStatus zia_identity_generate(ZiaEngine* engine, uint8_t out_pub[ZIA_PUBLIC_KEY_LEN]) {
    if (!engine || !out_pub) return ZIA_ERR_INVALID_ARG;
    if (engine->has_identity) return ZIA_ERR_ALREADY_INITIALIZED;

    primitives::ed25519_keypair(engine->identity_public, engine->identity_private);
    engine->has_identity = true;

    // On persiste immédiatement pour que l'identité survive au redémarrage.
    // L'échec n'est pas fatal : sans coffre-fort disponible (session sans
    // trousseau, contexte headless, test), l'identité reste utilisable pour
    // cette session — elle ne sera simplement pas retrouvée au prochain
    // démarrage. Refuser tout net rendrait le moteur inutilisable ; on
    // consigne donc l'échec, consultable via zia_last_error().
    if (!storage::save_identity(*engine)) {
        engine->last_error = "identité non persistée (coffre-fort indisponible)";
    } else {
        engine->last_error.clear();
    }

    std::memcpy(out_pub, engine->identity_public, ZIA_PUBLIC_KEY_LEN);
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_identity_get_public_key(ZiaEngine* engine, uint8_t out_pub[ZIA_PUBLIC_KEY_LEN]) {
    if (!engine || !out_pub) return ZIA_ERR_INVALID_ARG;
    if (!engine->has_identity) return ZIA_ERR_NOT_INITIALIZED;
    std::memcpy(out_pub, engine->identity_public, ZIA_PUBLIC_KEY_LEN);
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_identity_sign(ZiaEngine* engine, const uint8_t* msg, size_t msg_len,
                                    uint8_t out_sig[ZIA_SIGNATURE_LEN]) {
    if (!engine || !out_sig || (!msg && msg_len > 0)) return ZIA_ERR_INVALID_ARG;
    if (!engine->has_identity) return ZIA_ERR_NOT_INITIALIZED;
    primitives::ed25519_sign(engine->identity_private, msg, msg_len, out_sig);
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_verify_signature(const uint8_t pub[ZIA_PUBLIC_KEY_LEN], const uint8_t* msg,
                                       size_t msg_len, const uint8_t sig[ZIA_SIGNATURE_LEN]) {
    if (!pub || !sig || (!msg && msg_len > 0)) return ZIA_ERR_INVALID_ARG;
    return primitives::ed25519_verify(pub, msg, msg_len, sig) ? ZIA_OK : ZIA_ERR_SIGNATURE_INVALID;
}
