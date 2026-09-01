#!/bin/bash
# Compiles the pure-logic sources together with the test runner and executes them.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)/LogicTests"
swiftc -O \
    BindAll/Store/ActionKey.swift \
    BindAll/Store/Settings.swift \
    BindAll/Actions/PromptParser.swift \
    BindAll/Actions/MaskAISlop.swift \
    BindAll/Store/HistoryStore.swift \
    BindAll/Engines/AIEngine.swift \
    BindAll/Proofread/TextIssue.swift \
    BindAll/Proofread/WordBoundary.swift \
    BindAll/Proofread/UnderlineGeometry.swift \
    BindAll/Proofread/IssueMerger.swift \
    BindAll/Proofread/ProofreadCache.swift \
    BindAll/Proofread/ProofreadLanguage.swift \
    BindAll/Proofread/RecheckPolicy.swift \
    BindAll/UI/PopupTilePacker.swift \
    BindAll/Engines/LanguageToolEngine.swift \
    BindAll/Autocomplete/AutocompleteEngine.swift \
    BindAll/Autocomplete/AutocompleteLearningStore.swift \
    BindAll/Autocomplete/LearnedWordAudit.swift \
    Tests/main.swift \
    -o "$OUT"

"$OUT"
