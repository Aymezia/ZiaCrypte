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

TMP_SO="$(mktemp -d)/libzia_crypto.so"
g++ -std=c++20 -O2 -DNDEBUG -fPIC -shared \
  -I"$ENGINE/include" -I"$ENGINE/src" $(pkg-config --cflags libsecret-1) \
  "$ENGINE/src/engine.cpp" "$ENGINE/src/identity.cpp" "$ENGINE/src/x3dh.cpp" \
  "$ENGINE/src/ratchet.cpp" "$ENGINE/src/session.cpp" \
  "$ENGINE/src/primitives/primitives.cpp" \
  "$ENGINE/src/storage/identity_store.cpp" \
  "$ENGINE/src/storage/secure_blob.cpp" "$ENGINE/src/vault.cpp" \
  "$ENGINE/src/attachment.cpp" \
  "$ENGINE/platform/linux/secure_key_store_linux.cpp" \
  -o "$TMP_SO" \
  -Wl,--exclude-libs,ALL "$SODIUM_A" $(pkg-config --libs libsecret-1)

echo ">> Compilation de l'application Flutter"
# Adresse du serveur intégrée au binaire : l'utilisateur n'a rien à saisir.
ZIA_SERVER_URL="${ZIA_SERVER_URL:-https://51.83.199.103.nip.io}"
echo "   serveur intégré : $ZIA_SERVER_URL"
(cd "$APP" && flutter build linux --release --dart-define=ZIA_SERVER_URL="$ZIA_SERVER_URL")

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
