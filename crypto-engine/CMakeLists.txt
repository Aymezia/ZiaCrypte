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
endif()
