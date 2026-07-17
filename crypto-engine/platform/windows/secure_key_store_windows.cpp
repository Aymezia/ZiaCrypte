// Backend Windows du SecureKeyStore via DPAPI (Data Protection API).
//
// ⚠️ NON COMPILÉ NI TESTÉ dans l'environnement de développement Linux : ce
// fichier ne se construit que sur Windows (toolchain MSVC) et sera validé par
// le job Windows de la CI matricielle (Phase 8). La logique reflète l'API
// documentée de DPAPI et le motif d'enveloppe validé côté Linux en Phase 7.
//
// DPAPI ne « stocke » pas : il chiffre un blob lié au compte utilisateur
// (CRYPTPROTECT_LOCAL_MACHINE volontairement NON utilisé — on veut un secret
// lié à l'utilisateur, pas à la machine). On persiste donc le blob chiffré
// dans %LOCALAPPDATA%\ZiaCrypte\master.key.dpapi. Sans la session de
// l'utilisateur Windows, ce blob est inexploitable.

#include "storage/secure_key_store.hpp"

#include <windows.h>
#include <wincrypt.h>
#include <shlobj.h>
#include <sodium.h>

#include <fstream>
#include <string>
#include <vector>

namespace zia::crypto::storage {
namespace {

std::wstring key_file_path() {
    PWSTR local_app_data = nullptr;
    if (SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local_app_data) != S_OK) {
        return L"";
    }
    std::wstring dir = std::wstring(local_app_data) + L"\\ZiaCrypte";
    CoTaskMemFree(local_app_data);
    CreateDirectoryW(dir.c_str(), nullptr); // no-op si déjà présent
    return dir + L"\\master.key.dpapi";
}

bool read_file(const std::wstring& path, std::vector<uint8_t>& out) {
    std::ifstream f(path.c_str(), std::ios::binary);
    if (!f) return false;
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}

bool write_file(const std::wstring& path, const uint8_t* data, size_t len) {
    std::ofstream f(path.c_str(), std::ios::binary | std::ios::trunc);
    if (!f) return false;
    f.write(reinterpret_cast<const char*>(data), static_cast<std::streamsize>(len));
    return f.good();
}

class WindowsSecureKeyStore : public SecureKeyStore {
public:
    bool has_master_key() override {
        std::wstring path = key_file_path();
        if (path.empty()) return false;
        return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
    }

    bool generate_and_store_master_key(SecureBuffer& out_key) override {
        std::wstring path = key_file_path();
        if (path.empty()) return false;

        out_key = SecureBuffer(crypto_secretstream_xchacha20poly1305_KEYBYTES);
        randombytes_buf(out_key.data(), out_key.size());

        DATA_BLOB in{static_cast<DWORD>(out_key.size()), out_key.data()};
        DATA_BLOB encrypted{0, nullptr};
        if (!CryptProtectData(&in, L"ZiaCrypte master key", nullptr, nullptr, nullptr,
                              CRYPTPROTECT_UI_FORBIDDEN, &encrypted)) {
            return false;
        }
        bool ok = write_file(path, encrypted.pbData, encrypted.cbData);
        SecureZeroMemory(encrypted.pbData, encrypted.cbData);
        LocalFree(encrypted.pbData);
        return ok;
    }

    bool load_master_key(SecureBuffer& out_key) override {
        std::wstring path = key_file_path();
        if (path.empty()) return false;

        std::vector<uint8_t> blob;
        if (!read_file(path, blob) || blob.empty()) return false;

        DATA_BLOB in{static_cast<DWORD>(blob.size()), blob.data()};
        DATA_BLOB decrypted{0, nullptr};
        if (!CryptUnprotectData(&in, nullptr, nullptr, nullptr, nullptr,
                                CRYPTPROTECT_UI_FORBIDDEN, &decrypted)) {
            return false;
        }

        bool ok = decrypted.cbData == crypto_secretstream_xchacha20poly1305_KEYBYTES;
        if (ok) {
            out_key = SecureBuffer(decrypted.cbData);
            memcpy(out_key.data(), decrypted.pbData, decrypted.cbData);
        }
        SecureZeroMemory(decrypted.pbData, decrypted.cbData);
        LocalFree(decrypted.pbData);
        return ok;
    }

    bool delete_master_key() override {
        std::wstring path = key_file_path();
        if (path.empty()) return false;
        return DeleteFileW(path.c_str()) != 0;
    }
};

} // namespace

SecureKeyStore& platform_key_store() {
    static WindowsSecureKeyStore instance;
    return instance;
}

} // namespace zia::crypto::storage
