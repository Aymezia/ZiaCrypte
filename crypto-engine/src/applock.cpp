#include "zia/zia_crypto.h"
#include "engine_internal.hpp"
#include "storage/secure_blob.hpp"

#include <sodium.h>

#include <cstring>
#include <string>
#include <vector>

/**
 * Code de verrouillage de l'application.
 *
 * ## Ce que ça protège, et ce que ça ne protège pas
 *
 * Un téléphone déverrouillé posé sur une table, un ordinateur laissé ouvert :
 * ce code interdit la lecture des conversations à qui passe par là. C'est tout,
 * et c'est déjà beaucoup, parce que c'est de loin la manière la plus fréquente
 * dont une conversation est lue par quelqu'un d'autre.
 *
 * Il ne protège PAS d'un adversaire qui possède l'appareil et sait ce qu'il
 * fait : les clés restent déchiffrables par le coffre-fort du système dès que
 * la session utilisateur est ouverte, indépendamment de ce code. Prétendre le
 * contraire supposerait de dériver la clé du coffre depuis le code — ce qui
 * empêcherait de recevoir les messages application fermée, et transformerait un
 * code à quatre chiffres oublié en perte définitive du compte.
 *
 * ## Pourquoi le moteur et pas Dart
 *
 * `crypto_pwhash_str` produit une chaîne autonome contenant sel, paramètres et
 * empreinte, et `crypto_pwhash_str_verify` la vérifie en temps constant. Écrire
 * cela en Dart supposerait d'y faire de la cryptographie, ce que ce projet
 * s'interdit — et une comparaison naïve de chaînes fuirait par le temps de
 * réponse.
 */

using namespace zia::crypto;

namespace {
constexpr const char* kEntree = "app_lock";

/**
 * Paramètres délibérément élevés pour un code court.
 *
 * Un code à quatre ou six chiffres n'a que quelques milliers à un million de
 * possibilités : sans coût par essai, il tombe instantanément. INTERACTIVE
 * (64 Mio, 2 passes) porte chaque essai à une fraction de seconde, ce qui rend
 * l'énumération hors ligne coûteuse sans rendre le déverrouillage pénible.
 */
constexpr unsigned long long kOps = crypto_pwhash_OPSLIMIT_INTERACTIVE;
constexpr size_t kMem = crypto_pwhash_MEMLIMIT_INTERACTIVE;
} // namespace

ZIA_API ZiaStatus zia_app_lock_set(ZiaEngine* engine, const char* code) {
  if (!engine || !code) return ZIA_ERR_INVALID_ARG;
  const size_t len = std::strlen(code);
  if (len < 4 || len > 128) {
    engine->last_error = "code trop court ou trop long";
    return ZIA_ERR_INVALID_ARG;
  }

  char hash[crypto_pwhash_STRBYTES];
  if (crypto_pwhash_str(hash, code, len, kOps, kMem) != 0) {
    engine->last_error = "memoire insuffisante pour deriver le code";
    return ZIA_ERR_OUT_OF_MEMORY;
  }

  const bool ok = storage::secure_write(
      *engine, kEntree, reinterpret_cast<const uint8_t*>(hash),
      std::strlen(hash) + 1);
  sodium_memzero(hash, sizeof(hash));
  return ok ? ZIA_OK : ZIA_ERR_STORAGE_IO;
}

ZIA_API ZiaStatus zia_app_lock_verify(ZiaEngine* engine, const char* code) {
  if (!engine || !code) return ZIA_ERR_INVALID_ARG;

  std::vector<uint8_t> stocke;
  if (!storage::secure_read(*engine, kEntree, stocke) || stocke.empty()) {
    // Aucun code posé : ce n'est pas un échec de vérification.
    return ZIA_ERR_SESSION_NOT_FOUND;
  }
  // Terminaison garantie avant de la passer à une fonction C : une entrée
  // tronquée ferait lire au-delà du tampon.
  if (stocke.back() != '\0') stocke.push_back('\0');

  const int rc = crypto_pwhash_str_verify(
      reinterpret_cast<const char*>(stocke.data()), code, std::strlen(code));
  sodium_memzero(stocke.data(), stocke.size());
  return rc == 0 ? ZIA_OK : ZIA_ERR_CRYPTO_FAILURE;
}

ZIA_API ZiaStatus zia_app_lock_status(ZiaEngine* engine, int* out_set) {
  if (!engine || !out_set) return ZIA_ERR_INVALID_ARG;
  std::vector<uint8_t> stocke;
  *out_set = storage::secure_read(*engine, kEntree, stocke) && !stocke.empty();
  if (!stocke.empty()) sodium_memzero(stocke.data(), stocke.size());
  return ZIA_OK;
}

ZIA_API ZiaStatus zia_app_lock_clear(ZiaEngine* engine) {
  if (!engine) return ZIA_ERR_INVALID_ARG;
  return storage::secure_erase(*engine, kEntree) ? ZIA_OK : ZIA_ERR_STORAGE_IO;
}
