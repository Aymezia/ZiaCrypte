// Vérifie le numéro de sécurité — la seule défense contre un serveur qui
// substituerait ses propres clés d'identité.
//
// La propriété qui compte n'est pas « ça produit 60 chiffres » mais « les deux
// correspondants lisent le même nombre, et un attaquant intercalé en produit un
// différent ». C'est ce qui est testé ici.

#include "zia/zia_crypto.h"
#include "safety_number_internal.hpp"

#include <sodium.h>

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

int checks = 0;
void ok(const char* label) {
  ++checks;
  std::printf("[OK] %s\n", label);
}

struct Party {
  uint8_t pub[ZIA_PUBLIC_KEY_LEN];
  const char* id;
};

Party make_party(const char* id, uint8_t seed) {
  Party p{};
  std::memset(p.pub, seed, sizeof(p.pub));
  p.id = id;
  return p;
}

std::string number_for(const Party& a, const Party& b) {
  char out[ZIA_SAFETY_NUMBER_DIGITS + 1] = {};
  const ZiaStatus st = zia_safety_number(a.pub, a.id, b.pub, b.id, out);
  assert(st == ZIA_OK);
  return std::string(out);
}

} // namespace

// Vecteur de test officiel de libsignal (NumericFingerprintGeneratorTest).
//
// Les clés y font 33 octets (préfixe 0x05 de type DJB) et les identifiants sont
// des numéros de téléphone : ce n'est pas le format de ZiaCrypte. On teste donc
// la primitive de calcul directement, pour prouver que notre implémentation de
// l'algorithme est conforme et pas seulement plausible. Sans ce contrôle, une
// erreur d'un tour de hachage passerait inaperçue — tous les autres tests
// (symétrie, déterminisme, détection) réussiraient malgré tout.
void check_libsignal_vector() {
  const uint8_t alice[33] = {0x05, 0x06, 0x86, 0x3b, 0xc6, 0x6d, 0x02, 0xb4, 0x0d,
                             0x27, 0xb8, 0xd4, 0x9c, 0xa7, 0xc0, 0x9e, 0x92, 0x39,
                             0x23, 0x6f, 0x9d, 0x7d, 0x25, 0xd6, 0xfc, 0xca, 0x5c,
                             0xe1, 0x3c, 0x70, 0x64, 0xd8, 0x68};
  const uint8_t bob[33] = {0x05, 0xf7, 0x81, 0xb6, 0xfb, 0x32, 0xfe, 0xd9, 0xba,
                           0x1c, 0xf2, 0xde, 0x97, 0x8d, 0x4d, 0x5d, 0xa2, 0x8d,
                           0xc3, 0x40, 0x46, 0xae, 0x81, 0x44, 0x02, 0xb5, 0xc0,
                           0xdb, 0xd9, 0x6f, 0xda, 0x90, 0x7b};
  const char* expected =
      "300354477692869396892869876765458257569162576843440918079131";

  const std::string a = zia::internal::party_digits(alice, sizeof(alice), "+14152222222");
  const std::string b = zia::internal::party_digits(bob, sizeof(bob), "+14153333333");
  const std::string combined = (a < b) ? (a + b) : (b + a);

  if (combined != expected) {
    std::printf("[ÉCHEC] vecteur libsignal\n  attendu : %s\n  obtenu  : %s\n",
                expected, combined.c_str());
    std::abort();
  }
  ok("conforme au vecteur de test officiel de libsignal");
}

int main() {
  assert(sodium_init() >= 0);

  check_libsignal_vector();

  const Party alice = make_party("alice-user-id", 0x11);
  const Party bob = make_party("bob-user-id", 0x22);
  const Party mallory = make_party("bob-user-id", 0x33); // se fait passer pour Bob

  // --- Format ---
  const std::string number = number_for(alice, bob);
  assert(number.size() == ZIA_SAFETY_NUMBER_DIGITS);
  for (char c : number) assert(c >= '0' && c <= '9');
  ok("60 chiffres décimaux");

  // --- Symétrie : c'est la propriété qui rend la comparaison possible ---
  // Alice calcule (elle, Bob) ; Bob calcule (lui, Alice). Sans cette égalité,
  // les deux liraient des nombres différents et la vérification serait
  // impraticable.
  assert(number_for(alice, bob) == number_for(bob, alice));
  ok("les deux correspondants obtiennent le même nombre");

  // --- Déterminisme ---
  assert(number_for(alice, bob) == number_for(alice, bob));
  ok("stable d'un appel à l'autre");

  // --- Détection de l'intercepteur ---
  // Mallory relaie en substituant sa clé, tout en gardant l'identifiant de Bob.
  // Si le numéro ne changeait pas, l'attaque serait indétectable.
  const std::string spoofed = number_for(alice, mallory);
  assert(spoofed != number);
  ok("une clé substituée change le nombre (attaque de l'intercepteur visible)");

  // --- L'identifiant entre bien dans le calcul ---
  // Sans cela, une clé volée pourrait être rejouée sous un autre compte.
  const Party bob_renamed = make_party("autre-compte", 0x22);
  assert(number_for(alice, bob_renamed) != number);
  ok("l'identifiant de compte est lié à la clé");

  // --- Refus des cas dégénérés ---
  char out[ZIA_SAFETY_NUMBER_DIGITS + 1] = {};
  assert(zia_safety_number(alice.pub, alice.id, alice.pub, alice.id, out) ==
         ZIA_ERR_INVALID_ARG);
  ok("deux clés identiques sont refusées");

  assert(zia_safety_number(nullptr, "x", bob.pub, "y", out) == ZIA_ERR_INVALID_ARG);
  assert(zia_safety_number(alice.pub, "x", bob.pub, "y", nullptr) == ZIA_ERR_INVALID_ARG);
  ok("arguments nuls refusés sans planter");

  // --- Un identifiant absent reste accepté (dégradé mais valide) ---
  const ZiaStatus st = zia_safety_number(alice.pub, nullptr, bob.pub, nullptr, out);
  assert(st == ZIA_OK && std::strlen(out) == ZIA_SAFETY_NUMBER_DIGITS);
  ok("identifiant nul toléré");

  std::printf("\n%d vérifications passées\n", checks);
  return 0;
}
