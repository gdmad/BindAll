import Foundation

// Tiny assertion harness (avoids needing an XCTest bundle/host for pure-logic tests).
var failures = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ \(message)")
    }
}
func eq(_ a: String, _ b: String, _ message: String) {
    check(a == b, "\(message)  (got: \(a.debugDescription))")
}

print("PromptParser")
let keys = ActionKey.defaults
let defaultPrompt = "DEFAULT"

// No separator → default prompt over whole text.
let p1 = PromptParser.parse(text: "hello world", separator: "--", defaultPrompt: defaultPrompt, actionKeys: keys)
check(!p1.hadExplicitInstruction, "no separator → default")
eq(p1.instruction, defaultPrompt, "no separator uses default prompt")
eq(p1.content, "hello world", "no separator keeps full content")

// Action key resolution.
let p2 = PromptParser.parse(text: "Ghbdtn rfr ltkf -- w", separator: "--", defaultPrompt: defaultPrompt, actionKeys: keys)
check(p2.hadExplicitInstruction, "separator + key → explicit")
eq(p2.content, "Ghbdtn rfr ltkf", "content trimmed before separator")
check(p2.instruction.contains("layout"), "w resolves to layout prompt")

// Freeform instruction.
let p3 = PromptParser.parse(text: "Hello -- translate to Chinese", separator: "--", defaultPrompt: defaultPrompt, actionKeys: keys)
eq(p3.content, "Hello", "freeform content")
check(p3.instruction.hasPrefix("translate to Chinese"), "freeform instruction kept")

// Case-insensitive key match (Cyrillic).
let p4 = PromptParser.parse(text: "abc -- ГГ", separator: "--", defaultPrompt: defaultPrompt, actionKeys: keys)
check(p4.instruction.contains("Привет!"), "ГГ matches гг case-insensitively")

// All default keys resolve.
for k in ["w", "u", "l", "о", "гг"] {
    let p = PromptParser.parse(text: "x -- \(k)", separator: "--", defaultPrompt: defaultPrompt, actionKeys: keys)
    check(p.hadExplicitInstruction && p.instruction != defaultPrompt, "default key \(k) resolves")
}

// Separator glued to the key (no spaces) also works.
let pNoSpace = PromptParser.parse(text: "Ghbdtn rfr ltkf--w", separator: "--", defaultPrompt: defaultPrompt, actionKeys: keys)
eq(pNoSpace.content, "Ghbdtn rfr ltkf", "no-space separator: content")
check(pNoSpace.instruction.contains("layout"), "no-space separator: key resolves")

// Empty suffix → default.
let p5 = PromptParser.parse(text: "abc --", separator: "--", defaultPrompt: defaultPrompt, actionKeys: keys)
check(!p5.hadExplicitInstruction, "empty suffix → default")

// Uses LAST separator occurrence.
let p6 = PromptParser.parse(text: "a -- b -- w", separator: "--", defaultPrompt: defaultPrompt, actionKeys: keys)
eq(p6.content, "a -- b", "splits on last separator")

print("History ring buffer")
func entry(_ output: String) -> HistoryEntry {
    HistoryEntry(date: Date(), kind: .action, input: "in", output: output, engine: "test")
}
var hist: [HistoryEntry] = []
for i in 1...5 { hist = HistoryEntry.appending(entry("e\(i)"), to: hist, limit: 3) }
check(hist.count == 3, "ring buffer trims to limit")
eq(hist.first?.output ?? "nil", "e5", "newest entry first")
eq(hist.last?.output ?? "nil", "e3", "oldest kept entry is e3")
let single = HistoryEntry.appending(entry("only"), to: [], limit: 3)
check(single.count == 1 && single.first?.output == "only", "append to empty list")

print("MaskAISlop")
eq(MaskAISlop.apply(to: "a — b"), "a - b", "em dash → hyphen")
eq(MaskAISlop.apply(to: "a – b"), "a - b", "en dash → hyphen")
eq(MaskAISlop.apply(to: "\u{201C}hi\u{201D}"), "\"hi\"", "smart double quotes → straight")
eq(MaskAISlop.apply(to: "it\u{2019}s"), "it's", "fancy apostrophe → straight")
eq(MaskAISlop.apply(to: "hi 😀 there"), "hi there", "emoji removed (adjacent doubled space swallowed)")
eq(MaskAISlop.apply(to: "wait\u{2026}"), "wait...", "ellipsis → three dots")
eq(MaskAISlop.apply(to: "a\u{00A0}b"), "a b", "nbsp → space")
eq(MaskAISlop.apply(to: "plain text"), "plain text", "plain text unchanged")

print("MaskAISlop formatting preservation")
// The normalizer must never change the layout of the text: line breaks, paragraphs,
// indentation and alignment have to come out exactly as they went in.
func preserved(_ text: String, _ message: String) {
    eq(MaskAISlop.apply(to: text), text, message)
}
preserved("line one\nline two", "newlines preserved")
preserved("para one\n\npara two", "blank line between paragraphs preserved")
preserved("a\tb\tc", "tabs preserved")
preserved("win\r\nline", "CRLF preserved")
preserved("\nstart", "leading newline preserved")
preserved("end\n", "trailing newline preserved")
preserved("    indented code", "leading-space indentation preserved")
preserved("col1  col2   col3", "inner space runs (alignment) preserved")
preserved("- item 1\n- item 2\n  - nested", "markdown list structure preserved")
preserved("# Header\n\nBody text.", "markdown header + paragraph preserved")
preserved("```\nlet x = 1\n    let y = 2\n```", "fenced code block with indentation preserved")
preserved("Привет, мир!\nКак дела?", "cyrillic multi-line text untouched")
preserved("cafe\u{0301}".precomposedStringWithCanonicalMapping, "precomposed accents (NFC) untouched")

// Replacements keep the surrounding layout intact.
eq(MaskAISlop.apply(to: "  a — b\n\tc \u{201C}d\u{201D}"), "  a - b\n\tc \"d\"",
   "replacements do not disturb indentation/newlines/tabs")
eq(MaskAISlop.apply(to: "x 😀  y"), "x  y", "emoji strip swallows only one adjacent space")
eq(MaskAISlop.apply(to: "😀line\nkeep  it"), "line\nkeep  it", "strip at start does not touch later spacing")

print("LanguageTool applyMatches")
func ltMatch(_ offset: Int, _ length: Int, _ replacement: String) -> [String: Any] {
    ["offset": offset, "length": length, "replacements": [["value": replacement]]]
}
eq(LanguageToolEngine.applyMatches([ltMatch(0, 3, "the")], to: "teh cat"), "the cat", "single replacement")
eq(LanguageToolEngine.applyMatches([ltMatch(0, 3, "the"), ltMatch(4, 3, "the")], to: "teh teh"),
   "the the", "two replacements applied right-to-left")
eq(LanguageToolEngine.applyMatches([], to: "no change"), "no change", "no matches keeps text")
eq(LanguageToolEngine.applyMatches([["offset": 0, "length": 3]], to: "teh cat"),
   "teh cat", "match without replacements is skipped")
eq(LanguageToolEngine.applyMatches([ltMatch(100, 3, "x")], to: "short"),
   "short", "out-of-range match is ignored")

print("Autocomplete partialWord")
eq(AutocompleteEngine.partialWord(in: "hello wor", caretUTF16Offset: 9), "wor", "partial mid-typing")
eq(AutocompleteEngine.partialWord(in: "hello ", caretUTF16Offset: 6), "", "empty right after a space")
eq(AutocompleteEngine.partialWord(in: "hello.wor", caretUTF16Offset: 9), "wor", "word starts after punctuation")
eq(AutocompleteEngine.partialWord(in: "appl", caretUTF16Offset: 2), "ap", "uses only text left of the caret")
eq(AutocompleteEngine.partialWord(in: "café", caretUTF16Offset: 4), "café", "accented letters kept")
eq(AutocompleteEngine.partialWord(in: "", caretUTF16Offset: 0), "", "empty text")

print("Autocomplete recased")
eq(AutocompleteEngine.recased("apple", like: "App"), "Apple", "capitalized partial capitalizes")
eq(AutocompleteEngine.recased("apple", like: "APP"), "APPLE", "all-caps partial uppercases")
eq(AutocompleteEngine.recased("apple", like: "app"), "apple", "lowercase keeps dictionary case")
eq(AutocompleteEngine.recased("iPhone", like: "iph"), "iPhone", "lowercase keeps proper-noun case")

print("Autocomplete isWordTerminator")
check(AutocompleteEngine.isWordTerminator("."), "period ends a word")
check(AutocompleteEngine.isWordTerminator(","), "comma ends a word")
check(AutocompleteEngine.isWordTerminator("!"), "exclamation ends a word")
check(!AutocompleteEngine.isWordTerminator("'"), "apostrophe is inside a contraction")
check(!AutocompleteEngine.isWordTerminator("-"), "hyphen is inside a compound word")
check(!AutocompleteEngine.isWordTerminator("5"), "digit is inside a token")
check(!AutocompleteEngine.isWordTerminator("a"), "letter is not a boundary")

print("LanguageToolMode.inferred")
check(LanguageToolMode.inferred(fromBaseURL: "https://api.languagetool.org/v2") == .free,
      "public URL infers free")
check(LanguageToolMode.inferred(fromBaseURL: "https://api.languagetoolplus.com/v2") == .premium,
      "plus URL infers premium")
check(LanguageToolMode.inferred(fromBaseURL: "http://home.lan:8081/v2") == .selfHosted,
      "a custom URL infers self-hosted")

print("Settings.languageToolConnection")
var s = Settings()
s.languageToolUsername = "me@x.com"
s.languageToolBaseURL = "http://home.lan:8081/v2"

s.languageToolMode = .free
let free = s.languageToolConnection(token: "secret")
eq(free.baseURL, "https://api.languagetool.org/v2", "free forces the public URL")
check(free.username.isEmpty && free.apiKey.isEmpty, "free never sends credentials, even if filled in")

s.languageToolMode = .premium
let prem = s.languageToolConnection(token: "secret")
eq(prem.baseURL, "https://api.languagetoolplus.com/v2", "premium forces the plus host")
eq(prem.username, "me@x.com", "premium sends the username")
eq(prem.apiKey, "secret", "premium sends the token")

s.languageToolMode = .selfHosted
let selfh = s.languageToolConnection(token: "secret")
eq(selfh.baseURL, "http://home.lan:8081/v2", "self-hosted uses the user URL")
eq(selfh.apiKey, "secret", "self-hosted forwards the token when present")

print("Settings mode migration (resilient decoding)")
func decode(_ json: String) -> Settings {
    try! JSONDecoder().decode(Settings.self, from: Data(json.utf8))
}
// Saved before modes existed: mode is inferred from the stored URL.
check(decode("{\"languageToolBaseURL\":\"https://api.languagetool.org/v2\"}").languageToolMode == .free,
      "legacy public URL migrates to free")
check(decode("{\"languageToolBaseURL\":\"https://api.languagetoolplus.com/v2\"}").languageToolMode == .premium,
      "legacy plus URL migrates to premium")
check(decode("{}").languageToolMode == .free, "empty settings default to free")
// An explicitly stored mode wins over inference.
check(decode("{\"languageToolMode\":\"selfHosted\",\"languageToolBaseURL\":\"https://api.languagetool.org/v2\"}").languageToolMode == .selfHosted,
      "an explicit stored mode is kept")

print("LanguageToolEngine.authParams")
let loneUser = LanguageToolEngine.authParams(["text": "x"], username: "me@x.com", apiKey: "")
check(loneUser["username"] == nil && loneUser["apiKey"] == nil, "lone username is dropped (would 400)")
let loneKey = LanguageToolEngine.authParams(["text": "x"], username: "", apiKey: "abc")
check(loneKey["apiKey"] == nil, "lone apiKey is dropped")
let pair = LanguageToolEngine.authParams(["text": "x"], username: "me@x.com", apiKey: "abc")
check(pair["username"] == "me@x.com" && pair["apiKey"] == "abc", "a full pair is attached")
check(LanguageToolEngine.authParams(["text": "x"], username: "", apiKey: "")["text"] == "x",
      "original params survive")

print("")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) TEST(S) FAILED")
    exit(1)
}
