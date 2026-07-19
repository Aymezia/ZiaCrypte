#!/usr/bin/env bash
#
# Lance les fuzzers du moteur sur un budget de temps donné.
#
# Un fuzzer n'a pas de fin : il tourne tant qu'on lui en laisse le temps. Ce
# script encapsule les réglages qui, sans eux, donnent l'illusion d'un fuzzing
# qui travaille alors qu'il est figé.
#
# Usage : run-fuzzers.sh [secondes]   (défaut : 60)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUDGET="${1:-60}"
BUILD="$ROOT/build/linux-fuzz"
CORPUS="${ZIA_FUZZ_CORPUS:-$ROOT/build/fuzz-corpus}"

[ -x "$BUILD/tests/zia_fuzz_parsers" ] || {
  echo "Fuzzer absent. Construis-le d'abord :" >&2
  echo "  cmake --preset linux-fuzz && cmake --build build/linux-fuzz" >&2
  exit 2
}

mkdir -p "$CORPUS"

# Graines : artefacts valides produits par le moteur, que le fuzzer déforme.
# Sans elles, il consacre son budget à redécouvrir la structure des entrées et
# reste bloqué sur les contrôles de surface.
if [ -x "$BUILD/tests/zia_fuzz_seed_corpus" ]; then
  "$BUILD/tests/zia_fuzz_seed_corpus" "$CORPUS" >/dev/null 2>&1 || true
fi

# --- Réglages indispensables, chacun pour une raison précise ---
#
# ASAN_SYMBOLIZER_PATH : sans lui, libFuzzer lance llvm-symbolizer pour afficher
#   le nom de chaque fonction nouvellement atteinte et ATTEND un enfant qui ne
#   vient jamais. Le processus se fige à la treizième itération, couverture
#   bloquée à 6, sans le moindre message d'erreur. `-print_funcs=0` supprime le
#   besoin ; le chemin explicite sert aux rapports de plantage, où l'on veut
#   justement des noms.
#
# detect_leaks=0 : LeakSanitizer balaie la mémoire à la sortie et bute sur les
#   pages verrouillées de l'allocateur sécurisé de libsodium. On garde ASan pour
#   ce qui compte ici — débordements et usages après libération sur des octets
#   hostiles — et on renonce à la détection de fuites, hors sujet pour ce test.
SYMBOLIZER="${ASAN_SYMBOLIZER_PATH:-$(command -v llvm-symbolizer || ls /usr/lib/llvm-*/bin/llvm-symbolizer 2>/dev/null | head -1 || true)}"

echo ">> Fuzzing des points d'entrée du moteur — budget ${BUDGET}s"
echo "   corpus : $CORPUS"

# Sortie écrite DIRECTEMENT dans un fichier, sans `tee` ni aucun tube.
#
# libFuzzer se bloquait sur le tube : sa sortie est verbeuse, et il finissait
# figé dans un poll au lieu de respecter son budget de temps. Un fuzzer qui
# dépasse de quinze minutes un budget de deux, sans rien signaler, est pire
# qu'un fuzzer absent : on croit la vérification faite.
set +e
ASAN_SYMBOLIZER_PATH="$SYMBOLIZER" \
ASAN_OPTIONS=detect_leaks=0 \
  "$BUILD/tests/zia_fuzz_parsers" "$CORPUS" \
    -max_total_time="$BUDGET" \
    -print_funcs=0 \
    -print_final_stats=1 > "$BUILD/fuzz.log" 2>&1
CODE=$?
set -e
tail -20 "$BUILD/fuzz.log"

COUVERTURE=$(grep -oE 'cov: [0-9]+' "$BUILD/fuzz.log" | tail -1 || echo 'cov: ?')
echo
echo ">> $COUVERTURE — entrées conservées : $(ls -1 "$CORPUS" 2>/dev/null | wc -l)"

if [ "$CODE" -ne 0 ]; then
  echo "ÉCHEC : le fuzzer s'est arrêté sur une entrée fautive." >&2
  echo "Elle est enregistrée sous crash-*, artefact à conserver pour rejouer." >&2
  exit "$CODE"
fi

# Garde-fou : un fuzzer figé rend 0 sans rien avoir exploré. La couverture
# minimale attendue évite qu'une régression de configuration passe pour un
# succès — c'est exactement ce qui s'est produit pendant la mise au point.
VALEUR=$(echo "$COUVERTURE" | grep -oE '[0-9]+' || echo 0)
SEUIL="${ZIA_FUZZ_MIN_COVERAGE:-100}"
if [ "$VALEUR" -lt "$SEUIL" ]; then
  echo "ÉCHEC : couverture $VALEUR < $SEUIL attendue — le fuzzer n'a rien exploré." >&2
  echo "Symptôme typique d'un blocage silencieux, pas d'un code sans défaut." >&2
  exit 1
fi

echo ">> Aucun défaut trouvé sur ce budget."
