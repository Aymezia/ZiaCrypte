#include "secure_blob.hpp"

#include "engine_internal.hpp"
#include "memory/secure_buffer.hpp"
#include "secure_key_store.hpp"

#include <sodium.h>

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>

namespace zia::crypto::storage {
namespace {

/* Un nom fourni par l'appelant ne doit jamais pouvoir désigner un fichier hors
 * du coffre : on n'accepte qu'un jeu de caractères sûr, ce qui exclut « / »,
 * « \ » et « .. ». */
bool valid_name(const std::string& name) {
  if (name.empty() || name.size() > 128) return false;
  return std::all_of(name.begin(), name.end(), [](unsigned char c) {
    return std::isalnum(c) || c == '.' || c == '_' || c == '-';
  });
}

std::filesystem::path vault_dir(const ZiaEngine& engine) {
  return std::filesystem::path(engine.storage_path) / "vault";
}

bool master_key(SecureBuffer& out) {
  auto& store = platform_key_store();
  if (store.has_master_key()) return store.load_master_key(out);
  return store.generate_and_store_master_key(out);
}

} // namespace

bool secure_write(const ZiaEngine& engine, const std::string& name,
                  const uint8_t* data, size_t len) {
  if (engine.storage_path.empty() || !valid_name(name)) return false;
  if (len > 0 && data == nullptr) return false;

  SecureBuffer key;
  if (!master_key(key)) return false;

  std::error_code ec;
  std::filesystem::create_directories(vault_dir(engine), ec);
  if (ec) return false;

  uint8_t header[crypto_secretstream_xchacha20poly1305_HEADERBYTES];
  crypto_secretstream_xchacha20poly1305_state st;
  if (crypto_secretstream_xchacha20poly1305_init_push(&st, header, key.data()) != 0) {
    return false;
  }

  std::vector<uint8_t> cipher(len + crypto_secretstream_xchacha20poly1305_ABYTES);
  unsigned long long cipher_len = 0;
  if (crypto_secretstream_xchacha20poly1305_push(
          &st, cipher.data(), &cipher_len, data, len, nullptr, 0,
          crypto_secretstream_xchacha20poly1305_TAG_FINAL) != 0) {
    return false;
  }

  // Écriture atomique : on ne veut jamais d'entrée à moitié écrite.
  const auto final_path = vault_dir(engine) / (name + ".zia");
  const auto tmp_path = final_path.string() + ".tmp";
  {
    std::ofstream f(tmp_path, std::ios::binary | std::ios::trunc);
    if (!f) return false;
    f.write(reinterpret_cast<const char*>(header), sizeof(header));
    f.write(reinterpret_cast<const char*>(cipher.data()),
            static_cast<std::streamsize>(cipher_len));
    if (!f.good()) return false;
  }
  std::filesystem::rename(tmp_path, final_path, ec);
  return !ec;
}

bool secure_read(const ZiaEngine& engine, const std::string& name,
                 std::vector<uint8_t>& out) {
  if (engine.storage_path.empty() || !valid_name(name)) return false;

  std::ifstream f(vault_dir(engine) / (name + ".zia"), std::ios::binary);
  if (!f) return false;

  std::vector<uint8_t> raw((std::istreambuf_iterator<char>(f)),
                           std::istreambuf_iterator<char>());
  constexpr size_t kMin = crypto_secretstream_xchacha20poly1305_HEADERBYTES +
                          crypto_secretstream_xchacha20poly1305_ABYTES;
  if (raw.size() < kMin) return false;

  SecureBuffer key;
  if (!master_key(key)) return false;

  crypto_secretstream_xchacha20poly1305_state st;
  if (crypto_secretstream_xchacha20poly1305_init_pull(&st, raw.data(), key.data()) != 0) {
    return false;
  }

  const uint8_t* cipher = raw.data() + crypto_secretstream_xchacha20poly1305_HEADERBYTES;
  const size_t cipher_len = raw.size() - crypto_secretstream_xchacha20poly1305_HEADERBYTES;

  out.assign(cipher_len - crypto_secretstream_xchacha20poly1305_ABYTES, 0);
  unsigned long long plain_len = 0;
  uint8_t tag = 0;
  if (crypto_secretstream_xchacha20poly1305_pull(&st, out.data(), &plain_len, &tag,
                                                 cipher, cipher_len, nullptr, 0) != 0) {
    out.clear();
    return false;
  }
  out.resize(static_cast<size_t>(plain_len));
  return true;
}

bool secure_erase(const ZiaEngine& engine, const std::string& name) {
  if (engine.storage_path.empty() || !valid_name(name)) return false;
  std::error_code ec;
  std::filesystem::remove(vault_dir(engine) / (name + ".zia"), ec);
  return !ec;
}

} // namespace zia::crypto::storage
