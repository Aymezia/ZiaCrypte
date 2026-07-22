/**
 * Éprouve les clés d'expéditeur de groupe.
 *
 * Trois moteurs distincts — un émetteur, deux membres — chacun avec son propre
 * stockage. C'est le seul montage qui prouve ce qui compte : un message chiffré
 * UNE fois se déchiffre chez PLUSIEURS destinataires, et seulement chez ceux à
 * qui la clé a été distribuée.
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

std::string dossier(const char* suffixe) {
    auto p = std::filesystem::temp_directory_path() /
             ("zia_sk_test_" + std::string(suffixe) + "_" + std::to_string(::getpid()));
    std::filesystem::remove_all(p);
    std::filesystem::create_directories(p);
    return p.string();
}

/* Déchiffre et compare au texte attendu. */
bool lit(ZiaEngine* e, const char* groupe, const char* expediteur, const uint8_t* msg,
         size_t msg_len, const char* attendu) {
    uint8_t* clair = nullptr;
    size_t clair_len = 0;
    if (zia_sender_key_decrypt(e, groupe, expediteur, msg, msg_len, &clair, &clair_len) != ZIA_OK) {
        return false;
    }
    const bool ok = clair_len == std::strlen(attendu) &&
                    std::memcmp(clair, attendu, clair_len) == 0;
    zia_free_buffer(clair, clair_len);
    return ok;
}

} // namespace

int main() {
    std::printf("Clés d'expéditeur de groupe\n");

    const std::string da = dossier("a"), db = dossier("b"), dc = dossier("c");
    const char* GROUPE = "groupe-test";

    ZiaStatus st = ZIA_OK;
    ZiaEngine* alice = zia_engine_init(da.c_str(), &st);
    ZiaEngine* bob = zia_engine_init(db.c_str(), &st);
    ZiaEngine* carol = zia_engine_init(dc.c_str(), &st);
    verifier(alice && bob && carol, "trois moteurs créés");

    // --- Alice crée sa clé d'expéditeur et la distribue --------------------
    uint8_t* distrib = nullptr;
    size_t distrib_len = 0;
    verifier(zia_sender_key_create(alice, GROUPE, &distrib, &distrib_len) == ZIA_OK,
             "clé d'expéditeur créée");
    verifier(distrib_len == 76, "message de distribution de taille attendue");

    verifier(zia_sender_key_process(bob, GROUPE, "alice", distrib, distrib_len) == ZIA_OK,
             "Bob enregistre la clé d'Alice");
    verifier(zia_sender_key_process(carol, GROUPE, "alice", distrib, distrib_len) == ZIA_OK,
             "Carol enregistre la clé d'Alice");

    // --- UN chiffrement, DEUX lecteurs ------------------------------------
    const char* texte = "bonjour le groupe";
    uint8_t* msg = nullptr;
    size_t msg_len = 0;
    verifier(zia_sender_key_encrypt(alice, GROUPE,
                                    reinterpret_cast<const uint8_t*>(texte),
                                    std::strlen(texte), &msg, &msg_len) == ZIA_OK,
             "message chiffré UNE fois");

    // Le clair ne doit apparaître nulle part dans le chiffré.
    bool fuite = false;
    for (size_t i = 0; msg && i + std::strlen(texte) <= msg_len; ++i) {
        if (std::memcmp(msg + i, texte, std::strlen(texte)) == 0) { fuite = true; break; }
    }
    verifier(!fuite, "aucune trace en clair dans le message");

    verifier(lit(bob, GROUPE, "alice", msg, msg_len, texte), "Bob déchiffre");
    verifier(lit(carol, GROUPE, "alice", msg, msg_len, texte), "Carol déchiffre");

    // --- Un non-membre ne peut rien en faire ------------------------------
    const std::string dd = dossier("d");
    ZiaEngine* mallory = zia_engine_init(dd.c_str(), &st);
    uint8_t* vain = nullptr;
    size_t vain_len = 0;
    verifier(zia_sender_key_decrypt(mallory, GROUPE, "alice", msg, msg_len, &vain, &vain_len) !=
                 ZIA_OK,
             "un non-membre ne déchiffre PAS");

    // --- Altération refusée -----------------------------------------------
    {
        std::vector<uint8_t> altere(msg, msg + msg_len);
        altere[msg_len / 2] ^= 0xFF;
        uint8_t* x = nullptr; size_t xl = 0;
        verifier(zia_sender_key_decrypt(bob, GROUPE, "alice", altere.data(), altere.size(), &x,
                                        &xl) != ZIA_OK,
                 "message altéré REFUSÉ");
    }

    // --- Message rejoué dans un AUTRE groupe : refusé ---------------------
    // Le groupe entre dans les données additionnelles : sans ça, un message
    // pourrait être replacé dans une autre conversation.
    {
        uint8_t* d2 = nullptr; size_t d2l = 0;
        zia_sender_key_create(alice, "autre-groupe", &d2, &d2l);
        zia_sender_key_process(bob, "autre-groupe", "alice", d2, d2l);
        uint8_t* x = nullptr; size_t xl = 0;
        verifier(zia_sender_key_decrypt(bob, "autre-groupe", "alice", msg, msg_len, &x, &xl) !=
                     ZIA_OK,
                 "message rejoué dans un autre groupe REFUSÉ");
        zia_free_buffer(d2, d2l);
    }

    // --- Hors séquence : le retardataire reste lisible ---------------------
    uint8_t *m1 = nullptr, *m2 = nullptr, *m3 = nullptr;
    size_t l1 = 0, l2 = 0, l3 = 0;
    zia_sender_key_encrypt(alice, GROUPE, reinterpret_cast<const uint8_t*>("un"), 2, &m1, &l1);
    zia_sender_key_encrypt(alice, GROUPE, reinterpret_cast<const uint8_t*>("deux"), 4, &m2, &l2);
    zia_sender_key_encrypt(alice, GROUPE, reinterpret_cast<const uint8_t*>("trois"), 5, &m3, &l3);

    // Carol reçoit le troisième d'abord, puis les deux précédents.
    verifier(lit(carol, GROUPE, "alice", m3, l3, "trois"), "message 3 lu en premier");
    verifier(lit(carol, GROUPE, "alice", m1, l1, "un"), "message 1 lu APRÈS (clé sautée gardée)");
    verifier(lit(carol, GROUPE, "alice", m2, l2, "deux"), "message 2 lu APRÈS");

    // Rejeu du même message : la clé sautée a été consommée.
    verifier(!lit(carol, GROUPE, "alice", m1, l1, "un"), "rejeu du message 1 REFUSÉ");

    // --- Rotation : l'ancienne clé ne lit plus la suite --------------------
    // C'est ce qui doit être fait au départ d'un membre.
    {
        uint8_t* d3 = nullptr; size_t d3l = 0;
        verifier(zia_sender_key_create(alice, GROUPE, &d3, &d3l) == ZIA_OK,
                 "clé d'expéditeur renouvelée");
        uint8_t* apres = nullptr; size_t apres_len = 0;
        zia_sender_key_encrypt(alice, GROUPE, reinterpret_cast<const uint8_t*>("secret"), 6,
                               &apres, &apres_len);
        // Bob n'a pas reçu la nouvelle distribution : il ne doit pas suivre.
        uint8_t* x = nullptr; size_t xl = 0;
        verifier(zia_sender_key_decrypt(bob, GROUPE, "alice", apres, apres_len, &x, &xl) != ZIA_OK,
                 "après rotation, l'ancienne clé ne lit PLUS");
        // Une fois la nouvelle distribution reçue, il suit de nouveau.
        verifier(zia_sender_key_process(bob, GROUPE, "alice", d3, d3l) == ZIA_OK,
                 "nouvelle distribution acceptée");
        verifier(lit(bob, GROUPE, "alice", apres, apres_len, "secret"),
                 "Bob relit après la nouvelle distribution");
        zia_free_buffer(d3, d3l);
        zia_free_buffer(apres, apres_len);
    }

    // --- Chiffrer sans clé : refusé ---------------------------------------
    uint8_t* y = nullptr; size_t yl = 0;
    verifier(zia_sender_key_encrypt(bob, "groupe-inconnu",
                                    reinterpret_cast<const uint8_t*>("x"), 1, &y, &yl) != ZIA_OK,
             "chiffrer sans clé d'expéditeur REFUSÉ");

    zia_free_buffer(distrib, distrib_len);
    zia_free_buffer(msg, msg_len);
    zia_free_buffer(m1, l1);
    zia_free_buffer(m2, l2);
    zia_free_buffer(m3, l3);
    zia_engine_shutdown(alice);
    zia_engine_shutdown(bob);
    zia_engine_shutdown(carol);
    zia_engine_shutdown(mallory);
    std::filesystem::remove_all(da);
    std::filesystem::remove_all(db);
    std::filesystem::remove_all(dc);
    std::filesystem::remove_all(dd);

    std::printf("%s\n", echecs == 0 ? "\nTout est conforme." : "\nDES TESTS ONT ÉCHOUÉ.");
    return echecs == 0 ? 0 : 1;
}
