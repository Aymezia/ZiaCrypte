# Outil de signature des releases. Utilise libsodium directement : c'est un
# outil de publication, pas du code embarqué dans l'application.
add_executable(zia_sign_release sign_release.cpp)
target_link_libraries(zia_sign_release PRIVATE zia::sodium)
