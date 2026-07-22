#pragma once

#include "memory/secure_buffer.hpp"
#include <cstddef>
#include <cstdint>

namespace zia::crypto::primitives {

constexpr size_t kPublicKeyLen = 32;
constexpr size_t kSignatureLen = 64;
constexpr size_t kSharedSecretLen = 32;
constexpr size_t kAeadNonceLen = 12; // ChaCha20-Poly1305 IETF

/* Ed25519 : identité et signatures */
void ed25519_keypair(uint8_t out_pub[kPublicKeyLen], SecureBuffer& out_priv);
void ed25519_sign(const SecureBuffer& priv, const uint8_t* msg, size_t msg_len,
                   uint8_t out_sig[kSignatureLen]);
bool ed25519_verify(const uint8_t pub[kPublicKeyLen], const uint8_t* msg, size_t msg_len,
                     const uint8_t sig[kSignatureLen]);

/* X25519 : accord de clé (prekeys, ratchet DH) */
void x25519_keypair(uint8_t out_pub[kPublicKeyLen], SecureBuffer& out_priv);
bool x25519_scalarmult(const SecureBuffer& priv, const uint8_t pub[kPublicKeyLen],
                        uint8_t out_shared[kSharedSecretLen]);

/* Conversion identité Ed25519 -> X25519, pour l'utiliser dans X3DH (comme Signal) */
bool ed25519_to_x25519_public(const uint8_t ed_pub[kPublicKeyLen], uint8_t out_x_pub[kPublicKeyLen]);
bool ed25519_to_x25519_private(const SecureBuffer& ed_priv, SecureBuffer& out_x_priv);

/* ML-KEM-768 (FIPS 203) : encapsulation de clé post-quantique, via liboqs.
   Aucune implémentation maison ici — ces fonctions ne font qu'appeler liboqs et
   ranger le résultat dans nos types. Le niveau 768 est celui retenu par Signal
   pour PQXDH : catégorie NIST 3, et le seul avec un vrai recul de déploiement.

   Le KEM ne REMPLACE jamais X25519, il s'y ajoute : le secret partagé final
   mélange les deux, de sorte que casser ML-KEM ramène exactement à la sécurité
   d'aujourd'hui, et casser X25519 laisse la protection post-quantique. */
constexpr size_t kPqPublicKeyLen  = 1184; // OQS_KEM_ml_kem_768_length_public_key
constexpr size_t kPqSecretKeyLen  = 2400; // ..._length_secret_key
constexpr size_t kPqCiphertextLen = 1088; // ..._length_ciphertext

void mlkem768_keypair(uint8_t out_pub[kPqPublicKeyLen], SecureBuffer& out_priv);

/* Côté initiateur : produit un chiffré à transmettre et le secret partagé. */
bool mlkem768_encapsulate(const uint8_t pub[kPqPublicKeyLen],
                           uint8_t out_ciphertext[kPqCiphertextLen],
                           uint8_t out_shared[kSharedSecretLen]);

/* Côté répondeur : retrouve le même secret à partir du chiffré reçu. */
bool mlkem768_decapsulate(const SecureBuffer& priv,
                           const uint8_t ciphertext[kPqCiphertextLen],
                           uint8_t out_shared[kSharedSecretLen]);

/* HKDF-SHA256 : dérivation de la clé racine du ratchet et du secret X3DH */
void hkdf_sha256(const uint8_t* salt, size_t salt_len, const uint8_t* ikm, size_t ikm_len,
                  const char* info, uint8_t* out, size_t out_len);

/* HMAC-SHA256 : avancement des chaînes symétriques (KDF_CK) */
void hmac_sha256(const SecureBuffer& key, uint8_t single_byte_input, uint8_t out[32]);

/* AEAD ChaCha20-Poly1305 IETF. out_ciphertext doit faire plaintext_len + 16 octets ;
   out_plaintext doit faire ciphertext_len - 16 octets. */
bool aead_encrypt(const SecureBuffer& key, const uint8_t nonce[kAeadNonceLen],
                   const uint8_t* plaintext, size_t plaintext_len,
                   const uint8_t* ad, size_t ad_len,
                   uint8_t* out_ciphertext);
bool aead_decrypt(const SecureBuffer& key, const uint8_t nonce[kAeadNonceLen],
                   const uint8_t* ciphertext, size_t ciphertext_len,
                   const uint8_t* ad, size_t ad_len,
                   uint8_t* out_plaintext);

} // namespace zia::crypto::primitives
