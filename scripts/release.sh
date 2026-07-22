#!/usr/bin/env bash
# Publie une release COMPLÈTE en UNE seule saisie de la phrase de passe.
#
# Le problème que ça résout : Windows et macOS ne se compilent que sur des
# machines Windows/macOS — les runners GitHub — donc leurs artefacts n'existent
# qu'APRÈS un passage d'intégration continue. La clé de signature, elle, ne doit
# JAMAIS monter sur un runner public : c'est elle qui décide quel code
# s'installera chez les utilisateurs. Signer imposait donc deux temps — les 3
# artefacts locaux, puis les 2 distants — et donc deux saisies de la phrase.
#
# Ce script inverse l'ordre : il construit les 3 artefacts locaux, DÉCLENCHE la
# CI et ATTEND qu'elle produise Windows et macOS, rapatrie les 5, PUIS les fait
# signer tous d'un coup. La release n'est publiée qu'ensuite, déjà complète —
# jamais à moitié. Une seule phrase de passe, tout à la fin.
#
# Prérequis : gh authentifié ; Flutter + Android SDK + MinGW installés ; la clé
#             de signature dans ~/.ziacrypte-signing/release.key ; le moteur
#             linux-system compilé (pour l'outil de signature).
#
# Usage :
#   1. Monte le numéro dans app/pubspec.yaml, commite, pousse.
#   2. scripts/release.sh
#   La version provient de pubspec.yaml : une seule source de vérité.
#
# Notes de version : par défaut, GitHub les génère. Pour les rédiger, place le
# texte dans un fichier et exporte  ZIA_RELEASE_NOTES=/chemin/notes.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- Flutter et Android SDK sur le PATH, sans coder de chemin en dur ----------
if ! command -v flutter >/dev/null 2>&1; then
  for c in "${FLUTTER_ROOT:-}/bin" "$HOME/flutter/bin" /opt/flutter/bin; do
    [ -x "$c/flutter" ] && { PATH="$c:$PATH"; break; }
  done
fi
command -v flutter >/dev/null 2>&1 || { echo "flutter introuvable — PATH ou FLUTTER_ROOT"; exit 1; }
: "${ANDROID_HOME:=$HOME/android-sdk}"
[ -d "$ANDROID_HOME" ] || { echo "Android SDK introuvable ($ANDROID_HOME) — renseigne ANDROID_HOME"; exit 1; }
export PATH ANDROID_HOME
export ANDROID_SDK_ROOT="$ANDROID_HOME"

VERSION="$(grep -m1 '^version:' app/pubspec.yaml | sed 's/version: *//' | cut -d+ -f1)"
TAG="v$VERSION"
echo ">> Release $TAG"

# --- Garde-fous : rien de pire qu'une release bâtie sur un arbre incohérent ---
[ -z "$(git status --porcelain)" ] || { echo "ERREUR : arbre git non propre — commite d'abord."; exit 1; }
if git rev-parse "$TAG" >/dev/null 2>&1 || gh release view "$TAG" >/dev/null 2>&1; then
  echo "ERREUR : $TAG existe déjà — monte la version dans app/pubspec.yaml."; exit 1
fi
git fetch -q origin
UP="$(git rev-parse '@{u}' 2>/dev/null || echo none)"
[ "$(git rev-parse HEAD)" = "$UP" ] || {
  echo "ERREUR : HEAD diffère de origin — pousse d'abord, la CI construit depuis origin."; exit 1; }

DEFINES=(
  --dart-define=ZIA_SERVER_URL=https://51.83.199.103.nip.io
  --dart-define=ZIA_UPDATE_PUBKEY=ovIl8hVTU9GEtjODO3Pp9HaF5QCXx+jTiZKzM2xVuN4=
)

STAGE="$ROOT/dist/release"
rm -rf "$STAGE"; mkdir -p "$STAGE"

# --- 1-3. Artefacts locaux : Linux, Android, moteur de test Windows ----------
echo ">> [1/5] Moteur de test Windows (MinGW, autonome)"
./crypto-engine/scripts/build-windows-mingw.sh >/dev/null
cp dist/windows-x64/zia_crypto_test.exe "$STAGE/"

echo ">> [2/5] Application Linux"
./scripts/package-linux-app.sh >/dev/null
cp dist/ziacrypte-linux-x64.tar.gz "$STAGE/"

echo ">> [3/5] APK Android"
( cd app && flutter build apk --release "${DEFINES[@]}" >/dev/null )
cp app/build/app/outputs/flutter-apk/app-release.apk "$STAGE/ziacrypte-android.apk"

# --- 4. Windows + macOS : déclenchés sur la CI, puis attendus ----------------
echo ">> [4/5] Windows + macOS via CI (non compilables ici) — déclenchement"
BRANCHE="$(git rev-parse --abbrev-ref HEAD)"
gh workflow run build-apps.yml --ref "$BRANCHE"

# Le run qui vient d'être lancé : le plus récent en workflow_dispatch sur CE
# commit. On boucle car GitHub met quelques secondes à l'enregistrer.
SHA="$(git rev-parse HEAD)"
RUN=""
for _ in $(seq 1 12); do
  sleep 5
  RUN="$(gh run list --workflow=build-apps.yml --event=workflow_dispatch \
         --json databaseId,headSha \
         --jq "[.[] | select(.headSha==\"$SHA\")][0].databaseId" 2>/dev/null || true)"
  [ -n "$RUN" ] && [ "$RUN" != "null" ] && break
done
[ -n "$RUN" ] && [ "$RUN" != "null" ] || { echo "ERREUR : run CI introuvable."; exit 1; }
echo "   run $RUN — attente de la fin (≈8 min)…"
gh run watch "$RUN" --exit-status --interval 20 >/dev/null || {
  echo "ERREUR : la CI a échoué. RIEN n'est publié — corrige puis relance."; exit 1; }

echo "   rapatriement des deux paquets"
gh run download "$RUN" -n ziacrypte-windows-x64-app -D "$STAGE"
gh run download "$RUN" -n ziacrypte-macos-app -D "$STAGE"
# gh dépose chaque artefact dans un sous-dossier à son nom : on remonte les zips
# au niveau du dossier à signer, puis on retire les sous-dossiers vides.
find "$STAGE" -mindepth 2 -name '*-app.zip' -exec mv -f {} "$STAGE/" \;
find "$STAGE" -mindepth 1 -type d -empty -delete

echo "   5 artefacts rassemblés :"
ls -1 "$STAGE"

# --- 5. Signature (UNE phrase) puis publication ------------------------------
echo ">> [5/5] Signature des 5 artefacts — la phrase de passe est demandée UNE fois"
./scripts/sign-artifacts.sh "$STAGE"

echo ">> Publication de $TAG"
git tag "$TAG"
git push -q origin "$TAG"
if [ -n "${ZIA_RELEASE_NOTES:-}" ] && [ -f "${ZIA_RELEASE_NOTES:-}" ]; then
  gh release create "$TAG" --title "ZiaCrypte $TAG" --notes-file "$ZIA_RELEASE_NOTES" "$STAGE"/*
else
  gh release create "$TAG" --title "ZiaCrypte $TAG" --generate-notes "$STAGE"/*
fi
echo ">> Publié et complet : $(gh release view "$TAG" --json url --jq .url)"
