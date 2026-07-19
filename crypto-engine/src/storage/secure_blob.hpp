#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

struct ZiaEngine;

namespace zia::crypto::storage {

/**
 * Coffre local générique : chiffre des données arbitraires sous la clé maîtresse
 * de l'appareil (celle du coffre-fort du système) et les range dans
 * `<storage_path>/vault/<nom>.zia`.
 *
 * Sert à l'application pour conserver ce qui est sensible mais n'est pas du
 * matériel cryptographique — l'historique des conversations, par exemple, qui
 * est du texte en clair une fois déchiffré et n'a donc rien à faire tel quel
 * sur le disque.
 *
 * Le nom est validé : seuls [A-Za-z0-9._-] sont acceptés, ce qui interdit toute
 * remontée de chemin (« ../ ») depuis un nom fourni par l'appelant.
 */

bool secure_write(const ZiaEngine& engine, const std::string& name,
                  const uint8_t* data, size_t len);

/** Renvoie false si l'entrée n'existe pas ou ne peut être déchiffrée. */
bool secure_read(const ZiaEngine& engine, const std::string& name,
                 std::vector<uint8_t>& out);

bool secure_erase(const ZiaEngine& engine, const std::string& name);

} // namespace zia::crypto::storage
