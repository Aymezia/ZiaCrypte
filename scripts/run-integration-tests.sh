#!/usr/bin/env bash
# Test d'intégration à deux clients, contre une instance de serveur DÉDIÉE.
#
# Pourquoi une instance dédiée plutôt que le serveur en service :
#  - il ne faut pas créer des comptes d'essai sur la production ;
#  - les limites de débit de la production (5 inscriptions/heure et par
#    adresse) font échouer le test dès la deuxième exécution — un échec qui ne
#    dit rien du code, et qui apprend à ignorer les échecs.
#
# On démarre donc un serveur sur un autre port, avec des limites relâchées,
# on lance le test, puis on l'arrête. La base est partagée : les comptes créés
# portent un préfixe horodaté et n'entrent en collision avec rien.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${ZIA_TEST_PORT:-3211}"
LIB="$ROOT/crypto-engine/build/linux-system/src/libzia_crypto.so"

[ -f "$LIB" ] || { echo "moteur introuvable : $LIB — compile-le d'abord"; exit 1; }
[ -f "$ROOT/server/dist/index.js" ] || { echo "serveur non compilé — npm run build"; exit 1; }

if ! command -v flutter >/dev/null 2>&1; then
  for c in "${FLUTTER_ROOT:-}/bin" "$HOME/flutter/bin" /opt/flutter/bin; do
    [ -x "$c/flutter" ] && { PATH="$c:$PATH"; break; }
  done
fi
export PATH

# Port déjà pris : on s'arrête ici.
#
# Sans ce contrôle, le nôtre échoue à se lier, l'attente de démarrage réussit
# quand même — l'autre répond exactement pareil — et le test s'exécute contre
# un serveur ÉTRANGER, souvent une version antérieure. On cherche alors une
# panne dans du code qui n'a pas tourné. C'est arrivé.
if ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]"; then
  echo "port $PORT déjà utilisé — arrête le serveur d'essai resté ouvert"
  echo "(ss -ltnp | grep :$PORT pour le retrouver)"
  exit 1
fi

echo ">> Démarrage d'un serveur d'essai sur le port $PORT"
(
  cd "$ROOT/server"
  # exec : le sous-shell DEVIENT node, donc $! est bien le serveur. Sans cela,
  # le piège de sortie ne tuait que le sous-shell et laissait node orphelin,
  # tenant le port jusqu'au prochain lancement.
  PORT="$PORT" \
  RATE_LIMIT_GLOBAL_MAX=100000 \
  RATE_LIMIT_REGISTER_MAX=100000 \
  RATE_LIMIT_PASSWORD_MAX=100000 \
  RATE_LIMIT_MESSAGE_MAX=100000 \
  exec node dist/index.js
) >/tmp/zia-test-server.log 2>&1 &
SERVEUR=$!
trap 'kill $SERVEUR 2>/dev/null' EXIT

for _ in $(seq 1 40); do
  sleep 0.5
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/v1/reports" \
          -H 'content-type: application/json' -d '{}' 2>/dev/null || true)
  [ "$code" = "401" ] && break
done
if ! kill -0 "$SERVEUR" 2>/dev/null; then
  echo "le serveur d'essai s'est arrêté — voir /tmp/zia-test-server.log"
  tail -20 /tmp/zia-test-server.log
  exit 1
fi
if [ "${code:-}" != "401" ]; then
  echo "le serveur d'essai n'a pas démarré — voir /tmp/zia-test-server.log"
  tail -20 /tmp/zia-test-server.log
  exit 1
fi
echo "   prêt"

export XDG_RUNTIME_DIR="$(mktemp -d)"
export XDG_DATA_HOME="$(mktemp -d)"
export ZIA_CRYPTO_LIB="$LIB"
cd "$ROOT/app"
# Surtout PAS `exec` ici : il remplacerait ce shell, le piège de sortie ne
# s'exécuterait jamais, et le serveur d'essai survivrait à chaque lancement —
# tenant le port et faisant tester la fois suivante contre la version d'avant.
dbus-run-session -- bash -c \
  'echo "" | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1
   flutter test --dart-define=ZIA_TEST_SERVER=http://127.0.0.1:'"$PORT"' \
     test/groupe_integration_test.dart test/statuts_integration_test.dart'
CODE=$?
kill "$SERVEUR" 2>/dev/null
exit $CODE
