# Déplacer les pièces jointes hors du VPS

Objectif : que le VPS ne conserve plus aucun fichier envoyé par les
utilisateurs. C'est le seul poste qui grossit — les enveloppes de messages en
base pèsent quelques centaines de kilo-octets et sont purgées après remise.

## Ce que ça change, et ce que ça ne change pas

L'architecture est déjà celle qu'il faut : le serveur **signe des URL**, et
l'application dépose ou récupère les octets **directement** chez l'hébergeur.
Les fichiers ne transitent donc jamais par l'API. Changer d'hébergeur est une
affaire de configuration, pas de code.

Ce qui reste sur le VPS après la bascule :

| Donnée | Où | Pourquoi elle y reste |
|---|---|---|
| Comptes, appareils, clés **publiques** | PostgreSQL | C'est l'annuaire qui permet d'ouvrir une session |
| Enveloppes de messages chiffrées | PostgreSQL | File d'attente de remise, purgée une fois délivrée |
| Pièces jointes | **plus rien** | déplacées |

Dire « rien sur le VPS » serait donc inexact tant que la base y tourne. Ce
qu'on peut affirmer, en revanche, c'est que **rien de lisible** n'y est stocké :
l'hébergeur du stockage comme le VPS ne détiennent que du chiffré, et aucune
clé privée n'existe côté serveur.

## Cloudflare R2

Retenu pour une raison précise : **pas de frais de sortie**. Une messagerie
télécharge bien plus qu'elle n'envoie — chaque destinataire récupère la pièce
jointe — et c'est le seul poste qui pourrait coûter cher ailleurs. 10 Go
gratuits, API compatible S3.

### Créer le bucket

1. Cloudflare → R2 → *Create bucket*, nom `ziacrypte-attachments`.
2. *Manage R2 API Tokens* → *Create API token*, permission **Object Read &
   Write**, restreint à ce seul bucket.
3. Noter l'*Access Key ID*, la *Secret Access Key* et l'*endpoint*
   `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.

Le bucket doit rester **privé**. L'accès public n'apporterait rien : tout ce
qu'il contient est chiffré et illisible sans les clés, qui ne circulent que
dans les messages de bout en bout. Il ne ferait qu'exposer les tailles et les
horaires.

### Renseigner le serveur

Dans `server/.env` :

```
S3_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com
S3_REGION=auto
S3_BUCKET=ziacrypte-attachments
S3_ACCESS_KEY=<access key id>
S3_SECRET_KEY=<secret access key>
S3_FORCE_PATH_STYLE=true
```

`S3_REGION=auto` est ce qu'attend R2. `S3_FORCE_PATH_STYLE` reste à `true` :
R2 accepte les deux styles d'URL.

### Vérifier AVANT de basculer les utilisateurs

```
node server/scripts/check-storage.mjs
```

Le script dépose un objet aléatoire par URL présignée, le relit, compare octet
à octet, le supprime, et confirme l'effacement. Ce dernier point n'est pas
décoratif : toute la purge de rétention en dépend, et un effacement qui échoue
en silence laisse les pièces jointes s'accumuler indéfiniment.

Puis :

```
sudo systemctl restart ziacrypte-server
```

### Les pièces jointes déjà déposées

Elles restent sur MinIO et deviennent inaccessibles depuis le nouvel hébergeur.
Deux options :

- **Les laisser mourir** : la rétention les supprimera, et les conversations
  concernées afficheront une pièce jointe introuvable. Acceptable pour des
  données de test.
- **Les recopier** avant bascule, avec `rclone` de l'ancien bucket vers le
  nouveau, en conservant les clés d'objet à l'identique — les identifiants en
  base y font référence.

### Une fois la bascule confirmée

MinIO n'a plus lieu d'être sur le VPS :

```
sudo systemctl disable --now minio
sudo rm -rf /var/lib/minio
```

Retirer aussi le vhost `storage.51.83.199.103.nip.io` de nginx : un point
d'entrée qui ne sert plus reste une surface d'attaque.

## Pourquoi pas gofile

Sans API S3, il n'existe pas d'URL de dépôt signée : les octets devraient
transiter par le VPS, exactement ce qu'on cherche à éviter. Les fichiers y sont
publics par lien, et surtout **la purge de rétention ne pourrait plus rien
supprimer** — ce qui est envoyé y resterait.
