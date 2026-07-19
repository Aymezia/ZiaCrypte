// Fabrique un corpus de départ pour le fuzzer.
//
// Un fuzzer parti de zéro passe l'essentiel de son temps à redécouvrir la
// structure des entrées : longueur d'en-tête exacte, forme d'un état de session
// sérialisé, en-tête de flux chiffré. Sur des formats contenant des champs
// authentifiés, il n'y arrive quasiment jamais tout seul.
//
// Les graines sont des artefacts VALIDES produits par le moteur lui-même. Le
// fuzzer part de là et les déforme : c'est ainsi qu'il atteint les chemins
// profonds, ceux qu'un attaquant viserait, au lieu de rebondir sur les
// contrôles d'entrée.
//
// Usage : fuzz_seed_corpus <dossier-de-sortie>

#include "zia/zia_crypto.h"

#include <sodium.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace {

/// Écrit une graine : premier octet = cible visée, puis la charge utile.
void ecrire(const std::filesystem::path& dir, const std::string& nom, uint8_t cible,
            const uint8_t* charge, size_t len) {
    std::ofstream f(dir / nom, std::ios::binary);
    f.put(static_cast<char>(cible));
    f.write(reinterpret_cast<const char*>(charge), static_cast<std::streamsize>(len));
    std::printf("   %-28s %zu octets\n", nom.c_str(), len + 1);
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: fuzz_seed_corpus <dossier>\n");
        return 2;
    }
    if (sodium_init() < 0) return 1;

    const std::filesystem::path dir = argv[1];
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);

    char modele[] = "/tmp/zia_seed_XXXXXX";
    const char* etat = mkdtemp(modele);
    if (!etat) return 1;

    ZiaStatus st = ZIA_OK;
    ZiaEngine* moteur = zia_engine_init(etat, &st);
    if (!moteur) return 1;

    uint8_t pub[ZIA_PUBLIC_KEY_LEN];
    zia_identity_generate(moteur, pub);

    ZiaPrekeyBundle bundle{};
    if (zia_prekey_bundle_generate(moteur, &bundle) != ZIA_OK) return 1;

    ZiaSession* session = nullptr;
    ZiaHandshakeMaterial handshake{};
    if (zia_session_from_bundle(moteur, &bundle, &session, &handshake) != ZIA_OK) return 1;

    std::printf(">> Graines écrites dans %s\n", dir.string().c_str());

    // Cible 0 : un message réellement chiffré (en-tête + ciphertext).
    {
        const char* clair = "message de depart pour le fuzzer";
        uint8_t *entete = nullptr, *chiffre = nullptr;
        size_t entete_len = 0, chiffre_len = 0;
        if (zia_session_encrypt(session, reinterpret_cast<const uint8_t*>(clair),
                                std::strlen(clair), &entete, &entete_len, &chiffre,
                                &chiffre_len) == ZIA_OK) {
            // Le harnais lit une longueur de coupe sur le premier octet : on la
            // place pour que l'en-tête et le ciphertext soient correctement
            // séparés dès la première exécution.
            std::vector<uint8_t> charge;
            charge.push_back(static_cast<uint8_t>(entete_len));
            charge.insert(charge.end(), entete, entete + entete_len);
            charge.insert(charge.end(), chiffre, chiffre + chiffre_len);
            ecrire(dir, "message_chiffre", 0, charge.data(), charge.size());
            zia_free_buffer(entete, entete_len);
            zia_free_buffer(chiffre, chiffre_len);
        }
    }

    // Cible 1 : un état de session sérialisé, valide.
    {
        uint8_t* donnees = nullptr;
        size_t len = 0;
        if (zia_session_serialize(session, &donnees, &len) == ZIA_OK) {
            ecrire(dir, "session_serialisee", 1, donnees, len);
            zia_free_buffer(donnees, len);
        }
    }

    // Cible 2 : une pièce jointe chiffrée, précédée de sa vraie clé.
    {
        const char* contenu = "contenu de piece jointe pour le corpus de depart";
        uint8_t cle[ZIA_ATTACHMENT_KEY_LEN];
        uint8_t* chiffre = nullptr;
        size_t chiffre_len = 0;
        if (zia_attachment_encrypt(reinterpret_cast<const uint8_t*>(contenu),
                                   std::strlen(contenu), cle, &chiffre,
                                   &chiffre_len) == ZIA_OK) {
            std::vector<uint8_t> charge(cle, cle + ZIA_ATTACHMENT_KEY_LEN);
            charge.insert(charge.end(), chiffre, chiffre + chiffre_len);
            ecrire(dir, "piece_jointe", 2, charge.data(), charge.size());
            zia_free_buffer(chiffre, chiffre_len);
        }
    }

    // Cible 3 : le matériel de handshake, tel qu'il circule sur le premier
    // message d'une session.
    ecrire(dir, "handshake", 3, reinterpret_cast<const uint8_t*>(&handshake),
           sizeof(handshake));

    zia_session_close(session);
    zia_engine_shutdown(moteur);
    std::filesystem::remove_all(etat, ec);
    return 0;
}
