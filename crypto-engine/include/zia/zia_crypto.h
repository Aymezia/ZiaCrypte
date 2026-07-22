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
/* ML-KEM-768 (FIPS 203) — composante post-quantique du handshake, cf. PQXDH. */
#define ZIA_PQ_PUBLIC_KEY_LEN  1184
#define ZIA_PQ_CIPHERTEXT_LEN  1088

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

    /* Prekey post-quantique (PQXDH). SIGNÉE par la clé d'identité, exactement
     * comme le signed prekey : sans cette signature, le serveur pourrait
     * substituer sa propre clé d'encapsulation et lire la composante PQ.
     *
     * has_pq_prekey = 0 décrit un correspondant qui n'a pas encore migré : le
     * handshake retombe alors sur le X3DH classique. Ce repli est le prix de
     * la compatibilité avec les versions déjà installées — voir
     * zia_session_require_pq pour l'interdire une fois le parc à jour. */
    uint8_t pq_prekey[ZIA_PQ_PUBLIC_KEY_LEN];
    uint8_t pq_prekey_signature[ZIA_SIGNATURE_LEN];
    uint8_t has_pq_prekey; /* 0/1 */
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

    /* Chiffré ML-KEM produit par l'initiateur contre la prekey PQ du
     * destinataire. Celui-ci le décapsule pour retrouver le même secret. */
    uint8_t pq_ciphertext[ZIA_PQ_CIPHERTEXT_LEN];
    uint8_t has_pq; /* 0/1 — 0 = handshake classique (pair non migré) */
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

/* ================= X3DH / PQXDH / Prekeys ================= */
/* Exiger la composante post-quantique.
 *
 * Par défaut DÉSACTIVÉ : un correspondant dont l'application n'a pas encore été
 * mise à jour envoie un handshake classique, et le refuser rendrait la
 * messagerie inutilisable pendant toute la migration. Une fois le parc à jour,
 * activer ce drapeau ferme le repli — sans lui, un serveur hostile pourrait
 * retirer la prekey PQ du bundle qu'il sert et forcer le handshake classique,
 * sans que personne ne s'en aperçoive. */
ZIA_API ZiaStatus zia_session_require_pq(ZiaEngine* engine, int required);
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
/* ---- Expéditeur scellé ----
 *
 * Le serveur ne peut pas lire les messages, mais il sait qui écrit à qui. Ce
 * graphe en apprend souvent plus que le contenu. Pire, le premier message d'une
 * session transporte la clé d'identité de l'expéditeur en clair dans son
 * en-tête : masquer seulement l'identifiant d'appareil ne changerait rien.
 *
 * `zia_sealed_seal` chiffre à destination d'une clé d'identité SANS révéler
 * l'expéditeur (crypto_box_seal : paire éphémère + secret partagé). Deux envois
 * du même contenu donnent des octets différents.
 *
 * L'expéditeur reste identifié À L'INTÉRIEUR de l'enveloppe : le destinataire
 * doit savoir qui lui parle. C'est le serveur, et lui seul, qu'on aveugle.
 *
 * Les tampons rendus sont à libérer avec zia_free_buffer. */
ZIA_API ZiaStatus zia_sealed_seal(const uint8_t recipient_identity[ZIA_PUBLIC_KEY_LEN],
                                  const uint8_t* plaintext, size_t plaintext_len,
                                  uint8_t** out, size_t* out_len);

/* Ouvre une enveloppe scellée qui nous est destinée. Échoue si elle vise un
 * autre appareil OU si elle a été altérée — les deux sont indiscernables. */
ZIA_API ZiaStatus zia_sealed_open(ZiaEngine* engine, const uint8_t* sealed,
                                  size_t sealed_len, uint8_t** out,
                                  size_t* out_len);

/* ---- Code de verrouillage de l'application ----
 *
 * Interdit la lecture des conversations à qui passe devant un appareil
 * déverrouillé — de loin la manière la plus fréquente dont une conversation est
 * lue par quelqu'un d'autre.
 *
 * Ne protège PAS d'un adversaire qui possède l'appareil : les clés restent
 * déchiffrables par le coffre-fort du système dès la session ouverte. Dériver
 * la clé du coffre depuis ce code empêcherait de recevoir les messages
 * application fermée, et ferait d'un code oublié une perte définitive.
 *
 * Le hachage est fait ici (Argon2id via crypto_pwhash_str) et la vérification
 * en temps constant : une comparaison de chaînes en Dart fuirait par le temps
 * de réponse. */
ZIA_API ZiaStatus zia_app_lock_set(ZiaEngine* engine, const char* code);
ZIA_API ZiaStatus zia_app_lock_verify(ZiaEngine* engine, const char* code);
ZIA_API ZiaStatus zia_app_lock_status(ZiaEngine* engine, int* out_set);
ZIA_API ZiaStatus zia_app_lock_clear(ZiaEngine* engine);

/**
 * Sauvegarde chiffrée exportable, protégée par une phrase de passe (Argon2id).
 *
 * Le coffre local est chiffré sous une clé du coffre-fort du système, qui ne
 * quitte jamais la machine : une sauvegarde chiffrée avec elle ne serait
 * restaurable que là où elle a été produite. Le contenu est donc rechiffré
 * sous une clé dérivée d'une phrase choisie par l'utilisateur.
 *
 * Le tampon rendu doit être libéré par zia_free_buffer. Phrase de 12
 * caractères minimum.
 */
ZIA_API ZiaStatus zia_backup_export(ZiaEngine* engine, const char* passphrase,
                                    uint8_t** out, size_t* out_len);

/**
 * Restaure une sauvegarde dans CE moteur, puis réécrit l'identité sous la clé
 * maîtresse de cet appareil.
 *
 * Renvoie ZIA_ERR_CRYPTO_FAILURE si la phrase est incorrecte ou le fichier
 * altéré — les deux sont indiscernables, et c'est voulu : le tag Poly1305 ne
 * dit pas laquelle des deux causes s'applique.
 */
ZIA_API ZiaStatus zia_backup_import(ZiaEngine* engine, const char* passphrase,
                                    const uint8_t* data, size_t len);

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
/* ------------------------------------------------------------------ groupes
 *
 * Clés d'expéditeur (« sender keys »).
 *
 * Sans elles, un message de groupe est chiffré UNE FOIS PAR APPAREIL
 * destinataire : dix membres à deux appareils, c'est vingt chiffrements et
 * vingt blobs pour un seul message. Avec elles, l'expéditeur chiffre une fois
 * avec une clé de chaîne propre au groupe, qu'il a distribuée à chaque membre
 * par le canal pair-à-pair DÉJÀ chiffré. Le coût cesse de croître avec la
 * taille du groupe.
 *
 * Ce que ça ne change pas : le serveur ne voit toujours que du chiffré, et
 * chaque message reste signé par son auteur (Ed25519) — un membre ne peut donc
 * pas se faire passer pour un autre, alors même qu'ils partagent la clé du
 * groupe. C'est ce qui distingue « chiffré pour le groupe » de « n'importe qui
 * dans le groupe peut forger n'importe quoi ».
 */

/* Crée (ou fait tourner) NOTRE clé d'expéditeur pour ce groupe, et renvoie le
 * message de distribution à transmettre à chaque membre par le canal chiffré.
 * À refaire quand la composition du groupe change : un partant ne doit plus
 * pouvoir lire la suite. */
ZIA_API ZiaStatus zia_sender_key_create(ZiaEngine* engine, const char* group_id,
                                        uint8_t** out_distribution, size_t* out_len);

/* Enregistre la clé d'expéditeur d'un membre, reçue par le canal chiffré. */
ZIA_API ZiaStatus zia_sender_key_process(ZiaEngine* engine, const char* group_id,
                                         const char* sender_id,
                                         const uint8_t* distribution, size_t len);

/* Chiffre un message UNE SEULE FOIS pour tout le groupe. */
ZIA_API ZiaStatus zia_sender_key_encrypt(ZiaEngine* engine, const char* group_id,
                                         const uint8_t* plaintext, size_t plaintext_len,
                                         uint8_t** out, size_t* out_len);

/* Déchiffre un message de groupe. La signature est vérifiée AVANT tout
 * déchiffrement : on ne traite pas les octets d'un expéditeur non authentifié. */
ZIA_API ZiaStatus zia_sender_key_decrypt(ZiaEngine* engine, const char* group_id,
                                         const char* sender_id,
                                         const uint8_t* message, size_t message_len,
                                         uint8_t** out, size_t* out_len);

ZIA_API ZiaStatus zia_session_serialize(ZiaSession* session, uint8_t** out, size_t* out_len);
ZIA_API ZiaStatus zia_session_deserialize(ZiaEngine* engine, const uint8_t* data, size_t len,
                                         ZiaSession** out_session);
ZIA_API void      zia_session_close(ZiaSession* session); /* wipe + free */

#ifdef __cplusplus
}
#endif
#endif /* ZIA_CRYPTO_H */
