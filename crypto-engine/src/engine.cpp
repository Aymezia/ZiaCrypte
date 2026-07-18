#include "zia/zia_crypto.h"
#include "engine_internal.hpp"
#include "storage/identity_store.hpp"

#include <sodium.h>
#include <cstdlib>

ZIA_API ZiaEngine* zia_engine_init(const char* storage_path, ZiaStatus* out_status) {
    if (sodium_init() < 0) {
        if (out_status) *out_status = ZIA_ERR_CRYPTO_FAILURE;
        return nullptr;
    }

    auto* engine = new ZiaEngine();
    engine->storage_path = storage_path ? storage_path : "";

    // Recharge l'identité déjà enregistrée sur cet appareil, s'il y en a une.
    // Son absence est normale au premier lancement : l'appelant génèrera alors
    // une identité, qui sera persistée à son tour.
    zia::crypto::storage::load_identity(*engine);

    if (out_status) *out_status = ZIA_OK;
    return engine;
}

ZIA_API void zia_engine_shutdown(ZiaEngine* engine) {
    delete engine;
}

ZIA_API const char* zia_last_error(ZiaEngine* engine) {
    return engine ? engine->last_error.c_str() : "";
}

ZIA_API void zia_free_buffer(uint8_t* buf, size_t len) {
    if (buf) {
        sodium_memzero(buf, len);
        free(buf);
    }
}
