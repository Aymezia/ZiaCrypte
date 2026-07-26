add_executable(zia_crypto_conformance_test conformance_test.cpp)
target_link_libraries(zia_crypto_conformance_test PRIVATE zia_crypto)

add_test(NAME conformance COMMAND zia_crypto_conformance_test)

add_executable(zia_persistence_test persistence_test.cpp)
target_link_libraries(zia_persistence_test PRIVATE zia_crypto)

add_test(NAME persistence COMMAND zia_persistence_test)

# Compile safety_number.cpp directement : le test confronte la primitive interne
# au vecteur officiel de libsignal, ce qui exige des clés de 33 octets là où
# l'ABI publique est bornée à 32. L'en-tête interne n'est pas installé.
add_executable(zia_safety_number_test
    safety_number_test.cpp
    ${CMAKE_SOURCE_DIR}/src/safety_number.cpp)
target_include_directories(zia_safety_number_test PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_link_libraries(zia_safety_number_test PRIVATE zia_crypto zia::sodium)

add_test(NAME safety_number COMMAND zia_safety_number_test)

# Fuzzers : construits uniquement sous le preset dédié (clang + libFuzzer).
# Ils ne font pas partie de `ctest` — un fuzzer n'a pas de fin, il tourne sur
# un budget de temps.
if(ZIA_BUILD_FUZZERS)
  # Générateur de graines : produit des artefacts VALIDES que le fuzzer déforme
  # ensuite. Sans lui, il passe son budget à redécouvrir la structure des
  # entrées au lieu d'explorer les chemins profonds.
  add_executable(zia_fuzz_seed_corpus fuzz_seed_corpus.cpp)
  target_link_libraries(zia_fuzz_seed_corpus PRIVATE zia_crypto zia::sodium)

  add_executable(zia_fuzz_parsers fuzz_parsers.cpp)
  target_link_libraries(zia_fuzz_parsers PRIVATE zia_crypto zia::sodium)
  target_link_options(zia_fuzz_parsers PRIVATE -fsanitize=fuzzer)
endif()

# Migration du format d'identité : compile le sérialiseur interne directement,
# seul moyen de fabriquer un fichier v1 maintenant que l'écriture produit du v2.
add_executable(zia_identity_migration_test
    identity_migration_test.cpp
    ${CMAKE_SOURCE_DIR}/src/storage/identity_store.cpp
    ${CMAKE_SOURCE_DIR}/src/primitives/primitives.cpp)
target_include_directories(zia_identity_migration_test PRIVATE ${CMAKE_SOURCE_DIR}/src)
# Pas de backend natif ici : le test fournit un coffre factice, puisqu'il ne
# sérialise qu'en mémoire. Compiler le coffre de chaque plateforme dans cette
# cible aurait demandé de dupliquer la sélection par système — et c'est
# exactement ce qui a cassé la compilation macOS.
target_link_libraries(zia_identity_migration_test PRIVATE zia_crypto zia::sodium zia::oqs)
add_test(NAME identity_migration COMMAND zia_identity_migration_test)

# Sauvegarde exportable : deux moteurs, deux dossiers de stockage. Le montage
# est ce qui fait la preuve — un aller-retour dans un seul moteur réussirait
# même si la clé de l'appareil s'était glissée dans le fichier.
add_executable(zia_backup_test backup_test.cpp)
target_link_libraries(zia_backup_test PRIVATE zia_crypto)
add_test(NAME backup COMMAND zia_backup_test)

# Expéditeur scellé : le test central n'est pas l'aller-retour — il réussirait
# avec n'importe quel chiffrement — mais le fait que l'enveloppe ne laisse rien
# filtrer de son auteur, et qu'un tiers ne puisse pas l'ouvrir.
add_executable(zia_sealed_sender_test sealed_sender_test.cpp)
target_link_libraries(zia_sealed_sender_test PRIVATE zia_crypto)
add_test(NAME sealed_sender COMMAND zia_sealed_sender_test)

add_executable(zia_sender_keys_test sender_keys_test.cpp)
target_link_libraries(zia_sender_keys_test PRIVATE zia_crypto)
add_test(NAME sender_keys COMMAND zia_sender_keys_test)

# Canaux : le lien porte la clé de lecture. Prouve le scellement/descellement
# sous le secret de lien, la lecture de bout en bout, et le refus de publier
# sans la clé de signature de l'admin.
add_executable(zia_channel_test channel_test.cpp)
target_link_libraries(zia_channel_test PRIVATE zia_crypto)
add_test(NAME channel COMMAND zia_channel_test)

# ------------------------------------------------------------------ NDEBUG
#
# Toute cette suite est écrite avec assert(). Or les presets compilent en
# Release, donc avec NDEBUG : le préprocesseur EFFAÇAIT chaque vérification.
# Les binaires s'exécutaient, affichaient leurs lignes « [OK] », et ne
# testaient rien d'autre que l'absence de plantage — un test vert qui ne
# vérifie rien est pire que pas de test, puisqu'on s'y fie.
#
# On retire donc NDEBUG pour les cibles de test uniquement. La bibliothèque,
# elle, reste compilée en Release.
set(ZIA_TEST_TARGETS
    zia_crypto_conformance_test
    zia_persistence_test
    zia_safety_number_test
    zia_identity_migration_test
    zia_backup_test
    zia_sealed_sender_test
    zia_sender_keys_test
    zia_channel_test)
foreach(cible IN LISTS ZIA_TEST_TARGETS)
    if(MSVC)
        target_compile_options(${cible} PRIVATE /UNDEBUG)
    else()
        target_compile_options(${cible} PRIVATE -UNDEBUG)
    endif()
endforeach()
