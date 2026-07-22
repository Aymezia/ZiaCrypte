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

echo ">> Démarrage d'un serveur d'essai sur le port $PORT"
(
  cd "$ROOT/server"
  PORT="$PORT" \
  RATE_LIMIT_GLOBAL_MAX=100000 \
  RATE_LIMIT_REGISTER_MAX=100000 \
  RATE_LIMIT_PASSWORD_MAX=100000 \
  RATE_LIMIT_MESSAGE_MAX=100000 \
  node dist/index.js
) >/tmp/zia-test-server.log 2>&1 &
SERVEUR=$!
trap 'kill $SERVEUR 2>/dev/null' EXIT

for _ in $(seq 1 40); do
  sleep 0.5
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/v1/reports" \
          -H 'content-type: application/json' -d '{}' 2>/dev/null || true)
  [ "$code" = "401" ] && break
done
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
exec dbus-run-session -- bash -c \
  'echo "" | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1
   flutter test --dart-define=ZIA_TEST_SERVER=http://127.0.0.1:'"$PORT"' \
     test/groupe_integration_test.dart'
