# CLAUDE.md

The full project guide is **[AGENTS.md](./AGENTS.md)** — read it first. It is the single source of
truth for stack, structure, architecture, build/test commands, and the working rules below.

## Quick reference
- Build: `xcodebuild -scheme BindAll build CODE_SIGNING_ALLOWED=NO`
- Tests: `./Tests/run_tests.sh`
- App: open `BindAll.xcodeproj` and Run (menu-bar agent, no Dock icon).

## Non-negotiable rules (see AGENTS.md for detail)
- English only; no emojis in code, comments, docs, or commit messages.
- Keep AGENTS.md in sync with the code.
- Build must compile after every change; bump the version in `Info.plist` before committing code.
- New source files are picked up automatically (synchronized group) — do not hand-edit `project.pbxproj`.
