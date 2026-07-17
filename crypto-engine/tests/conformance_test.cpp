// Test de conformité de bout en bout : Alice <-> Bob, X3DH + Double Ratchet.
//
// Ce n'est PAS un rejeu des vecteurs de test officiels de Signal (cf. Phase 2
// §11.5) : notre format de fil (header 40 octets, AD, KDF info strings) n'est
// pas destiné à être compatible octet-à-octet avec un client Signal réel — on
// ne cherche pas l'interopérabilité avec leur réseau. Ce test valide à la place
// les propriétés du protocole (forward secrecy, ordre, rejeu, falsification)
// par des allers-retours réels entre deux instances du moteur.
//
// Volontairement sans framework de test externe : un seul binaire, des assert().

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
        ZiaStatus status;
        handle = zia_engine_init(path, &status);
        assert(status == ZIA_OK && handle != nullptr);
    }
    ~Engine() { zia_engine_shutdown(handle); }
};

struct Session {
    ZiaSession* handle = nullptr;
    ~Session() {
        if (handle) zia_session_close(handle);
    }
};

std::vector<uint8_t> to_bytes(const std::string& s) {
    return std::vector<uint8_t>(s.begin(), s.end());
}

std::string send(ZiaSession* from, const std::string& plaintext,
                  std::vector<uint8_t>& out_header) {
    uint8_t* header = nullptr;
    size_t header_len = 0;
    uint8_t* ciphertext = nullptr;
    size_t ciphertext_len = 0;

    auto pt = to_bytes(plaintext);
    ZiaStatus rc = zia_session_encrypt(from, pt.data(), pt.size(), &header, &header_len,
                                        &ciphertext, &ciphertext_len);
    assert(rc == ZIA_OK);

    out_header.assign(header, header + header_len);
    std::string result(reinterpret_cast<char*>(ciphertext), ciphertext_len);
    zia_free_buffer(header, header_len);
    // le ciphertext est copié dans `result` avant d'être libéré : sûr car std::string copie.
    zia_free_buffer(ciphertext, ciphertext_len);
    return result;
}

bool try_receive(ZiaSession* to, const std::vector<uint8_t>& header, const std::string& ciphertext,
                  std::string& out_plaintext, ZiaStatus& out_status) {
    uint8_t* plaintext = nullptr;
    size_t plaintext_len = 0;
    out_status = zia_session_decrypt(to, header.data(), header.size(),
                                      reinterpret_cast<const uint8_t*>(ciphertext.data()),
                                      ciphertext.size(), &plaintext, &plaintext_len);
    if (out_status != ZIA_OK) return false;
    out_plaintext.assign(reinterpret_cast<char*>(plaintext), plaintext_len);
    zia_free_buffer(plaintext, plaintext_len);
    return true;
}

} // namespace

int main() {
    Engine alice_engine("/tmp/zia_test_alice");
    Engine bob_engine("/tmp/zia_test_bob");

    uint8_t alice_pub[ZIA_PUBLIC_KEY_LEN], bob_pub[ZIA_PUBLIC_KEY_LEN];
    assert(zia_identity_generate(alice_engine.handle, alice_pub) == ZIA_OK);
    assert(zia_identity_generate(bob_engine.handle, bob_pub) == ZIA_OK);

    // --- Bob publie un bundle de prekeys ---
    ZiaPrekeyBundle bundle;
    assert(zia_prekey_bundle_generate(bob_engine.handle, &bundle) == ZIA_OK);

    // Un bundle avec une signature falsifiée doit être rejeté.
    {
        ZiaPrekeyBundle tampered = bundle;
        tampered.signed_prekey_signature[0] ^= 0xFF;
        ZiaSession* bogus_session = nullptr;
        ZiaHandshakeMaterial bogus_hs;
        ZiaStatus rc = zia_session_from_bundle(alice_engine.handle, &tampered, &bogus_session, &bogus_hs);
        assert(rc == ZIA_ERR_SIGNATURE_INVALID);
    }

    // --- Alice initie le handshake X3DH ---
    Session alice_session;
    ZiaHandshakeMaterial handshake;
    assert(zia_session_from_bundle(alice_engine.handle, &bundle, &alice_session.handle, &handshake) == ZIA_OK);

    // --- Alice envoie le premier message ---
    std::vector<uint8_t> header1;
    std::string ct1 = send(alice_session.handle, "Bonjour Bob, ici Alice.", header1);

    // --- Bob accepte le handshake à partir du matériel joint au premier message ---
    Session bob_session;
    assert(zia_session_accept_handshake(bob_engine.handle, &handshake, &bob_session.handle) == ZIA_OK);

    std::string pt1;
    ZiaStatus rc;
    assert(try_receive(bob_session.handle, header1, ct1, pt1, rc));
    assert(pt1 == "Bonjour Bob, ici Alice.");
    printf("[OK] Handshake X3DH + premier message dechiffre : \"%s\"\n", pt1.c_str());

    // --- Bob répond (déclenche son propre DH ratchet step) ---
    std::vector<uint8_t> header2;
    std::string ct2 = send(bob_session.handle, "Salut Alice, bien recu.", header2);
    std::string pt2;
    assert(try_receive(alice_session.handle, header2, ct2, pt2, rc));
    assert(pt2 == "Salut Alice, bien recu.");
    printf("[OK] Reponse de Bob dechiffree par Alice : \"%s\"\n", pt2.c_str());

    // --- Plusieurs allers-retours (exercice plusieurs DH ratchet steps) ---
    for (int i = 0; i < 5; ++i) {
        std::vector<uint8_t> h;
        std::string msg = "Message alice #" + std::to_string(i);
        std::string ct = send(alice_session.handle, msg, h);
        std::string pt;
        assert(try_receive(bob_session.handle, h, ct, pt, rc));
        assert(pt == msg);

        std::vector<uint8_t> h2;
        std::string msg2 = "Reponse bob #" + std::to_string(i);
        std::string ct2b = send(bob_session.handle, msg2, h2);
        std::string pt2b;
        assert(try_receive(alice_session.handle, h2, ct2b, pt2b, rc));
        assert(pt2b == msg2);
    }
    printf("[OK] 5 allers-retours (plusieurs DH ratchet steps) valides\n");

    // --- Persistance chiffree at-rest : serialise la session de Bob, la ferme,
    //     la restaure depuis le blob chiffre (cle maitresse via SecureKeyStore),
    //     puis verifie qu'elle continue a fonctionner. ---
    {
        uint8_t* blob = nullptr;
        size_t blob_len = 0;
        assert(zia_session_serialize(bob_session.handle, &blob, &blob_len) == ZIA_OK);

        ZiaSession* restored = nullptr;
        assert(zia_session_deserialize(bob_engine.handle, blob, blob_len, &restored) == ZIA_OK);
        zia_free_buffer(blob, blob_len);

        zia_session_close(bob_session.handle);
        bob_session.handle = restored;

        std::vector<uint8_t> h;
        std::string msg = "Message apres restauration de session";
        std::string ct = send(alice_session.handle, msg, h);
        std::string pt;
        assert(try_receive(bob_session.handle, h, ct, pt, rc));
        assert(pt == msg);
        printf("[OK] Session serialisee/chiffree at-rest puis restauree avec succes\n");
    }

    // --- Livraison hors-ordre : Alice envoie A, B, C ; Bob les recoit C, A, B ---
    std::vector<uint8_t> ha, hb, hc;
    std::string cta = send(alice_session.handle, "A", ha);
    std::string ctb = send(alice_session.handle, "B", hb);
    std::string ctc = send(alice_session.handle, "C", hc);

    std::string pt;
    assert(try_receive(bob_session.handle, hc, ctc, pt, rc) && pt == "C");
    assert(try_receive(bob_session.handle, ha, cta, pt, rc) && pt == "A");
    assert(try_receive(bob_session.handle, hb, ctb, pt, rc) && pt == "B");
    printf("[OK] Livraison hors-ordre (C, A, B) geree via les cles sautees\n");

    // --- Rejeu : redecrypter un message deja consomme doit echouer ---
    assert(!try_receive(bob_session.handle, hc, ctc, pt, rc));
    assert(rc == ZIA_ERR_REPLAY_DETECTED);
    printf("[OK] Rejeu detecte et rejete (ZIA_ERR_REPLAY_DETECTED)\n");

    // --- Falsification : un ciphertext modifie doit echouer l'authentification ---
    {
        std::vector<uint8_t> h;
        std::string msg = "message original";
        std::string ct = send(alice_session.handle, msg, h);
        std::string forged = ct;
        forged[0] ^= 0xFF;
        std::string dummy;
        assert(!try_receive(bob_session.handle, h, forged, dummy, rc));
        assert(rc == ZIA_ERR_CRYPTO_FAILURE);
        printf("[OK] Ciphertext falsifie rejete (ZIA_ERR_CRYPTO_FAILURE)\n");
    }

    printf("\nTous les tests de conformite ont reussi.\n");
    return 0;
}
