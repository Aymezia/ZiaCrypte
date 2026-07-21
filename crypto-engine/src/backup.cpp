#include "zia/zia_crypto.h"
#include "engine_internal.hpp"
#include "storage/identity_store.hpp"
#include "storage/secure_blob.hpp"

#include <sodium.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

/**
 * Sauvegarde chiffrée exportable.
 *
 * ## Le problème qu'elle résout
 *
 * Les clés privées d'un compte n'existent que sur l'appareil qui l'a créé et ne
 * sont déposées nulle part — c'est la garantie même du chiffrement de bout en
 * bout. La contrepartie est brutale : appareil perdu, historique perdu, et
 * personne, pas même nous, ne peut le rendre.
 *
 * ## Pourquoi une phrase de passe et non la clé de l'appareil
 *
 * Le coffre local est chiffré sous une clé détenue par le coffre-fort du
 * système (Secret Service, DPAPI, Keychain, Android Keystore), volontairement
 * NON exportable. Une sauvegarde chiffrée avec elle ne serait restaurable que
 * sur la machine qui l'a produite — c'est-à-dire inutile.
 *
 * Le contenu est donc rechiffré sous une clé dérivée d'une phrase de passe
 * (Argon2id). Cela déplace le risque, et il faut le dire sans détour :
 * le fichier peut être copié et emporté, sa solidité ne tient plus qu'à la
 * phrase choisie.
 *
 * ## Ce qui n'est PAS fait ici
 *
 * Rien n'est envoyé nulle part. Le moteur produit un tampon ; l'application
 * décide où l'écrire. Déposer une sauvegarde sur le serveur reviendrait à lui
 * confier exactement ce que le chiffrement de bout en bout lui refuse.
 */

using namespace zia::crypto;

namespace {

constexpr char kMagic[8] = {'Z', 'I', 'A', 'B', 'K', 'P', '0', '1'};

/**
 * Paramètres Argon2id.
 *
 * Le profil MODERATE de libsodium réclame 256 Mio, qu'un téléphone refuse
 * régulièrement d'allouer — une sauvegarde qui échoue à la restauration sur le
 * seul appareil restant ne protège de rien. On garde donc la mémoire du profil
 * interactif (64 Mio) en doublant les passes : le coût pour un attaquant monte
 * sans risquer l'échec d'allocation.
 *
 * Les deux valeurs sont ÉCRITES dans l'en-tête : les durcir plus tard ne
 * cassera pas les sauvegardes déjà produites.
 */
constexpr unsigned long long kOpsLimit = 4;
constexpr size_t kMemLimit = crypto_pwhash_MEMLIMIT_INTERACTIVE;

constexpr uint8_t kKindIdentity = 0;
constexpr uint8_t kKindVault = 1;

void put_u32(std::vector<uint8_t>& out, uint32_t v) {
  for (int i = 0; i < 4; ++i) out.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xff));
}

void put_u64(std::vector<uint8_t>& out, uint64_t v) {
  for (int i = 0; i < 8; ++i) out.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xff));
}

class Reader {
 public:
  Reader(const uint8_t* data, size_t len) : d_(data), n_(len) {}

  bool read(uint8_t* out, size_t len) {
    if (n_ - i_ < len) return false;
    std::memcpy(out, d_ + i_, len);
    i_ += len;
    return true;
  }
  bool u32(uint32_t& v) {
    uint8_t b[4];
    if (!read(b, 4)) return false;
    v = static_cast<uint32_t>(b[0]) | (static_cast<uint32_t>(b[1]) << 8) |
        (static_cast<uint32_t>(b[2]) << 16) | (static_cast<uint32_t>(b[3]) << 24);
    return true;
  }
  bool u64(uint64_t& v) {
    uint8_t b[8];
    if (!read(b, 8)) return false;
    v = 0;
    for (int k = 7; k >= 0; --k) v = (v << 8) | b[static_cast<size_t>(k)];
    return true;
  }
  size_t remaining() const { return n_ - i_; }
  const uint8_t* cursor() const { return d_ + i_; }
  void skip(size_t len) { i_ += len; }

 private:
  const uint8_t* d_;
  size_t n_;
  size_t i_ = 0;
};

/** Noms des entrées du coffre présentes sur le disque. */
std::vector<std::string> vault_entries(const ZiaEngine& engine) {
  std::vector<std::string> noms;
  const auto dir = std::filesystem::path(engine.storage_path) / "vault";
  std::error_code ec;
  if (!std::filesystem::exists(dir, ec)) return noms;
  for (const auto& e : std::filesystem::directory_iterator(dir, ec)) {
    if (ec) break;
    if (!e.is_regular_file()) continue;
    const auto p = e.path();
    if (p.extension() != ".zia") continue;
    noms.push_back(p.stem().string());
  }
  // Ordre stable : deux sauvegardes du même état produisent le même contenu
  // clair, ce qui rend tout écart diagnosticable.
  std::sort(noms.begin(), noms.end());
  return noms;
}

} // namespace

ZIA_API ZiaStatus zia_backup_export(ZiaEngine* engine, const char* passphrase,
                                    uint8_t** out, size_t* out_len) {
  if (!engine || !passphrase || !out || !out_len) return ZIA_ERR_INVALID_ARG;
  if (!engine->has_identity) {
    engine->last_error = "aucune identite a sauvegarder";
    return ZIA_ERR_INVALID_ARG;
  }
  const size_t pass_len = std::strlen(passphrase);
  // Une phrase trop courte donnerait une fausse impression de protection : ce
  // fichier est destiné à quitter l'appareil.
  if (pass_len < 12) {
    engine->last_error = "phrase de passe trop courte (12 caracteres minimum)";
    return ZIA_ERR_INVALID_ARG;
  }

  std::vector<uint8_t> plain;
  std::vector<uint8_t> identity = storage::serialize_identity(*engine);
  const auto noms = vault_entries(*engine);

  put_u32(plain, static_cast<uint32_t>(1 + noms.size()));

  plain.push_back(kKindIdentity);
  put_u32(plain, 0);
  put_u32(plain, static_cast<uint32_t>(identity.size()));
  plain.insert(plain.end(), identity.begin(), identity.end());
  sodium_memzero(identity.data(), identity.size());

  for (const auto& nom : noms) {
    std::vector<uint8_t> data;
    if (!storage::secure_read(*engine, nom, data)) continue;
    plain.push_back(kKindVault);
    put_u32(plain, static_cast<uint32_t>(nom.size()));
    plain.insert(plain.end(), nom.begin(), nom.end());
    put_u32(plain, static_cast<uint32_t>(data.size()));
    plain.insert(plain.end(), data.begin(), data.end());
    sodium_memzero(data.data(), data.size());
  }

  uint8_t salt[crypto_pwhash_SALTBYTES];
  randombytes_buf(salt, sizeof(salt));

  SecureBuffer key(crypto_secretstream_xchacha20poly1305_KEYBYTES);
  if (crypto_pwhash(key.data(), key.size(), passphrase, pass_len, salt,
                    kOpsLimit, kMemLimit, crypto_pwhash_ALG_ARGON2ID13) != 0) {
    sodium_memzero(plain.data(), plain.size());
    engine->last_error = "memoire insuffisante pour deriver la cle";
    return ZIA_ERR_OUT_OF_MEMORY;
  }

  uint8_t header[crypto_secretstream_xchacha20poly1305_HEADERBYTES];
  crypto_secretstream_xchacha20poly1305_state st;
  if (crypto_secretstream_xchacha20poly1305_init_push(&st, header, key.data()) != 0) {
    sodium_memzero(plain.data(), plain.size());
    return ZIA_ERR_CRYPTO_FAILURE;
  }

  std::vector<uint8_t> cipher(plain.size() +
                              crypto_secretstream_xchacha20poly1305_ABYTES);
  unsigned long long cipher_len = 0;
  const int rc = crypto_secretstream_xchacha20poly1305_push(
      &st, cipher.data(), &cipher_len, plain.data(), plain.size(), nullptr, 0,
      crypto_secretstream_xchacha20poly1305_TAG_FINAL);
  sodium_memzero(plain.data(), plain.size());
  if (rc != 0) return ZIA_ERR_CRYPTO_FAILURE;

  std::vector<uint8_t> blob;
  blob.insert(blob.end(), kMagic, kMagic + sizeof(kMagic));
  blob.insert(blob.end(), salt, salt + sizeof(salt));
  put_u64(blob, kOpsLimit);
  put_u64(blob, static_cast<uint64_t>(kMemLimit));
  blob.insert(blob.end(), header, header + sizeof(header));
  blob.insert(blob.end(), cipher.begin(),
              cipher.begin() + static_cast<std::ptrdiff_t>(cipher_len));

  auto* buffer = static_cast<uint8_t*>(malloc(blob.size()));
  if (!buffer) return ZIA_ERR_OUT_OF_MEMORY;
  std::memcpy(buffer, blob.data(), blob.size());
  *out = buffer;
  *out_len = blob.size();
  return ZIA_OK;
}

ZIA_API ZiaStatus zia_backup_import(ZiaEngine* engine, const char* passphrase,
                                    const uint8_t* data, size_t len) {
  if (!engine || !passphrase || !data) return ZIA_ERR_INVALID_ARG;

  Reader r(data, len);
  uint8_t magic[8];
  if (!r.read(magic, sizeof(magic)) ||
      sodium_memcmp(magic, kMagic, sizeof(magic)) != 0) {
    engine->last_error = "ce fichier n'est pas une sauvegarde ZiaCrypte";
    return ZIA_ERR_INVALID_ARG;
  }

  uint8_t salt[crypto_pwhash_SALTBYTES];
  uint64_t ops = 0, mem = 0;
  uint8_t header[crypto_secretstream_xchacha20poly1305_HEADERBYTES];
  if (!r.read(salt, sizeof(salt)) || !r.u64(ops) || !r.u64(mem) ||
      !r.read(header, sizeof(header))) {
    engine->last_error = "sauvegarde tronquee";
    return ZIA_ERR_INVALID_ARG;
  }
  // Bornes sur les paramètres LUS dans le fichier : sans elles, une sauvegarde
  // hostile demanderait une allocation démesurée et ferait tomber
  // l'application au lieu d'être simplement refusée.
  if (ops == 0 || ops > 16 || mem < crypto_pwhash_MEMLIMIT_MIN ||
      mem > 1024ULL * 1024 * 1024) {
    engine->last_error = "parametres de sauvegarde hors bornes";
    return ZIA_ERR_INVALID_ARG;
  }
  if (r.remaining() < crypto_secretstream_xchacha20poly1305_ABYTES) {
    engine->last_error = "sauvegarde tronquee";
    return ZIA_ERR_INVALID_ARG;
  }

  SecureBuffer key(crypto_secretstream_xchacha20poly1305_KEYBYTES);
  if (crypto_pwhash(key.data(), key.size(), passphrase, std::strlen(passphrase),
                    salt, ops, static_cast<size_t>(mem),
                    crypto_pwhash_ALG_ARGON2ID13) != 0) {
    engine->last_error = "memoire insuffisante pour deriver la cle";
    return ZIA_ERR_OUT_OF_MEMORY;
  }

  crypto_secretstream_xchacha20poly1305_state st;
  if (crypto_secretstream_xchacha20poly1305_init_pull(&st, header, key.data()) != 0) {
    engine->last_error = "sauvegarde illisible";
    return ZIA_ERR_CRYPTO_FAILURE;
  }

  std::vector<uint8_t> plain(r.remaining() -
                             crypto_secretstream_xchacha20poly1305_ABYTES);
  unsigned long long plain_len = 0;
  uint8_t tag = 0;
  // C'est ICI qu'une phrase de passe erronée est détectée : le tag Poly1305 ne
  // vérifie pas. Aucun contrôle sur la phrase elle-même n'est fait ni ne doit
  // l'être — c'est l'authentification du chiffré qui tranche.
  if (crypto_secretstream_xchacha20poly1305_pull(
          &st, plain.data(), &plain_len, &tag, r.cursor(), r.remaining(),
          nullptr, 0) != 0) {
    engine->last_error = "phrase de passe incorrecte, ou sauvegarde alteree";
    return ZIA_ERR_CRYPTO_FAILURE;
  }
  if (tag != crypto_secretstream_xchacha20poly1305_TAG_FINAL) {
    sodium_memzero(plain.data(), plain.size());
    engine->last_error = "sauvegarde incomplete";
    return ZIA_ERR_CRYPTO_FAILURE;
  }

  Reader p(plain.data(), static_cast<size_t>(plain_len));
  uint32_t count = 0;
  bool ok = p.u32(count);
  bool identite_vue = false;

  for (uint32_t i = 0; ok && i < count; ++i) {
    uint8_t kind = 0;
    uint32_t name_len = 0, data_len = 0;
    if (!p.read(&kind, 1) || !p.u32(name_len)) { ok = false; break; }
    std::string nom;
    if (name_len > 0) {
      if (p.remaining() < name_len) { ok = false; break; }
      nom.assign(reinterpret_cast<const char*>(p.cursor()), name_len);
      p.skip(name_len);
    }
    if (!p.u32(data_len) || p.remaining() < data_len) { ok = false; break; }
    const uint8_t* payload = p.cursor();

    if (kind == kKindIdentity) {
      ok = storage::deserialize_identity(payload, data_len, *engine);
      identite_vue = ok;
    } else if (kind == kKindVault) {
      ok = storage::secure_write(*engine, nom, payload, data_len);
    }
    p.skip(data_len);
  }

  sodium_memzero(plain.data(), plain.size());

  if (!ok || !identite_vue) {
    engine->last_error = "sauvegarde illisible ou incomplete";
    return ZIA_ERR_CRYPTO_FAILURE;
  }

  // L'identité est réécrite sous la clé maîtresse de CET appareil : c'est ce
  // qui rend la restauration effective sur une autre machine.
  if (!storage::save_identity(*engine)) {
    engine->last_error = "impossible d'enregistrer l'identite restauree";
    return ZIA_ERR_STORAGE_IO;
  }
  return ZIA_OK;
}
