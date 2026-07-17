#include "zia/zia_crypto.h"
#include "engine_internal.hpp"
#include "primitives/primitives.hpp"

#include <cstring>

using namespace zia::crypto;

ZIA_API ZiaStatus zia_identity_generate(ZiaEngine* engine, uint8_t out_pub[ZIA_PUBLIC_KEY_LEN]) {
    if (!engine || !out_pub) return ZIA_ERR_INVALID_ARG;
    if (engine->has_identity) return ZIA_ERR_ALREADY_INITIALIZED;

    primitives::ed25519_keypair(engine->identity_public, engine->identity_private);
    engine->has_identity = true;
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
