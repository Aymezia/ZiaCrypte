#!/usr/bin/env bash
#
# Sauvegarde chiffrée de la base ZiaCrypte.
#
# ## Pourquoi elle est chiffrée
#
# Le dump contient les hachages de mots de passe, les pseudos, les métadonnées
# d'appareils et les blobs non encore remis. Le serveur ne peut rien déchiffrer
# de ces blobs, mais l'ensemble reste une photographie de qui parle à qui — ce
# que le chiffrement de bout en bout ne protège pas. Une sauvegarde en clair
# annulerait une partie du travail fait ailleurs.
#
# ## Pourquoi elle est ASYMÉTRIQUE
#
# On chiffre vers une clé publique dont la clé privée reste HORS de cette
# machine. Le serveur peut donc écrire des sauvegardes sans pouvoir relire les
# précédentes : quelqu'un qui prend le contrôle du serveur n'obtient pas
# l'historique des sauvegardes avec.
#
# Contrepartie, à assumer les yeux ouverts : perdre la clé privée rend TOUTES
# les sauvegardes définitivement illisibles. Elle doit être conservée ailleurs,
# et sa restauration doit avoir été essayée au moins une fois.
#
# ## Ce que ça ne protège pas
#
# Les sauvegardes écrites ici sont sur le même disque que la base. Cela couvre
# la corruption et l'effacement accidentel, PAS la perte de la machine. Les
# recopier hors du serveur reste indispensable.
#
# Usage : backup-db.sh [dossier-de-destination]
set -euo pipefail

BACKUP_DIR="${1:-${ZIA_BACKUP_DIR:-/var/backups/ziacrypte}}"
KEEP="${ZIA_BACKUP_KEEP:-14}"
RECIPIENT="${ZIA_BACKUP_RECIPIENT:-}"

if [ -z "$RECIPIENT" ]; then
  echo "ERREUR : ZIA_BACKUP_RECIPIENT non défini (identifiant de la clé publique GPG)." >&2
  echo "Crée une paire de clés et garde la privée AILLEURS que sur ce serveur :" >&2
  echo "  gpg --quick-generate-key 'ZiaCrypte Backup <backup@ziacrypte>' default default never" >&2
  echo "  gpg --export-secret-keys --armor <id> > cle-privee.asc   # à mettre à l'abri, puis" >&2
  echo "  gpg --delete-secret-keys <id>                            # à retirer du serveur" >&2
  exit 2
fi

# L'URL de connexion vient du .env du serveur : une seule source de vérité.
ENV_FILE="${ZIA_ENV_FILE:-/home/ubuntu/ZiaCrypte/server/.env}"
if [ -z "${DATABASE_URL:-}" ] && [ -f "$ENV_FILE" ]; then
  DATABASE_URL="$(grep -m1 '^DATABASE_URL=' "$ENV_FILE" | cut -d= -f2-)"
fi
[ -n "${DATABASE_URL:-}" ] || { echo "ERREUR : DATABASE_URL introuvable." >&2; exit 2; }

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FINAL="$BACKUP_DIR/ziacrypte-$STAMP.dump.gpg"
TMP="$FINAL.partiel"

cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

echo ">> Sauvegarde vers $FINAL"

# Le dump ne touche JAMAIS le disque en clair : il est chiffré au fil de l'eau.
#
# `pipefail` est vital ici. Sans lui, un pg_dump qui échoue en cours de route
# laisserait gpg produire un fichier parfaitement valide… contenant un dump
# tronqué. C'est le mode de défaillance classique des sauvegardes : on accumule
# des fichiers d'apparence saine, et on ne l'apprend que le jour où l'on essaie
# de restaurer.
set -o pipefail
pg_dump --format=custom --compress=9 --no-owner --no-privileges "$DATABASE_URL" \
  | gpg --batch --yes --encrypt --trust-model always --recipient "$RECIPIENT" \
        --output "$TMP"

# Contrôles réalisables SANS la clé privée : le fichier est-il un paquet
# OpenPGP plausible, et non vide ?
TAILLE=$(stat -c%s "$TMP")
if [ "$TAILLE" -lt 1024 ]; then
  echo "ERREUR : sauvegarde suspecte ($TAILLE octets), abandon." >&2
  exit 1
fi
if ! gpg --batch --list-packets "$TMP" >/dev/null 2>&1; then
  echo "ERREUR : le fichier produit n'est pas un paquet OpenPGP valide." >&2
  exit 1
fi

mv "$TMP" "$FINAL"
chmod 600 "$FINAL"
trap - EXIT

echo "   $(numfmt --to=iec "$TAILLE") — chiffré pour $RECIPIENT"

# Rotation : on garde les KEEP plus récentes.
mapfile -t ANCIENNES < <(ls -1t "$BACKUP_DIR"/ziacrypte-*.dump.gpg 2>/dev/null | tail -n +$((KEEP + 1)))
if [ ${#ANCIENNES[@]} -gt 0 ]; then
  printf '   rotation : %d ancienne(s) supprimée(s)\n' "${#ANCIENNES[@]}"
  rm -f "${ANCIENNES[@]}"
fi

echo "   sauvegardes conservées : $(ls -1 "$BACKUP_DIR"/ziacrypte-*.dump.gpg 2>/dev/null | wc -l)"
echo ">> Terminé"
echo
echo "RAPPEL : ces fichiers sont sur le même disque que la base. Recopie-les"
echo "hors de cette machine, et essaie une restauration (scripts/backup-restore-check.sh)."
