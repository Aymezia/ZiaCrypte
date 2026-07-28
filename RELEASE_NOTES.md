# ZiaCrypte v0.14.4 — un appel qui ne se connecte pas le dit

Fiabilité des appels : plus de « Connexion… » sans fin, une détection de connexion plus robuste, et une trace honnête quand un appel échoue.

## Downloads

| Asset | Platform |
|---|---|
| **`ziacrypte-android.apk`** | Android (arm64, arm32, x86_64) — enable "install from unknown sources" |
| **`ziacrypte-windows-x64-app.zip`** | Windows x64 — unzip, run `ziacrypte.exe` |
| **`ziacrypte-linux-x64.tar.gz`** | Linux x64 — `tar xzf … && cd linux-x64 && ./ziacrypte` |
| **`ziacrypte-macos-app.zip`** | macOS — unzip, right-click `ziacrypte.app` → Open (unsigned) |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine |

Every asset is signed, and the application verifies the signature before installing an update.

## Fiabilité des appels

- **Fini le « Connexion… » infini.** Si le média ne s'établit pas dans les 40 secondes après l'acceptation, l'appel s'arrête proprement avec une explication (« le média ne s'est pas établi — réseau, relais TURN ? ») au lieu de rester bloqué pour toujours. Le correspondant est prévenu.
- **Détection de connexion plus fiable.** L'écran passe à « En communication » dès que la connexion ICE aboutit, et pas seulement sur l'état agrégé — ce dernier n'étant pas rapporté partout de la même façon. Le minuteur démarre donc au bon moment.
- **Trace d'appel honnête.** Un appel accepté mais dont le média n'a jamais abouti s'inscrit désormais « **Appel échoué** » dans le fil, distinct de « Appel · durée » (abouti), « Appel manqué », « Appel refusé » et « Appel annulé ».

## Vérifié

- `flutter analyze` propre ; test d'appel à deux clients vert (appelant et appelé obtiennent leur relais ; trace inscrite des deux côtés)
- Côté relais de production : la cause racine des appels bloqués a été corrigée séparément (coturn allouait ses relais sur la mauvaise interface — perte de 100 % des paquets ; désormais 0 %)
