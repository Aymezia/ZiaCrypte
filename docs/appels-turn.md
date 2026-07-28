# Déployer le relais TURN (appels chiffrés)

Les appels vocaux passent par un serveur **TURN** (coturn) : il relaie le flux
audio quand une connexion directe est impossible, et — puisque le relais est
**forcé** côté client — il masque l'adresse IP de chaque correspondant à l'autre.

Le relais **ne peut pas écouter l'appel** : la voix est chiffrée de bout en bout
par WebRTC (DTLS-SRTP). Il voit les adresses IP et qu'un appel a lieu, jamais le
contenu.

Sans TURN déployé, l'application reste utilisable : le bouton d'appel répond
simplement « appels non disponibles ».

---

## 1. Choisir un secret partagé

Un seul secret, connu du serveur ZiaCrypte **et** de coturn. Génère-le :

```bash
openssl rand -hex 32
```

Garde la valeur : elle va dans les deux configurations ci-dessous, à l'identique.

## 2. Ouvrir les ports (pare-feu / groupe de sécurité)

| Port | Protocole | Rôle |
|---|---|---|
| 3478 | UDP + TCP | TURN/STUN |
| 5349 | TCP | TURN sur TLS (turns:) |
| 49160-49200 | UDP | plage de relais du média |

```bash
sudo ufw allow 3478
sudo ufw allow 3478/udp
sudo ufw allow 5349/tcp
sudo ufw allow 49160:49200/udp
```

## 3. Lancer coturn

La configuration durcie est versionnée : [`infra/coturn/turnserver.conf`](../infra/coturn/turnserver.conf)
(refuse tout relais vers les plages privées — un TURN ouvert est sinon un proxy
vers ton réseau interne). Lance le conteneur en lui passant le secret et l'IP
publique du VPS :

```bash
sudo docker run -d --name coturn --restart unless-stopped --network host \
  -v "$PWD/infra/coturn/turnserver.conf:/etc/coturn/turnserver.conf:ro" \
  coturn/coturn:4.6-alpine \
  -c /etc/coturn/turnserver.conf \
  --static-auth-secret="LE_SECRET_DE_L_ETAPE_1" \
  --external-ip="IP_PUBLIQUE_DU_VPS"
```

`--network host` évite d'avoir à mapper la plage de ports relais une à une.
`--external-ip` est indispensable derrière un NAT : sans lui, coturn annonce une
adresse privée injoignable.

> **NAT 1:1 (OVH, Scaleway, la plupart des VPS).** Si `ip addr` montre une
> adresse *privée* (`100.64.0.0/10`, `10.0.0.0/8`, `192.168.0.0/16`) sur
> l'interface, et non l'IP publique, la machine est en NAT 1:1 : le fournisseur
> traduit publique ↔ privée en amont. coturn doit alors connaître **les deux**,
> sous la forme `PUBLIQUE/PRIVÉE`, sinon il alloue ses relais sur l'adresse
> privée et l'annonce telle quelle — l'appel reste bloqué sur « Connexion… » :
>
> ```bash
> --external-ip="51.83.199.103/100.65.78.125"   # publique/privée
> ```
>
> Pour vérifier une allocation réelle sans appareil : `turnutils_uclient -y -u
> <expiry>:<user> -w <credential> <IP_PUBLIQUE>` doit journaliser
> `ALLOCATE processed, success` (logs `journalctl -u coturn` avec `verbose`).

### TLS (recommandé en production)

Pour `turns:` (port 5349), décommente `cert=` / `pkey=` dans `turnserver.conf`
et monte tes certificats (par exemple ceux de Let's Encrypt déjà utilisés par
nginx) dans le conteneur. Le lien TLS protège l'identifiant TURN en transit ;
sans lui, reste sur `turn:` (l'appel est chiffré de toute façon).

## 4. Dire au serveur ZiaCrypte d'utiliser ce TURN

Dans le `.env` du serveur (celui que lit le service systemd) :

```bash
TURN_URLS=turns:appel.tondomaine.fr:5349,turn:appel.tondomaine.fr:3478,turn:appel.tondomaine.fr:3478?transport=tcp
TURN_SHARED_SECRET=LE_SECRET_DE_L_ETAPE_1
# TURN_CREDENTIAL_TTL=3600   # optionnel, durée de vie des identifiants (secondes)
```

`TURN_URLS` liste ce que le client tentera dans l'ordre. Mets l'IP publique ou un
sous-domaine qui pointe dessus.

> **Toujours prévoir un transport TCP.** Beaucoup de réseaux (mobiles,
> entreprises, certains FAI) **bloquent l'UDP sortant** : le relais UDP par
> défaut n'aboutit jamais et l'appel reste sur « Connexion… ». Ajoute donc
> `turn:…:3478?transport=tcp` (et idéalement `turns:…:5349` en TLS) : le client
> essaie l'UDP d'abord — meilleure latence — puis retombe sur TCP. Le TCP passe
> partout où la poignée de main TCP passe. Sans ce repli, un correspondant en
> UDP bloqué ne peut pas appeler du tout.

Puis redémarre :

```bash
sudo systemctl restart ziacrypte-server
```

## 5. Vérifier

Le serveur distribue désormais des identifiants (route authentifiée) :

```bash
# Avec un jeton d'accès valide :
curl -H "Authorization: Bearer <ACCESS_TOKEN>" \
  https://<serveur>/v1/turn-credentials
# → { "ttl": 3600, "iceServers": [ { "urls": [...], "username": "...", "credential": "..." } ] }
```

S'il répond `503`, les variables TURN ne sont pas prises en compte (vérifie le
`.env` et le redémarrage). S'il répond un `iceServers`, l'application peut
appeler : essaie un appel réel entre deux appareils.

---

## Ce que le relais apprend, en clair

- **Oui** : les adresses IP des deux correspondants, et qu'un appel a lieu, quand.
- **Non** : la voix (chiffrée DTLS-SRTP), qui appelle qui au sens du contenu, ou
  quoi que ce soit du reste de l'application.

C'est le compromis assumé d'un canal audio temps réel : moins que ce qu'un
opérateur téléphonique voit, et sans jamais le contenu.
