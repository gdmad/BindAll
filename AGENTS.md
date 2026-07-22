# BindAll — AGENTS.md

macOS menu-bar utility that acts on the current selection via global hotkeys: AI text correction /
custom prompts, on-device translation, and screen-region OCR translation.

## Stack
- **Swift 6 + SwiftUI + AppKit**, target **macOS 26**
- Hand-authored Xcode project (`BindAll.xcodeproj`, file-system-synchronized group — new source files
  are picked up automatically, no need to edit `project.pbxproj`)
- Frameworks: `FoundationModels` (on-device LLM), `Translation` + `NaturalLanguage` (translation),
  `Vision` (OCR), `ServiceManagement` (launch at login), `Security` (Keychain)
- Menu-bar agent: `LSUIElement = true` (no Dock icon)
- Bundle id: `com.evgeny.bindall`

## Structure

```
BindAll/
├── App/
│   ├── BindAllApp.swift        # @main; placeholder SwiftUI Settings scene — UI is AppKit-driven
│   ├── AppDelegate.swift       # NSStatusItem menu (actions + shortcuts), settings window, icon, login
│   └── AppState.swift          # ObservableObject: settings persistence, Keychain keys, isProcessing
├── Hotkeys/
│   ├── HotkeyMonitor.swift     # CGEventTap; detects N presses of key+modifiers within a time window
│   ├── HotkeyCoordinator.swift # Orchestrates hotkey → selection → engine / translation / OCR
│   └── AccessibilityPermission.swift
├── Selection/
│   ├── SelectionReader.swift   # Reads selection from the pasteboard (AX attribute fallback)
│   └── TextInjector.swift      # Sets pasteboard + synthesizes Cmd+V; copy helper
├── Engines/
│   ├── AIEngine.swift          # protocol + EngineError
│   ├── AppleFoundationEngine.swift   # FoundationModels on-device LLM (temperature 0)
│   ├── OpenAICompatibleEngine.swift  # DeepSeek / OpenRouter / OpenAI / Ollama (one client)
│   ├── LanguageToolEngine.swift      # LanguageTool client: correct() applies all fixes;
│   │                                 # check()/parseMatches()/issues() feed Proofread
│   ├── TranslationService.swift      # Apple Translation framework + NL language detection
│   └── OCRService.swift        # screencapture region + Vision text recognition
├── Autocomplete/               # word completion while typing (off by default)
│   ├── AutocompleteEngine.swift       # NSSpellChecker completions/guesses + recasing + partial-word
│   ├── AutocompleteController.swift   # two CGEventTaps on own thread (listen-only monitor + active suppressor); AX/keystroke word; suggestions, next-word, accept
│   ├── AutocompleteLearningStore.swift# learned counts + bi/trigrams; next-word backoff + RU seed (thread-safe)
│   ├── ru_bigrams.txt                 # bundled Russian bigram seed (Google Books, CC BY 3.0)
│   └── AutocompleteOverlay.swift      # non-activating floating list shown near the caret
├── Proofread/                  # step through LanguageTool's findings one at a time
│   ├── TextIssue.swift                # shared issue model (UTF-16 ranges, stable ids)
│   ├── IssueMerger.swift              # merge/shift/relocate/firstIssue -- pure range algebra
│   ├── ProofreadCache.swift           # paragraph segmentation + per-paragraph issue cache
│   ├── ProofreadLanguage.swift        # language resolution; ru/uk disambiguation for "auto"
│   ├── LanguageToolProofreadProvider.swift # actor: paragraph-scoped checks + cache
│   ├── ProofreadAX.swift              # focused field text/selection, word bounds, in-place select
│   ├── IssueApplier.swift             # validated single fix: AX write, else select+paste
│   ├── WordBoundary.swift             # word range under the caret (click-to-proofread trigger)
│   └── ProofreadController.swift      # session, key tap (only while the popup is up), click popup
├── Actions/
│   ├── PromptParser.swift      # separator split + action-key resolution
│   ├── ActionRouter.swift      # EngineFactory (builds an AIEngine from settings)
│   └── MaskAISlop.swift        # typography normalizer (dashes/quotes/emoji)
├── UI/
│   ├── SettingsView.swift      # tabs: General, Actions, Providers, Autocomplete, Proofread (Translation and Shortcuts live inside General/Actions)
│   ├── AutocompleteSettingsView.swift  # autocomplete tab (count, layout, language, learning, per-app)
│   ├── ActionKeysSettingsView.swift
│   ├── ProvidersSettingsView.swift
│   ├── HistoryPanelView.swift  # History list shown as a popover from the menu bar (click = copy)
│   └── PopupController.swift   # floating NSPanel for translation/results (Copy/Close)
└── Store/
    ├── Settings.swift          # Codable settings, ProviderKind, HotkeyConfig
    ├── ActionKey.swift         # {key, label, prompt, hotkey?}; built-in w / u / l / о / гг
    ├── KeychainStore.swift     # API keys (generic password)
    └── LoginItemManager.swift  # SMAppService launch-at-login
Tests/
├── main.swift                  # PromptParser + MaskAISlop assertions (no XCTest host needed)
└── run_tests.sh
Info.plist                      # LSUIElement, version (source of truth for version)
```

## Triggers (defaults, all configurable in Settings → Actions → Shortcuts)
- **Cmd+C ×2** → default action: fix spelling/grammar, or run a custom prompt (separator / action key)
- **Cmd+C ×3** → translate the selection, shown in a popup near the cursor
- **Cmd+E** → OCR: select a screen region, recognize text, translate
- **Shift+Cmd+E** → Quick Translate window
- **Shift+Cmd+C** → **Proofread** (LanguageTool), only when enabled in Settings → General. Checks the
  whole focused field (read over AX; nothing needs to be selected), selects the first problem **in the
  field itself** and shows the fixes under it: arrows or mouse hover choose, Return or a click
  applies, Tab skips, Esc exits. The number of fixes listed per issue is a setting (1-10, default 3).
  A single click inside a problem word (or double-clicking one) also pops the fixes up on its own,
  with no shortcut.
- Each `ActionKey` may have its own recorded shortcut that runs its prompt on the selection directly.
- **Esc** cancels an in-flight action.
- **Word autocomplete** (off by default; enable on General, configure on the Autocomplete
  tab): as you type, a list of case-matched completions appears near the caret; arrow keys choose,
  **Tab** (and optionally Return) inserts; any other key, a click anywhere, or leaving the app
  dismisses it. It can predict the next word after a space and learn the words you use (local
  `AutocompleteLearningStore`): a word is learned when a space or punctuation closes it, and when a
  suggestion is accepted. Return deliberately does not learn (it submits password fields).
  Configurable: count, column/line layout, text
  size, dictionary language, and per-app allow/deny. Uses AX text+caret where available, otherwise a
  keystroke buffer (works in most apps). Skipped in password fields and BindAll's own windows.
  Its tap is an active tap (it consumes Tab/arrows while suggesting), so it runs on a **dedicated
  run-loop thread** and the callback only makes a cheap lock-protected suppression decision; all AX
  and NSSpellChecker work happens on a background queue. Do not move the tap back to the main run
  loop or do AX/spell-checker work in the callback -- that reintroduces per-keystroke input lag.

Because the Cmd+C triggers are the real copy shortcut, the selection is already on the pasteboard when
a burst fires; the event tap is **listen-only** and does not consume the keystroke. Per-action-key
shortcuts and Correct are not copy shortcuts, so they synthesize Cmd+C first
(`SelectionReader.copyCurrentSelection`). A burst fires immediately once the highest configured press
count for that key is reached (only counts with a larger sibling wait out the time window).

## Engines
- **Engine for text actions** (`Settings → General`): Apple on-device, DeepSeek, OpenRouter, OpenAI,
  or Ollama. Cloud providers share one OpenAI-compatible client (`/chat/completions`).
- **Translation is always on-device** via Apple's `Translation` framework, regardless of the chosen
  engine. It uses a two-language pair (primary/secondary) and translates into whichever the source is
  not; the source is auto-detected with `NaturalLanguage`.
- **Proofread (LanguageTool)** is a separate, optional action (not in the engine dropdown), enabled on
  General. LanguageTool is the only issue source: it is the one engine with real Russian grammar, and
  it reads the sentence, so it finds agreement and punctuation rather than just unknown words.
  (`NSSpellChecker` was tried as an offline layer and dropped -- its Russian guesses are poor: for
  "Прувет" it offers "Прусте"/"Пруте", never "Привет". Harper is English-only and Apple's
  FoundationModels does not support Russian at all, so neither is an option here.) The same settings
  drive it and the legacy `correct()` path. Text is sent one paragraph at a time and cached by
  paragraph text, so editing one sentence costs one request and re-checking costs none.
  The connection is configured under Providers via an explicit **connection mode**
  (`LanguageToolMode`): **Free public** (`api.languagetool.org`, no credentials -- the public server
  rejects them with HTTP 400), **Premium** (`api.languagetoolplus.com`, a different host, requires
  username + token), or **Self-hosted** (your own URL, optional credentials).
  `Settings.languageToolConnection(token:)` resolves the real endpoint and only puts credentials on
  the wire where they belong; `LanguageToolEngine.authParams` is a final guard that never sends a
  lone username or apiKey. The Premium token lives in the Keychain. The URL is pre-filled per mode
  but stays editable; there is no settings migration (mode defaults to Free).
- **Writing results back:** the frontmost app is captured when an action starts; the result is pasted
  with Cmd+V (reliable across native and Electron/Chromium apps). If focus moved to another app while
  the engine worked, the original app is re-activated first so the result lands where it started.

## Build & test

```bash
xcodebuild -scheme BindAll -configuration Debug build      # build
./Tests/run_tests.sh                                       # pure-logic unit tests
```

For a signing-free local build (CI / no certificate): append `CODE_SIGNING_ALLOWED=NO`.
Open `BindAll.xcodeproj` in Xcode and Run to launch the app (set the signing Team first).

## Permissions
- **Accessibility** — required for the event tap and the synthetic Cmd+V. The coordinator polls and
  starts the tap automatically once granted (no relaunch needed).
- **Apple Intelligence** — must be enabled for the on-device engine (`AppleFoundationEngine`).
- **Translation language packs** — may download on first use.

## Key Guarantees
- Menu-bar agent (`LSUIElement`); no Dock icon. The settings window temporarily switches the activation
  policy to `.regular` so it can come to the front, then back to `.accessory` on close.
- API keys live in the **Keychain**, never in `UserDefaults`.
- Hotkey bursts are debounced by a time window; a busy watchdog (25s) guarantees a stalled operation
  can never permanently block future hotkeys.
- Settings are a single Codable struct persisted to `UserDefaults` and merged with defaults on read.

## AI Instructions

Rules for AI assistants working on this project. **No emojis** in code, comments, docs, or commit
messages. All code, comments, docs, UI strings, and commit messages are in **English**.

### Audit AGENTS.md before changes
Before modifying source, review this file and update it if the change introduces new conventions,
shifts architecture, or deprecates documented behavior. This file is the single source of truth — keep
it in sync with the code.

### Build must stay green
After any code change, the project must compile: `xcodebuild -scheme BindAll build CODE_SIGNING_ALLOWED=NO`.
If logic in `Actions/` or `Engines/` changes, run `./Tests/run_tests.sh` and extend the tests.

### Git hygiene
Commit before starting new work. If the tree has uncommitted changes, checkpoint them first
(`"WIP: checkpoint before <task>"`). Keep each logical change in its own commit.

### Version bump
Before committing a code change, increment the version in `Info.plist`
(`CFBundleShortVersionString`, semver) and bump `CFBundleVersion`.
