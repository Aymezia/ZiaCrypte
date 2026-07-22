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


# Garde-fou : toute fonction déclarée dans l'en-tête public DOIT être exportée.
# La liste de sources ci-dessus est maintenue à la main ; sans ce contrôle, un
# fichier oublié produit une bibliothèque qui se compile, se lie et s'empaquette
# — puis fait échouer l'application au démarrage sur un symbole manquant.
#
# Prend en argument un FICHIER contenant les noms exportés (un par ligne) :
# extraire ces noms dépend du format binaire, c'est à l'appelant de le faire.
check_exported_symbols() {
  local exported="$1" missing=""
  for sym in $(grep -oE 'zia_[a-z_]+\(' "$ROOT/include/zia/zia_crypto.h" | tr -d '(' | sort -u); do
    grep -qx "$sym" "$exported" || missing="$missing $sym"
  done
  if [ -n "$missing" ]; then
    echo "ERREUR : symboles déclarés dans l'en-tête mais absents de la bibliothèque :"
    for s in $missing; do echo "  - $s"; done
    echo "Ajoute le fichier source correspondant à la liste de compilation."
    exit 1
  fi
  echo "   tous les symboles publics sont exportés"
}

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
  "$ROOT/src/storage/identity_store.cpp" "$ROOT/src/storage/secure_blob.cpp" "$ROOT/src/vault.cpp" "$ROOT/src/attachment.cpp" "$ROOT/src/safety_number.cpp" "$ROOT/src/release_signature.cpp" "$ROOT/src/backup.cpp" "$ROOT/src/applock.cpp" "$ROOT/src/sealed_sender.cpp" "$ROOT/src/sender_keys.cpp"
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

echo ">> Vérification des symboles exportés (DLL)"
"${MINGW_HOST}-objdump" -p "$DIST/zia_crypto.dll" \
  | grep -oE '\bzia_[a-z_]+\b' | sort -u > "$WORK/exported.txt"
check_exported_symbols "$WORK/exported.txt"
