#!/usr/bin/env bash
# Construit et empaquette l'application de bureau Linux, prête à distribuer.
#
# Produit dist/linux-x64/ et dist/ziacrypte-linux-x64.tar.gz contenant :
#   ziacrypte            l'exécutable
#   lib/libzia_crypto.so le moteur cryptographique (libsodium lié STATIQUEMENT,
#                        pour ne pas dépendre d'un libsodium installé)
#   data/                les ressources Flutter
#
# Prérequis : Flutter SDK, cmake/ninja/clang, libgtk-3-dev, libsodium-dev,
#             libsecret-1-dev.
#
# Note : libsecret reste lié dynamiquement — c'est le service de trousseau du
# bureau (GNOME Keyring / KWallet), présent sur toute session Linux de bureau.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/crypto-engine"
APP="$ROOT/app"
DIST="$ROOT/dist/linux-x64"

echo ">> Compilation du moteur (libsodium statique)"
SODIUM_A="$(pkg-config --variable=libdir libsodium 2>/dev/null || echo /usr/lib/x86_64-linux-gnu)/libsodium.a"
[ -f "$SODIUM_A" ] || { echo "libsodium.a introuvable — installe libsodium-dev"; exit 1; }

# liboqs (ML-KEM-768, PQXDH) : aucune distribution ne l'empaquette, on utilise
# l'installation locale (voir README / crypto-engine.yml). Lié STATIQUEMENT pour
# que le bundle reste autonome — un .so avec des symboles OQS non résolus
# planterait au chargement sur la machine cible, comme le fit Android sans son
# runtime C++.
OQS_A="$(pkg-config --variable=libdir liboqs 2>/dev/null || echo /usr/local/lib)/liboqs.a"
[ -f "$OQS_A" ] || OQS_A="/usr/local/lib/liboqs.a"
[ -f "$OQS_A" ] || { echo "liboqs.a introuvable — compile-le (cf. README, section moteur)"; exit 1; }
OQS_INC="$(dirname "$OQS_A")/../include"

TMP_SO="$(mktemp -d)/libzia_crypto.so"
# --no-undefined : le lien ÉCHOUE si un symbole reste non résolu, au lieu de
# produire un .so qui plante au dlopen chez l'utilisateur. C'est ce qui aurait
# attrapé au build l'absence de liboqs, plutôt qu'à l'exécution.
g++ -std=c++20 -O2 -DNDEBUG -fPIC -shared \
  -I"$ENGINE/include" -I"$ENGINE/src" -I"$OQS_INC" $(pkg-config --cflags libsecret-1) \
  "$ENGINE/src/engine.cpp" "$ENGINE/src/identity.cpp" "$ENGINE/src/x3dh.cpp" \
  "$ENGINE/src/ratchet.cpp" "$ENGINE/src/session.cpp" \
  "$ENGINE/src/primitives/primitives.cpp" \
  "$ENGINE/src/storage/identity_store.cpp" \
  "$ENGINE/src/storage/secure_blob.cpp" "$ENGINE/src/vault.cpp" \
  "$ENGINE/src/attachment.cpp" "$ENGINE/src/safety_number.cpp" "$ENGINE/src/release_signature.cpp" "$ENGINE/src/backup.cpp" "$ENGINE/src/applock.cpp" "$ENGINE/src/sealed_sender.cpp" "$ENGINE/src/sender_keys.cpp" "$ENGINE/src/channel.cpp" \
  "$ENGINE/platform/linux/secure_key_store_linux.cpp" \
  -o "$TMP_SO" \
  -Wl,--no-undefined -Wl,--exclude-libs,ALL "$SODIUM_A" "$OQS_A" $(pkg-config --libs libsecret-1)

# Garde-fou : toute fonction déclarée dans l'en-tête public DOIT être exportée
# par la bibliothèque. La liste de sources ci-dessus est maintenue à la main ;
# sans ce contrôle, oublier un fichier produit une bibliothèque qui se compile,
# se lie, s'empaquette — et fait échouer l'application au démarrage sur un
# symbole manquant. C'est arrivé avec safety_number.cpp.
echo ">> Vérification des symboles exportés"
#
# Un seul appel à `nm`, dont le résultat est comparé en mémoire. La version
# précédente relançait `nm` une fois par symbole — une vingtaine de processus
# dont certains échouaient par intermittence, produisant des listes de symboles
# « manquants » qui changeaient à chaque exécution alors que la bibliothèque
# les exportait bel et bien. Un contrôle qui donne des réponses différentes sur
# la même entrée ne contrôle rien.
EXPORTED="$(nm -D --defined-only "$TMP_SO" | awk '$2 == "T" { print $3 }' | sort -u)"
DECLARED="$(grep -oE 'zia_[a-z_]+\(' "$ENGINE/include/zia/zia_crypto.h" | tr -d '(' | sort -u)"
MISSING="$(comm -23 <(echo "$DECLARED") <(echo "$EXPORTED") | tr '\n' ' ')"
if [ -n "$MISSING" ]; then
  echo "ERREUR : symboles déclarés dans l'en-tête mais absents de la bibliothèque :"
  for S in $MISSING; do echo "  - $S"; done
  echo "Ajoute le fichier source correspondant à la liste de compilation ci-dessus."
  exit 1
fi
echo "   tous les symboles publics sont exportés"

echo ">> Compilation de l'application Flutter"
# Adresse du serveur intégrée au binaire : l'utilisateur n'a rien à saisir.
ZIA_SERVER_URL="${ZIA_SERVER_URL:-https://51.83.199.103.nip.io}"
echo "   serveur intégré : $ZIA_SERVER_URL"
# La version vient de pubspec.yaml : une seule source de vérité, et le
# vérificateur de mise à jour peut se comparer à la dernière release.
# Clé publique de signature des releases. Intégrée au binaire : c'est elle qui
# décide quel code l'application acceptera d'installer. La clé privée
# correspondante reste hors de toute machine publique.
ZIA_UPDATE_PUBKEY="${ZIA_UPDATE_PUBKEY:-ovIl8hVTU9GEtjODO3Pp9HaF5QCXx+jTiZKzM2xVuN4=}"
# Surchargeable pour tester le chemin de mise à jour : construire une version
# volontairement ancienne est le seul moyen de vérifier POUR DE VRAI qu'elle
# détecte, télécharge, authentifie et applique la release publiée.
ZIA_VERSION="${ZIA_VERSION:-$(grep -m1 '^version:' "$APP/pubspec.yaml" | sed 's/version: *//' | cut -d+ -f1)}"
echo "   version : $ZIA_VERSION"
# Racine de l'API de mise à jour. Surchargeable pour éprouver la chaîne contre
# un miroir local ; la sécurité ne dépend pas de cette adresse mais de la
# signature vérifiée ensuite.
ZIA_UPDATE_API="${ZIA_UPDATE_API:-https://api.github.com}"
echo "   API de mise à jour : $ZIA_UPDATE_API"
(cd "$APP" && flutter build linux --release \
  --dart-define=ZIA_SERVER_URL="$ZIA_SERVER_URL" \
  --dart-define=ZIA_VERSION="$ZIA_VERSION" \
  --dart-define=ZIA_UPDATE_API="$ZIA_UPDATE_API" \
  --dart-define=ZIA_UPDATE_PUBKEY="$ZIA_UPDATE_PUBKEY")

echo ">> Assemblage"
rm -rf "$DIST"
mkdir -p "$(dirname "$DIST")"
cp -r "$APP/build/linux/x64/release/bundle" "$DIST"
cp "$TMP_SO" "$DIST/lib/libzia_crypto.so"

echo ">> Archive"
tar -czf "$ROOT/dist/ziacrypte-linux-x64.tar.gz" -C "$(dirname "$DIST")" "$(basename "$DIST")"

echo ">> Terminé"
ls -lh "$ROOT/dist/ziacrypte-linux-x64.tar.gz"
echo "Dépendances externes du moteur :"
ldd "$DIST/lib/libzia_crypto.so" | grep -E "sodium|secret" || echo "  (libsodium embarqué)"
