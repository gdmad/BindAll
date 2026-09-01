#!/bin/bash
# Compiles and runs the autocomplete evaluator (Tests/eval_autocomplete.swift) against the RU corpus.
# Usage: Tests/eval_autocomplete.sh <variant> [cold|warm] [limit] [bigramSeed] [trigramSeed]
#   variant: baseline | context | semantic
#   bigramSeed / trigramSeed: override the bundled seed files (used to compare variant A's seed
#   against variant B's rich data).
set -euo pipefail
cd "$(dirname "$0")/.."

VARIANT="${1:-baseline}"
WARM="${2:-cold}"
LIMIT="${3:-5}"
BIGRAM="${4:-BindAll/Autocomplete/ru_bigrams_ctx.txt}"
TRIGRAM="${5:-}"

OUT="$(mktemp -d)/EvalAutocomplete"
swiftc -O \
    BindAll/Autocomplete/AutocompleteEngine.swift \
    BindAll/Autocomplete/AutocompleteLearningStore.swift \
    BindAll/Autocomplete/SemanticRanker.swift \
    Tests/eval_autocomplete.swift \
    -o "$OUT"

"$OUT" Tests/ru_eval_corpus.txt "$VARIANT" "$WARM" "$LIMIT" "$BIGRAM" "$TRIGRAM"
