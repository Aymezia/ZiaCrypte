#include "zia/zia_crypto.h"
#include "engine_internal.hpp"
#include "storage/secure_blob.hpp"

#include <cstdlib>
#include <cstring>
#include <vector>

using namespace zia::crypto;

ZIA_API ZiaStatus zia_secure_write(ZiaEngine* engine, const char* name,
                                   const uint8_t* data, size_t len) {
    if (!engine || !name || (len > 0 && !data)) return ZIA_ERR_INVALID_ARG;
    if (!storage::secure_write(*engine, name, data, len)) {
        engine->last_error = "écriture dans le coffre local impossible";
        return ZIA_ERR_STORAGE_IO;
    }
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_secure_read(ZiaEngine* engine, const char* name,
                                  uint8_t** out, size_t* out_len) {
    if (!engine || !name || !out || !out_len) return ZIA_ERR_INVALID_ARG;

    std::vector<uint8_t> data;
    if (!storage::secure_read(*engine, name, data)) {
        // Entrée absente : cas normal (rien encore enregistré), pas une panne.
        return ZIA_ERR_SESSION_NOT_FOUND;
    }

    // Un buffer d'au moins 1 octet, pour que l'appelant reçoive toujours un
    // pointeur valide à libérer via zia_free_buffer.
    auto* buffer = static_cast<uint8_t*>(malloc(data.empty() ? 1 : data.size()));
    if (!buffer) return ZIA_ERR_OUT_OF_MEMORY;
    if (!data.empty()) std::memcpy(buffer, data.data(), data.size());

    *out = buffer;
    *out_len = data.size();
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_secure_erase(ZiaEngine* engine, const char* name) {
    if (!engine || !name) return ZIA_ERR_INVALID_ARG;
    return storage::secure_erase(*engine, name) ? ZIA_OK : ZIA_ERR_STORAGE_IO;
}
