// Migration du format d'identité : v1 (avant PQXDH) -> v2 (avec prekey PQ).
//
// ## Pourquoi ce test existe
//
// Le fichier `identity.zia` d'un appareil déjà installé est en version 1. S'il
// cessait d'être relu, l'application régénérerait une identité au démarrage :
// nouveau compte, sessions perdues, historique inaccessible, et rien à
// l'écran pour dire pourquoi. C'est la panne la plus grave que cette phase
// puisse introduire, et la seule qui ne se voit PAS sur une machine de
// développement — où le fichier est de toute façon recréé.
//
// Le test appelle directement le sérialiseur interne (comme safety_number_test
// le fait pour sa primitive) : c'est le seul moyen de fabriquer un fichier
// v1 maintenant que l'écriture produit du v2.

#include "storage/identity_store.hpp"
#include "storage/secure_key_store.hpp"
#include "engine_internal.hpp"
#include "primitives/primitives.hpp"

#include <sodium.h>

#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>

using namespace zia::crypto;

/* Coffre factice.
 *
 * identity_store.cpp référence platform_key_store() pour CHIFFRER le fichier,
 * mais ce test ne touche qu'au sérialiseur : rien n'est écrit sur disque, donc
 * aucune clé maîtresse n'est nécessaire. Fournir ce stub évite de compiler le
 * coffre natif de chaque plateforme dans un test qui ne s'en sert pas — c'est
 * précisément ce qui cassait la compilation macOS, où le backend n'était pas
 * ajouté à la cible. */
namespace zia::crypto::storage {
namespace {
class CoffreFactice final : public SecureKeyStore {
 public:
  bool has_master_key() override { return false; }
  bool generate_and_store_master_key(SecureBuffer&) override { return false; }
  bool load_master_key(SecureBuffer&) override { return false; }
  bool delete_master_key() override { return false; }
};
} // namespace

SecureKeyStore& platform_key_store() {
  static CoffreFactice coffre;
  return coffre;
}
} // namespace zia::crypto::storage

namespace {

int checks = 0;
void ok(const char* label) {
  ++checks;
  std::printf("[OK] %s\n", label);
}

/* Reconstitue exactement ce qu'écrivait la version 1 : aucun champ PQ, et
 * l'octet de version à 1. */
std::vector<uint8_t> serialize_v1(const ZiaEngine& e) {
  std::vector<uint8_t> buf;
  auto append = [&](const void* p, size_t n) {
    const auto* b = static_cast<const uint8_t*>(p);
    buf.insert(buf.end(), b, b + n);
  };

  buf.push_back(1); // version
  buf.push_back(1); // has_identity
  append(e.identity_public, 32);
  append(e.identity_private.data(), 64);

  buf.push_back(1); // has signed prekey
  append(e.signed_prekey->public_key, 32);
  append(e.signed_prekey->private_key.data(), 32);
  append(e.signed_prekey->signature, 64);

  const uint32_t n = static_cast<uint32_t>(e.one_time_prekeys.size());
  const uint8_t count[4] = {static_cast<uint8_t>(n), static_cast<uint8_t>(n >> 8),
                            static_cast<uint8_t>(n >> 16), static_cast<uint8_t>(n >> 24)};
  append(count, 4);
  for (const auto& otpk : e.one_time_prekeys) {
    append(otpk.public_key, 32);
    append(otpk.private_key.data(), 32);
    buf.push_back(otpk.consumed ? 1 : 0);
  }
  return buf;
}

ZiaEngine make_engine() {
  ZiaEngine e;
  e.has_identity = true;
  primitives::ed25519_keypair(e.identity_public, e.identity_private);

  ZiaSignedPrekey spk;
  primitives::x25519_keypair(spk.public_key, spk.private_key);
  primitives::ed25519_sign(e.identity_private, spk.public_key, 32, spk.signature);
  e.signed_prekey = std::move(spk);

  ZiaOneTimePrekey otpk;
  primitives::x25519_keypair(otpk.public_key, otpk.private_key);
  e.one_time_prekeys.push_back(std::move(otpk));
  return e;
}

} // namespace

int main() {
  // Ce test appelle les primitives SANS passer par zia_engine_init, qui est
  // d'ordinaire ce qui initialise libsodium. Sans cet appel, l'allocation
  // protégée de SecureBuffer avorte avant même le premier contrôle.
  assert(sodium_init() >= 0);

  const ZiaEngine origine = make_engine();

  // --- Un fichier v1 doit se relire, et rendre la MÊME identité ---
  {
    const std::vector<uint8_t> v1 = serialize_v1(origine);
    ZiaEngine relu;
    assert(storage::deserialize_identity(v1.data(), v1.size(), relu));
    assert(relu.has_identity);
    assert(std::memcmp(relu.identity_public, origine.identity_public, 32) == 0);
    assert(relu.signed_prekey.has_value());
    assert(std::memcmp(relu.signed_prekey->public_key, origine.signed_prekey->public_key, 32) == 0);
    assert(relu.one_time_prekeys.size() == 1);
    // Pas de clé PQ : elle sera créée à la première rotation, sans que
    // l'utilisateur ait à refaire quoi que ce soit.
    assert(!relu.pq_prekey.has_value());
    ok("Identite v1 relue sans perte, sans cle PQ");
  }

  // --- Un fichier v2 fait l'aller-retour complet, PQ comprise ---
  {
    ZiaEngine avec_pq = make_engine();
    ZiaPqPrekey pq;
    primitives::mlkem768_keypair(pq.public_key, pq.private_key);
    primitives::ed25519_sign(avec_pq.identity_private, pq.public_key,
                             primitives::kPqPublicKeyLen, pq.signature);
    avec_pq.pq_prekey = std::move(pq);

    const std::vector<uint8_t> v2 = storage::serialize_identity(avec_pq);
    assert(v2[0] == 2);

    ZiaEngine relu;
    assert(storage::deserialize_identity(v2.data(), v2.size(), relu));
    assert(relu.pq_prekey.has_value());
    assert(std::memcmp(relu.pq_prekey->public_key, avec_pq.pq_prekey->public_key,
                       primitives::kPqPublicKeyLen) == 0);
    assert(relu.pq_prekey->private_key.size() == primitives::kPqSecretKeyLen);
    assert(std::memcmp(relu.pq_prekey->private_key.data(),
                       avec_pq.pq_prekey->private_key.data(),
                       primitives::kPqSecretKeyLen) == 0);
    ok("Aller-retour v2 : la cle post-quantique survit au redemarrage");
  }

  // --- Une version inconnue est refusée, pas devinée ---
  {
    std::vector<uint8_t> futur = storage::serialize_identity(origine);
    futur[0] = 99;
    ZiaEngine relu;
    assert(!storage::deserialize_identity(futur.data(), futur.size(), relu));
    ok("Version inconnue refusee (pas d'interpretation au hasard)");
  }

  // --- Un fichier tronqué est refusé sans lire hors limites ---
  {
    const std::vector<uint8_t> v2 = storage::serialize_identity(origine);
    for (size_t coupe : {size_t{1}, v2.size() / 2, v2.size() - 1}) {
      ZiaEngine relu;
      assert(!storage::deserialize_identity(v2.data(), coupe, relu));
    }
    ok("Fichier tronque refuse proprement");
  }

  std::printf("\n%d verifications de migration reussies.\n", checks);
  return 0;
}
