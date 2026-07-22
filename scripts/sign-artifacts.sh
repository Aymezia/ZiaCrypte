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
# Usage : sign-artifacts.sh <dossier> [cle.key]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOSSIER="${1:-$ROOT/dist/release}"
CLE="${2:-${ZIA_SIGNING_KEY:-$HOME/.ziacrypte-signing/release.key}}"
OUTIL="$ROOT/crypto-engine/build/linux-system/tools/zia_sign_release"

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
fi

echo ">> ${#fichiers[@]} artefact(s) signé(s) et vérifié(s)"
