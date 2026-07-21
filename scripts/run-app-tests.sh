#!/usr/bin/env bash
# Suite de tests Flutter, moteur natif COMPRIS.
#
# Pourquoi ce script existe : `flutter test` seul affiche « All tests passed »
# en sautant les 12 cas qui exercent réellement le moteur — ils s'ignorent
# d'eux-mêmes quand ZIA_CRYPTO_LIB est absent. Un vert qui ne prouve rien est
# pire qu'un rouge.
#
# Il faut de plus un Secret Service : sans lui, tout test qui persiste une
# identité échoue en « coffre-fort indisponible ». On en monte un JETABLE, avec
# XDG_DATA_HOME déplacé, pour ne pas écrire de clés de test dans les trousseaux
# réels de l'utilisateur.
#
# Prérequis : gnome-keyring, dbus-x11, et le moteur compilé
#             (cmake --preset linux-system && cmake --build --preset linux-system)
#
# Usage : scripts/run-app-tests.sh [chemins de tests...]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/crypto-engine/build/linux-system/src/libzia_crypto.so"

if [ ! -f "$LIB" ]; then
  echo "moteur introuvable : $LIB"
  echo "compile-le d'abord :"
  echo "  cd crypto-engine && cmake --preset linux-system && cmake --build --preset linux-system"
  exit 1
fi

# Flutter n'est pas toujours sur le PATH des shells non interactifs (crochets,
# tâches planifiées) : on le cherche là où il est habituellement installé
# plutôt que de coder en dur le chemin d'une machine.
if ! command -v flutter >/dev/null 2>&1; then
  for CANDIDAT in "${FLUTTER_ROOT:-}/bin" "$HOME/flutter/bin" /opt/flutter/bin /usr/lib/flutter/bin; do
    if [ -x "$CANDIDAT/flutter" ]; then PATH="$CANDIDAT:$PATH"; break; fi
  done
fi
export PATH
command -v flutter >/dev/null 2>&1 || { echo "flutter introuvable — ajoute-le au PATH ou renseigne FLUTTER_ROOT"; exit 1; }

command -v dbus-run-session >/dev/null || { echo "dbus-run-session manquant — apt install dbus-x11"; exit 1; }
command -v gnome-keyring-daemon >/dev/null || { echo "gnome-keyring-daemon manquant — apt install gnome-keyring"; exit 1; }

export XDG_RUNTIME_DIR="$(mktemp -d)"
export XDG_DATA_HOME="$(mktemp -d)"
export ZIA_CRYPTO_LIB="$LIB"
cd "$ROOT/app"

# Mot de passe vide, comme en CI : le démon s'annonce sur D-Bus, ce qui suffit
# à libsecret — inutile d'exporter GNOME_KEYRING_CONTROL.
exec dbus-run-session -- bash -c \
  'echo "" | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1
   flutter test "$@"' _ "$@"
