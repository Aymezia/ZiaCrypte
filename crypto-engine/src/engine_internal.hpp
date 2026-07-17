#pragma once

#include "memory/secure_buffer.hpp"
#include <string>
#include <vector>
#include <optional>
#include <cstdint>

/* État d'un signed prekey : régénéré à chaque rotation (cf. Phase 2 §11.5). */
struct ZiaSignedPrekey {
    uint8_t public_key[32];
    zia::crypto::SecureBuffer private_key;
    uint8_t signature[64];
};

/* One-time prekey : consommée une seule fois par un handshake entrant. */
struct ZiaOneTimePrekey {
    uint8_t public_key[32];
    zia::crypto::SecureBuffer private_key;
    bool consumed = false;
};

/* Définition réelle du handle opaque ZiaEngine, invisible au-delà de la frontière FFI. */
struct ZiaEngine {
    std::string storage_path;
    std::string last_error;

    bool has_identity = false;
    uint8_t identity_public[32] = {};
    zia::crypto::SecureBuffer identity_private;

    std::optional<ZiaSignedPrekey> signed_prekey;
    std::vector<ZiaOneTimePrekey> one_time_prekeys;
};
