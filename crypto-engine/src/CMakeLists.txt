add_library(zia_crypto SHARED
    engine.cpp
    identity.cpp
    x3dh.cpp
    ratchet.cpp
    session.cpp
    primitives/primitives.cpp
    storage/identity_store.cpp
    storage/secure_blob.cpp
    vault.cpp
)

target_include_directories(zia_crypto
    PUBLIC ${CMAKE_SOURCE_DIR}/include
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(zia_crypto PRIVATE zia::sodium)

# SecureKeyStore : une implémentation par plateforme (Phases 7-8), sélectionnée
# à la compilation. Chaque backend s'appuie sur le SDK natif de son OS.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    # Secret Service / libsecret — implémenté et testé en Phase 7.
    target_sources(zia_crypto PRIVATE ${CMAKE_SOURCE_DIR}/platform/linux/secure_key_store_linux.cpp)
    target_link_libraries(zia_crypto PRIVATE PkgConfig::LIBSECRET)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    # DPAPI (crypt32) — écrit en Phase 8, à valider via la CI Windows.
    target_sources(zia_crypto PRIVATE ${CMAKE_SOURCE_DIR}/platform/windows/secure_key_store_windows.cpp)
    target_link_libraries(zia_crypto PRIVATE crypt32)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin" OR CMAKE_SYSTEM_NAME STREQUAL "iOS")
    # Keychain Services (Objective-C++) — écrit en Phase 8, à valider via la CI macOS/iOS.
    target_sources(zia_crypto PRIVATE ${CMAKE_SOURCE_DIR}/platform/apple/secure_key_store_apple.mm)
    target_link_libraries(zia_crypto PRIVATE "-framework Foundation" "-framework Security")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Android")
    # Android Keystore via JNI — écrit en Phase 8, à valider via la CI Android (NDK).
    target_sources(zia_crypto PRIVATE ${CMAKE_SOURCE_DIR}/platform/android/secure_key_store_android.cpp)
endif()

set_target_properties(zia_crypto PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VERSION 0.1.0
)
