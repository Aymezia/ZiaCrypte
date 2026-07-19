#include "zia/zia_crypto.h"
#include "safety_number_internal.hpp"

#include <sodium.h>

#include <cstring>
#include <string>

/*
 * Numéro de sécurité — vérification de contact.
 *
 * ## Le problème qu'il résout
 *
 * Tout le chiffrement de ZiaCrypte repose sur des clés d'identité récupérées
 * auprès du serveur. Un serveur malveillant (ou saisi, ou compromis) peut
 * servir SA clé au lieu de celle du correspondant, déchiffrer, rechiffrer, et
 * relayer : les deux parties se parlent normalement sans rien remarquer. Aucune
 * quantité de chiffrement ne protège de ça, parce que l'attaque porte sur
 * l'authenticité des clés, pas sur leur confidentialité.
 *
 * Le numéro de sécurité est la sortie de secours : une empreinte des deux clés
 * d'identité, que les correspondants comparent par un canal que le serveur ne
 * contrôle pas — de vive voix, en personne, par QR code. Si les deux nombres
 * concordent, personne ne s'est intercalé.
 *
 * ## L'algorithme
 *
 * Repris de Signal (libsignal, NumericFingerprintGenerator), volontairement à
 * l'identique : c'est un format éprouvé, publiquement analysé, et rien
 * n'invite à inventer ici.
 *
 *   h = version_be16 || clé_publique || identifiant      (concaténation brute)
 *   répéter 5200 fois : h = SHA512( h || clé_publique )
 *   30 premiers octets → 6 groupes de 5 octets → entier 40 bits % 100000
 *
 * Le premier tour part de la concaténation elle-même, non de son condensat :
 * c'est exactement ce que fait libsignal, et la conformité est verrouillée par
 * leur vecteur de test officiel dans safety_number_test.cpp.
 *
 * Les 5200 itérations ne sont pas décoratives : elles renchérissent la
 * recherche d'une seconde paire de clés produisant la même empreinte tronquée.
 * Sans elles, un attaquant pourrait engendrer des clés jusqu'à en trouver une
 * dont les 30 chiffres affichés coïncident avec ceux de sa cible.
 *
 * L'identifiant stable (l'identifiant de compte) entre dans le calcul pour
 * qu'une clé ne puisse pas être rejouée sous un autre compte.
 *
 * Le résultat est symétrique : les deux moitiés sont ordonnées, si bien que les
 * deux correspondants lisent exactement le même nombre sans se concerter sur
 * qui est « local ».
 */

namespace {

constexpr uint16_t kFingerprintVersion = 0;
constexpr int kIterations = 5200;
constexpr size_t kDigitsPerParty = 30;
constexpr size_t kBytesUsed = 30; /* 6 groupes de 5 octets */

} // namespace

/* Empreinte à 30 chiffres d'une seule partie.
 *
 * `key_len` est paramétrable pour que les tests puissent lui soumettre le
 * vecteur officiel de libsignal, dont les clés font 33 octets. L'API publique
 * n'expose que ZIA_PUBLIC_KEY_LEN. */
std::string zia::internal::party_digits(const uint8_t* pub, std::size_t key_len,
                                        const char* identifier) {
    const size_t id_len = identifier ? std::strlen(identifier) : 0;

    /* Valeur de départ : la CONCATÉNATION BRUTE version || clé || identifiant.
     * Elle n'est pas hachée avant d'entrer dans la boucle — c'est bien ce que
     * fait libsignal (`hash = combine(version, publicKey, stableIdentifier)`
     * puis la boucle). Ajouter un SHA-512 initial produirait un nombre
     * différent de celui de Signal, donc un format incompatible pour rien. */
    std::string state_buf;
    state_buf.reserve(2 + key_len + id_len);
    state_buf.push_back(static_cast<char>(kFingerprintVersion >> 8));
    state_buf.push_back(static_cast<char>(kFingerprintVersion & 0xff));
    state_buf.append(reinterpret_cast<const char*>(pub), key_len);
    if (id_len > 0) state_buf.append(identifier, id_len);

    uint8_t hash[crypto_hash_sha512_BYTES];

    /* Premier tour depuis la concaténation, puis itérations sur le condensat.
     * La clé est réinjectée à chaque tour : impossible de précalculer la
     * chaîne indépendamment d'elle. */
    {
        crypto_hash_sha512_state state;
        crypto_hash_sha512_init(&state);
        crypto_hash_sha512_update(
            &state, reinterpret_cast<const uint8_t*>(state_buf.data()),
            state_buf.size());
        crypto_hash_sha512_update(&state, pub, key_len);
        crypto_hash_sha512_final(&state, hash);
    }
    for (int i = 1; i < kIterations; ++i) {
        crypto_hash_sha512_state state;
        crypto_hash_sha512_init(&state);
        crypto_hash_sha512_update(&state, hash, sizeof(hash));
        crypto_hash_sha512_update(&state, pub, key_len);
        crypto_hash_sha512_final(&state, hash);
    }

    /* 6 groupes de 5 octets lus en big-endian, ramenés à 5 chiffres. */
    std::string digits;
    digits.reserve(kDigitsPerParty);
    for (size_t offset = 0; offset < kBytesUsed; offset += 5) {
        uint64_t chunk = 0;
        for (size_t b = 0; b < 5; ++b) {
            chunk = (chunk << 8) | hash[offset + b];
        }
        const uint32_t group = static_cast<uint32_t>(chunk % 100000u);
        char buf[6];
        std::snprintf(buf, sizeof(buf), "%05u", group);
        digits.append(buf, 5);
    }

    sodium_memzero(hash, sizeof(hash));
    return digits;
}

ZIA_API ZiaStatus zia_safety_number(const uint8_t local_pub[ZIA_PUBLIC_KEY_LEN],
                                    const char* local_id,
                                    const uint8_t remote_pub[ZIA_PUBLIC_KEY_LEN],
                                    const char* remote_id,
                                    char out[ZIA_SAFETY_NUMBER_DIGITS + 1]) {
    if (!local_pub || !remote_pub || !out) return ZIA_ERR_INVALID_ARG;

    /* Deux clés identiques signalent une erreur d'appel (on se compare à
     * soi-même) ou une attaque grossière où le serveur a renvoyé notre propre
     * clé comme étant celle du correspondant. Dans les deux cas, refuser. */
    if (sodium_memcmp(local_pub, remote_pub, ZIA_PUBLIC_KEY_LEN) == 0) {
        return ZIA_ERR_INVALID_ARG;
    }

    using zia::internal::party_digits;
    const std::string mine = party_digits(local_pub, ZIA_PUBLIC_KEY_LEN, local_id);
    const std::string theirs = party_digits(remote_pub, ZIA_PUBLIC_KEY_LEN, remote_id);

    /* Ordre déterminé par le contenu, pas par le point de vue : les deux
     * correspondants obtiennent la même chaîne. */
    const std::string combined =
        (mine < theirs) ? (mine + theirs) : (theirs + mine);

    if (combined.size() != ZIA_SAFETY_NUMBER_DIGITS) {
        return ZIA_ERR_CRYPTO_FAILURE;
    }
    std::memcpy(out, combined.data(), ZIA_SAFETY_NUMBER_DIGITS);
    out[ZIA_SAFETY_NUMBER_DIGITS] = '\0';
    return ZIA_OK;
}
