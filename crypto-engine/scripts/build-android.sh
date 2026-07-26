#!/usr/bin/env bash
# Cross-compilation du moteur pour Android (NDK), une bibliothèque par ABI.
#
# Produit app/android/app/src/main/jniLibs/<abi>/libzia_crypto.so, emplacement
# où Gradle les embarque automatiquement dans l'APK. Le chargeur Android les
# résout ensuite par simple nom.
#
# libsodium est compilé depuis les sources pour chaque ABI et lié STATIQUEMENT :
# rien d'autre à embarquer.
#
# Prérequis : ANDROID_NDK_HOME (ou ANDROID_HOME avec un NDK installé), curl.

set -euo pipefail

SODIUM_VERSION="1.0.20"
API_LEVEL=24                      # Android 7.0, seuil courant pour Flutter
ABIS=("arm64-v8a" "armeabi-v7a" "x86_64")
OQS_VERSION="0.14.0"                # ML-KEM-768 (PQXDH)
# Permet de ne construire qu'une ABI pendant une mise au point :
#   ZIA_ABIS="arm64-v8a" ./scripts/build-android.sh
[ -n "${ZIA_ABIS:-}" ] && read -r -a ABIS <<< "$ZIA_ABIS"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JNI_LIBS="$(cd "$ROOT/.." && pwd)/app/android/app/src/main/jniLibs"

NDK="${ANDROID_NDK_HOME:-}"
if [ -z "$NDK" ]; then
  NDK="$(ls -d "${ANDROID_HOME:-$HOME/android-sdk}"/ndk/* 2>/dev/null | head -1 || true)"
fi
[ -n "$NDK" ] && [ -d "$NDK" ] || { echo "NDK introuvable — définis ANDROID_NDK_HOME"; exit 1; }

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo ">> Sources libsodium ${SODIUM_VERSION}"


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

# Correspondance ABI -> triplet de la chaîne de compilation
declare -A HOST=( ["arm64-v8a"]="aarch64-linux-android" \
                  ["armeabi-v7a"]="armv7a-linux-androideabi" \
                  ["x86_64"]="x86_64-linux-android" )
# Le préfixe des binutils diffère du triplet du compilateur pour armeabi-v7a.
declare -A TOOLPREFIX=( ["arm64-v8a"]="aarch64-linux-android" \
                        ["armeabi-v7a"]="arm-linux-androideabi" \
                        ["x86_64"]="x86_64-linux-android" )

for abi in "${ABIS[@]}"; do
  host="${HOST[$abi]}"
  echo ">> [$abi] compilation de libsodium"
  sodium_prefix="$WORK/sodium-$abi"
  (
    cd "$WORK/libsodium-stable"
    make distclean >/dev/null 2>&1 || true
    export CC="$TOOLCHAIN/bin/${host}${API_LEVEL}-clang"
    export AR="$TOOLCHAIN/bin/llvm-ar"
    export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
    ./configure --host="${TOOLPREFIX[$abi]}" --prefix="$sodium_prefix" \
      --enable-static --disable-shared --with-sysroot="$TOOLCHAIN/sysroot" \
      CFLAGS="-O2 -fPIC" >/dev/null
    make -j"$(nproc)" >/dev/null
    make install >/dev/null
  )

  # liboqs pour cette ABI. Comme libsodium : statique, ML-KEM seul, sans
  # OpenSSL — un .so d'application n'a pas à embarquer deux bibliothèques
  # cryptographiques complètes.
  echo ">> [$abi] compilation de liboqs"
  oqs_prefix="$WORK/oqs-$abi"
  if [ ! -d "$WORK/liboqs" ]; then
    git clone --depth 1 --branch "$OQS_VERSION" \
      https://github.com/open-quantum-safe/liboqs.git "$WORK/liboqs" >/dev/null 2>&1
  fi
  cmake -S "$WORK/liboqs" -B "$WORK/liboqs/build-$abi" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$API_LEVEL" \
    -DCMAKE_BUILD_TYPE=Release \
    -DOQS_MINIMAL_BUILD=KEM_ml_kem_768 \
    -DOQS_USE_OPENSSL=OFF -DOQS_BUILD_ONLY_LIB=ON -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_PREFIX="$oqs_prefix" >/dev/null
  cmake --build "$WORK/liboqs/build-$abi" --target install -j"$(nproc)" >/dev/null

  echo ">> [$abi] compilation de libzia_crypto.so"
  out_dir="$JNI_LIBS/$abi"
  mkdir -p "$out_dir"
  # -static-libstdc++ : le runtime C++ (libc++_shared.so) est lié STATIQUEMENT.
  # Sans lui, le .so réclame libc++_shared.so à l'exécution, absente de l'APK —
  # l'application plante au tout premier chargement du moteur avec
  # « dlopen failed: library "libc++_shared.so" not found ». Sûr ici : le moteur
  # n'expose qu'une ABI C (extern "C"), donc aucun objet C++ ne franchit la
  # frontière, seul cas où un runtime C++ statique poserait problème.
  "$TOOLCHAIN/bin/${host}${API_LEVEL}-clang++" \
    -std=c++20 -O2 -DNDEBUG -fPIC -shared -static-libstdc++ \
    -I"$ROOT/include" -I"$ROOT/src" -I"$sodium_prefix/include" \
    -I"$oqs_prefix/include" \
    "$ROOT/src/engine.cpp" "$ROOT/src/identity.cpp" "$ROOT/src/x3dh.cpp" \
    "$ROOT/src/ratchet.cpp" "$ROOT/src/session.cpp" \
    "$ROOT/src/primitives/primitives.cpp" \
    "$ROOT/src/storage/identity_store.cpp" "$ROOT/src/storage/secure_blob.cpp" \
    "$ROOT/src/vault.cpp" "$ROOT/src/attachment.cpp" \
    "$ROOT/src/safety_number.cpp" "$ROOT/src/release_signature.cpp" "$ROOT/src/backup.cpp" "$ROOT/src/applock.cpp" "$ROOT/src/sealed_sender.cpp" "$ROOT/src/sender_keys.cpp" "$ROOT/src/channel.cpp" \
    "$ROOT/platform/android/secure_key_store_android.cpp" \
    -o "$out_dir/libzia_crypto.so" \
    "$sodium_prefix/lib/libsodium.a" "$oqs_prefix/lib/liboqs.a" -llog

  "$TOOLCHAIN/bin/llvm-strip" --strip-unneeded "$out_dir/libzia_crypto.so"
  "$TOOLCHAIN/bin/llvm-nm" --dynamic --defined-only "$out_dir/libzia_crypto.so" \
    | grep -oE '\bzia_[a-z_]+\b' | sort -u > "$WORK/exported_$abi.txt"
  check_exported_symbols "$WORK/exported_$abi.txt"
  echo "   $(ls -lh "$out_dir/libzia_crypto.so" | awk '{print $5}')"
done

echo ">> Terminé — bibliothèques dans $JNI_LIBS"
ls -R "$JNI_LIBS"
