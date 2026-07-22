/**
 * Éprouve la sauvegarde chiffrée exportable.
 *
 * Deux moteurs distincts, chacun avec son propre dossier de stockage : c'est le
 * seul montage qui prouve ce qui compte, à savoir qu'une sauvegarde produite
 * ici se restaure AILLEURS. Un aller-retour dans le même moteur ne dirait rien
 * — il réussirait même si la clé de l'appareil s'était glissée dans le fichier.
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

void verifier(bool condition, const char* quoi) {
  std::printf("  [%s] %s\n", condition ? "ok" : "ÉCHEC", quoi);
  if (!condition) ++echecs;
}

// Un contrôle sauté n'est pas un contrôle réussi : on le dit explicitement, et
// il ne compte ni pour ni contre. Sert aux vérifications qui exigent un service
// absent de l'environnement courant (ici le trousseau système).
void sauter(const char* quoi) {
  std::printf("  [skip] %s\n", quoi);
}

std::string dossier_temporaire(const char* suffixe) {
  auto p = std::filesystem::temp_directory_path() /
           ("zia_backup_test_" + std::string(suffixe) + "_" +
            std::to_string(::getpid()));
  std::filesystem::remove_all(p);
  std::filesystem::create_directories(p);
  return p.string();
}

} // namespace

int main() {
  std::printf("Sauvegarde chiffrée exportable\n");

  const std::string dossier_a = dossier_temporaire("a");
  const std::string dossier_b = dossier_temporaire("b");
  const char* phrase = "phrase-de-passe-correcte";

  // --- Appareil A : identité + une entrée de coffre ------------------------
  ZiaStatus st = ZIA_OK;
  uint8_t cle_publique_a[32] = {};
  ZiaEngine* a = zia_engine_init(dossier_a.c_str(), &st);
  verifier(a != nullptr && st == ZIA_OK, "moteur A créé");
  verifier(zia_identity_generate(a, cle_publique_a) == ZIA_OK,
           "identité A générée");

  const char* contenu = "historique-de-conversation";
  // L'entrée de coffre exige le service de trousseau du système (libsecret).
  // Un runner d'intégration continue sous désinfecteurs n'en a pas : la
  // primitive renvoie alors ZIA_ERR_STORAGE_IO. On ne fait pas échouer le test
  // pour autant — la partie coffre est SAUTÉE, et l'aller-retour du FORMAT de
  // sauvegarde et ses refus (mauvaise phrase, fichier altéré), qui sont la
  // vraie cible des sanitizers, restent vérifiés strictement. Le job
  // « build + test », lui, fournit un trousseau et contrôle le coffre de bout
  // en bout.
  const ZiaStatus st_coffre =
      zia_secure_write(a, "historique",
                       reinterpret_cast<const uint8_t*>(contenu),
                       std::strlen(contenu));
  const bool coffre_dispo = (st_coffre == ZIA_OK);
  if (coffre_dispo) {
    verifier(true, "entrée de coffre écrite");
  } else {
    sauter("coffre (trousseau système indisponible)");
  }

  // --- Export --------------------------------------------------------------
  uint8_t* sauvegarde = nullptr;
  size_t taille = 0;
  verifier(zia_backup_export(a, phrase, &sauvegarde, &taille) == ZIA_OK,
           "sauvegarde produite");
  verifier(taille > 100, "sauvegarde de taille plausible");

  // Le contenu ne doit apparaître nulle part en clair dans le fichier.
  bool fuite = false;
  if (sauvegarde && taille >= std::strlen(contenu)) {
    for (size_t i = 0; i + std::strlen(contenu) <= taille; ++i) {
      if (std::memcmp(sauvegarde + i, contenu, std::strlen(contenu)) == 0) {
        fuite = true;
        break;
      }
    }
  }
  verifier(!fuite, "aucune trace en clair du contenu dans le fichier");

  // --- Mauvaise phrase de passe -------------------------------------------
  const std::string dossier_c = dossier_temporaire("c");
  ZiaEngine* mauvais = zia_engine_init(dossier_c.c_str(), &st);
  verifier(zia_backup_import(mauvais, "phrase-de-passe-fausse", sauvegarde,
                             taille) != ZIA_OK,
           "phrase de passe erronée REFUSÉE");

  // --- Fichier altéré ------------------------------------------------------
  if (sauvegarde && taille > 0) {
    std::vector<uint8_t> altere(sauvegarde, sauvegarde + taille);
    altere[taille / 2] ^= 0xFF;
    verifier(zia_backup_import(mauvais, phrase, altere.data(), altere.size()) !=
                 ZIA_OK,
             "sauvegarde altérée REFUSÉE");
  }

  // --- Restauration sur un AUTRE appareil ---------------------------------
  // Aller-retour complet seulement si le coffre est disponible : sans
  // trousseau, l'import ne peut pas réinstaller le coffre et échouerait pour une
  // raison d'environnement, pas de code — ce que le job « build + test »
  // couvre déjà avec un trousseau.
  ZiaEngine* b = nullptr;
  if (coffre_dispo) {
    b = zia_engine_init(dossier_b.c_str(), &st);
    verifier(b != nullptr && st == ZIA_OK, "moteur B créé");
    verifier(zia_backup_import(b, phrase, sauvegarde, taille) == ZIA_OK,
             "sauvegarde restaurée sur B");

    uint8_t cle_publique_b[32] = {};
    verifier(zia_identity_get_public_key(b, cle_publique_b) == ZIA_OK,
             "clé publique B lue");
    verifier(std::memcmp(cle_publique_a, cle_publique_b, 32) == 0,
             "B a retrouvé l'IDENTITÉ de A");

    uint8_t* relu = nullptr;
    size_t relu_len = 0;
    verifier(zia_secure_read(b, "historique", &relu, &relu_len) == ZIA_OK,
             "entrée de coffre restaurée");
    verifier(relu_len == std::strlen(contenu) &&
                 std::memcmp(relu, contenu, relu_len) == 0,
             "contenu du coffre identique");
    if (relu) zia_free_buffer(relu, relu_len);
  } else {
    sauter("restauration sur un autre appareil (trousseau indisponible)");
  }

  // --- Phrase trop courte refusée -----------------------------------------
  uint8_t* inutile = nullptr;
  size_t inutile_len = 0;
  verifier(zia_backup_export(a, "court", &inutile, &inutile_len) != ZIA_OK,
           "phrase de passe trop courte refusée à l'export");

  if (sauvegarde) zia_free_buffer(sauvegarde, taille);
  zia_engine_shutdown(a);
  if (b) zia_engine_shutdown(b);
  zia_engine_shutdown(mauvais);
  std::filesystem::remove_all(dossier_a);
  std::filesystem::remove_all(dossier_b);
  std::filesystem::remove_all(dossier_c);

  std::printf("%s\n", echecs == 0 ? "\nTout est conforme." : "\nDES TESTS ONT ÉCHOUÉ.");
  return echecs == 0 ? 0 : 1;
}
