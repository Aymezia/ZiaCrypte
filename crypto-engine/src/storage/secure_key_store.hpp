#pragma once

#include "memory/secure_buffer.hpp"

namespace zia::crypto::storage {

/*
 * Coffre-fort de la clé maîtresse locale (Phase 2 §11.2). Ne protège jamais un
 * secret applicatif directement : uniquement la clé qui chiffre à son tour la
 * base de sessions locale (crypto_secretstream, cf. session.cpp). Une
 * implémentation par plateforme, choisie à la compilation :
 *
 *   - Linux : Secret Service / libsecret — implémentée et testée en Phase 7
 *     (platform/linux/secure_key_store_linux.cpp).
 *   - iOS/macOS : Keychain Services (`SecItemAdd`/`SecItemCopyMatching`),
 *     option Secure Enclave pour la clé d'enveloppe — CONÇUE mais pas encore
 *     écrite : nécessite Xcode, indisponible dans cet environnement.
 *   - Android : Android Keystore via JNI (clé AES non exportable protégeant
 *     un blob stocké applicativement) — CONÇUE, pas encore écrite : nécessite
 *     le NDK/SDK Android.
 *   - Windows : DPAPI (`CryptProtectData`/`CryptUnprotectData`) — CONÇUE, pas
 *     encore écrite : nécessite un toolchain MSVC.
 *
 * Ecrire du code natif non testable ici serait plus risqué que de le différer :
 * cf. Phase 7 §16.4 pour le détail de chaque conception.
 */
class SecureKeyStore {
public:
    virtual ~SecureKeyStore() = default;

    virtual bool has_master_key() = 0;
    virtual bool generate_and_store_master_key(SecureBuffer& out_key) = 0;
    virtual bool load_master_key(SecureBuffer& out_key) = 0;
    virtual bool delete_master_key() = 0;
};

/* Retourne l'implémentation choisie à la compilation pour la plateforme cible. */
SecureKeyStore& platform_key_store();

} // namespace zia::crypto::storage
