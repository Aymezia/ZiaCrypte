# Données détenues et durées de conservation — ZiaCrypte

> **Modèle de travail, pas un avis juridique.** À faire relire par un juriste
> avant l'ouverture au public. Les passages entre crochets sont à compléter.

Ce document dit ce que le serveur détient **réellement**. Il est écrit en
regardant le schéma de base de données, pas en récitant des intentions.

---

## Le principe : on ne peut livrer que ce qu'on détient

La meilleure protection contre une fuite, une saisie ou une réquisition, c'est
de **ne pas avoir la donnée**. ZiaCrypte est construit là-dessus : le serveur
achemine des blobs qu'il ne peut pas ouvrir.

Ce que le serveur **ne détient à aucun moment** :

- aucune **clé privée** (elles sont générées et gardées sur les appareils) ;
- aucun **message déchiffrable** — même en copiant toute la base, on obtient du
  chiffré sans clé ;
- aucun **carnet d'adresses** importé ;
- aucun **contenu de pièce jointe** lisible (chiffré avant dépôt) ;
- aucun **nom de groupe** (il circule dans le canal chiffré, pas en base).

## Ce que le serveur détient

| Donnée | Pourquoi | Conservation |
|---|---|---|
| Pseudonyme, date de création, rôle | Identifier le compte, l'authentifier | Jusqu'à suppression du compte |
| Empreinte du mot de passe (Argon2id) | Authentification | Jusqu'à suppression du compte |
| Secret de vérification en deux étapes | Second facteur | Tant que la 2FA est active |
| Appareils liés : identifiant, nom, plateforme, **clé publique**, dernière activité | Acheminer vers les bons appareils, détecter un appareil ajouté | Jusqu'à suppression du compte ou révocation |
| Clés **publiques** pré-partagées (prekeys) | Établir une session chiffrée | Jusqu'à consommation ou remplacement |
| Participation aux conversations | Savoir à qui router un message | Jusqu'à suppression |
| **Messages chiffrés** en attente | Remettre le message | Effacés après remise (≈ [24 h]) ou à expiration (≈ [30 j]) |
| Pièces jointes **chiffrées** | Transfert de fichiers | Expiration (≈ [30 j]) ; photos de profil : jusqu'à suppression |
| Blocages | Refuser la remise côté serveur | Jusqu'à déblocage ou suppression |
| **Signalements** (motif, note, copie transmise) | Traiter les abus | [12 mois] après clôture, puis effacement |
| Journal d'administration | Rendre les décisions contestables | **Jamais purgé** |
| Données de connexion (horodatage, empreinte d'adresse IP) | Obligation légale, sécurité | [durée légale applicable] |

### Le cas particulier des signalements

C'est **le seul endroit** où le serveur détient du texte en clair. Il n'y arrive
pas en déchiffrant : c'est le **destinataire** d'un message qui a choisi de nous
en transmettre une copie pour dénoncer un abus. Nous ne recevons que ce message
précis, pas la conversation, pas les autres échanges.

Un signalement n'a **pas** de lien de clé étrangère vers les comptes concernés :
il survit à la suppression du compte visé. Sinon, supprimer un compte effacerait
les preuves qui justifiaient de le supprimer.

## Expéditeur scellé : ce que le serveur cesse de voir

Quand l'expéditeur scellé est actif, le message est déposé **sans
authentification**, au moyen d'un jeton de remise que le destinataire a lui-même
distribué dans le canal chiffré. La ligne enregistrée ne porte alors **ni
l'expéditeur, ni la conversation** — seulement le destinataire et le blob. Le
serveur perd ainsi une grande partie du graphe social qu'il observait.

## Suppression du compte

Efface : le compte, ses appareils, ses sessions, ses clés publiques, ses
blocages, ses pièces jointes de profil, ses messages en attente.

N'efface **pas** : les messages déjà reçus et déchiffrés chez les
correspondants (ils sont sur leurs appareils), ni le journal d'administration,
ni les signalements le concernant.

## Réquisitions judiciaires

Sur demande d'une autorité compétente et régulière, nous ne pouvons fournir que
ce qui figure au tableau ci-dessus — c'est-à-dire des **métadonnées** et, le cas
échéant, les signalements reçus. **Aucun contenu de message ne peut être fourni**,
car aucun n'est lisible par le serveur.

## Sous-traitants

| Rôle | Prestataire | Données concernées |
|---|---|---|
| Hébergement du serveur et de la base | **[hébergeur, pays]** | Toutes celles du tableau |
| Stockage des pièces jointes | **[stockage objet, pays]** | Blobs **chiffrés** uniquement |
| Distribution des mises à jour | GitHub | Aucune donnée d'utilisateur |

## Tes droits

Accès, rectification, effacement, portabilité, opposition : écris à
**[adresse e-mail de contact]**. Nous répondons sous [un mois]. Réserve faite de
ce qui précède : nous ne pouvons pas te restituer des messages, n'en détenant
aucun de lisible.
