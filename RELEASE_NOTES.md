# ZiaCrypte v0.14.2 — les appels laissent une trace

Petit palier de finition sur les appels vocaux : on voit enfin **combien de temps** dure un appel, et chaque appel **laisse une ligne dans la conversation** — durée, manqué, refusé, annulé.

## Downloads

| Asset | Platform |
|---|---|
| **`ziacrypte-android.apk`** | Android (arm64, arm32, x86_64) — enable "install from unknown sources" |
| **`ziacrypte-windows-x64-app.zip`** | Windows x64 — unzip, run `ziacrypte.exe` |
| **`ziacrypte-linux-x64.tar.gz`** | Linux x64 — `tar xzf … && cd linux-x64 && ./ziacrypte` |
| **`ziacrypte-macos-app.zip`** | macOS — unzip, right-click `ziacrypte.app` → Open (unsigned) |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine |

Every asset is signed, and the application verifies the signature before installing an update.

## Nouveautés

- **Minuteur d'appel.** Une fois en communication, l'écran d'appel affiche la durée qui défile (`0:07`, `1:42`…) au lieu d'un simple « En communication ».
- **Historique dans le fil.** À la fin d'un appel, une ligne discrète s'inscrit dans la conversation :
  - **`Appel · 2:34`** quand il a abouti (durée),
  - **`Appel manqué`** si on n'a pas décroché,
  - **`Appel refusé`** si l'un des deux a refusé,
  - **`Appel annulé`** si l'appelant a raccroché avant la réponse.

  Chaque côté note ce qu'il a vécu — rien n'est synchronisé ni envoyé au serveur.

## Côté serveur / relais

- Le guide de déploiement TURN gagne une note sur le **NAT 1:1** (OVH, Scaleway…) : coturn doit recevoir `--external-ip=PUBLIQUE/PRIVÉE`, sinon il annonce une adresse privée injoignable et l'appel reste bloqué sur « Connexion… ». C'est précisément le réglage appliqué au relais de production.

## Verified by actually running it

- Flutter suite verte ; le test d'appel à deux clients vérifie désormais aussi que **la trace d'appel apparaît des deux côtés**, chiffrée, entre l'appelant et l'appelé
- Chemin complet prouvé de bout en bout : sonnerie, acceptation, durée, raccroché, trace
