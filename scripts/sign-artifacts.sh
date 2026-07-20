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

echo ">> Signature des artefacts de $DOSSIER"
signes=0
for f in "$DOSSIER"/*; do
  # On ne signe pas les signatures elles-mêmes.
  case "$f" in *.sig) continue;; esac
  [ -f "$f" ] || continue
  "$OUTIL" sign "$CLE" "$f" >/dev/null
  # Contrôle immédiat : une signature qu'on ne vérifie pas soi-même ne prouve
  # rien — autant s'assurer tout de suite qu'elle est utilisable.
  PUB="${CLE%.key}.pub"
  if [ -f "$PUB" ] && ! "$OUTIL" verify "$PUB" "$f" "$f.sig" >/dev/null; then
    echo "ERREUR : la signature de $(basename "$f") ne se vérifie pas." >&2
    exit 1
  fi
  echo "   $(basename "$f").sig"
  signes=$((signes + 1))
done

echo ">> $signes artefact(s) signé(s) et vérifié(s)"
