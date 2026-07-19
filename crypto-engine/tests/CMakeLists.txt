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
