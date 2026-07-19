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

  echo ">> [$abi] compilation de libzia_crypto.so"
  out_dir="$JNI_LIBS/$abi"
  mkdir -p "$out_dir"
  "$TOOLCHAIN/bin/${host}${API_LEVEL}-clang++" \
    -std=c++20 -O2 -DNDEBUG -fPIC -shared \
    -I"$ROOT/include" -I"$ROOT/src" -I"$sodium_prefix/include" \
    "$ROOT/src/engine.cpp" "$ROOT/src/identity.cpp" "$ROOT/src/x3dh.cpp" \
    "$ROOT/src/ratchet.cpp" "$ROOT/src/session.cpp" \
    "$ROOT/src/primitives/primitives.cpp" \
    "$ROOT/src/storage/identity_store.cpp" "$ROOT/src/storage/secure_blob.cpp" \
    "$ROOT/src/vault.cpp" \
    "$ROOT/platform/android/secure_key_store_android.cpp" \
    -o "$out_dir/libzia_crypto.so" \
    "$sodium_prefix/lib/libsodium.a" -llog

  "$TOOLCHAIN/bin/llvm-strip" --strip-unneeded "$out_dir/libzia_crypto.so"
  echo "   $(ls -lh "$out_dir/libzia_crypto.so" | awk '{print $5}')"
done

echo ">> Terminé — bibliothèques dans $JNI_LIBS"
ls -R "$JNI_LIBS"
