# ZiaCrypte v0.14.5 — l'appel sonne sur tous les appareils

Correctif : après une réinstallation, le correspondant ne recevait plus les appels. On sonnait un seul de ses appareils — parfois l'ancien, disparu. **À installer sur les deux appareils.**

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

- **L'appel sonne désormais sur TOUS les appareils du correspondant.** Avant, on n'en sonnait qu'un seul (le premier connu). Après une réinstallation — qui crée une nouvelle identité d'appareil — l'application pouvait garder l'**ancien appareil** (mort) comme premier de la liste : l'invitation partait vers lui, et le téléphone actif du correspondant ne sonnait jamais. Les messages, eux, passaient, car ils sont diffusés à tous les appareils ; les appels, non. C'est corrigé : on sonne partout, **le premier qui décroche prend l'appel**, et les autres appareils cessent de sonner.
- Corollaire : annuler un appel sortant avant réponse fait bien **taire tous** les appareils sonnés.

## Vérifié

- `flutter analyze` propre ; test d'appel à deux clients vert (aucune régression sur le trajet sonnerie → acceptation → raccroché → trace)
- Le trajet multi-appareils est vérifié par revue (comme la couche média, il ne peut s'éprouver qu'entre appareils réels)
