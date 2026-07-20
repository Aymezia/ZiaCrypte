#include "zia/zia_crypto.h"

#include <sodium.h>

#include <cstdio>

/*
 * Vérification de la signature d'un fichier de mise à jour.
 *
 * ## Pourquoi c'est ici et pas dans l'application
 *
 * Une mise à jour automatique télécharge du code et le fait exécuter. Sans
 * vérification d'authenticité, quiconque prend le contrôle de l'hébergement —
 * ou s'intercale sur le réseau — obtient l'exécution de code chez TOUS les
 * utilisateurs. Ce serait une porte d'entrée bien plus large que tout ce que le
 * chiffrement des messages protège.
 *
 * TLS ne suffit pas : il protège le transport, pas l'origine. Il oblige à faire
 * confiance à l'hébergeur et à toute autorité de certification. On signe donc
 * les artefacts avec une clé Ed25519 dont la partie publique est intégrée à
 * l'application, et la partie privée reste HORS de tout serveur.
 *
 * ## Pourquoi en flux
 *
 * Un artefact fait des dizaines de mégaoctets. On le hache par blocs plutôt que
 * de le charger entièrement en mémoire — indispensable sur mobile — puis on
 * vérifie la signature sur le condensat.
 */

ZIA_API ZiaStatus zia_verify_file_signature(const uint8_t public_key[ZIA_PUBLIC_KEY_LEN],
                                            const char* path,
                                            const uint8_t signature[ZIA_SIGNATURE_LEN]) {
    if (!public_key || !path || !signature) return ZIA_ERR_INVALID_ARG;

    std::FILE* f = std::fopen(path, "rb");
    if (!f) return ZIA_ERR_STORAGE_IO;

    crypto_hash_sha512_state state;
    if (crypto_hash_sha512_init(&state) != 0) {
        std::fclose(f);
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    unsigned char buffer[64 * 1024];
    size_t lus;
    while ((lus = std::fread(buffer, 1, sizeof(buffer), f)) > 0) {
        if (crypto_hash_sha512_update(&state, buffer, lus) != 0) {
            std::fclose(f);
            sodium_memzero(buffer, sizeof(buffer));
            return ZIA_ERR_CRYPTO_FAILURE;
        }
    }
    const bool lecture_ok = std::ferror(f) == 0;
    std::fclose(f);
    sodium_memzero(buffer, sizeof(buffer));
    if (!lecture_ok) return ZIA_ERR_STORAGE_IO;

    unsigned char digest[crypto_hash_sha512_BYTES];
    if (crypto_hash_sha512_final(&state, digest) != 0) return ZIA_ERR_CRYPTO_FAILURE;

    // La signature porte sur le condensat, pas sur le fichier : c'est la même
    // construction côté outil de signature, et elle évite de tout charger.
    const int rc = crypto_sign_verify_detached(signature, digest, sizeof(digest), public_key);
    sodium_memzero(digest, sizeof(digest));

    return rc == 0 ? ZIA_OK : ZIA_ERR_SIGNATURE_INVALID;
}
