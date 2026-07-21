#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

struct ZiaEngine;

namespace zia::crypto::storage {

/**
 * Persistance de l'identité de l'appareil (clé d'identité, signed prekey,
 * one-time prekeys) dans `<storage_path>/identity.zia`.
 *
 * Le fichier est chiffré avec `crypto_secretstream_xchacha20poly1305` sous la
 * clé maîtresse détenue par le coffre-fort du système (Secret Service, DPAPI,
 * Keychain…). Sans la session utilisateur, il est inexploitable : aucune clé
 * privée n'atteint jamais le disque en clair.
 *
 * Sans persistance, le moteur régénérerait des clés à chaque démarrage et
 * l'utilisateur perdrait son compte ; c'est ce que corrige ce module.
 */

/** Écrit l'état d'identité. Renvoie false en cas d'échec (E/S ou coffre-fort). */
bool save_identity(const ZiaEngine& engine);

/**
 * Recharge l'état d'identité s'il existe. Renvoie false si aucun fichier n'est
 * présent, ou s'il est illisible (clé maîtresse absente, fichier corrompu).
 */
bool load_identity(ZiaEngine& engine);

/**
 * Sérialise / désérialise l'état d'identité EN CLAIR.
 *
 * Exposé pour la sauvegarde exportable, qui doit rechiffrer ce même contenu
 * sous une phrase de passe au lieu de la clé maîtresse de l'appareil — sans
 * quoi une sauvegarde ne serait restaurable que sur la machine qui l'a
 * produite, ce qui lui ôterait tout intérêt.
 *
 * L'appelant DOIT effacer le tampon rendu (sodium_memzero) : il contient des
 * clés privées.
 */
std::vector<uint8_t> serialize_identity(const ZiaEngine& engine);
bool deserialize_identity(const uint8_t* data, size_t len, ZiaEngine& engine);

} // namespace zia::crypto::storage
