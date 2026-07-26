# Testing proofread in an app

The "Supported apps" list on the Proofread tab is a record of testing, not a guess. Run this pass
before adding an app to `ProofreadSupport.verified` (BindAll/Proofread/ProofreadSupport.swift).

Budget: about five minutes per app.

## Before you start

- Settings → General: Proofread enabled; Accessibility granted.
- Settings → Proofread: a working LanguageTool connection (Test connection is green), "Skip fields
  shorter than" at its default 12, "Fixes shown per issue" at 3.
- Have a test sentence ready with four errors of different kinds, far enough apart to click
  individually. Russian works well because LanguageTool has real grammar rules for it:

  ```
  Прывет как дила у тибя сигодня
  ```

- Keep the menu bar item reachable: several steps use "Proofread diagnostics (click into a field)…".

## The pass

Do these in order in the app under test. Note the first step that fails -- that determines the
level, and everything after it can be skipped.

### 1. Underlines appear

Type the test sentence into the app's main text field. Wait about a second after the last
keystroke.

**Expect:** the misspelled words get purple squiggles, other kinds get orange/blue/gray ones.
Some apps (Slack, browsers) also draw the system's own red squiggles -- that is macOS, not us.

If nothing appears, run diagnostics (step 6) before deciding: no underlines with readable text is
`.fixesOnly`, no readable text at all means the app is unsupported.

### 2. Underlines are in the right place

Look closely at where the squiggles sit: they must be under the words they belong to, not shifted
by a word or a line. Then:

- scroll the text a few lines and back -- the underlines must follow the text;
- move the window -- within about half a second they must catch up.

**A shifted underline is a failure, not a cosmetic issue.** It means the app reports different
coordinates than the text we measured, and fixes are likely to land on the wrong word too.

### 3. Clicking shows the fixes

Click inside the second underlined word.

**Expect:** the popup opens immediately (no visible delay -- the issues are already known), sits
above that word, and the word itself is selected in the app.

### 4. Keys behave

With the popup open:

- ↑ / ↓ move between the fixes for this word;
- Tab and → move to the next problem word, ← to the previous one, wrapping around at the ends;
- Esc closes the popup while the underlines stay.

### 5. Applying a fix replaces the right word

This is the step that matters most. Deliberately skip the first error, then:

- apply a fix to the **second** word -- exactly that word must change;
- apply a fix to the **last** word -- exactly that word must change;
- try applying with the mouse (click a row) and with Return.

**Expect:** either the correct word is replaced, or the honest refusal "The text changed -
checking again…". Anything replacing a neighbouring word is a bug -- report it with the app name
and which word was clicked versus which one changed.

### 6. Diagnostics

Menu bar → "Proofread diagnostics (click into a field)…", then click into the app's text field
within a few seconds and wait for the report.

Useful lines:

- `Result: readable field (N UTF-16 units)` -- the text is available at all;
- `Word coordinates: yes …` or `via leaf elements …` -- underlines are possible;
  `Word coordinates: NO …` -- they are not, in this app;
- `AXStringForRange …` / `Offsets differ …` -- whether the app indexes its text the way we do;
- `Known support: …` -- what the shipped list currently claims.

Copy the report when reporting a problem.

## Deciding the level

| What happened | Level | Add to the list? |
|---|---|---|
| Steps 1-5 all pass | `.full` | Yes |
| No underlines (or they cannot be positioned), but steps 3-5 pass | `.fixesOnly` | Yes |
| Underlines land on the wrong words | -- | No: report it |
| A fix replaces a different word | -- | No: report it, this comes first |
| No readable text (diagnostics say so) | -- | No |

Add a `note` when the app has a quirk worth warning about ("macOS draws its own red squiggles
here"), not for anything that applies everywhere.

## Apps worth covering

Native: TextEdit, Notes, Mail, Pages, Xcode, Terminal (single-line), Safari (a web form).
Electron/Chromium: Slack, Obsidian, VS Code, Discord, Notion, Chrome.
Other: Telegram, Firefox, JetBrains IDEs, Microsoft Word.

Test the app's *main* writing surface (a Slack message box, an Obsidian note, a Mail body), not
its search field: short fields are skipped by design.

## Reporting

For each app tested, send: the app name and version, the level from the table above, anything
odd, and -- if a step failed -- the diagnostics report from step 6. Entries are then added to
`ProofreadSupport.verified` by hand.
