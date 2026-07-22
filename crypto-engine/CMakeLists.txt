cmake_minimum_required(VERSION 3.24)
project(zia_crypto LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# --- libsodium ---
# Chemin nominal (cross-platform) : le port vcpkg fournit la cible importée
# `unofficial-sodium::sodium`, avec des triplets pour Windows/Linux/macOS/
# Android/iOS. Activé en configurant avec
#   -DCMAKE_TOOLCHAIN_FILE=<vcpkg>/scripts/buildsystems/vcpkg.cmake
# Repli (poste de dev Linux sans vcpkg, CI légère) : libsodium système via
# pkg-config. On expose dans les deux cas une même cible `zia::sodium` pour que
# le reste du projet n'ait pas à savoir d'où vient libsodium.
find_package(unofficial-sodium CONFIG QUIET)
if(TARGET unofficial-sodium::sodium)
    add_library(zia::sodium ALIAS unofficial-sodium::sodium)
    message(STATUS "libsodium: via vcpkg (unofficial-sodium::sodium)")
else()
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(SODIUM REQUIRED IMPORTED_TARGET libsodium)
    add_library(zia::sodium ALIAS PkgConfig::SODIUM)
    message(STATUS "libsodium: via pkg-config système (repli hors vcpkg)")
endif()

# --- liboqs (ML-KEM-768, Phase 39) ---
# Même schéma que libsodium : le port vcpkg pour les builds cross-plateformes,
# l'installation système en repli sur un poste de dev Linux. Exposé sous
# `zia::oqs` pour que le reste du projet ignore d'où il vient.
#
# liboqs se compile ici SANS OpenSSL (-DOQS_USE_OPENSSL=OFF) : ML-KEM n'en a
# pas besoin, et faire entrer OpenSSL dans un moteur qui ne dépend que de
# libsodium doublerait la surface cryptographique pour rien.
find_package(liboqs CONFIG QUIET)
if(TARGET OQS::oqs)
    add_library(zia::oqs ALIAS OQS::oqs)
    message(STATUS "liboqs: cible OQS::oqs")
else()
    find_path(OQS_INCLUDE_DIR oqs/oqs.h)
    find_library(OQS_LIBRARY NAMES oqs)
    if(NOT OQS_INCLUDE_DIR OR NOT OQS_LIBRARY)
        message(FATAL_ERROR
            "liboqs introuvable. Compile-le avec :\n"
            "  cmake -S . -B build -DOQS_MINIMAL_BUILD=KEM_ml_kem_768 "
            "-DOQS_USE_OPENSSL=OFF -DOQS_BUILD_ONLY_LIB=ON && ninja -C build install")
    endif()
    add_library(zia_oqs_imported STATIC IMPORTED)
    set_target_properties(zia_oqs_imported PROPERTIES
        IMPORTED_LOCATION ${OQS_LIBRARY}
        INTERFACE_INCLUDE_DIRECTORIES ${OQS_INCLUDE_DIR})
    add_library(zia::oqs ALIAS zia_oqs_imported)
    message(STATUS "liboqs: ${OQS_LIBRARY} (repli hors vcpkg)")
endif()

# Coffre-fort de clé maîtresse (Phase 7) : sur Linux desktop, Secret Service via
# libsecret est une dépendance système (GLib/D-Bus), pas un paquet vcpkg — comme
# pour Keychain/Keystore/DPAPI sur les autres plateformes, on s'appuie sur le
# SDK natif de l'OS plutôt que de le vendoriser.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(LIBSECRET REQUIRED IMPORTED_TARGET libsecret-1)
endif()

add_subdirectory(src)

option(ZIA_BUILD_TESTS "Compiler les tests unitaires du crypto-engine" OFF)
if(ZIA_BUILD_TESTS)
    enable_testing() # requis pour que ctest découvre les add_test() des sous-répertoires
    add_subdirectory(tests)
add_subdirectory(tools)
endif()
