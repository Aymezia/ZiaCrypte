#!/usr/bin/env bash
#
# Vérification de restauration.
#
# Une sauvegarde qu'on n'a jamais restaurée n'est pas une sauvegarde : c'est un
# fichier dont on espère quelque chose. Ce script fait l'essai pour de vrai —
# il déchiffre la dernière sauvegarde, la restaure dans une base JETABLE, compte
# les lignes table par table, compare à la base vivante, puis supprime la copie.
#
# Il exige la clé privée. Si celle-ci est conservée hors du serveur — c'est la
# configuration recommandée — alors ce script se lance depuis la machine qui la
# détient, pas depuis le serveur. C'est le prix de la propriété « un serveur
# compromis ne peut pas relire ses anciennes sauvegardes ».
#
# La base jetable est créée puis supprimée. La base de production n'est jamais
# touchée : aucune commande d'écriture ne la vise.
#
# Usage : backup-restore-check.sh [fichier.dump.gpg]
set -euo pipefail

BACKUP_DIR="${ZIA_BACKUP_DIR:-/var/backups/ziacrypte}"
ENV_FILE="${ZIA_ENV_FILE:-/home/ubuntu/ZiaCrypte/server/.env}"

if [ -z "${DATABASE_URL:-}" ] && [ -f "$ENV_FILE" ]; then
  DATABASE_URL="$(grep -m1 '^DATABASE_URL=' "$ENV_FILE" | cut -d= -f2-)"
fi
[ -n "${DATABASE_URL:-}" ] || { echo "ERREUR : DATABASE_URL introuvable." >&2; exit 2; }

SOURCE="${1:-$(ls -1t "$BACKUP_DIR"/ziacrypte-*.dump.gpg 2>/dev/null | head -1 || true)}"
[ -n "$SOURCE" ] || { echo "ERREUR : aucune sauvegarde trouvée dans $BACKUP_DIR." >&2; exit 2; }
[ -f "$SOURCE" ] || { echo "ERREUR : $SOURCE introuvable." >&2; exit 2; }

# Base jetable, nom horodaté pour ne jamais entrer en collision.
SCRATCH="ziacrypte_verif_$(date -u +%Y%m%d%H%M%S)"
BASE_URL="${DATABASE_URL%/*}"
SCRATCH_URL="$BASE_URL/$SCRATCH"
ADMIN_URL="$BASE_URL/postgres"

echo ">> Vérification de $SOURCE"
echo "   base jetable : $SCRATCH"

nettoyer() {
  psql "$ADMIN_URL" -q -c "DROP DATABASE IF EXISTS \"$SCRATCH\";" >/dev/null 2>&1 || true
}
trap nettoyer EXIT

psql "$ADMIN_URL" -q -c "CREATE DATABASE \"$SCRATCH\";"

echo ">> Déchiffrement et restauration"
set -o pipefail
# Le dump déchiffré ne touche pas le disque : il passe directement à pg_restore.
# `--exit-on-error` est indispensable : sans lui, pg_restore signale les erreurs
# et rend malgré tout 0, et une restauration à moitié faite passerait pour bonne.
gpg --batch --quiet --decrypt "$SOURCE" \
  | pg_restore --dbname="$SCRATCH_URL" --no-owner --no-privileges --exit-on-error

echo ">> Comparaison avec la base vivante"

TABLES=$(psql "$DATABASE_URL" -tAc "
  SELECT tablename FROM pg_tables
  WHERE schemaname='public' AND tablename <> '_prisma_migrations'
  ORDER BY tablename;")

ECARTS=0
VIDES=0
for t in $TABLES; do
  VIVANT=$(psql "$DATABASE_URL" -tAc "SELECT count(*) FROM \"$t\";")
  COPIE=$(psql "$SCRATCH_URL" -tAc "SELECT count(*) FROM \"$t\";" 2>/dev/null || echo "ABSENTE")
  if [ "$COPIE" = "ABSENTE" ]; then
    printf '   %-28s %8s -> %s  TABLE MANQUANTE\n' "$t" "$VIVANT" "$COPIE"
    ECARTS=$((ECARTS + 1))
  elif [ "$VIVANT" != "$COPIE" ]; then
    # Un écart n'est pas forcément une faute : la base a pu vivre depuis la
    # sauvegarde. On le signale sans le compter comme une erreur, sauf si la
    # copie est vide alors que la base ne l'est pas.
    if [ "$COPIE" -eq 0 ] && [ "$VIVANT" -gt 0 ]; then
      printf '   %-28s %8s -> %-8s  VIDE DANS LA COPIE\n' "$t" "$VIVANT" "$COPIE"
      VIDES=$((VIDES + 1))
    else
      printf '   %-28s %8s -> %-8s  (écart, la base a évolué depuis)\n' "$t" "$VIVANT" "$COPIE"
    fi
  else
    printf '   %-28s %8s -> %-8s  ok\n' "$t" "$VIVANT" "$COPIE"
  fi
done

echo
if [ "$ECARTS" -gt 0 ] || [ "$VIDES" -gt 0 ]; then
  echo "ÉCHEC : $ECARTS table(s) manquante(s), $VIDES vide(s) à tort."
  echo "Cette sauvegarde ne permettrait pas de repartir. Ne t'y fie pas."
  exit 1
fi

echo "SUCCÈS : la sauvegarde se restaure et contient toutes les tables."
echo "La base jetable est supprimée."
