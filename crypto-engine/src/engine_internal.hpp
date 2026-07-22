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

/* Clé de message d'un groupe reçue hors séquence, conservée pour plus tard.
   Sans ce cache, un message arrivé en retard serait indéchiffrable à jamais. */
struct ZiaSenderSkippedKey {
    uint32_t iteration;
    zia::crypto::SecureBuffer key;
};

/* État d'une clé d'expéditeur pour un groupe.
   `sender_id` vide désigne la NÔTRE : c'est la seule pour laquelle on détient
   la clé de signature privée. Pour les autres membres on ne garde que leur clé
   publique — de quoi vérifier, jamais de quoi forger en leur nom. */
struct ZiaSenderKey {
    std::string group_id;
    std::string sender_id;
    zia::crypto::SecureBuffer chain_key;
    uint32_t iteration = 0;
    uint8_t signing_public[32] = {};
    zia::crypto::SecureBuffer signing_private; /* vide chez les pairs */
    std::vector<ZiaSenderSkippedKey> skipped;
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

    /* Clés d'expéditeur des groupes : la nôtre et celles des membres. */
    std::vector<ZiaSenderKey> sender_keys;
};
