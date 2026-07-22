#!/usr/bin/env bash
#
# Signe les artefacts d'une release avec la clé Ed25519 de publication.
#
# Chaque fichier reçoit un `.sig` détaché, publié à côté de lui. L'application
# refuse d'installer un artefact dont la signature manque ou ne correspond pas :
# sans cela, quiconque prend le contrôle de l'hébergement obtiendrait
# l'exécution de code chez tous les utilisateurs.
#
# La clé PRIVÉE ne doit jamais se trouver sur un serveur ni dans le dépôt.
#
# Usage : sign-artifacts.sh <dossier> [cle.key] [--publier [tag]]
#
#   --publier [tag]  Après signature, téléverse chaque artefact ET son .sig sur
#                    la release GitHub indiquée (par défaut : la plus récente).
#                    On envoie la PAIRE (artefact + signature) : la signature
#                    vaut pour ces octets-là précisément ; publier l'un sans
#                    l'autre laisserait une release incohérente. Option
#                    volontairement explicite — release.sh signe un dossier
#                    AVANT que la release existe, il ne doit donc jamais publier
#                    ici (il crée la release lui-même, ensuite).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTIL="$ROOT/crypto-engine/build/linux-system/tools/zia_sign_release"

# --- Lecture des arguments : deux positionnels (dossier, clé) + un drapeau ----
DOSSIER=""
CLE=""
PUBLIER=0
TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --publier)
      PUBLIER=1
      # Un tag explicite peut suivre ; sinon on prendra la release la plus récente.
      if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then TAG="$2"; shift; fi
      ;;
    --*)
      echo "ERREUR : option inconnue « $1 »." >&2; exit 2 ;;
    *)
      if [ -z "$DOSSIER" ]; then DOSSIER="$1"
      elif [ -z "$CLE" ]; then CLE="$1"
      else echo "ERREUR : argument en trop « $1 »." >&2; exit 2; fi
      ;;
  esac
  shift
done
DOSSIER="${DOSSIER:-$ROOT/dist/release}"
CLE="${CLE:-${ZIA_SIGNING_KEY:-$HOME/.ziacrypte-signing/release.key}}"

if [ "$PUBLIER" = 1 ] && ! command -v gh >/dev/null 2>&1; then
  echo "ERREUR : --publier exige gh (GitHub CLI) authentifié." >&2; exit 2
fi

[ -x "$OUTIL" ] || {
  echo "Outil de signature absent. Construis-le :" >&2
  echo "  cmake --preset linux-system && cmake --build build/linux-system" >&2
  exit 2
}
[ -f "$CLE" ] || {
  echo "ERREUR : clé privée introuvable ($CLE)." >&2
  echo "Génère-la hors ligne :  zia_sign_release keygen release" >&2
  exit 2
}
[ -d "$DOSSIER" ] || { echo "ERREUR : dossier introuvable ($DOSSIER)." >&2; exit 2; }

# Tous les artefacts sont signés en UN SEUL appel à l'outil : si la clé est
# chiffrée, la phrase de passe n'est donc demandée qu'une fois. Un appel par
# fichier la redemandait à chaque tour — une corvée qui ne protégeait rien,
# puisque la phrase réside de toute façon en mémoire le temps de dériver la clé.
echo ">> Signature des artefacts de $DOSSIER"
fichiers=()
for f in "$DOSSIER"/*; do
  case "$f" in *.sig) continue;; esac  # on ne signe pas les signatures
  [ -f "$f" ] || continue
  fichiers+=("$f")
done

if [ ${#fichiers[@]} -eq 0 ]; then
  echo "ERREUR : aucun artefact à signer dans $DOSSIER." >&2
  exit 1
fi

"$OUTIL" sign "$CLE" "${fichiers[@]}"

# Contrôle immédiat : une signature qu'on ne vérifie pas soi-même ne prouve
# rien. On revérifie chaque `.sig` produit, avec la clé publique.
PUB="${CLE%.key}.pub"
if [ -f "$PUB" ]; then
  for f in "${fichiers[@]}"; do
    if ! "$OUTIL" verify "$PUB" "$f" "$f.sig" >/dev/null; then
      echo "ERREUR : la signature de $(basename "$f") ne se vérifie pas." >&2
      exit 1
    fi
    echo "   $(basename "$f").sig  vérifié"
  done
else
  echo "AVERTISSEMENT : clé publique absente ($PUB) — signatures non revérifiées." >&2
fi

echo ">> ${#fichiers[@]} artefact(s) signé(s) et vérifié(s)"

# --- Publication optionnelle sur la release GitHub ---------------------------
if [ "$PUBLIER" = 1 ]; then
  if [ -z "$TAG" ]; then
    TAG="$(gh release view --json tagName --jq .tagName 2>/dev/null || true)"
    [ -n "$TAG" ] || { echo "ERREUR : aucune release trouvée à publier." >&2; exit 1; }
  fi
  echo ">> Téléversement vers la release $TAG (artefact + signature)"
  # La paire est envoyée ensemble : la signature vaut pour ces octets précis.
  # --clobber remplace une version antérieure du même nom sans échouer.
  a_envoyer=()
  for f in "${fichiers[@]}"; do
    a_envoyer+=("$f" "$f.sig")
  done
  gh release upload "$TAG" "${a_envoyer[@]}" --clobber
  echo ">> Release $TAG complétée : $(gh release view "$TAG" --json url --jq .url)"
fi
