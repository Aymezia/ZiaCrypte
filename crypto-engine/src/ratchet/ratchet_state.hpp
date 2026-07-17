#pragma once

#include "zia/zia_crypto.h"
#include "memory/secure_buffer.hpp"
#include <cstdint>
#include <vector>

/* Clé de message mise de côté parce qu'un message est arrivé hors-ordre — cf.
 * Phase 2 §11.2 (plafonnée à kMaxSkippedKeys pour éviter un DoS mémoire). */
struct ZiaSkippedKey {
    uint8_t dh_public[32];
    uint32_t n;
    zia::crypto::SecureBuffer key;
};

/* Définition réelle du handle opaque ZiaSession (état complet du Double Ratchet). */
struct ZiaSession {
    uint8_t ad[64] = {}; // identités des deux parties (immuable pour la session)

    uint8_t dhs_public[32] = {};
    zia::crypto::SecureBuffer dhs_private;

    bool has_dhr = false;
    uint8_t dhr_public[32] = {};

    zia::crypto::SecureBuffer root_key;

    bool has_send_chain = false;
    zia::crypto::SecureBuffer send_chain_key;

    bool has_recv_chain = false;
    zia::crypto::SecureBuffer recv_chain_key;

    uint32_t ns = 0;
    uint32_t nr = 0;
    uint32_t pn = 0;

    std::vector<ZiaSkippedKey> skipped;
};

namespace zia::crypto::ratchet {

constexpr size_t kMaxSkippedKeys = 1000; // cf. Phase 2 §11.2

/* Initialisation côté initiateur (Alice), immédiatement après le calcul de SK
 * via X3DH. `their_initial_dh_public` est le signed prekey public de Bob. */
void init_as_initiator(ZiaSession& session, const uint8_t sk[32],
                        const uint8_t their_initial_dh_public[32]);

/* Initialisation côté répondeur (Bob). Sa paire DH initiale EST sa paire de
 * signed prekey (réutilisable par plusieurs handshakes entrants tant qu'elle
 * n'a pas tourné) — d'où le clone() plutôt qu'un déplacement. */
void init_as_responder(ZiaSession& session, const uint8_t sk[32],
                        const uint8_t my_initial_dh_public[32],
                        const zia::crypto::SecureBuffer& my_initial_dh_private);

} // namespace zia::crypto::ratchet
