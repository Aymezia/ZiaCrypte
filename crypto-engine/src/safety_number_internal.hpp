#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

/*
 * Détail d'implémentation du numéro de sécurité, exposé aux tests seulement.
 *
 * Ne fait pas partie de l'ABI C publique : ce fichier n'est pas installé, et
 * la cible de test compile safety_number.cpp directement plutôt que de
 * dépendre d'un symbole exporté. Il sert à confronter la primitive au vecteur
 * de test de libsignal, dont les clés font 33 octets là où ZiaCrypte en
 * manipule 32 — l'API publique, elle, reste bornée à ZIA_PUBLIC_KEY_LEN.
 */
namespace zia::internal {

/** Les 30 chiffres d'une seule partie. `key_len` est libre pour les tests. */
std::string party_digits(const uint8_t* key, std::size_t key_len,
                         const char* identifier);

} // namespace zia::internal
