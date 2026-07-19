// Vérifie que l'identité de l'appareil survit à un redémarrage du moteur.
//
// Sans cela, l'application régénérerait des clés à chaque lancement et
// l'utilisateur perdrait son compte : c'est la propriété la plus visible pour
// lui, donc elle est testée explicitement.

#include "zia/zia_crypto.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>

namespace {

int checks = 0;
void ok(const char* label) {
  ++checks;
  std::printf("[OK] %s\n", label);
}

ZiaEngine* open_engine(const std::string& path) {
  ZiaStatus status = ZIA_OK;
  ZiaEngine* engine = zia_engine_init(path.c_str(), &status);
  assert(status == ZIA_OK && engine != nullptr);
  return engine;
}

} // namespace

int main() {
  const std::string dir =
      (std::filesystem::temp_directory_path() / "zia_persistence_test").string();
  std::filesystem::remove_all(dir);
  std::filesystem::create_directories(dir);

  uint8_t first_identity[ZIA_PUBLIC_KEY_LEN];
  uint8_t first_bundle_spk[ZIA_PUBLIC_KEY_LEN];

  // --- Premier lancement : création de l'identité ---
  {
    ZiaEngine* engine = open_engine(dir);

    // Aucune identité au départ.
    uint8_t tmp[ZIA_PUBLIC_KEY_LEN];
    assert(zia_identity_get_public_key(engine, tmp) == ZIA_ERR_NOT_INITIALIZED);

    assert(zia_identity_generate(engine, first_identity) == ZIA_OK);

    ZiaPrekeyBundle bundle;
    assert(zia_prekey_bundle_generate(engine, &bundle) == ZIA_OK);
    std::memcpy(first_bundle_spk, bundle.signed_prekey, ZIA_PUBLIC_KEY_LEN);

    zia_engine_shutdown(engine);
    ok("Premier lancement : identité et prekeys créées");
  }

  assert(std::filesystem::exists(std::filesystem::path(dir) / "identity.zia"));
  ok("Le fichier d'identité chiffré est présent sur disque");

  // --- Second lancement : l'identité doit être rechargée telle quelle ---
  {
    ZiaEngine* engine = open_engine(dir);

    uint8_t reloaded[ZIA_PUBLIC_KEY_LEN];
    assert(zia_identity_get_public_key(engine, reloaded) == ZIA_OK);
    assert(std::memcmp(reloaded, first_identity, ZIA_PUBLIC_KEY_LEN) == 0);
    ok("Après redémarrage : même clé d'identité");

    // Regénérer doit être refusé : l'identité existe déjà.
    uint8_t ignored[ZIA_PUBLIC_KEY_LEN];
    assert(zia_identity_generate(engine, ignored) == ZIA_ERR_ALREADY_INITIALIZED);
    ok("Regénération refusée (l'identité existante est préservée)");

    // Le signed prekey rechargé est le même : les handshakes en cours restent
    // valides, et la clé privée nécessaire pour y répondre est bien là.
    ZiaPrekeyBundle bundle;
    assert(zia_prekey_bundle_generate(engine, &bundle) == ZIA_OK);
    assert(std::memcmp(bundle.signed_prekey, first_bundle_spk, ZIA_PUBLIC_KEY_LEN) == 0);
    assert(std::memcmp(bundle.identity_key, first_identity, ZIA_PUBLIC_KEY_LEN) == 0);
    ok("Signed prekey conservé (les handshakes entrants restent déchiffrables)");

    // La signature du signed prekey doit toujours se vérifier avec l'identité.
    assert(zia_verify_signature(bundle.identity_key, bundle.signed_prekey,
                                ZIA_PUBLIC_KEY_LEN,
                                bundle.signed_prekey_signature) == ZIA_OK);
    ok("Signature du signed prekey toujours valide après rechargement");

    zia_engine_shutdown(engine);
  }

  // --- Coffre local : ce qu'on y range survit et reste chiffré ---
  {
    ZiaEngine* engine = open_engine(dir);
    const char* payload = "historique de conversation, en clair uniquement en memoire";
    const size_t payload_len = std::strlen(payload);

    assert(zia_secure_write(engine, "historique-alice",
                            reinterpret_cast<const uint8_t*>(payload),
                            payload_len) == ZIA_OK);

    // Une entrée inexistante se signale proprement, sans erreur fatale.
    uint8_t* absent = nullptr;
    size_t absent_len = 0;
    assert(zia_secure_read(engine, "jamais-ecrit", &absent, &absent_len) ==
           ZIA_ERR_SESSION_NOT_FOUND);

    // Un nom malveillant ne doit pas pouvoir sortir du coffre.
    assert(zia_secure_write(engine, "../../evasion",
                            reinterpret_cast<const uint8_t*>(payload), payload_len) ==
           ZIA_ERR_STORAGE_IO);
    ok("Coffre local : nom de fichier malveillant refusé");

    zia_engine_shutdown(engine);

    // Relecture après redémarrage du moteur.
    engine = open_engine(dir);
    uint8_t* read_back = nullptr;
    size_t read_len = 0;
    assert(zia_secure_read(engine, "historique-alice", &read_back, &read_len) == ZIA_OK);
    assert(read_len == payload_len);
    assert(std::memcmp(read_back, payload, payload_len) == 0);
    zia_free_buffer(read_back, read_len);
    ok("Coffre local : contenu retrouvé intact après redémarrage");

    // Le fichier sur disque ne doit pas contenir le texte en clair.
    const auto blob = std::filesystem::path(dir) / "vault" / "historique-alice.zia";
    assert(std::filesystem::exists(blob));
    std::ifstream f(blob, std::ios::binary);
    const std::string raw((std::istreambuf_iterator<char>(f)),
                          std::istreambuf_iterator<char>());
    assert(raw.find("historique de conversation") == std::string::npos);
    ok("Coffre local : rien en clair sur le disque");

    zia_engine_shutdown(engine);
  }

  // --- Un autre emplacement de stockage donne une identité distincte ---
  {
    const std::string other = dir + "_autre";
    std::filesystem::remove_all(other);
    ZiaEngine* engine = open_engine(other);

    uint8_t fresh[ZIA_PUBLIC_KEY_LEN];
    assert(zia_identity_generate(engine, fresh) == ZIA_OK);
    assert(std::memcmp(fresh, first_identity, ZIA_PUBLIC_KEY_LEN) != 0);
    ok("Un autre appareil obtient bien une identité différente");

    zia_engine_shutdown(engine);
    std::filesystem::remove_all(other);
  }

  std::filesystem::remove_all(dir);
  std::printf("\n%d/%d verifications reussies — l'identite survit au redemarrage.\n",
              checks, checks);
  return 0;
}
