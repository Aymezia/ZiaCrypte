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
//   sign_release protect <cle.key> <cle.key.enc>   -> chiffre la cle privee
//
// CE QUE LE CHIFFREMENT DE LA CLE PROTEGE, ET CE QU'IL NE PROTEGE PAS
//
// Protege : une image disque, une capture de machine virtuelle ou une
// sauvegarde volee ne contiennent plus qu'un fichier inexploitable.
//
// NE protege PAS d'une compromission en cours : la phrase de passe est saisie
// sur cette machine au moment de signer. Qui la controle a ce moment-la peut
// la capturer (frappe clavier, memoire du processus) et repartir avec la cle
// en clair. Sur un serveur expose a Internet, c'est une reduction du risque,
// pas une mise a l'abri. La seule mise a l'abri est que la cle ne soit pas
// sur cette machine.
//
// La signature porte sur le SHA-512 du fichier, exactement comme le vérifie
// zia_verify_file_signature côté application.

#include <sodium.h>

#include <termios.h>
#include <unistd.h>

#include <cstring>
#include <iostream>

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

constexpr char kMagic[8] = {'Z','I','A','K','E','Y','0','1'};
constexpr unsigned long long kOps = crypto_pwhash_OPSLIMIT_MODERATE;
constexpr size_t kMem = crypto_pwhash_MEMLIMIT_MODERATE;

// Lecture sans echo. La phrase ne passe NI par argv NI par l'environnement :
// les deux sont lisibles par tout autre processus de la machine (ps, /proc),
// ce qui annulerait l'interet du chiffrement.
std::string demander_phrase(const char* invite) {
  std::fprintf(stderr, "%s", invite);
  std::fflush(stderr);
  termios avant{};
  const bool tty = tcgetattr(STDIN_FILENO, &avant) == 0;
  if (tty) {
    termios muet = avant;
    muet.c_lflag &= ~static_cast<tcflag_t>(ECHO);
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &muet);
  }
  std::string phrase;
  std::getline(std::cin, phrase);
  if (tty) {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &avant);
    std::fprintf(stderr, "\n");
  }
  return phrase;
}

bool est_chiffree(const std::vector<unsigned char>& brut) {
  return brut.size() > sizeof(kMagic) &&
         std::memcmp(brut.data(), kMagic, sizeof(kMagic)) == 0;
}

int proteger(const std::string& entree, const std::string& sortie) {
  std::vector<unsigned char> sk;
  if (!lire_fichier(entree, sk) || sk.size() != crypto_sign_SECRETKEYBYTES) {
    std::fprintf(stderr, "cle privee illisible ou de taille incorrecte\n");
    return 1;
  }
  const std::string p1 = demander_phrase("Phrase de passe : ");
  if (p1.size() < 12) {
    std::fprintf(stderr, "phrase trop courte (12 caracteres minimum)\n");
    return 1;
  }
  // Demandee deux fois : une faute de frappe rendrait la cle definitivement
  // inutilisable, et avec elle tout le canal de mise a jour.
  if (p1 != demander_phrase("Confirme la phrase : ")) {
    std::fprintf(stderr, "les deux phrases different\n");
    return 1;
  }

  unsigned char sel[crypto_pwhash_SALTBYTES];
  randombytes_buf(sel, sizeof(sel));
  unsigned char cle[crypto_secretstream_xchacha20poly1305_KEYBYTES];
  if (crypto_pwhash(cle, sizeof(cle), p1.c_str(), p1.size(), sel, kOps, kMem,
                    crypto_pwhash_ALG_ARGON2ID13) != 0) {
    std::fprintf(stderr, "memoire insuffisante pour deriver la cle\n");
    return 1;
  }

  unsigned char entete[crypto_secretstream_xchacha20poly1305_HEADERBYTES];
  crypto_secretstream_xchacha20poly1305_state st;
  crypto_secretstream_xchacha20poly1305_init_push(&st, entete, cle);
  std::vector<unsigned char> chiffre(
      sk.size() + crypto_secretstream_xchacha20poly1305_ABYTES);
  unsigned long long n = 0;
  crypto_secretstream_xchacha20poly1305_push(
      &st, chiffre.data(), &n, sk.data(), sk.size(), nullptr, 0,
      crypto_secretstream_xchacha20poly1305_TAG_FINAL);
  sodium_memzero(sk.data(), sk.size());
  sodium_memzero(cle, sizeof(cle));

  std::vector<unsigned char> out;
  out.insert(out.end(), kMagic, kMagic + sizeof(kMagic));
  out.insert(out.end(), sel, sel + sizeof(sel));
  out.insert(out.end(), entete, entete + sizeof(entete));
  out.insert(out.end(), chiffre.begin(),
             chiffre.begin() + static_cast<std::ptrdiff_t>(n));

  if (!ecrire_fichier(sortie, out.data(), out.size())) {
    std::fprintf(stderr, "ecriture impossible : %s\n", sortie.c_str());
    return 1;
  }
  std::printf("cle chiffree : %s\n", sortie.c_str());
  std::printf("Efface maintenant la version en clair, et garde une sauvegarde\n"
              "HORS LIGNE : sans cette cle, plus aucune mise a jour ne sera\n"
              "installable par ceux qui ont deja l'application.\n");
  return 0;
}

// Ouvre une cle chiffree. La phrase est demandee UNE fois par execution, d'ou
// la signature de plusieurs fichiers en un seul appel.
bool ouvrir_cle(std::vector<unsigned char>& sk) {
  if (!est_chiffree(sk)) return sk.size() == crypto_sign_SECRETKEYBYTES;

  const size_t prefixe = sizeof(kMagic) + crypto_pwhash_SALTBYTES +
                         crypto_secretstream_xchacha20poly1305_HEADERBYTES;
  if (sk.size() < prefixe + crypto_secretstream_xchacha20poly1305_ABYTES) {
    std::fprintf(stderr, "fichier de cle tronque\n");
    return false;
  }
  const unsigned char* sel = sk.data() + sizeof(kMagic);
  const unsigned char* entete = sel + crypto_pwhash_SALTBYTES;

  const std::string phrase = demander_phrase("Phrase de passe de la cle : ");
  unsigned char cle[crypto_secretstream_xchacha20poly1305_KEYBYTES];
  if (crypto_pwhash(cle, sizeof(cle), phrase.c_str(), phrase.size(), sel, kOps,
                    kMem, crypto_pwhash_ALG_ARGON2ID13) != 0) {
    std::fprintf(stderr, "memoire insuffisante\n");
    return false;
  }

  crypto_secretstream_xchacha20poly1305_state st;
  if (crypto_secretstream_xchacha20poly1305_init_pull(&st, entete, cle) != 0) {
    std::fprintf(stderr, "cle illisible\n");
    return false;
  }
  std::vector<unsigned char> clair(
      sk.size() - prefixe - crypto_secretstream_xchacha20poly1305_ABYTES);
  unsigned long long n = 0;
  unsigned char tag = 0;
  const int rc = crypto_secretstream_xchacha20poly1305_pull(
      &st, clair.data(), &n, &tag, sk.data() + prefixe, sk.size() - prefixe,
      nullptr, 0);
  sodium_memzero(cle, sizeof(cle));
  if (rc != 0 || n != crypto_sign_SECRETKEYBYTES) {
    std::fprintf(stderr, "phrase de passe incorrecte, ou fichier altere\n");
    return false;
  }
  sk.assign(clair.begin(), clair.begin() + static_cast<std::ptrdiff_t>(n));
  sodium_memzero(clair.data(), clair.size());
  return true;
}

int signer(const std::string& cle, const std::string& fichier) {
  std::vector<unsigned char> sk;
  if (!lire_fichier(cle, sk) || !ouvrir_cle(sk)) {
    std::fprintf(stderr, "cle privee illisible\n");
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
                 "  sign_release verify <cle.pub> <fichier> <fichier.sig>\n"
                 "  sign_release protect <cle.key> <cle.key.enc>\n");
    return 2;
  }
  const std::string cmd = argv[1];
  if (cmd == "keygen") return keygen(argv[2]);
  if (cmd == "protect" && argc >= 4) return proteger(argv[2], argv[3]);
  if (cmd == "sign" && argc >= 4) return signer(argv[2], argv[3]);
  if (cmd == "verify" && argc >= 5) return verifier(argv[2], argv[3], argv[4]);
  std::fprintf(stderr, "commande inconnue\n");
  return 2;
}
