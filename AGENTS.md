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
│   ├── LanguageToolEngine.swift      # LanguageTool grammar/spell correction (the "Correct" action)
│   ├── TranslationService.swift      # Apple Translation framework + NL language detection
│   └── OCRService.swift        # screencapture region + Vision text recognition
├── Autocomplete/               # experimental: word completion while typing (off by default)
│   ├── AutocompleteEngine.swift     # NSSpellChecker completion + pure partial-word helper
│   ├── AutocompleteController.swift # CGEventTap + AX read; shows / accepts (Tab) the suggestion
│   └── AutocompleteOverlay.swift    # non-activating floating chip shown near the caret
├── Actions/
│   ├── PromptParser.swift      # separator split + action-key resolution
│   ├── ActionRouter.swift      # EngineFactory (builds an AIEngine from settings)
│   └── MaskAISlop.swift        # typography normalizer (dashes/quotes/emoji)
├── UI/
│   ├── SettingsView.swift      # tabs: General, Actions, Providers, Translation, Hotkeys
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

## Triggers (defaults, all configurable in Settings → Shortcuts)
- **Cmd+C ×2** → default action: fix spelling/grammar, or run a custom prompt (separator / action key)
- **Cmd+C ×3** → translate the selection, shown in a popup near the cursor
- **Cmd+E** → OCR: select a screen region, recognize text, translate
- **Shift+Cmd+E** → Quick Translate window
- **Shift+Cmd+C** → Correct (LanguageTool), only when enabled in Settings → General.
- Each `ActionKey` may have its own recorded shortcut that runs its prompt on the selection directly.
- **Esc** cancels an in-flight action.
- **Word autocomplete** (experimental, off by default; Settings -> General): as you type, a short list
  of case-matched completions appears near the caret; the **arrow keys** choose and **Tab** inserts.
  Count and layout (column = Up/Down, line = Left/Right) are configurable. Uses AX text+caret where
  available, otherwise a keystroke buffer (works in most apps; chip position is best in native fields).
  Skipped in password fields.

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
- **Correct (LanguageTool)** is a separate, optional action (not in the engine dropdown). It sends the
  selection to a LanguageTool server (public, self-hosted, or Premium) and applies the suggested fixes.
  Configured under Providers; the Premium token lives in the Keychain.
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
