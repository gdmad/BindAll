# BindAll

A minimal macOS menu-bar utility that acts on the currently selected text with global shortcuts —
fix grammar, run custom prompts, translate, and OCR-translate from the screen. On-device by default
(Apple Intelligence + Apple Translation), with optional cloud providers.

No Dock icon: BindAll lives in the menu bar (`LSUIElement`).

## Features

- **Fix / transform text** — select text, press the shortcut, and the corrected result replaces it in
  place. Uses the Apple on-device model by default, or a cloud provider.
- **Action keys** — short suffixes after a separator (default `--`) run a saved instruction, e.g.
  `Ghbdtn rfr ltkf -- w`. A free-form instruction also works: `Hello -- translate to Chinese`.
  Built-in keys: `w` (fix keyboard layout), `u` (UPPERCASE), `l` (lowercase), `о` (formal tone),
  `гг` (polite request). Each key can also get **its own global shortcut**.
- **Translate** — on-device translation (Apple Translation) into your target language with source
  auto-detection, shown in a popup near the cursor with the original text and Copy.
- **Quick Translate** — a window to type text and translate it on the fly, with a Source/Target
  language pair and swap.
- **OCR translate** — drag-select a screen region; text is recognized (Vision) and translated.
- **Providers** — Apple on-device (default), DeepSeek, OpenRouter, OpenAI, Ollama. Add an API key,
  pick a model, Test connection. OpenRouter has a "free models only" filter.
- **History** — the last results are kept locally and reachable from the menu bar (click to copy).
- **Mask AI Slop** — optional: normalize em/en dashes, smart quotes/apostrophes, strip emoji.
- **Launch at login**, automatic light/dark, and in-app **Check for Updates**.

## Default shortcuts

All shortcuts are configurable in Settings → Shortcuts.

| Shortcut | Action |
|---|---|
| `Cmd+C` ×2 | Fix / run the default action on the selection |
| `Cmd+C` ×3 | Translate the selection (popup) |
| `Cmd+E` | OCR: select a screen region and translate it |
| `Shift+Cmd+E` | Open Quick Translate |

Because `Cmd+C` is the real copy shortcut, pressing it the configured number of times both copies the
selection and triggers BindAll. Per-action-key shortcuts (any combo you record) copy the selection
themselves, so no separator is needed.

## Install

Download the latest `BindAll-<version>.dmg` from [Releases](https://github.com/gdmad/BindAll/releases),
open it, and drag **BindAll** into **Applications**.

The build is **not notarized** (no paid Apple Developer account), so macOS blocks it on first launch.
Open **System Settings → Privacy & Security**, scroll to the bottom, and click **Open Anyway** next to
BindAll. You only do this once.

## Permissions

1. **Accessibility** — required to detect the shortcut key taps and to paste results back. On first
   launch BindAll asks for it; grant it in *System Settings → Privacy & Security → Accessibility*.
   The tap starts automatically once granted (no relaunch needed).
2. **Apple Intelligence** — needed only for the on-device text engine. Enable it in System Settings;
   the General tab shows live status. Cloud providers work without it.
3. **Translation language packs** may download once on first use.

## Privacy

- API keys are stored in the **Keychain**, never in plain settings or the repo.
- The default engine and translation run **on device**. Cloud providers are used only if you select
  one and add a key.
- History is stored locally in `~/Library/Application Support/BindAll/` and never includes API keys;
  it can be turned off and cleared.

## Build from source

Requirements: **macOS 26**, **Xcode 26**.

```sh
open BindAll.xcodeproj
```

In Xcode, select the **BindAll** target → *Signing & Capabilities* → set **your** Team (a stable
signature keeps the Accessibility grant across rebuilds). Then Run. From the CLI without signing:

```sh
xcodebuild -scheme BindAll build CODE_SIGNING_ALLOWED=NO
```

Build a distributable `.dmg`:

```sh
./scripts/release.sh             # local-signed dmg in .release/
./scripts/release.sh --notarize  # Developer ID + notarization (paid account required)
```

## Tests

Pure-logic unit tests (no Xcode host needed):

```sh
./Tests/run_tests.sh
```

## Architecture

```
BindAll/
  App/        BindAllApp, AppDelegate (menu bar + windows), AppState, UpdateChecker
  Hotkeys/    HotkeyMonitor (CGEventTap), HotkeyCoordinator, AccessibilityPermission
  Selection/  SelectionReader, TextInjector (synthetic Cmd+C / Cmd+V)
  Engines/    AIEngine, AppleFoundationEngine, OpenAICompatibleEngine, TranslationService, OCRService
  Actions/    PromptParser, ActionRouter (EngineFactory), MaskAISlop
  UI/         SettingsView, ProvidersSettingsView, ActionKeysSettingsView, ShortcutRecorder,
              PopupController, QuickTranslateController
  Store/      Settings, ActionKey, KeychainStore, HistoryStore, LoginItemManager, AppLanguages
Tests/        main.swift, run_tests.sh
```

The visible UI (status item, settings window, popups) is driven from `AppDelegate` with AppKit; the
SwiftUI `App` only hosts the settings views. See [AGENTS.md](AGENTS.md) for contributor conventions.

## License

[MIT](LICENSE) © Evgeny Mishenko
