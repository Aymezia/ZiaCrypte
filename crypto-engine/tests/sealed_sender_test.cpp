/**
 * Expediteur scelle : ce que l'enveloppe cache, et a qui elle s'ouvre.
 *
 * Le test central n'est pas l'aller-retour — il reussirait avec n'importe quel
 * chiffrement. C'est que l'enveloppe ne laisse RIEN filtrer de son auteur, et
 * qu'un tiers ne peut pas l'ouvrir.
 */
#include "zia/zia_crypto.h"

#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

namespace {
int echecs = 0;
void verifier(bool c, const char* quoi) {
  std::printf("  [%s] %s\n", c ? "ok" : "ECHEC", quoi);
  if (!c) ++echecs;
}
std::string dossier(const char* s) {
  auto p = std::filesystem::temp_directory_path() /
           ("zia_sealed_" + std::string(s) + "_" + std::to_string(::getpid()));
  std::filesystem::remove_all(p);
  std::filesystem::create_directories(p);
  return p.string();
}
} // namespace

int main() {
  std::printf("Expediteur scelle\n");

  ZiaStatus st = ZIA_OK;
  const std::string da = dossier("a"), db = dossier("b"), dc = dossier("c");

  uint8_t pub_a[32] = {}, pub_b[32] = {}, pub_c[32] = {};
  ZiaEngine* alice = zia_engine_init(da.c_str(), &st);
  ZiaEngine* bob = zia_engine_init(db.c_str(), &st);
  ZiaEngine* carol = zia_engine_init(dc.c_str(), &st);
  verifier(alice && bob && carol, "trois moteurs crees");
  zia_identity_generate(alice, pub_a);
  zia_identity_generate(bob, pub_b);
  zia_identity_generate(carol, pub_c);

  const char* secret = "expediteur-a-masquer-et-contenu-secret";
  const size_t n = std::strlen(secret);

  uint8_t* scelle = nullptr;
  size_t scelle_len = 0;
  verifier(zia_sealed_seal(pub_b, reinterpret_cast<const uint8_t*>(secret), n,
                           &scelle, &scelle_len) == ZIA_OK,
           "Alice scelle a destination de Bob");
  verifier(scelle_len > n, "l'enveloppe est plus longue que le clair");

  // Ce que le SERVEUR verrait : rien du contenu, rien de l'expediteur.
  bool fuite_contenu = false;
  for (size_t i = 0; scelle && i + n <= scelle_len; ++i) {
    if (std::memcmp(scelle + i, secret, n) == 0) { fuite_contenu = true; break; }
  }
  verifier(!fuite_contenu, "aucune trace du contenu en clair");

  bool fuite_identite = false;
  for (size_t i = 0; scelle && i + 32 <= scelle_len; ++i) {
    if (std::memcmp(scelle + i, pub_a, 32) == 0) { fuite_identite = true; break; }
  }
  verifier(!fuite_identite,
           "la cle d'identite de l'EXPEDITEUR n'apparait pas dans l'enveloppe");

  // Deux envois identiques doivent differer : sinon le serveur relierait les
  // messages entre eux, ce qui rendrait le scellement decoratif.
  uint8_t* scelle2 = nullptr;
  size_t scelle2_len = 0;
  zia_sealed_seal(pub_b, reinterpret_cast<const uint8_t*>(secret), n, &scelle2,
                  &scelle2_len);
  verifier(scelle2 && scelle2_len == scelle_len &&
               std::memcmp(scelle, scelle2, scelle_len) != 0,
           "deux envois du meme contenu donnent des octets differents");

  // Bob ouvre.
  uint8_t* clair = nullptr;
  size_t clair_len = 0;
  verifier(zia_sealed_open(bob, scelle, scelle_len, &clair, &clair_len) == ZIA_OK,
           "Bob ouvre l'enveloppe");
  verifier(clair_len == n && std::memcmp(clair, secret, n) == 0,
           "le contenu est intact");

  // Carol ne peut pas.
  uint8_t* vol = nullptr;
  size_t vol_len = 0;
  verifier(zia_sealed_open(carol, scelle, scelle_len, &vol, &vol_len) != ZIA_OK,
           "Carol NE PEUT PAS ouvrir une enveloppe destinee a Bob");

  // Enveloppe alteree.
  if (scelle && scelle_len > 0) {
    std::vector<uint8_t> altere(scelle, scelle + scelle_len);
    altere[scelle_len / 2] ^= 0xFF;
    uint8_t* x = nullptr; size_t xl = 0;
    verifier(zia_sealed_open(bob, altere.data(), altere.size(), &x, &xl) != ZIA_OK,
             "enveloppe alteree REFUSEE");
  }

  // Enveloppe tronquee.
  uint8_t* y = nullptr; size_t yl = 0;
  verifier(zia_sealed_open(bob, scelle, 8, &y, &yl) != ZIA_OK,
           "enveloppe tronquee REFUSEE");

  if (clair) zia_free_buffer(clair, clair_len);
  if (scelle) zia_free_buffer(scelle, scelle_len);
  if (scelle2) zia_free_buffer(scelle2, scelle2_len);
  zia_engine_shutdown(alice);
  zia_engine_shutdown(bob);
  zia_engine_shutdown(carol);
  std::filesystem::remove_all(da);
  std::filesystem::remove_all(db);
  std::filesystem::remove_all(dc);

  std::printf("%s\n", echecs == 0 ? "\nTout est conforme." : "\nDES TESTS ONT ECHOUE.");
  return echecs == 0 ? 0 : 1;
}
