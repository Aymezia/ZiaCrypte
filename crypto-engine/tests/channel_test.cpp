// Canaux de diffusion : le lien porte la clé de lecture.
//
// Ce test valide les deux propriétés qui font tout l'intérêt d'un canal
// chiffré ET ouvert, et qui casseraient en silence :
//
//   1. Qui détient le lien lit — le blob scellé, déscellé avec le bon secret,
//      redonne EXACTEMENT la distribution, et un abonné l'importe puis lit un
//      message publié par l'admin.
//   2. Qui n'a pas le lien ne lit rien — un secret erroné, un blob altéré, un
//      blob tronqué échouent sans jamais rendre une distribution utilisable.
//
// La signature de l'admin est le troisième pilier : un abonné détient la clé
// de chaîne (il lit) mais PAS la clé de signature privée (il ne peut pas
// publier). On le vérifie en montrant qu'un abonné ne peut pas produire un
// message que d'autres accepteraient.

#include "zia/zia_crypto.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct Engine {
    ZiaEngine* handle;
    explicit Engine(const char* path) {
        ZiaStatus st;
        handle = zia_engine_init(path, &st);
        assert(st == ZIA_OK && handle != nullptr);
        uint8_t pub[ZIA_PUBLIC_KEY_LEN];
        assert(zia_identity_generate(handle, pub) == ZIA_OK);
    }
    ~Engine() { zia_engine_shutdown(handle); }
};

std::vector<uint8_t> seal(const uint8_t secret[32], const std::vector<uint8_t>& distribution) {
    uint8_t* out = nullptr;
    size_t out_len = 0;
    assert(zia_channel_seal_key(secret, distribution.data(), distribution.size(),
                                &out, &out_len) == ZIA_OK);
    std::vector<uint8_t> r(out, out + out_len);
    zia_free_buffer(out, out_len);
    return r;
}

int checks = 0;
void ok(const char* label) { ++checks; std::printf("[OK] %s\n", label); }

} // namespace

int main() {
    const char* channel = "canal-annonces";

    Engine admin("/tmp/zia_channel_admin");
    Engine abonne("/tmp/zia_channel_sub");

    // L'admin crée la clé du canal et récupère la distribution (matériel de
    // lecture). Son identifiant d'expéditeur dans le canal est vide, comme pour
    // notre propre clé de groupe.
    uint8_t* distribution = nullptr;
    size_t dist_len = 0;
    assert(zia_sender_key_create(admin.handle, channel, &distribution, &dist_len) == ZIA_OK);
    std::vector<uint8_t> distr(distribution, distribution + dist_len);
    zia_free_buffer(distribution, dist_len);

    // Le secret du lien : 32 octets aléatoires, ce qui voyagerait après le « # »
    // du lien d'invitation.
    uint8_t link_secret[ZIA_CHANNEL_LINK_SECRET_LEN];
    for (size_t i = 0; i < sizeof(link_secret); ++i) link_secret[i] = static_cast<uint8_t>(i * 7 + 1);

    // --- 1. Le lien porte la clé : sceller puis désceller redonne la distribution ---
    std::vector<uint8_t> sealed = seal(link_secret, distr);
    assert(sealed.size() > distr.size()); // nonce + tag ajoutés
    {
        uint8_t* opened = nullptr;
        size_t opened_len = 0;
        assert(zia_channel_open_key(link_secret, sealed.data(), sealed.size(),
                                    &opened, &opened_len) == ZIA_OK);
        assert(opened_len == distr.size());
        assert(std::memcmp(opened, distr.data(), distr.size()) == 0);
        zia_free_buffer(opened, opened_len);
        ok("Le blob scelle, ouvert avec le bon secret, redonne la distribution");
    }

    // --- Bout en bout : l'abonné importe la distribution et LIT un message ---
    {
        uint8_t* opened = nullptr;
        size_t opened_len = 0;
        assert(zia_channel_open_key(link_secret, sealed.data(), sealed.size(),
                                    &opened, &opened_len) == ZIA_OK);
        // « admin » : l'identifiant sous lequel l'abonné range la clé de l'admin.
        assert(zia_sender_key_process(abonne.handle, channel, "admin",
                                      opened, opened_len) == ZIA_OK);
        zia_free_buffer(opened, opened_len);

        const std::string message = "Annonce : la version 0.11 est disponible.";
        uint8_t* ct = nullptr;
        size_t ct_len = 0;
        assert(zia_sender_key_encrypt(admin.handle, channel,
                   reinterpret_cast<const uint8_t*>(message.data()), message.size(),
                   &ct, &ct_len) == ZIA_OK);

        uint8_t* pt = nullptr;
        size_t pt_len = 0;
        assert(zia_sender_key_decrypt(abonne.handle, channel, "admin", ct, ct_len,
                                      &pt, &pt_len) == ZIA_OK);
        assert(std::string(reinterpret_cast<char*>(pt), pt_len) == message);
        zia_free_buffer(ct, ct_len);
        zia_free_buffer(pt, pt_len);
        ok("Un abonne muni du lien lit un message publie par l'admin");
    }

    // --- 2a. Un secret erroné n'ouvre rien ---
    {
        uint8_t mauvais[ZIA_CHANNEL_LINK_SECRET_LEN];
        std::memcpy(mauvais, link_secret, sizeof(mauvais));
        mauvais[0] ^= 0xFF;
        uint8_t* opened = nullptr;
        size_t opened_len = 0;
        assert(zia_channel_open_key(mauvais, sealed.data(), sealed.size(),
                                    &opened, &opened_len) == ZIA_ERR_CRYPTO_FAILURE);
        ok("Un secret de lien errone est rejete (pas de descellement partiel)");
    }

    // --- 2b. Un blob altéré n'ouvre rien ---
    {
        std::vector<uint8_t> altere = sealed;
        altere[altere.size() - 1] ^= 0x80; // touche le tag d'authentification
        uint8_t* opened = nullptr;
        size_t opened_len = 0;
        assert(zia_channel_open_key(link_secret, altere.data(), altere.size(),
                                    &opened, &opened_len) == ZIA_ERR_CRYPTO_FAILURE);
        ok("Un blob scelle altere est rejete");
    }

    // --- 2c. Un blob tronqué (plus court qu'un nonce + tag) est rejeté ---
    {
        uint8_t* opened = nullptr;
        size_t opened_len = 0;
        assert(zia_channel_open_key(link_secret, sealed.data(), 8,
                                    &opened, &opened_len) == ZIA_ERR_CRYPTO_FAILURE);
        ok("Un blob tronque est rejete sans lire hors limites");
    }

    // --- 3. Un abonné ne peut pas publier au nom de l'admin ---
    //
    // L'abonné a importé la clé de LECTURE, pas la clé de signature de l'admin.
    // S'il fabrique sa propre clé d'expéditeur pour ce canal et publie, sa
    // signature est la SIENNE : un autre abonné, qui n'a enregistré sous
    // « admin » que la clé de l'admin, ne peut pas déchiffrer ce que l'abonné a
    // signé de sa propre clé sous ce même nom.
    {
        Engine intrus("/tmp/zia_channel_intrus");
        uint8_t* faux = nullptr;
        size_t faux_len = 0;
        assert(zia_sender_key_create(intrus.handle, channel, &faux, &faux_len) == ZIA_OK);
        zia_free_buffer(faux, faux_len);

        const std::string forge = "Faux : envoyez vos codes ici.";
        uint8_t* ct = nullptr;
        size_t ct_len = 0;
        assert(zia_sender_key_encrypt(intrus.handle, channel,
                   reinterpret_cast<const uint8_t*>(forge.data()), forge.size(),
                   &ct, &ct_len) == ZIA_OK);

        // L'abonné a « admin » = la clé de l'ADMIN. Le message de l'intrus est
        // signé d'une autre clé : la vérification échoue avant tout déchiffrement.
        uint8_t* pt = nullptr;
        size_t pt_len = 0;
        const ZiaStatus rc = zia_sender_key_decrypt(abonne.handle, channel, "admin",
                                                    ct, ct_len, &pt, &pt_len);
        assert(rc != ZIA_OK);
        zia_free_buffer(ct, ct_len);
        ok("Un abonne ne peut pas publier au nom de l'admin (signature)");
    }

    std::printf("\n%d verifications de canal reussies.\n", checks);
    return 0;
}
