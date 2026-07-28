# ZiaCrypte v0.14.3 — les appels se connectent enfin

Correctif de fond sur les appels vocaux : ils restaient bloqués sur « Connexion… » sans jamais aboutir. **Il faut cette version sur les deux appareils** pour que les appels fonctionnent.

## Downloads

| Asset | Platform |
|---|---|
| **`ziacrypte-android.apk`** | Android (arm64, arm32, x86_64) — enable "install from unknown sources" |
| **`ziacrypte-windows-x64-app.zip`** | Windows x64 — unzip, run `ziacrypte.exe` |
| **`ziacrypte-linux-x64.tar.gz`** | Linux x64 — `tar xzf … && cd linux-x64 && ./ziacrypte` |
| **`ziacrypte-macos-app.zip`** | macOS — unzip, right-click `ziacrypte.app` → Open (unsigned) |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine |

Every asset is signed, and the application verifies the signature before installing an update.

## Le correctif

- **L'appelé récupère maintenant ses propres identifiants de relais.** C'était le vrai blocage : seul l'appelant demandait un accès au relais TURN. Comme les appels forcent le passage par le relais (pour masquer les adresses IP), le correspondant qui décroche n'avait **aucun serveur relais** et ne pouvait produire aucun chemin réseau — l'appel restait « en connexion » indéfiniment. Les deux côtés obtiennent désormais leurs identifiants.
- **Repli TCP quand l'UDP est bloqué.** Beaucoup de réseaux (mobiles, entreprises) coupent l'UDP sortant, ce qu'utilise le relais par défaut. L'application tente désormais aussi le relais **en TCP** : elle essaie l'UDP d'abord (meilleure latence), puis retombe sur TCP, qui passe partout. (Réglage côté serveur, déjà en place sur le relais de production.)

## Vérifié

- Le test d'appel à deux clients vérifie désormais que **l'appelant ET l'appelé** obtiennent leurs identifiants de relais — la régression qui bloquait les appels est couverte
- Chemin complet prouvé de bout en bout : sonnerie, acceptation, durée, raccroché, trace, chiffré
- Relais de production vérifié : allocation TURN réussie (`ALLOCATE processed, success`), transport TCP joignable
