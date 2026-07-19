# Sauvegardes

## Ce qui est en jeu

Le serveur ne détient aucune clé privée d'utilisateur. C'est la propriété
recherchée, mais elle a une conséquence directe : **si la base est perdue, rien
ne permet de la reconstruire**. Ni depuis les appareils, ni depuis les
sauvegardes des utilisateurs — ils n'en ont pas. Les comptes, les appareils
enregistrés et les prekeys publiées disparaissent définitivement.

C'est le seul endroit du projet où une erreur est irréversible.

## Mise en place

### 1. Créer la paire de clés — ailleurs que sur le serveur

À faire sur ta machine, **pas** sur le VPS :

```bash
gpg --quick-generate-key 'ZiaCrypte Backup <backup@ziacrypte>' default default never
gpg --list-keys --with-colons backup@ziacrypte | awk -F: '/^fpr/{print $10; exit}'
```

Exporte la clé **publique** et transfère-la au serveur :

```bash
gpg --export --armor <empreinte> > backup-pub.asc
scp backup-pub.asc ubuntu@<serveur>:/tmp/
```

Sur le serveur :

```bash
gpg --import /tmp/backup-pub.asc && rm /tmp/backup-pub.asc
```

Le serveur ne reçoit que la clé publique. Il peut donc écrire des sauvegardes,
sans pouvoir relire les précédentes. Quelqu'un qui prend le contrôle de la
machine n'obtient pas l'historique avec.

**Sauvegarde ta clé privée hors ligne.** La perdre rend toutes les sauvegardes
définitivement illisibles. C'est le prix de la propriété ci-dessus, et il se
paie comptant.

### 2. Installer la tâche planifiée

```bash
sudo mkdir -p /var/backups/ziacrypte && sudo chown ubuntu:ubuntu /var/backups/ziacrypte
sudo cp deploy/ziacrypte-backup.{service,timer} /etc/systemd/system/
sudo sed -i 's/^Environment=ZIA_BACKUP_RECIPIENT=$/Environment=ZIA_BACKUP_RECIPIENT=<empreinte>/' \
  /etc/systemd/system/ziacrypte-backup.service
sudo systemctl daemon-reload
sudo systemctl enable --now ziacrypte-backup.timer
```

Vérifier :

```bash
systemctl list-timers ziacrypte-backup.timer
sudo systemctl start ziacrypte-backup.service && journalctl -u ziacrypte-backup -n 20
```

### 3. Recopier hors de la machine

Les sauvegardes écrites dans `/var/backups/ziacrypte` sont **sur le même disque
que la base**. Cela couvre la corruption et l'effacement accidentel, pas la
perte de la machine. Un `rsync` vers un autre hébergeur, ou un simple
téléchargement périodique, reste indispensable. Les fichiers étant chiffrés, la
destination n'a pas besoin d'être de confiance.

## Vérifier qu'une sauvegarde est restaurable

Une sauvegarde qu'on n'a jamais restaurée n'est pas une sauvegarde : c'est un
fichier dont on espère quelque chose.

```bash
./scripts/backup-restore-check.sh [fichier.dump.gpg]
```

Le script déchiffre la dernière sauvegarde, la restaure dans une base
**jetable**, compte les lignes table par table, compare à la base vivante, puis
supprime la copie. La base de production n'est jamais touchée.

Il exige la clé privée : lance-le donc depuis la machine qui la détient. À faire
au moins une fois maintenant, puis après chaque changement de schéma.

## Ce que le script refuse de faire

Le mode de défaillance classique des sauvegardes est le fichier d'apparence
saine contenant un dump tronqué : `pg_dump` échoue en cours de route, mais
l'outil de chiffrement produit malgré tout un fichier valide. On accumule alors
des sauvegardes inutilisables, et on ne l'apprend que le jour où l'on en a
besoin.

`backup-db.sh` s'arrête en erreur dans ce cas et n'écrit aucun fichier — vérifié
en pointant volontairement vers une base inexistante : zéro fichier produit,
zéro résidu partiel, code de sortie non nul. systemd le voit, et le journal le
signale.

## Ce qui n'est pas couvert

- **Le stockage objet des pièces jointes** (MinIO) n'est pas sauvegardé par ce
  script. Les pièces jointes perdues ne rendent pas les comptes inutilisables,
  mais les messages qui y renvoient afficheront un échec de téléchargement.
- **La restauration ponctuelle** (point-in-time recovery) demanderait
  l'archivage des WAL. Ici la granularité est celle de la dernière sauvegarde
  quotidienne.
