// Backend macOS/iOS du SecureKeyStore via Keychain Services (Objective-C++).
//
// ⚠️ NON COMPILÉ NI TESTÉ dans l'environnement de développement Linux : ce
// fichier (.mm) ne se construit qu'avec la toolchain Apple (Xcode) et sera
// validé par les jobs macOS/iOS de la CI matricielle (Phase 8). La logique
// reflète l'API documentée de Keychain Services et le motif d'enveloppe validé
// côté Linux en Phase 7.
//
// Contrairement à libsecret (chaînes C) et DPAPI, Keychain accepte directement
// des données binaires : la clé maîtresse de 32 octets est stockée telle quelle
// via kSecValueData, sans encodage base64. Sur iOS, kSecAttrAccessible est réglé
// sur "AfterFirstUnlockThisDeviceOnly" : lisible après le premier déverrouillage
// (pour le traitement des notifications en arrière-plan), jamais synchronisé,
// jamais exporté hors de l'appareil.

#include "storage/secure_key_store.hpp"

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <sodium.h>

namespace zia::crypto::storage {
namespace {

NSDictionary* base_query() {
    return @{
        (__bridge id)kSecClass:        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:  @"com.ziacrypte.MasterKey",
        (__bridge id)kSecAttrAccount:  @"ziacrypte",
    };
}

class AppleSecureKeyStore : public SecureKeyStore {
public:
    bool has_master_key() override {
        NSMutableDictionary* q = [base_query() mutableCopy];
        q[(__bridge id)kSecReturnData] = @NO;
        q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, nullptr);
        return status == errSecSuccess;
    }

    bool generate_and_store_master_key(SecureBuffer& out_key) override {
        out_key = SecureBuffer(crypto_secretstream_xchacha20poly1305_KEYBYTES);
        randombytes_buf(out_key.data(), out_key.size());

        NSData* key_data = [NSData dataWithBytes:out_key.data() length:out_key.size()];
        NSMutableDictionary* q = [base_query() mutableCopy];
        q[(__bridge id)kSecValueData] = key_data;
        q[(__bridge id)kSecAttrAccessible] =
            (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;

        SecItemDelete((__bridge CFDictionaryRef)base_query()); // remplace un éventuel résidu
        OSStatus status = SecItemAdd((__bridge CFDictionaryRef)q, nullptr);
        return status == errSecSuccess;
    }

    bool load_master_key(SecureBuffer& out_key) override {
        NSMutableDictionary* q = [base_query() mutableCopy];
        q[(__bridge id)kSecReturnData] = @YES;
        q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

        CFTypeRef result = nullptr;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
        if (status != errSecSuccess || result == nullptr) return false;

        NSData* data = (__bridge_transfer NSData*)result;
        if (data.length != crypto_secretstream_xchacha20poly1305_KEYBYTES) return false;

        out_key = SecureBuffer(data.length);
        memcpy(out_key.data(), data.bytes, data.length);
        return true;
    }

    bool delete_master_key() override {
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)base_query());
        return status == errSecSuccess || status == errSecItemNotFound;
    }
};

} // namespace

SecureKeyStore& platform_key_store() {
    static AppleSecureKeyStore instance;
    return instance;
}

} // namespace zia::crypto::storage
