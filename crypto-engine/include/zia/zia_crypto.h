#ifndef ZIA_CRYPTO_H
#define ZIA_CRYPTO_H

#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32)
  #define ZIA_API __declspec(dllexport)
#else
  #define ZIA_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Tailles fixes (octets) ---- */
#define ZIA_PUBLIC_KEY_LEN   32   /* X25519 / Ed25519 */
#define ZIA_SIGNATURE_LEN    64   /* Ed25519 */
#define ZIA_ATTACHMENT_KEY_LEN 32 /* clé de pièce jointe (XChaCha20-Poly1305) */
#define ZIA_SAFETY_NUMBER_DIGITS 60 /* 2 x 30 chiffres, format Signal */

/* ---- Handles opaques ---- */
typedef struct ZiaEngine  ZiaEngine;
typedef struct ZiaSession ZiaSession;

/* ---- Codes de statut ---- */
typedef enum {
    ZIA_OK                      = 0,
    ZIA_ERR_INVALID_ARG         = 1,
    ZIA_ERR_OUT_OF_MEMORY       = 2,
    ZIA_ERR_NOT_INITIALIZED     = 3,
    ZIA_ERR_ALREADY_INITIALIZED = 4,
    ZIA_ERR_STORAGE_IO          = 5,
    ZIA_ERR_CRYPTO_FAILURE      = 6,
    ZIA_ERR_SESSION_NOT_FOUND   = 7,
    ZIA_ERR_SIGNATURE_INVALID   = 8,
    ZIA_ERR_REPLAY_DETECTED     = 9,
    ZIA_ERR_SKIPPED_KEY_LIMIT   = 10,
    ZIA_ERR_BUNDLE_EXHAUSTED    = 11, /* plus de one-time prekey côté serveur */
    ZIA_ERR_NOT_IMPLEMENTED     = 99, /* scaffolding Phase 5 — retiré au fil de la Phase 6 */
} ZiaStatus;

/* ---- Structures POD (aucun pointeur vers un secret) ---- */
typedef struct {
    uint8_t identity_key[ZIA_PUBLIC_KEY_LEN];
    uint8_t signed_prekey[ZIA_PUBLIC_KEY_LEN];
    uint8_t signed_prekey_signature[ZIA_SIGNATURE_LEN];
    uint8_t one_time_prekey[ZIA_PUBLIC_KEY_LEN];
    uint8_t has_one_time_prekey; /* 0/1 — le pool serveur peut être épuisé */
} ZiaPrekeyBundle;

/* Matériel de handshake X3DH à transmettre par le canal applicatif (ratchet_header
 * seul ne suffit pas) sur le PREMIER message d'une nouvelle session — cf. Phase 6,
 * correction apportée à l'implémentation : sans ce matériel, le répondeur ne peut
 * pas recalculer le secret partagé SK. Absent des messages suivants. */
typedef struct {
    uint8_t initiator_identity_key[ZIA_PUBLIC_KEY_LEN];
    uint8_t initiator_ephemeral_key[ZIA_PUBLIC_KEY_LEN];
    uint8_t used_one_time_prekey[ZIA_PUBLIC_KEY_LEN];
    uint8_t has_one_time_prekey; /* 0/1 */
} ZiaHandshakeMaterial;

/* ================= Cycle de vie ================= */
ZIA_API ZiaEngine*  zia_engine_init(const char* storage_path, ZiaStatus* out_status);
ZIA_API void        zia_engine_shutdown(ZiaEngine* engine);
ZIA_API const char* zia_last_error(ZiaEngine* engine);
ZIA_API void        zia_free_buffer(uint8_t* buf, size_t len);

/* ================= Identité ================= */
ZIA_API ZiaStatus zia_identity_generate(ZiaEngine* engine, uint8_t out_pub[ZIA_PUBLIC_KEY_LEN]);
ZIA_API ZiaStatus zia_identity_get_public_key(ZiaEngine* engine, uint8_t out_pub[ZIA_PUBLIC_KEY_LEN]);
ZIA_API ZiaStatus zia_identity_sign(ZiaEngine* engine, const uint8_t* msg, size_t msg_len,
                                    uint8_t out_sig[ZIA_SIGNATURE_LEN]);
ZIA_API ZiaStatus zia_verify_signature(const uint8_t pub[ZIA_PUBLIC_KEY_LEN],
                                       const uint8_t* msg, size_t msg_len,
                                       const uint8_t sig[ZIA_SIGNATURE_LEN]);

/* ================= X3DH / Prekeys ================= */
ZIA_API ZiaStatus zia_prekey_bundle_generate(ZiaEngine* engine, ZiaPrekeyBundle* out_bundle);
ZIA_API ZiaStatus zia_prekey_bundle_rotate(ZiaEngine* engine);

/* Côté initiateur (Alice) : consomme le bundle public de Bob, dérive SK, initialise
 * la session en tant qu'Alice, et produit le matériel à joindre au premier message. */
ZIA_API ZiaStatus zia_session_from_bundle(ZiaEngine* engine, const ZiaPrekeyBundle* their_bundle,
                                          ZiaSession** out_session,
                                          ZiaHandshakeMaterial* out_handshake);

/* Côté répondeur (Bob) : reçoit le matériel de handshake joint au premier message
 * d'Alice, recalcule le même SK, initialise la session en tant que Bob. */
ZIA_API ZiaStatus zia_session_accept_handshake(ZiaEngine* engine, const ZiaHandshakeMaterial* handshake,
                                               ZiaSession** out_session);

/* ================= Double Ratchet ================= */
/* Le header (clé DH publique courante + compteurs N/PN) est retourné séparément du
 * ciphertext : il n'est pas chiffré mais sert de donnée authentifiée (AD) à l'AEAD,
 * et correspond 1:1 aux champs ratchet_header/ciphertext de EncryptedEnvelope (§7.2). */
ZIA_API ZiaStatus zia_session_encrypt(ZiaSession* session, const uint8_t* plaintext, size_t plaintext_len,
                                      uint8_t** out_header, size_t* out_header_len,
                                      uint8_t** out_ciphertext, size_t* out_ciphertext_len);
ZIA_API ZiaStatus zia_session_decrypt(ZiaSession* session,
                                      const uint8_t* header, size_t header_len,
                                      const uint8_t* ciphertext, size_t ciphertext_len,
                                      uint8_t** out_plaintext, size_t* out_plaintext_len);

/* ================= Pièces jointes ================= */
/* Chiffre un fichier sous une clé tirée au hasard, renvoyée à l'appelant. Le
 * ciphertext est destiné à un hébergeur de stockage ; la clé, elle, voyage
 * dans le message chiffré de bout en bout — l'hébergeur ne peut donc rien lire.
 * Les tampons de sortie sont à libérer avec zia_free_buffer. */
ZIA_API ZiaStatus zia_attachment_encrypt(const uint8_t* plaintext, size_t plaintext_len,
                                         uint8_t out_key[ZIA_ATTACHMENT_KEY_LEN],
                                         uint8_t** out_ciphertext, size_t* out_len);
/* ---- Mise à jour signée ----
 *
 * Vérifie qu'un fichier téléchargé a bien été signé par la clé attendue.
 * Le hachage se fait EN FLUX : un artefact de plusieurs dizaines de Mo n'est
 * jamais chargé entièrement en mémoire. `signature` est détachée (Ed25519). */
ZIA_API ZiaStatus zia_verify_file_signature(const uint8_t public_key[ZIA_PUBLIC_KEY_LEN],
                                            const char* path,
                                            const uint8_t signature[ZIA_SIGNATURE_LEN]);

/* ---- Vérification de contact ----
 *
 * Empreinte des deux clés d'identité, à comparer hors bande (de vive voix, QR).
 * C'est la seule protection contre un serveur qui substituerait ses propres
 * clés : le chiffrement seul n'y peut rien, l'attaque portant sur
 * l'authenticité des clés et non sur leur confidentialité.
 *
 * Le résultat est symétrique : les deux correspondants lisent le même nombre.
 * `out` reçoit 60 chiffres suivis d'un octet nul. */
ZIA_API ZiaStatus zia_safety_number(const uint8_t local_pub[ZIA_PUBLIC_KEY_LEN],
                                    const char* local_id,
                                    const uint8_t remote_pub[ZIA_PUBLIC_KEY_LEN],
                                    const char* remote_id,
                                    char out[ZIA_SAFETY_NUMBER_DIGITS + 1]);

ZIA_API ZiaStatus zia_attachment_decrypt(const uint8_t key[ZIA_ATTACHMENT_KEY_LEN],
                                         const uint8_t* ciphertext, size_t ciphertext_len,
                                         uint8_t** out_plaintext, size_t* out_len);

/* ================= Coffre local chiffré ================= */
/* Range des données arbitraires chiffrées sous la clé maîtresse de l'appareil.
 * Destiné à ce qui est sensible sans être du matériel cryptographique —
 * l'historique des conversations en particulier, qui ne doit pas se retrouver
 * en clair sur le disque. `name` n'accepte que [A-Za-z0-9._-]. */
ZIA_API ZiaStatus zia_secure_write(ZiaEngine* engine, const char* name,
                                   const uint8_t* data, size_t len);
ZIA_API ZiaStatus zia_secure_read(ZiaEngine* engine, const char* name,
                                  uint8_t** out, size_t* out_len);
ZIA_API ZiaStatus zia_secure_erase(ZiaEngine* engine, const char* name);

/* ================= Persistance de session ================= */
ZIA_API ZiaStatus zia_session_serialize(ZiaSession* session, uint8_t** out, size_t* out_len);
ZIA_API ZiaStatus zia_session_deserialize(ZiaEngine* engine, const uint8_t* data, size_t len,
                                         ZiaSession** out_session);
ZIA_API void      zia_session_close(ZiaSession* session); /* wipe + free */

#ifdef __cplusplus
}
#endif
#endif /* ZIA_CRYPTO_H */
