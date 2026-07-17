#include "zia/zia_crypto.h"
#include "engine_internal.hpp"

#include <sodium.h>
#include <cstdlib>

ZIA_API ZiaEngine* zia_engine_init(const char* storage_path, ZiaStatus* out_status) {
    if (sodium_init() < 0) {
        if (out_status) *out_status = ZIA_ERR_CRYPTO_FAILURE;
        return nullptr;
    }

    auto* engine = new ZiaEngine();
    engine->storage_path = storage_path ? storage_path : "";
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
