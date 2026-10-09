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
│   └── AppState.swift          # @Observable: settings persistence, Keychain keys (keychainRevision), isProcessing;
│                               # views read it via @Environment(AppState.self), AppKit code via Observations { }
├── Hotkeys/
│   ├── HotkeyMonitor.swift     # CGEventTap; detects N presses of key+modifiers within a time window
│   ├── HotkeyCoordinator.swift # Orchestrates hotkey → selection → engine / translation / OCR
│   └── AccessibilityPermission.swift
├── Selection/
│   ├── SelectionReader.swift   # Reads selection from the pasteboard (AX attribute fallback)
│   ├── TextInjector.swift      # Sets pasteboard + synthesizes Cmd+V; copy helper
│   └── InjectedEvents.swift    # Marks/detects BindAll's own synthetic keys, so proofread/autocomplete ignore each other's writes
├── Engines/
│   ├── AIEngine.swift          # protocol + EngineError
│   ├── AppleFoundationEngine.swift   # FoundationModels on-device LLM (temperature 0)
│   ├── OpenAICompatibleEngine.swift  # DeepSeek / OpenRouter / OpenAI / Ollama (one client)
│   ├── LanguageToolEngine.swift      # LanguageTool client: correct() applies all fixes;
│   │                                 # check()/parseMatches()/issues() feed Proofread
│   ├── TranslationService.swift      # Apple Translation framework + NL language detection
│   ├── TranslationLayout.swift # pure: puts the source's line breaks back into a translation
│   ├── OCRParagraphs.swift     # pure: joins wrapped OCR lines back into paragraphs
│   └── OCRService.swift        # screencapture region + Vision text recognition
├── Autocomplete/               # word completion while typing (off by default)
│   ├── AutocompleteEngine.swift       # NSSpellChecker completions/guesses + recasing + partial-word; Mode (baseline/context/semantic) + scorer re-ranking
│   ├── AutocompleteController.swift   # two CGEventTaps on own thread (listen-only monitor + active suppressor); AX/keystroke word; suggestions, next-word, accept
│   ├── AutocompleteLearningStore.swift# learned counts + bi/trigrams; next-word backoff + RU seed; contextScore() ranks completions by preceding words (thread-safe)
│   ├── LearnedWordAudit.swift         # pure: which learned words look like typos (dictionary check comes in as a closure)
│   ├── AutocompleteInsertion.swift    # pure: append the suggestion's remainder vs. delete-and-retype (never passes through an empty field)
│   ├── SemanticRanker.swift           # experimental: NLContextualEmbedding (Cyrillic) cosine re-ranking, debug-only
│   ├── ru_bigrams_ctx.txt             # RU bigram seed (Leipzig news, CC BY 4.0) -- feeds both next-word and completion ranking
│   ├── ru_trigrams.txt                # RU trigram seed (Leipzig news, CC BY 4.0) for completion ranking
│   └── AutocompleteOverlay.swift      # non-activating floating list shown near the caret (PopupKit)
├── Proofread/                  # step through LanguageTool's findings one at a time
│   ├── TextIssue.swift                # shared issue model (UTF-16 ranges, stable ids)
│   ├── IssueMerger.swift              # merge/shift/context-checked relocate/firstIssue -- pure range algebra
│   ├── ProofreadCache.swift           # paragraph segmentation + per-paragraph issue cache
│   ├── HiddenBreaks.swift             # pure: block breaks Chromium leaves out of AXValue (check text + map back)
│   ├── ProofreadLanguage.swift        # language resolution; ru/uk disambiguation for "auto"
│   ├── LanguageToolProofreadProvider.swift # actor: paragraph-scoped checks + cache
│   ├── ProofreadAX.swift              # focused field text/selection, word bounds, in-place select
│   ├── IssueApplier.swift             # validated single fix: AX write, else verified select+paste
│   ├── WordBoundary.swift             # word range under the caret (click-to-proofread trigger)
│   ├── UnderlineGeometry.swift        # pure geometry: rect flip, underline drop/thickness, line check
│   ├── IssueKindStyle.swift           # one source of truth for issue-kind color and symbol
│   ├── RecheckPolicy.swift            # pure: whether the post-write pass re-checks (defers to a click's check)
│   ├── ProofreadClickPolicy.swift     # pure: what a click does (probe a word / dismiss / ignore a selection)
│   ├── UnderlineOverlay.swift         # click-through panel with a straight underline under every found issue
│   └── ProofreadController.swift      # session, key tap (only while the popup is up), click popup
├── Actions/
│   ├── PromptParser.swift      # separator split + action-key resolution
│   ├── ActionRouter.swift      # EngineFactory (builds an AIEngine from settings)
│   └── MaskAISlop.swift        # typography normalizer (dashes/quotes/emoji)
├── UI/
│   ├── SettingsView.swift      # tab bar + selected tab: General, Actions, Translation, Autocomplete, Proofread, Providers -- each feature owns its tab, including its on/off switch
│   ├── SettingsTab / SettingsTabBar / SettingsTabRow / SettingsTabButton / SettingsTabContent .swift
│   │                           # in-window tab bar, NOT TabView: on macOS 26+ a Tab-built TabView moves
│   │                           # the tabs into the title bar as overflowing icons. ViewThatFits picks the
│   │                           # widest layout that fits: icon+title, icon over title, icons only
│   ├── GeneralSettingsView / ActionsSettingsView / TranslationSettingsView (+ TranslationSection,
│   │   TranslationStatusRow, LanguagePicker) / ShortcutsSection .swift  # one type per file
│   ├── HelpHint / HelpHeader / HelpToggleRow .swift # help icon, header with help, and the Form toggle
│   │                           # with a help hint (keeps the hint's Button out of the Toggle's label)
│   ├── AutocompleteSettingsView.swift  # autocomplete tab (on/off, count, layout, language, learning, per-app)
│   ├── LearnedWordsView / TypoFilterRow / LearnedWordRow .swift # learned-words sheet
│   ├── LanguageSelectionBinding.swift  # Binding<[String]>.contains(code) / .isAuto for menu toggles
│   ├── ProofreadSettingsView.swift     # proofread tab (on/off, fixes, layout, language, per-app)
│   ├── AppFilterSection.swift          # shared per-app allow/deny section (autocomplete + proofread)
│   ├── ActionKeysSettingsView.swift / ActionKeyRow.swift # action keys; rows bound by id, never by index
│   ├── ProvidersSettingsView.swift     # engine picker + AI providers (keys, models; drafts written back deferred)
│   ├── ShortcutRecorder.swift / HotkeyFormatter.swift # click-to-record shortcut field, glyph formatting
│   ├── DarkFieldStyle / ClearFocusOnAppear / DeferredWrite .swift # input box style, no auto-focus on
│   │                           # tab appear, deferred settings writes from text fields
│   ├── LanguageToolConnectionSection.swift # LT mode/URL/credentials block on the Proofread tab
│   ├── PopupKit.swift          # shared popup metrics/panel/placement/tile measuring (AppKit geometry, not views)
│   ├── PopupPresenter.swift    # owns a popup's non-activating panel; generic present(view), no AnyView
│   ├── PopupChrome.swift       # material panel + hairline border modifier (reads Reduce Transparency from the environment)
│   ├── PopupCell.swift         # one item: selection pill, selected/button accessibility traits
│   ├── PopupItemsLayout.swift  # the one column/line/tile layout both popups use
│   ├── PopupTilePacker.swift   # pure: how many cells fit the tile's first row
│   ├── ProofreadPopover.swift  # the fixes popup: presenter + placement above the word
│   ├── FixesPopupView.swift    # the fixes popup's content: header + PopupItemsLayout
│   ├── FixesPopupHeader.swift  # kind marker, rule wording, "N of M" counter (one accessibility element)
│   ├── PopupMessageView.swift  # one-line notice in the same chrome
│   ├── FirstMouseHostingView.swift # NSHostingView that accepts the first click on a never-key panel
│   ├── HistoryPanelView.swift / HistoryRow.swift / HistoryDetail.swift # History popover from the menu bar
│   ├── PopupController.swift   # floating NSPanel for translation/results; closes on Esc/Close only
│   ├── PopupModel.swift / PopupView.swift / PopupHeader.swift / PopupOriginalSection.swift
│   │                           # result popup: header is the only drag area, copy-original icon
│   ├── WindowDragHandle.swift  # NSView that drags its window (body stays text-selectable)
│   ├── KeyablePanel.swift      # NSPanel that can become key from an accessory app
│   ├── QuickTranslate*.swift   # Quick Translate window: controller, @Observable model, view, language
│   │                           # bar, input (vertical TextField: system placeholder level with the
│   │                           # caret; Return translates, Shift+Return inserts a newline), output,
│   │                           # action bar ([Clear] ... [Close][Copy]), footer
│   ├── CopyButton.swift / CloseButton.swift # the shared translation-window buttons (Copy is the
│   │                           # prominent one, "Copied" for 1.5 s)
│   └── CopyShortcutMonitor.swift # Cmd+C in a translation window: the selection if there is one,
│                               # otherwise the whole translation
└── Store/
    ├── Settings.swift          # Codable settings, ProviderKind, HotkeyConfig
    ├── ActionKey.swift         # {key, label, prompt, hotkey?}; built-in w / u / l / о / гг
    ├── KeychainStore.swift     # API keys (generic password)
    └── LoginItemManager.swift  # SMAppService launch-at-login
Tests/
├── main.swift                  # pure-logic assertions across actions, settings, proofread, popups (no XCTest host needed)
├── run_tests.sh
├── eval_autocomplete.sh        # autocomplete ranking evaluator (hit@1/hit@3/MRR per prefix)
├── eval_autocomplete.swift     # harness: RU corpus, cold/warm store, baseline|context|semantic modes
├── gen_ru_ngrams.py            # rebuilds ru_bigrams_ctx.txt / ru_trigrams.txt from a sentence corpus
└── ru_eval_corpus.txt          # 105 RU sentences (80 hand-written + 25 Leipzig news) used by the evaluator
Info.plist                      # LSUIElement, version (source of truth for version)
```

## Triggers (defaults, all configurable in Settings → Actions → Shortcuts)
- **Cmd+C ×2** → default action: fix spelling/grammar, or run a custom prompt (separator / action key)
- **Cmd+C ×3** → translate the selection, shown in a popup near the cursor
- **Cmd+E** → OCR: select a screen region, recognize text, translate
- **Shift+Cmd+E** → Quick Translate window
- **Proofread** (LanguageTool), only when enabled on Settings → Proofread, has **no shortcut**: a
  pause in typing (~0.6 s) re-checks the focused field and underlines every issue in place
  (straight underlines; spelling is red, grammar yellow, punctuation green, style blue -- LanguageTool's own
  palette). Clicking an
  underlined word shows its fixes instantly -- the issues are already known, no round trip. In the
  popup: arrows or mouse hover choose a fix (the column layout uses up/down for fixes and
  left/right for problem words, the line swaps them, and the tile uses both axes for fixes), Return
  or a click applies it, Tab steps between problem words (wrapping around), Esc closes it (the
  underlines stay). Both popups share `UI/PopupKit.swift` (system-menu look: material panel, standard
  selection pill, no zoom or animation; honours Reduce Transparency and Differentiate Without Color),
  take their text size from Settings → General, and their layout
  (Column / Line / Tile -- two rows) from their own setting, shared with autocomplete. The number of fixes listed per issue is a setting
  (1-10, default 3). Underlines follow scrolling and window moves, go down while typing and come
  back with the fresh result, and disappear on an app switch. Apps that expose no word coordinates
  (many Electron/web fields) get no underlines; the popup still works if their text is readable.
  Chromium-based apps only build an accessibility tree when asked, so `ProofreadAX` sets
  `AXManualAccessibility` on the frontmost process once (`enableElectronAccessibilityIfNeeded`).
  One LanguageTool rule is hidden on purpose (`LanguageToolEngine.ignoredProofreadRules`):
  `UPPERCASE_SENTENCE_START`, "this sentence does not start with an uppercase letter". It is right by
  the book and wrong for chat, where nearly every message starts in lowercase -- left on, it put a
  permanent green underline (LanguageTool files it under `typographical`, which maps to punctuation)
  on the first word of everything. It is filtered where matches become issues, not via the request's
  `disabledRules`, because the "Correct" action shares the engine and there capitalising the start is
  a legitimate fix. To hide another rule, add its id to that set.
  **A selection never opens the popup** (`ProofreadClickPolicy`): editors put their own controls over
  a selection -- Slack's formatting toolbar lands exactly where the fixes popup would -- so
  double-clicking a word or dragging across a paragraph that holds an underlined one is left alone,
  and only a plain click into a word asks for fixes. For the same reason the popup never selects the
  word it is about (`showCurrent()`, in any app, not just Chromium/Electron -- a selection left
  behind once the popup closes turned a single Backspace into deleting the whole word); the underline
  already marks it, and `IssueApplier` makes the selection itself right before pasting a fix.
- Each `ActionKey` may have its own recorded shortcut that runs its prompt on the selection directly.
- **Esc** cancels an in-flight action.
- **Word autocomplete** (off by default; enable and configure on the Autocomplete tab): as you type, a list of case-matched completions appears near the caret; arrow keys choose,
  **Tab** (and optionally Return) inserts; any other key, a click anywhere, or leaving the app
  dismisses it. Completions are **ranked by the preceding words** (the "Rank by context" setting,
  default on): `AutocompleteLearningStore.contextScore` interpolates learned trigram > learned
  bigram > bundled RU trigram/bigram seeds > personal frequency, and the pool (learned + dictionary
  completions, up to 30) is re-ranked by that score -- this was validated by an experiment, run with
  `Tests/eval_autocomplete.sh` (context beat baseline and a semantic-embedding variant on hit@1/MRR
  against `Tests/ru_eval_corpus.txt`). It can predict the next word
  after a space: the context (up to two preceding words) is read from the focused field via AX where
  one is exposed, the same way the current word is ranked, so it also works after clicking back into
  a sentence or returning from another app -- not only mid-typing-run, which is all the keystroke
  buffer (`prevWord`/`prevWord2`, used as the fallback when AX exposes no text) can see. It also
  learns the words you use (local
  `AutocompleteLearningStore`): a word is learned when a space or punctuation closes it, and when a
  suggestion is accepted. Return deliberately does not learn (it submits password fields).
  Learned words can be reviewed: the "Learned words" sheet flags every word the dictionary does
  not know (`LearnedWordAudit`, pinned words exempt) and can drop them in one go -- anything typed
  twice gets learned, typos included.
  Configurable: count, column/line/tile layout, text
  size, dictionary language, and per-app allow/deny. Uses AX text+caret where available, otherwise a
  keystroke buffer (works in most apps). Skipped in password fields and BindAll's own windows.
  The ranking mode can be overridden for experiments with
  `defaults write com.evgeny.bindall AutocompleteVariant -string baseline|context|semantic`
  (semantic re-ranking via `SemanticRanker` measured poorly on Russian and stays off by default).
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
- **Engine for text actions** (`Settings → Providers`): Apple on-device, DeepSeek, OpenRouter, OpenAI,
  or Ollama. Cloud providers share one OpenAI-compatible client (`/chat/completions`). This picker and
  the **Provider** picker just below it configure different things -- the Provider section edits
  credentials/model for whichever provider is selected there, not necessarily the one actions run on;
  the Provider list tags the active one with "— active" for exactly this reason. `/models` is a public
  listing on some providers (OpenRouter answers it with no key at all), so it cannot stand in for an
  auth check: `testConnection()` always makes a real `/chat/completions` call, and `listModels()`
  refuses to run with an empty key rather than silently returning an anonymous provider's catalog. A
  401/403 names the provider in the error text, since it is otherwise indistinguishable from a
  same-shaped key belonging to a different provider (`OpenAICompatibleEngine.providerName`). Keys are
  trimmed of whitespace before being saved (`ProvidersSettingsView.saveKey`) -- a pasted key with a
  trailing newline is invisible in the field and would otherwise fail with an unexplained 401.
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
  The connection is configured on the Proofread tab via an explicit **connection mode**
  (`LanguageToolMode`): **Free public** (`api.languagetool.org`, no credentials -- the public server
  rejects them with HTTP 400), **Premium** (`api.languagetoolplus.com`, a different host, requires
  username + token), or **Self-hosted** (your own URL, no credentials -- the server is reached by URL
  alone, so the tab shows no username or token fields for it).
  `Settings.languageToolConnection(token:)` resolves the real endpoint and puts credentials on the
  wire for Premium only; `LanguageToolEngine.authParams` is a final guard that never sends a
  lone username or apiKey. The Premium token lives in the Keychain. The URL is pre-filled per mode
  but stays editable; there is no settings migration (mode defaults to Free).
- **Slack block boundaries:** Slack (Chromium) reports list items, quotes and code blocks glued
  together in `AXValue` ("Buy bread.Call mom"), which made LanguageTool flag every list item's first
  word with `SENTENCE_WHITESPACE`. `ProofreadAX.hiddenBreaks` (Chromium only) walks the field's text
  leaves; when they add up to exactly `AXValue`, each seam with no whitespace whose next leaf starts
  on a lower line (per `AXBoundsForRange`) is a hidden break. The check runs on
  `HiddenBreaks.checkText` (newlines put back), and `mapBack` returns issues in `AXValue`
  coordinates, dropping any that span a break and retaking original/context from the field's text.
- **Translation layout:** Apple's model (macOS 27) translates each line as its own segment and
  joins the output with blank lines. The whole text still goes in one request (context matters);
  `TranslationLayout.restore` then swaps the output's newline runs for the source's. OCR lines are
  first joined into paragraphs (`OCRParagraphs`: small vertical gap and aligned left edge = same
  paragraph; a hyphenated wrap is rejoined), since screen line breaks cut sentences in half.
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
- **Accessibility** — required for the event taps and the synthetic Cmd+V. `HotkeyCoordinator`'s
  2s retry timer polls `AccessibilityPermission.isGranted` and (re)starts the hotkey tap and the
  proofread monitors automatically once it is granted -- no relaunch needed. A macOS upgrade can
  leave the Accessibility checkbox showing granted while `AXIsProcessTrusted()` is actually stale
  (its designated requirement no longer matches what got re-signed); Settings → General → Status
  shows Accessibility and **Global shortcuts** separately for exactly this case -- if shortcuts
  read "Not active" with Accessibility "Granted", remove BindAll from the Accessibility list and
  grant it again. `AccessibilityPermission.listenEventAccessGranted` (Input Monitoring) is
  diagnostic-only, logged when a tap fails to install; it is never requested on its own.
- **Apple Intelligence** — must be enabled for the on-device engine (`AppleFoundationEngine`).
- **Translation language packs** — may download on first use.

## Diagnostics
Failures that used to be silent (a `tapCreate` returning nil, a monitor that never (re)installs) are
now logged via `os.Logger`, subsystem `com.evgeny.bindall`, one category per area (`hotkeys`,
`proofread`, `proofread-ax`, `login-item`, …): `log stream --predicate 'subsystem ==
"com.evgeny.bindall"'`. `ProofreadAX.alignedRange`'s search window now scales with how far into the
text the range sits (`max(16, min(256, location / 20))`) instead of a fixed ±16 UTF-16 units, and a
miss is logged at `.debug` -- a fixed small window is what let long-document offset drift (an app's
own AX bookkeeping disagreeing with ours) silently drop underlines and fixes. All AX calls made
against another app's process now go through a 0.25s `AXUIElementSetMessagingTimeout`
(`ProofreadAX.enableElectronAccessibilityIfNeeded`), so a hung target app cannot hang BindAll's main
thread (and, with it, the active proofread popup tap the system would then disable).

## Key Guarantees
- Menu-bar agent (`LSUIElement`); no Dock icon. The settings window temporarily switches the activation
  policy to `.regular` so it can come to the front, then back to `.accessory` on close.
- The status icon is always the `sparkles` symbol; the three states differ only in the button's alpha
  (`AppDelegate.updateStatusIcon`): full while idle, pulsing while an action runs, and dimmed to
  `disabledAlpha` while the master switch (`settings.enabled`) is off. The master switch gates the
  hotkey bursts, autocomplete and proofread alike, so "off" must stay visually distinguishable --
  otherwise a disabled app looks exactly like a working one whose shortcuts do nothing.
- The status menu draws every shortcut hint itself (six of them, one right-aligned column) and has
  **no real key equivalents**. Give an item a real one and the system reserves its own column right of
  the widest title -- our drawn line counts as a title -- so it lands to the right of ours and moving
  ours only pushes it further; that is why Settings and Quit are drawn too. Their keys still work
  while the menu is open through a local key monitor installed in `menuWillOpen` and removed in
  `menuDidClose`.
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
