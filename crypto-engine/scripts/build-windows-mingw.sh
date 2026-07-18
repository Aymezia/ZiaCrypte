#!/usr/bin/env bash
# Cross-compilation Windows x64 du crypto-engine depuis Linux, via MinGW-w64.
# Produit des artefacts AUTONOMES (libsodium lié statiquement, runtime MinGW
# statique) — aucune DLL tierce à distribuer.
#
# Sortie dans dist/windows-x64/ :
#   - zia_crypto_test.exe   : test de conformité autonome (un seul fichier)
#   - zia_crypto.dll        : le moteur, self-contained (libsodium embarqué)
#
# Prérequis (Debian/Ubuntu) :
#   sudo apt install mingw-w64 curl make
#   (optionnel, pour exécuter le .exe ici : sudo apt install wine)
#
# Sur une CI Windows native on utilise plutôt le build CMake/vcpkg
# (.github/workflows/crypto-engine-crossbuild.yml).

set -euo pipefail

SODIUM_VERSION="1.0.20"
MINGW_HOST="x86_64-w64-mingw32"
CXX="${MINGW_HOST}-g++"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # crypto-engine/
DIST="$(cd "$ROOT/.." && pwd)/dist/windows-x64"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ">> Récupération et compilation statique de libsodium ${SODIUM_VERSION}"
curl -sSL -o "$WORK/libsodium.tar.gz" \
  "https://download.libsodium.org/libsodium/releases/libsodium-${SODIUM_VERSION}-stable.tar.gz"
tar xzf "$WORK/libsodium.tar.gz" -C "$WORK"
(
  cd "$WORK/libsodium-stable"
  ./configure --host="$MINGW_HOST" --prefix="$WORK/sodium" \
    --enable-static --disable-shared CFLAGS="-O2" >/dev/null
  make -j"$(nproc)" >/dev/null
  make install >/dev/null
)
SODIUM="$WORK/sodium"

ENGINE_SRC=(
  "$ROOT/src/engine.cpp" "$ROOT/src/identity.cpp" "$ROOT/src/x3dh.cpp"
  "$ROOT/src/ratchet.cpp" "$ROOT/src/session.cpp" "$ROOT/src/primitives/primitives.cpp"
  "$ROOT/platform/windows/secure_key_store_windows.cpp"
)
COMMON_FLAGS=(-std=c++20 -O2 -DSODIUM_STATIC=1 -I"$ROOT/include" -I"$ROOT/src" -I"$SODIUM/include")
STATIC_LINK=(-static -static-libgcc -static-libstdc++
             -L"$SODIUM/lib" -l:libsodium.a -lcrypt32 -lshell32 -lole32 -luuid)

mkdir -p "$DIST"

echo ">> Compilation de zia_crypto_test.exe (autonome)"
"$CXX" "${COMMON_FLAGS[@]}" \
  "${ENGINE_SRC[@]}" "$ROOT/tests/conformance_test.cpp" \
  -o "$DIST/zia_crypto_test.exe" "${STATIC_LINK[@]}"

echo ">> Compilation de zia_crypto.dll (self-contained)"
"$CXX" "${COMMON_FLAGS[@]}" -shared \
  "${ENGINE_SRC[@]}" \
  -o "$DIST/zia_crypto.dll" \
  -Wl,--out-implib,"$DIST/libzia_crypto.dll.a" \
  "${STATIC_LINK[@]}"

echo ">> Terminé. Artefacts autonomes dans : $DIST"
ls -la "$DIST"
