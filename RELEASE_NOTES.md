# ZiaCrypte v0.15.0 — rester connecté + refonte façon Teams

Une grosse mise à jour : plus besoin de retaper son mot de passe à chaque ouverture, une interface repensée avec barre latérale et onglet Appels, et une longue série d'améliorations du fil, des appels et du confort.

## Downloads

| Asset | Platform |
|---|---|
| **`ziacrypte-android.apk`** | Android (arm64, arm32, x86_64) — enable "install from unknown sources" |
| **`ziacrypte-windows-x64-app.zip`** | Windows x64 — unzip, run `ziacrypte.exe` |
| **`ziacrypte-linux-x64.tar.gz`** | Linux x64 — `tar xzf … && cd linux-x64 && ./ziacrypte` |
| **`ziacrypte-macos-app.zip`** | macOS — unzip, right-click `ziacrypte.app` → Open (unsigned) |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine |

Every asset is signed, and the application verifies the signature before installing an update.

## Rester connecté

- **Case « Rester connecté »** à la connexion : l'application **reprend la session à l'ouverture, sans mot de passe**. Le jeton de reprise est gardé dans le coffre chiffré de l'appareil — et comme le mot de passe ne chiffrait déjà pas les clés en local, on ne perd aucune sécurité.
- **Code à l'ouverture** : si un code de verrouillage est posé, il est demandé d'emblée. Interrupteur dans Réglages > Compte pour couper « rester connecté » sans se déconnecter.

## Interface façon Teams

- **Barre latérale d'icônes** (grand écran) : Discussions / Appels, avec ton **avatar et ta pastille de connexion** en pied ; barre d'onglets en bas sur mobile.
- **Onglet Appels** : l'historique des appels (durée, manqués, refusés…), avec rappel en un tap.
- **Épingler des conversations** (appui long) et **filtres** au-dessus de la liste : Tous / Non lus / Groupes / Canaux.
- **Présence riche** : raccourcis 🟢 Disponible / 🟠 Occupé / ⛔ Ne pas déranger / 🌙 Absent, et la **pastille se colore** selon l'état déclaré.

## Fil de discussion

- **Actions au survol** (desktop) : réagir / répondre / plus, sans appui long.
- **« … est en train d'écrire »** directement dans la liste.
- **Ligne « Nouveaux messages »** là où tu t'étais arrêté ; **taper une citation** défile jusqu'au message d'origine et le surligne.
- **Mise en forme légère** : `code`, **gras**, _italique_.
- **Coller une image** (Ctrl/⌘+V) et **glisser-déposer** un fichier pour l'envoyer.

## Appels

- **Sonnerie et vibration** à l'appel entrant.
- **Indicateur de qualité** de liaison (bonne / moyenne / faible) une fois connecté.
- **Réduire l'appel en pastille flottante** pour continuer à naviguer pendant la communication.

## Confort & accessibilité

- **Interface compacte** (Réglages > Apparence) pour resserrer listes et contrôles.
- **Libellés pour lecteurs d'écran** sur la présence et les appels ; la taille de police système est respectée.

## Vérifié

- `flutter analyze` propre ; suite widget/unit verte ; test d'appel à deux clients (sonnerie, acceptation, relais, trace) vert
- Nouvelles dépendances natives pour le coller/glisser (`desktop_drop`, `pasteboard`) : à confirmer au premier build sur chaque plateforme
