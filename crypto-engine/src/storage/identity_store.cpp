#include "identity_store.hpp"

#include "engine_internal.hpp"
#include "secure_key_store.hpp"

#include <sodium.h>

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <vector>

namespace zia::crypto::storage {
namespace {

/* Version 1 : identité + signed prekey + one-time prekeys.
   Version 2 : ajoute la prekey post-quantique (PQXDH).

   La lecture accepte les DEUX : un appareil déjà installé possède un fichier
   v1, et le refuser lui ferait perdre son identité — donc toutes ses sessions
   et tout son historique. Il est relu, puis réécrit en v2 à la première
   rotation. L'écriture, elle, produit toujours la version courante. */
constexpr uint8_t kFormatVersion = 2;
constexpr size_t kIdentityPrivLen = 64; // crypto_sign_SECRETKEYBYTES
constexpr size_t kX25519PrivLen = 32;
constexpr size_t kPqPubLen = 1184;
constexpr size_t kPqPrivLen = 2400;

std::filesystem::path identity_path(const std::string& storage_path) {
  return std::filesystem::path(storage_path) / "identity.zia";
}

void append(std::vector<uint8_t>& out, const void* data, size_t len) {
  const auto* p = static_cast<const uint8_t*>(data);
  out.insert(out.end(), p, p + len);
}

void append_u32(std::vector<uint8_t>& out, uint32_t v) {
  uint8_t tmp[4] = {static_cast<uint8_t>(v), static_cast<uint8_t>(v >> 8),
                    static_cast<uint8_t>(v >> 16), static_cast<uint8_t>(v >> 24)};
  append(out, tmp, 4);
}

/* Lecteur avec bornes : toute lecture hors limites échoue proprement plutôt
 * que de lire de la mémoire arbitraire (le fichier peut être corrompu). */
class Reader {
 public:
  Reader(const uint8_t* data, size_t len) : data_(data), len_(len) {}

  bool read(void* out, size_t n) {
    if (offset_ + n > len_) return false;
    std::memcpy(out, data_ + offset_, n);
    offset_ += n;
    return true;
  }

  bool read_u32(uint32_t& out) {
    uint8_t b[4];
    if (!read(b, 4)) return false;
    out = static_cast<uint32_t>(b[0]) | (static_cast<uint32_t>(b[1]) << 8) |
          (static_cast<uint32_t>(b[2]) << 16) | (static_cast<uint32_t>(b[3]) << 24);
    return true;
  }

  bool read_secret(SecureBuffer& out, size_t n) {
    out = SecureBuffer(n);
    return read(out.data(), n);
  }

  bool at_end() const { return offset_ == len_; }

 private:
  const uint8_t* data_;
  size_t len_;
  size_t offset_ = 0;
};

} // namespace

std::vector<uint8_t> serialize_identity(const ZiaEngine& engine) {
  std::vector<uint8_t> buf;
  buf.push_back(kFormatVersion);

  buf.push_back(engine.has_identity ? 1 : 0);
  append(buf, engine.identity_public, 32);
  if (engine.has_identity) {
    append(buf, engine.identity_private.data(), kIdentityPrivLen);
  }

  const bool has_spk = engine.signed_prekey.has_value();
  buf.push_back(has_spk ? 1 : 0);
  if (has_spk) {
    append(buf, engine.signed_prekey->public_key, 32);
    append(buf, engine.signed_prekey->private_key.data(), kX25519PrivLen);
    append(buf, engine.signed_prekey->signature, 64);
  }

  const bool has_pq = engine.pq_prekey.has_value();
  buf.push_back(has_pq ? 1 : 0);
  if (has_pq) {
    append(buf, engine.pq_prekey->public_key, kPqPubLen);
    append(buf, engine.pq_prekey->private_key.data(), kPqPrivLen);
    append(buf, engine.pq_prekey->signature, 64);
  }

  append_u32(buf, static_cast<uint32_t>(engine.one_time_prekeys.size()));
  for (const auto& otpk : engine.one_time_prekeys) {
    append(buf, otpk.public_key, 32);
    append(buf, otpk.private_key.data(), kX25519PrivLen);
    buf.push_back(otpk.consumed ? 1 : 0);
  }
  return buf;
}

bool deserialize_identity(const uint8_t* data, size_t len, ZiaEngine& engine) {
  Reader r(data, len);

  uint8_t version = 0;
  if (!r.read(&version, 1) || version < 1 || version > kFormatVersion) return false;

  uint8_t flag = 0;
  if (!r.read(&flag, 1)) return false;
  engine.has_identity = flag != 0;
  if (!r.read(engine.identity_public, 32)) return false;
  if (engine.has_identity && !r.read_secret(engine.identity_private, kIdentityPrivLen)) {
    return false;
  }

  if (!r.read(&flag, 1)) return false;
  if (flag) {
    ZiaSignedPrekey spk;
    if (!r.read(spk.public_key, 32)) return false;
    if (!r.read_secret(spk.private_key, kX25519PrivLen)) return false;
    if (!r.read(spk.signature, 64)) return false;
    engine.signed_prekey = std::move(spk);
  } else {
    engine.signed_prekey.reset();
  }

  engine.pq_prekey.reset();
  if (version >= 2) {
    if (!r.read(&flag, 1)) return false;
    if (flag) {
      ZiaPqPrekey pq;
      if (!r.read(pq.public_key, kPqPubLen)) return false;
      if (!r.read_secret(pq.private_key, kPqPrivLen)) return false;
      if (!r.read(pq.signature, 64)) return false;
      engine.pq_prekey = std::move(pq);
    }
  }

  uint32_t count = 0;
  if (!r.read_u32(count)) return false;
  engine.one_time_prekeys.clear();
  engine.one_time_prekeys.reserve(count);
  for (uint32_t i = 0; i < count; ++i) {
    ZiaOneTimePrekey otpk;
    if (!r.read(otpk.public_key, 32)) return false;
    if (!r.read_secret(otpk.private_key, kX25519PrivLen)) return false;
    uint8_t consumed = 0;
    if (!r.read(&consumed, 1)) return false;
    otpk.consumed = consumed != 0;
    engine.one_time_prekeys.push_back(std::move(otpk));
  }

  return r.at_end();
}

namespace {

bool master_key(SecureBuffer& out) {
  auto& store = platform_key_store();
  if (store.has_master_key()) return store.load_master_key(out);
  return store.generate_and_store_master_key(out);
}

} // namespace

bool save_identity(const ZiaEngine& engine) {
  if (engine.storage_path.empty()) return false;

  SecureBuffer key;
  if (!master_key(key)) return false;

  std::error_code ec;
  std::filesystem::create_directories(engine.storage_path, ec);
  if (ec) return false;

  std::vector<uint8_t> plain = serialize_identity(engine);

  uint8_t header[crypto_secretstream_xchacha20poly1305_HEADERBYTES];
  crypto_secretstream_xchacha20poly1305_state st;
  if (crypto_secretstream_xchacha20poly1305_init_push(&st, header, key.data()) != 0) {
    sodium_memzero(plain.data(), plain.size());
    return false;
  }

  std::vector<uint8_t> cipher(plain.size() + crypto_secretstream_xchacha20poly1305_ABYTES);
  unsigned long long cipher_len = 0;
  const int rc = crypto_secretstream_xchacha20poly1305_push(
      &st, cipher.data(), &cipher_len, plain.data(), plain.size(), nullptr, 0,
      crypto_secretstream_xchacha20poly1305_TAG_FINAL);
  sodium_memzero(plain.data(), plain.size());
  if (rc != 0) return false;

  // Écriture atomique : un fichier temporaire puis un renommage, pour ne
  // jamais laisser une identité à moitié écrite en cas de coupure.
  const auto final_path = identity_path(engine.storage_path);
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

bool load_identity(ZiaEngine& engine) {
  if (engine.storage_path.empty()) return false;

  const auto path = identity_path(engine.storage_path);
  std::ifstream f(path, std::ios::binary);
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

  std::vector<uint8_t> plain(cipher_len - crypto_secretstream_xchacha20poly1305_ABYTES);
  unsigned long long plain_len = 0;
  uint8_t tag = 0;
  const int rc = crypto_secretstream_xchacha20poly1305_pull(
      &st, plain.data(), &plain_len, &tag, cipher, cipher_len, nullptr, 0);
  if (rc != 0) {
    sodium_memzero(plain.data(), plain.size());
    return false;
  }

  const bool ok = deserialize_identity(plain.data(), static_cast<size_t>(plain_len), engine);
  sodium_memzero(plain.data(), plain.size());
  return ok;
}

} // namespace zia::crypto::storage
