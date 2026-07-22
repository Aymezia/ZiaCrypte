/**
 * Clés d'expéditeur pour les groupes (« sender keys »).
 *
 * ## Le problème résolu
 *
 * En pair-à-pair, un message de groupe doit être chiffré une fois par appareil
 * destinataire. Le coût croît avec la taille du groupe : dix membres à deux
 * appareils, c'est vingt chiffrements et vingt blobs pour UN message.
 *
 * Ici, l'expéditeur possède une chaîne de clés propre au groupe. Il la
 * distribue une fois à chaque membre — par le canal pair-à-pair déjà chiffré,
 * qui reste donc la racine de confiance — puis chiffre chaque message UNE fois.
 *
 * ## Aucune cryptographie maison
 *
 * Tout repose sur les primitives déjà éprouvées du moteur : HMAC-SHA256 pour
 * faire avancer la chaîne (exactement la construction du ratchet),
 * ChaCha20-Poly1305 IETF pour le chiffrement authentifié, Ed25519 pour la
 * signature. Rien n'est inventé ici : seul l'assemblage est propre au groupe.
 *
 * ## Pourquoi une signature EN PLUS du chiffrement authentifié
 *
 * La clé de groupe est partagée par tous les membres. L'AEAD prouve donc qu'un
 * message vient « de quelqu'un du groupe », pas de QUI. Sans signature, tout
 * membre pourrait forger un message au nom d'un autre. La signature Ed25519 de
 * l'expéditeur rétablit l'imputabilité, et elle est vérifiée AVANT tout
 * déchiffrement : on ne traite pas les octets d'une source non authentifiée.
 *
 * ## Ce que ça ne protège pas
 *
 * Un membre qui reçoit la clé peut lire tout ce qui suit tant qu'elle n'a pas
 * tourné. C'est pourquoi `zia_sender_key_create` doit être rappelé à chaque
 * départ d'un membre : sans rotation, un partant continuerait de lire.
 */
#include "zia/zia_crypto.h"

#include "engine_internal.hpp"
#include "primitives/primitives.hpp"

#include <sodium.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>

using zia::crypto::SecureBuffer;

namespace {

constexpr char kMagicDistribution[8] = {'Z', 'I', 'A', 'S', 'K', 'D', '0', '1'};
constexpr char kMagicMessage[8] = {'Z', 'I', 'A', 'S', 'K', 'M', '0', '1'};

constexpr size_t kMagicLen = 8;
constexpr size_t kChainKeyLen = 32;
constexpr size_t kSignatureLen = 64;
constexpr size_t kDistributionLen = kMagicLen + 4 + kChainKeyLen + 32;

/* Borne du rattrapage hors séquence. Identique en esprit au ratchet : un
   message annonçant une itération lointaine ne doit pas nous faire dériver des
   millions de clés — ce serait un déni de service offert à l'expéditeur. */
constexpr uint32_t kMaxSkip = 2000;
constexpr size_t kMaxSkippedKeys = 2000;

void put_u32(uint8_t* p, uint32_t v) {
    p[0] = static_cast<uint8_t>(v >> 24);
    p[1] = static_cast<uint8_t>(v >> 16);
    p[2] = static_cast<uint8_t>(v >> 8);
    p[3] = static_cast<uint8_t>(v);
}

uint32_t get_u32(const uint8_t* p) {
    return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
           (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
}

/* Avance la chaîne : clé de message = HMAC(ck, 0x01), chaîne suivante =
   HMAC(ck, 0x02). Même construction que le ratchet pair-à-pair. */
void kdf_chain(const SecureBuffer& ck, SecureBuffer& out_next, SecureBuffer& out_mk) {
    uint8_t mk[32], next[32];
    zia::crypto::primitives::hmac_sha256(ck, 0x01, mk);
    zia::crypto::primitives::hmac_sha256(ck, 0x02, next);
    out_mk = SecureBuffer(32);
    out_next = SecureBuffer(32);
    std::memcpy(out_mk.data(), mk, 32);
    std::memcpy(out_next.data(), next, 32);
    sodium_memzero(mk, sizeof(mk));
    sodium_memzero(next, sizeof(next));
}

ZiaSenderKey* trouver(ZiaEngine* engine, const std::string& group, const std::string& sender) {
    auto it = std::find_if(engine->sender_keys.begin(), engine->sender_keys.end(),
                           [&](const ZiaSenderKey& k) {
                               return k.group_id == group && k.sender_id == sender;
                           });
    return it == engine->sender_keys.end() ? nullptr : &*it;
}

void ranger_clef_sautee(ZiaSenderKey& st, uint32_t iteration, SecureBuffer&& key) {
    if (st.skipped.size() >= kMaxSkippedKeys) st.skipped.erase(st.skipped.begin());
    ZiaSenderSkippedKey sk;
    sk.iteration = iteration;
    sk.key = std::move(key);
    st.skipped.push_back(std::move(sk));
}

bool reprendre_clef_sautee(ZiaSenderKey& st, uint32_t iteration, SecureBuffer& out) {
    auto it = std::find_if(st.skipped.begin(), st.skipped.end(),
                           [&](const ZiaSenderSkippedKey& sk) { return sk.iteration == iteration; });
    if (it == st.skipped.end()) return false;
    out = std::move(it->key);
    st.skipped.erase(it);
    return true;
}

} // namespace

ZIA_API ZiaStatus zia_sender_key_create(ZiaEngine* engine, const char* group_id,
                                        uint8_t** out_distribution, size_t* out_len) {
    if (!engine || !group_id || !out_distribution || !out_len) return ZIA_ERR_INVALID_ARG;

    const std::string group(group_id);
    if (group.empty()) return ZIA_ERR_INVALID_ARG;

    SecureBuffer chain(kChainKeyLen);
    randombytes_buf(chain.data(), kChainKeyLen);

    uint8_t sig_pub[32];
    SecureBuffer sig_priv;
    zia::crypto::primitives::ed25519_keypair(sig_pub, sig_priv);

    /* Rotation : on remplace l'état existant. Les clés sautées de l'ancienne
       chaîne n'ont plus d'objet — les garder laisserait déchiffrable ce que la
       rotation est justement censée fermer. */
    ZiaSenderKey* existant = trouver(engine, group, std::string());
    if (existant) {
        existant->chain_key = std::move(chain);
        existant->iteration = 0;
        std::memcpy(existant->signing_public, sig_pub, 32);
        existant->signing_private = std::move(sig_priv);
        existant->skipped.clear();
    } else {
        ZiaSenderKey st;
        st.group_id = group;
        st.sender_id.clear();
        st.chain_key = std::move(chain);
        st.iteration = 0;
        std::memcpy(st.signing_public, sig_pub, 32);
        st.signing_private = std::move(sig_priv);
        engine->sender_keys.push_back(std::move(st));
        existant = &engine->sender_keys.back();
    }

    auto* buf = static_cast<uint8_t*>(malloc(kDistributionLen));
    if (!buf) return ZIA_ERR_OUT_OF_MEMORY;
    std::memcpy(buf, kMagicDistribution, kMagicLen);
    put_u32(buf + kMagicLen, existant->iteration);
    std::memcpy(buf + kMagicLen + 4, existant->chain_key.data(), kChainKeyLen);
    std::memcpy(buf + kMagicLen + 4 + kChainKeyLen, existant->signing_public, 32);

    *out_distribution = buf;
    *out_len = kDistributionLen;
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_sender_key_process(ZiaEngine* engine, const char* group_id,
                                         const char* sender_id,
                                         const uint8_t* distribution, size_t len) {
    if (!engine || !group_id || !sender_id || !distribution) return ZIA_ERR_INVALID_ARG;
    if (len != kDistributionLen) return ZIA_ERR_INVALID_ARG;
    if (sodium_memcmp(distribution, kMagicDistribution, kMagicLen) != 0) return ZIA_ERR_INVALID_ARG;

    const std::string group(group_id);
    const std::string sender(sender_id);
    /* Un identifiant d'expéditeur vide désignerait NOTRE propre clé : accepter
       une distribution sous ce nom laisserait un pair écraser notre chaîne. */
    if (group.empty() || sender.empty()) return ZIA_ERR_INVALID_ARG;

    const uint32_t iteration = get_u32(distribution + kMagicLen);
    SecureBuffer chain(kChainKeyLen);
    std::memcpy(chain.data(), distribution + kMagicLen + 4, kChainKeyLen);

    ZiaSenderKey* st = trouver(engine, group, sender);
    if (!st) {
        ZiaSenderKey nouveau;
        nouveau.group_id = group;
        nouveau.sender_id = sender;
        engine->sender_keys.push_back(std::move(nouveau));
        st = &engine->sender_keys.back();
    } else {
        /* Nouvelle distribution du même membre : sa chaîne a tourné. On repart
           de zéro, anciennes clés sautées comprises. */
        st->skipped.clear();
    }
    st->chain_key = std::move(chain);
    st->iteration = iteration;
    std::memcpy(st->signing_public, distribution + kMagicLen + 4 + kChainKeyLen, 32);
    st->signing_private.reset();
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_sender_key_encrypt(ZiaEngine* engine, const char* group_id,
                                         const uint8_t* plaintext, size_t plaintext_len,
                                         uint8_t** out, size_t* out_len) {
    if (!engine || !group_id || (!plaintext && plaintext_len) || !out || !out_len) {
        return ZIA_ERR_INVALID_ARG;
    }
    const std::string group(group_id);
    ZiaSenderKey* st = trouver(engine, group, std::string());
    if (!st || st->chain_key.size() != kChainKeyLen) return ZIA_ERR_SESSION_NOT_FOUND;

    SecureBuffer next, mk;
    kdf_chain(st->chain_key, next, mk);
    const uint32_t iteration = st->iteration;

    const size_t ct_len = plaintext_len + crypto_aead_chacha20poly1305_ietf_ABYTES;
    const size_t total = kMagicLen + 4 + ct_len + kSignatureLen;
    auto* buf = static_cast<uint8_t*>(malloc(total));
    if (!buf) return ZIA_ERR_OUT_OF_MEMORY;

    std::memcpy(buf, kMagicMessage, kMagicLen);
    put_u32(buf + kMagicLen, iteration);

    /* Le groupe entre dans les données additionnelles : un message ne peut pas
       être rejoué dans un autre groupe, même si la clé y était connue. */
    uint8_t nonce[12] = {0}; /* clé de message à usage unique : nonce fixe sûr */
    const bool ok = zia::crypto::primitives::aead_encrypt(
        mk, nonce, plaintext, plaintext_len,
        reinterpret_cast<const uint8_t*>(group.data()), group.size(), buf + kMagicLen + 4);
    if (!ok) {
        free(buf);
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    /* Signature de l'en-tête ET du chiffré : elle lie l'auteur au message. */
    uint8_t signature[kSignatureLen];
    zia::crypto::primitives::ed25519_sign(st->signing_private, buf, kMagicLen + 4 + ct_len,
                                          signature);
    std::memcpy(buf + kMagicLen + 4 + ct_len, signature, kSignatureLen);

    st->chain_key = std::move(next);
    st->iteration = iteration + 1;

    *out = buf;
    *out_len = total;
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_sender_key_decrypt(ZiaEngine* engine, const char* group_id,
                                         const char* sender_id,
                                         const uint8_t* message, size_t message_len,
                                         uint8_t** out, size_t* out_len) {
    if (!engine || !group_id || !sender_id || !message || !out || !out_len) {
        return ZIA_ERR_INVALID_ARG;
    }
    const size_t entete = kMagicLen + 4;
    if (message_len < entete + crypto_aead_chacha20poly1305_ietf_ABYTES + kSignatureLen) {
        return ZIA_ERR_INVALID_ARG;
    }
    if (sodium_memcmp(message, kMagicMessage, kMagicLen) != 0) return ZIA_ERR_INVALID_ARG;

    const std::string group(group_id);
    ZiaSenderKey* st = trouver(engine, group, std::string(sender_id));
    if (!st || st->chain_key.size() != kChainKeyLen) return ZIA_ERR_SESSION_NOT_FOUND;

    const size_t signe_len = message_len - kSignatureLen;
    const uint8_t* signature = message + signe_len;

    /* Vérification AVANT déchiffrement : on ne fait rien des octets d'un
       expéditeur qu'on n'a pas authentifié. */
    if (!zia::crypto::primitives::ed25519_verify(st->signing_public, message, signe_len,
                                                 signature)) {
        return ZIA_ERR_SIGNATURE_INVALID;
    }

    const uint32_t iteration = get_u32(message + kMagicLen);
    const size_t ct_len = signe_len - entete;

    SecureBuffer mk;
    if (iteration < st->iteration) {
        /* Message en retard : sa clé a peut-être été mise de côté. */
        if (!reprendre_clef_sautee(*st, iteration, mk)) return ZIA_ERR_REPLAY_DETECTED;
    } else {
        if (iteration - st->iteration > kMaxSkip) return ZIA_ERR_SKIPPED_KEY_LIMIT;
        /* Rattrapage : on range les clés intermédiaires pour les messages qui
           arriveront plus tard, puis on dérive celle attendue. */
        while (st->iteration < iteration) {
            SecureBuffer next, saute;
            kdf_chain(st->chain_key, next, saute);
            ranger_clef_sautee(*st, st->iteration, std::move(saute));
            st->chain_key = std::move(next);
            st->iteration += 1;
        }
        SecureBuffer next;
        kdf_chain(st->chain_key, next, mk);
        st->chain_key = std::move(next);
        st->iteration += 1;
    }

    const size_t pt_len = ct_len - crypto_aead_chacha20poly1305_ietf_ABYTES;
    auto* plaintext = static_cast<uint8_t*>(malloc(pt_len ? pt_len : 1));
    if (!plaintext) return ZIA_ERR_OUT_OF_MEMORY;

    uint8_t nonce[12] = {0};
    const bool ok = zia::crypto::primitives::aead_decrypt(
        mk, nonce, message + entete, ct_len,
        reinterpret_cast<const uint8_t*>(group.data()), group.size(), plaintext);
    if (!ok) {
        free(plaintext);
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    *out = plaintext;
    *out_len = pt_len;
    return ZIA_OK;
}
