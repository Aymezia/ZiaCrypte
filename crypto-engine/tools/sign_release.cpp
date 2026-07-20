// Outil de signature des artefacts de release.
//
// La clé PRIVÉE ne doit jamais se trouver sur un serveur : c'est elle qui
// autorise l'exécution de code chez tous les utilisateurs. Elle vit sur la
// machine de la personne qui publie, et nulle part ailleurs. La clé publique,
// elle, est intégrée à l'application.
//
//   sign_release keygen <prefixe>          -> <prefixe>.pub / <prefixe>.key
//   sign_release sign <cle.key> <fichier>  -> <fichier>.sig
//   sign_release verify <cle.pub> <fichier> <fichier.sig>
//
// La signature porte sur le SHA-512 du fichier, exactement comme le vérifie
// zia_verify_file_signature côté application.

#include <sodium.h>

#include <cstdio>
#include <string>
#include <vector>

namespace {

bool lire_fichier(const std::string& path, std::vector<unsigned char>& out) {
  std::FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  unsigned char buf[64 * 1024];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) {
    out.insert(out.end(), buf, buf + n);
  }
  const bool ok = std::ferror(f) == 0;
  std::fclose(f);
  return ok;
}

bool ecrire_fichier(const std::string& path, const unsigned char* data, size_t len) {
  std::FILE* f = std::fopen(path.c_str(), "wb");
  if (!f) return false;
  const bool ok = std::fwrite(data, 1, len, f) == len;
  std::fclose(f);
  return ok;
}

/// SHA-512 du fichier, calculé en flux — un artefact fait des dizaines de Mo.
bool hacher(const std::string& path, unsigned char out[crypto_hash_sha512_BYTES]) {
  std::FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  crypto_hash_sha512_state st;
  crypto_hash_sha512_init(&st);
  unsigned char buf[64 * 1024];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) {
    crypto_hash_sha512_update(&st, buf, n);
  }
  const bool ok = std::ferror(f) == 0;
  std::fclose(f);
  if (!ok) return false;
  crypto_hash_sha512_final(&st, out);
  return true;
}

int keygen(const std::string& prefixe) {
  unsigned char pk[crypto_sign_PUBLICKEYBYTES];
  unsigned char sk[crypto_sign_SECRETKEYBYTES];
  crypto_sign_keypair(pk, sk);

  if (!ecrire_fichier(prefixe + ".pub", pk, sizeof(pk)) ||
      !ecrire_fichier(prefixe + ".key", sk, sizeof(sk))) {
    std::fprintf(stderr, "écriture impossible\n");
    return 1;
  }
  std::printf("clé publique : %s.pub\n", prefixe.c_str());
  std::printf("clé PRIVÉE   : %s.key\n", prefixe.c_str());
  std::printf(
      "\nLa clé privée autorise l'exécution de code chez tous les utilisateurs.\n"
      "Garde-la hors ligne, jamais sur un serveur.\n");

  std::vector<char> b64(
      sodium_base64_ENCODED_LEN(sizeof(pk), sodium_base64_VARIANT_ORIGINAL));
  sodium_bin2base64(b64.data(), b64.size(), pk, sizeof(pk),
                    sodium_base64_VARIANT_ORIGINAL);
  std::printf("\nÀ intégrer dans l'application (base64) :\n  %s\n", b64.data());

  sodium_memzero(sk, sizeof(sk));
  return 0;
}

int signer(const std::string& cle, const std::string& fichier) {
  std::vector<unsigned char> sk;
  if (!lire_fichier(cle, sk) || sk.size() != crypto_sign_SECRETKEYBYTES) {
    std::fprintf(stderr, "clé privée illisible ou de taille incorrecte\n");
    return 1;
  }
  unsigned char digest[crypto_hash_sha512_BYTES];
  if (!hacher(fichier, digest)) {
    std::fprintf(stderr, "fichier illisible : %s\n", fichier.c_str());
    return 1;
  }
  unsigned char sig[crypto_sign_BYTES];
  crypto_sign_detached(sig, nullptr, digest, sizeof(digest), sk.data());
  sodium_memzero(sk.data(), sk.size());

  const std::string out = fichier + ".sig";
  if (!ecrire_fichier(out, sig, sizeof(sig))) {
    std::fprintf(stderr, "écriture impossible : %s\n", out.c_str());
    return 1;
  }
  std::printf("signé : %s\n", out.c_str());
  return 0;
}

int verifier(const std::string& clePub, const std::string& fichier,
             const std::string& sigPath) {
  std::vector<unsigned char> pk, sig;
  if (!lire_fichier(clePub, pk) || pk.size() != crypto_sign_PUBLICKEYBYTES) {
    std::fprintf(stderr, "clé publique invalide\n");
    return 1;
  }
  if (!lire_fichier(sigPath, sig) || sig.size() != crypto_sign_BYTES) {
    std::fprintf(stderr, "signature invalide\n");
    return 1;
  }
  unsigned char digest[crypto_hash_sha512_BYTES];
  if (!hacher(fichier, digest)) {
    std::fprintf(stderr, "fichier illisible\n");
    return 1;
  }
  if (crypto_sign_verify_detached(sig.data(), digest, sizeof(digest), pk.data()) != 0) {
    std::fprintf(stderr, "SIGNATURE REFUSÉE\n");
    return 2;
  }
  std::printf("signature valide\n");
  return 0;
}

} // namespace

int main(int argc, char** argv) {
  if (sodium_init() < 0) return 1;
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage:\n"
                 "  sign_release keygen <prefixe>\n"
                 "  sign_release sign <cle.key> <fichier>\n"
                 "  sign_release verify <cle.pub> <fichier> <fichier.sig>\n");
    return 2;
  }
  const std::string cmd = argv[1];
  if (cmd == "keygen") return keygen(argv[2]);
  if (cmd == "sign" && argc >= 4) return signer(argv[2], argv[3]);
  if (cmd == "verify" && argc >= 5) return verifier(argv[2], argv[3], argv[4]);
  std::fprintf(stderr, "commande inconnue\n");
  return 2;
}
