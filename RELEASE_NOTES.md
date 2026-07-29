# ZiaCrypte v0.14.6 — un message illisible ne bloque plus tout

Correctif : un seul message indéchiffrable (typiquement après qu'un côté a réinstallé) affichait « Erreur cryptographique » et **bloquait la réception de tous les autres**. Plus maintenant.

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

- **Un message qu'on ne peut pas déchiffrer est ignoré, sans bloquer les autres.** Après une réinstallation, le correspondant peut envoyer des messages chiffrés avec l'ancienne session, que la nouvelle installation ne sait plus lire. Jusqu'ici, le premier de ces messages faisait échouer **tout le lot de réception** et affichait une bannière « Erreur cryptographique : ZiaCryptoFailureException » — bloquant l'arrivée des messages **suivants**, pourtant lisibles. Désormais, un message illisible est simplement sauté (comme le sont déjà les messages de groupe indéchiffrables), et la conversation se rétablit d'elle-même dès que le correspondant relance une poignée de main.
- Même protection sur l'acceptation d'une poignée de main invalide ou rejouée.

## Vérifié

- `flutter analyze` propre ; test d'appel à deux clients vert, y compris l'échange d'un message texte (le chemin de déchiffrement normal reste intact)
