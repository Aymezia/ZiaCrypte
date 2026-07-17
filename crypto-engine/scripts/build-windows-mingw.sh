#!/usr/bin/env bash
# Cross-compilation Windows x64 du crypto-engine depuis Linux, via MinGW-w64.
#
# Produit, dans dist/windows-x64/ :
#   - zia_crypto.dll        (le moteur, backend DPAPI inclus)
#   - libsodium-26.dll      (dépendance runtime, liée dynamiquement)
#   - zia_crypto_test.exe   (test de conformité autonome)
#
# Prérequis (Debian/Ubuntu) :
#   sudo apt install mingw-w64 curl
#   (optionnel, pour exécuter le .exe ici : sudo apt install wine)
#
# Ce script a servi à valider le backend Windows DPAPI sous wine avant toute
# machine Windows réelle. Sur une vraie CI Windows, on utilise plutôt le build
# CMake/vcpkg natif (cf. .github/workflows/crypto-engine.yml).

set -euo pipefail

SODIUM_VERSION="1.0.22"
MINGW="x86_64-w64-mingw32-g++"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # crypto-engine/
DIST="$(cd "$ROOT/.." && pwd)/dist/windows-x64"    # <repo>/dist/windows-x64
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ">> Récupération de libsodium ${SODIUM_VERSION} (build MinGW)"
curl -sSL -o "$WORK/libsodium.tar.gz" \
  "https://download.libsodium.org/libsodium/releases/libsodium-${SODIUM_VERSION}-stable-mingw.tar.gz"
tar xzf "$WORK/libsodium.tar.gz" -C "$WORK"
SODIUM="$WORK/libsodium-win64"

mkdir -p "$DIST"

echo ">> Compilation de zia_crypto.dll"
"$MINGW" -std=c++20 -O2 -DNDEBUG \
  -I"$ROOT/include" -I"$ROOT/src" -I"$SODIUM/include" \
  -shared -o "$DIST/zia_crypto.dll" \
  "$ROOT/src/engine.cpp" "$ROOT/src/identity.cpp" "$ROOT/src/x3dh.cpp" \
  "$ROOT/src/ratchet.cpp" "$ROOT/src/session.cpp" "$ROOT/src/primitives/primitives.cpp" \
  "$ROOT/platform/windows/secure_key_store_windows.cpp" \
  -Wl,--out-implib,"$WORK/libzia_crypto.dll.a" \
  -static-libgcc -static-libstdc++ \
  -L"$SODIUM/lib" -lsodium -lcrypt32 -lshell32 -lole32 -luuid

cp "$SODIUM/bin/libsodium-26.dll" "$DIST/"

echo ">> Compilation de zia_crypto_test.exe"
"$MINGW" -std=c++20 -O2 \
  -I"$ROOT/include" \
  -o "$DIST/zia_crypto_test.exe" \
  "$ROOT/tests/conformance_test.cpp" \
  -static-libgcc -static-libstdc++ \
  -L"$WORK" -L"$DIST" -lzia_crypto

echo ">> Terminé. Binaires dans : $DIST"
ls -la "$DIST"
