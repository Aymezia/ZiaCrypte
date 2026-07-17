// Implémentation Linux du SecureKeyStore via Secret Service (libsecret), le
// mécanisme standard desktop (GNOME Keyring, KWallet via le compat Secret
// Service). La clé maîtresse (32 octets) est encodée en base64 avant stockage
// car l'API "password" de libsecret manipule des chaînes C, incompatibles avec
// des octets bruts pouvant contenir des NUL. Testée en Phase 7 sous une session
// D-Bus + gnome-keyring-daemon headless.

#include "storage/secure_key_store.hpp"

#include <libsecret/secret.h>
#include <sodium.h>
#include <cstring>
#include <vector>

namespace zia::crypto::storage {
namespace {

const SecretSchema* schema() {
    static const SecretSchema s = {
        "com.ziacrypte.MasterKey",
        SECRET_SCHEMA_NONE,
        {
            {"engine", SECRET_SCHEMA_ATTRIBUTE_STRING},
        },
        0, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr // champs réservés de libsecret
    };
    return &s;
}

class LinuxSecureKeyStore : public SecureKeyStore {
public:
    bool has_master_key() override {
        GError* error = nullptr;
        gchar* password = secret_password_lookup_sync(schema(), nullptr, &error,
                                                        "engine", "ziacrypte", nullptr);
        bool found = password != nullptr;
        // secret_password_wipe() efface le contenu MAIS ne libère pas le buffer
        // (vérifié dans la source libsecret : `egg_secure_strclear` seulement) —
        // secret_password_free() fait les deux (`egg_secure_strfree`), c'est la
        // bonne fonction ici puisque nous possédons cette chaîne.
        if (password) secret_password_free(password);
        if (error) g_error_free(error);
        return found;
    }

    bool generate_and_store_master_key(SecureBuffer& out_key) override {
        out_key = SecureBuffer(crypto_secretstream_xchacha20poly1305_KEYBYTES);
        randombytes_buf(out_key.data(), out_key.size());

        const size_t encoded_len =
            sodium_base64_ENCODED_LEN(crypto_secretstream_xchacha20poly1305_KEYBYTES,
                                       sodium_base64_VARIANT_ORIGINAL);
        std::vector<char> encoded(encoded_len);
        sodium_bin2base64(encoded.data(), encoded.size(), out_key.data(), out_key.size(),
                           sodium_base64_VARIANT_ORIGINAL);

        GError* error = nullptr;
        gboolean ok = secret_password_store_sync(schema(), SECRET_COLLECTION_DEFAULT,
                                                   "Clé maîtresse ZiaCrypte", encoded.data(),
                                                   nullptr, &error, "engine", "ziacrypte", nullptr);
        sodium_memzero(encoded.data(), encoded.size());
        if (error) {
            g_error_free(error);
            return false;
        }
        return ok;
    }

    bool load_master_key(SecureBuffer& out_key) override {
        GError* error = nullptr;
        gchar* password = secret_password_lookup_sync(schema(), nullptr, &error,
                                                        "engine", "ziacrypte", nullptr);
        if (error) {
            g_error_free(error);
            return false;
        }
        if (!password) return false;

        out_key = SecureBuffer(crypto_secretstream_xchacha20poly1305_KEYBYTES);
        size_t decoded_len = 0;
        int rc = sodium_base642bin(out_key.data(), out_key.size(),
                                    password, std::strlen(password),
                                    nullptr, &decoded_len, nullptr,
                                    sodium_base64_VARIANT_ORIGINAL);
        secret_password_free(password); // efface ET libère (cf. commentaire dans has_master_key)
        return rc == 0 && decoded_len == out_key.size();
    }

    bool delete_master_key() override {
        GError* error = nullptr;
        gboolean ok = secret_password_clear_sync(schema(), nullptr, &error,
                                                   "engine", "ziacrypte", nullptr);
        if (error) {
            g_error_free(error);
            return false;
        }
        return ok;
    }
};

} // namespace

SecureKeyStore& platform_key_store() {
    static LinuxSecureKeyStore instance;
    return instance;
}

} // namespace zia::crypto::storage
