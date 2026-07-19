// Fuzzing des points d'entrée qui reçoivent des octets venus de l'extérieur.
//
// Ces fonctions analysent des données qu'un attaquant contrôle entièrement :
// l'en-tête ratchet et le ciphertext arrivent du réseau via un serveur qu'on ne
// suppose PAS honnête, et le contenu des pièces jointes vient d'un hébergeur de
// stockage tiers. Une corruption mémoire y serait exploitable à distance.
//
// Les tests de conformité ne couvrent que des entrées valides : ils vérifient
// que le protocole fonctionne, pas qu'il résiste à ce qui est malformé. Le
// fuzzing s'attaque exactement à l'angle mort restant.
//
// Compilé avec libFuzzer + ASan/UBSan (preset linux-fuzz).

#include "zia/zia_crypto.h"

#include <sodium.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>

namespace {

ZiaEngine* g_engine = nullptr;
ZiaSession* g_session = nullptr;
std::string g_dir;

/// Prépare une fois pour toutes un moteur et une session réelle.
///
/// Fuzzer `zia_session_decrypt` sans session ouverte ne testerait que le refus
/// d'un pointeur nul. Ce qui nous intéresse est le chemin d'analyse complet,
/// avec un état de ratchet valide derrière.
void setup() {
  if (sodium_init() < 0) std::abort();

  // Dossier NEUF à chaque exécution.
  //
  // Un dossier réutilisé contient déjà une identité, que le moteur tente alors
  // de relire — ce qui réclame le trousseau du système, absent en CI comme
  // sous un fuzzer. Le processus se figeait avant même la bannière de
  // libFuzzer, donnant l'impression d'un fuzzing qui tourne sans jamais rien
  // trouver. Repartir de zéro évite entièrement ce chemin.
  char modele[] = "/tmp/zia_fuzz_XXXXXX";
  const char* dir = mkdtemp(modele);
  if (!dir) std::abort();
  g_dir = dir;

  ZiaStatus status = ZIA_OK;
  g_engine = zia_engine_init(dir, &status);
  if (!g_engine) return;

  if (zia_identity_generate(g_engine, nullptr) != ZIA_OK) {
    uint8_t pub[ZIA_PUBLIC_KEY_LEN];
    zia_identity_generate(g_engine, pub);
  }

  // Un correspondant fictif : son bundle sert à ouvrir une vraie session.
  ZiaPrekeyBundle bundle{};
  if (zia_prekey_bundle_generate(g_engine, &bundle) != ZIA_OK) return;

  ZiaHandshakeMaterial handshake{};
  zia_session_from_bundle(g_engine, &bundle, &g_session, &handshake);
}

/// Arrêt propre à la sortie.
///
/// Sans cela, le processus se fige à la terminaison : LeakSanitizer balaie la
/// mémoire et bute sur les pages verrouillées de l'allocateur sécurisé de
/// libsodium, que le moteur détient encore. Le fuzzer ne rendait alors JAMAIS
/// la main — il paraissait tourner sans jamais afficher le moindre résultat.
void teardown() {
  if (g_session) {
    zia_session_close(g_session);
    g_session = nullptr;
  }
  if (g_engine) {
    zia_engine_shutdown(g_engine);
    g_engine = nullptr;
  }
  if (!g_dir.empty()) {
    std::error_code ec;
    std::filesystem::remove_all(g_dir, ec);
    g_dir.clear();
  }
}

struct Init {
  Init() {
    setup();
    std::atexit(teardown);
  }
} g_init;

} // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (size < 2) return 0;

  // Le premier octet choisit la cible, le reste est la donnée hostile.
  const uint8_t cible = data[0] % 4;
  const uint8_t* charge = data + 1;
  const size_t charge_len = size - 1;

  switch (cible) {
    case 0: {
      // En-tête ratchet et ciphertext arbitraires sur une session valide.
      // C'est le chemin le plus exposé : ces octets viennent du réseau à
      // chaque message reçu.
      if (!g_session || charge_len < 2) break;
      const size_t coupe = charge[0] % charge_len;
      uint8_t* sortie = nullptr;
      size_t sortie_len = 0;
      const ZiaStatus st = zia_session_decrypt(
          g_session, charge + 1, coupe, charge + 1 + coupe,
          charge_len - 1 - coupe, &sortie, &sortie_len);
      // Un succès sur des octets aléatoires serait une faille en soi : le
      // chiffrement authentifié doit les rejeter.
      if (st == ZIA_OK && sortie) zia_free_buffer(sortie, sortie_len);
      break;
    }
    case 1: {
      // Session sérialisée corrompue. Elle vient du coffre local, mais un
      // fichier altéré ne doit pas faire mieux qu'échouer proprement.
      if (!g_engine) break;
      ZiaSession* restauree = nullptr;
      if (zia_session_deserialize(g_engine, charge, charge_len, &restauree) ==
              ZIA_OK &&
          restauree) {
        zia_session_close(restauree);
      }
      break;
    }
    case 2: {
      // Contenu de pièce jointe fourni par l'hébergeur de stockage, avec une
      // clé arbitraire.
      if (charge_len <= ZIA_ATTACHMENT_KEY_LEN) break;
      uint8_t* clair = nullptr;
      size_t clair_len = 0;
      if (zia_attachment_decrypt(charge, charge + ZIA_ATTACHMENT_KEY_LEN,
                                 charge_len - ZIA_ATTACHMENT_KEY_LEN, &clair,
                                 &clair_len) == ZIA_OK &&
          clair) {
        zia_free_buffer(clair, clair_len);
      }
      break;
    }
    case 3: {
      // Matériel de handshake malformé : reçu sur le PREMIER message d'une
      // session, donc avant toute authentification de l'expéditeur.
      if (!g_engine || charge_len < sizeof(ZiaHandshakeMaterial)) break;
      ZiaHandshakeMaterial handshake{};
      std::memcpy(&handshake, charge, sizeof(handshake));
      ZiaSession* ouverte = nullptr;
      if (zia_session_accept_handshake(g_engine, &handshake, &ouverte) ==
              ZIA_OK &&
          ouverte) {
        zia_session_close(ouverte);
      }
      break;
    }
  }
  return 0;
}
