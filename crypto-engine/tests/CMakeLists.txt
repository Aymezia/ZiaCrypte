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

# Sauvegarde exportable : deux moteurs, deux dossiers de stockage. Le montage
# est ce qui fait la preuve — un aller-retour dans un seul moteur réussirait
# même si la clé de l'appareil s'était glissée dans le fichier.
add_executable(zia_backup_test backup_test.cpp)
target_link_libraries(zia_backup_test PRIVATE zia_crypto)
add_test(NAME backup COMMAND zia_backup_test)
