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

// MARK: - Proofread

func issue(_ location: Int, _ length: Int, source: IssueSource = .languageTool,
           kind: IssueKind = .spelling, original: String = "x",
           replacements: [String] = [], ruleId: String? = nil) -> TextIssue {
    TextIssue(range: NSRange(location: location, length: length), kind: kind, shortMessage: "",
              message: "", replacements: replacements, ruleId: ruleId, source: source, original: original)
}

print("LanguageToolEngine Equatable")
// The proofread provider reconfigures only when the engine actually changes; a token-only change
// must count, so equality has to include the credentials, not just the URL.
let engA = LanguageToolEngine(baseURL: "u", username: "me", apiKey: "k1", language: "ru")
let engSame = LanguageToolEngine(baseURL: "u", username: "me", apiKey: "k1", language: "ru")
let engToken = LanguageToolEngine(baseURL: "u", username: "me", apiKey: "k2", language: "ru")
check(engA == engSame, "identical engines are equal")
check(engA != engToken, "a token-only change makes engines unequal")

print("LanguageToolEngine.parseMatches")
let ltJSON = """
{"matches": [
  {"offset": 5, "length": 3, "message": "Spelling mistake", "shortMessage": "Spelling",
   "replacements": [{"value": "the"}, {"value": "thee"}],
   "rule": {"id": "MORFOLOGIK_RULE", "issueType": "misspelling", "category": {"id": "TYPOS"}}},
  {"offset": 20, "length": 2, "message": "No replacement offered", "replacements": [],
   "rule": {"id": "STYLE_X", "issueType": "style", "category": {"id": "STYLE"}}},
  {"offset": -1, "length": 4, "message": "malformed"},
  {"length": 4, "message": "no offset"}
]}
"""
let ltMatches = try! LanguageToolEngine.parseMatches(Data(ltJSON.utf8))
check(ltMatches.count == 2, "malformed matches are dropped (got \(ltMatches.count))")
check(ltMatches[0].replacements == ["the", "thee"], "replacements parsed in order")
eq(ltMatches[0].ruleId ?? "", "MORFOLOGIK_RULE", "rule id parsed")
eq(ltMatches[0].categoryId ?? "", "TYPOS", "category id parsed")
eq(ltMatches[0].shortMessage, "Spelling", "short message parsed")
check(ltMatches[1].replacements.isEmpty, "match without replacements is kept")

print("LanguageToolEngine.kind")
check(LanguageToolEngine.kind(for: ltMatches[0]) == .spelling, "TYPOS category → spelling")
check(LanguageToolEngine.kind(for: ltMatches[1]) == .style, "style issueType → style")
check(LanguageToolEngine.kind(for: LTMatch(offset: 0, length: 1, message: "", shortMessage: "",
                                           replacements: [], ruleId: nil, issueType: "whitespace",
                                           categoryId: "TYPOGRAPHY")) == .punctuation,
      "whitespace issueType → punctuation")
check(LanguageToolEngine.kind(for: LTMatch(offset: 0, length: 1, message: "", shortMessage: "",
                                           replacements: [], ruleId: nil, issueType: nil,
                                           categoryId: nil)) == .grammar,
      "unknown issueType → grammar")

print("LanguageToolEngine.issues offsets are UTF-16")
// The emoji is 2 UTF-16 units, so "bad" starts at 3, not 2. LanguageTool counts the same way.
let emojiText = "a😉bad end"
let emojiIssues = LanguageToolEngine.issues(
    from: [LTMatch(offset: 3, length: 3, message: "m", shortMessage: "s", replacements: ["good"],
                   ruleId: "R", issueType: "misspelling", categoryId: "TYPOS")],
    text: emojiText)
check(emojiIssues.count == 1, "issue inside text is kept")
eq(emojiIssues[0].original, "bad", "UTF-16 offset past an emoji resolves to the right substring")
let outOfRange = LanguageToolEngine.issues(
    from: [LTMatch(offset: 100, length: 3, message: "", shortMessage: "", replacements: [],
                   ruleId: nil, issueType: nil, categoryId: nil)],
    text: emojiText)
check(outOfRange.isEmpty, "issue past the end of text is dropped")

print("TextIssue identity")
let idA = issue(5, 3, original: "teh").id
let idB = issue(5, 3, original: "teh").id
eq(idA, idB, "same issue re-checked yields the same id")
check(idA != issue(6, 3, original: "teh").id, "different location yields a different id")

print("IssueMerger.merge")
// LanguageTool fires several rules on one word; the user must be asked about it once.
let typo = issue(0, 3, kind: .spelling, original: "teh", replacements: ["the"], ruleId: "TYPO")
let dupe = issue(0, 3, kind: .grammar, original: "teh", replacements: ["the", "tea"], ruleId: "OTHER")
let sameRange = IssueMerger.merge([typo, dupe])
check(sameRange.count == 1, "identical ranges collapse to one issue")
check(sameRange[0].replacements == ["the", "tea"], "replacements are unioned and deduped")

let overlap = IssueMerger.merge([issue(0, 5, original: "a b c"), issue(2, 3, original: "b c")])
check(overlap.count == 1 && overlap[0].range.length == 5, "overlapping issue loses to the longer one")

let disjoint = IssueMerger.merge([issue(10, 2, original: "aa"), issue(0, 2, original: "bb")])
check(disjoint.count == 2, "disjoint issues both survive")
check(disjoint[0].range.location == 0, "merge output is sorted by location")
check(IssueMerger.merge([issue(0, 0, original: "")]).isEmpty, "empty ranges are dropped")

print("IssueMerger.firstIssue(overlapping:)")
let picked = [issue(0, 3, original: "teh"), issue(10, 4, original: "wrng")]
check(IssueMerger.firstIssue(in: picked, overlapping: NSRange(location: 10, length: 4))?.original == "wrng",
      "a selection on an issue finds it")
check(IssueMerger.firstIssue(in: picked, overlapping: NSRange(location: 11, length: 1))?.original == "wrng",
      "a partial selection inside an issue finds it")
check(IssueMerger.firstIssue(in: picked, overlapping: NSRange(location: 5, length: 2)) == nil,
      "a selection on clean text finds nothing")
check(IssueMerger.firstIssue(in: picked, overlapping: NSRange(location: 12, length: 0))?.original == "wrng",
      "a caret inside an issue finds it")

print("IssueMerger.relocate")
let teh = issue(4, 3, original: "teh")
check(IssueMerger.relocate(teh, in: "the teh cat") == NSRange(location: 4, length: 3),
      "unchanged text relocates to the same range")
// The user typed "Well, " at the start while the panel was open.
check(IssueMerger.relocate(teh, in: "Well, the teh cat") == NSRange(location: 10, length: 3),
      "text shifted by an edit is found at its new offset")
check(IssueMerger.relocate(teh, in: "the cat") == nil, "vanished text does not relocate")
// The old range no longer matches, and two candidates are equally plausible: refuse to guess.
check(IssueMerger.relocate(teh, in: "xxxx teh teh") == nil, "ambiguous text does not relocate")
// An exact hit at the original range wins even when the word occurs twice: the text did not move.
check(IssueMerger.relocate(teh, in: "teh teh cat") == NSRange(location: 4, length: 3),
      "a still-valid range is used without searching")
check(IssueMerger.relocate(teh, in: "the cat sat on the mat and teh dog", window: 5) == nil,
      "a match far outside the window is not used")
check(IssueMerger.relocate(issue(0, 0, original: ""), in: "abc") == nil, "empty original never relocates")

print("TextSegmenter.paragraphs")
func tiles(_ ps: [Paragraph], _ text: String) -> Bool {
    var next = 0
    for p in ps {
        if p.range.location != next { return false }
        next = NSMaxRange(p.range)
    }
    return next == (text as NSString).length
}
let lfText = "one\ntwo\nthree"
let lf = TextSegmenter.paragraphs(of: lfText)
check(lf.count == 3, "LF splits into three paragraphs")
eq(lf[0].text, "one\n", "separator stays with its paragraph")
eq(lf[2].text, "three", "last paragraph without a trailing separator")
check(tiles(lf, lfText), "LF paragraphs tile the text with no gaps")

let crlfText = "one\r\ntwo"
let crlf = TextSegmenter.paragraphs(of: crlfText)
check(crlf.count == 2, "CRLF counts as one separator")
eq(crlf[0].text, "one\r\n", "CRLF stays with its paragraph")
check(tiles(crlf, crlfText), "CRLF paragraphs tile the text")

let blankText = "one\n\nthree"
let blank = TextSegmenter.paragraphs(of: blankText)
check(blank.count == 3, "a blank line is its own paragraph")
check(tiles(blank, blankText), "paragraphs around a blank line tile the text")
check(TextSegmenter.paragraphs(of: "").isEmpty, "empty text has no paragraphs")
check(!TextSegmenter.isCheckable(Paragraph(range: NSRange(location: 0, length: 1), text: "\n")),
      "a blank paragraph is not worth checking")

print("ProofreadCache")
let cache = ProofreadCache()
let para = Paragraph(range: NSRange(location: 7, length: 5), text: "hello")
check(cache.issues(for: para) == nil, "cache starts empty")
cache.store([issue(1, 2, original: "el")], for: para)
check(cache.issues(for: para)?.count == 1, "stored issues are found by paragraph text")
let rebased = ProofreadCache.rebase(cache.issues(for: para)!, to: para.range.location)
check(rebased[0].range.location == 8, "rebase moves paragraph-local ranges into document coordinates")
eq(rebased[0].original, "el", "rebase preserves the issue payload")
cache.prune(keeping: [Paragraph(range: NSRange(location: 0, length: 5), text: "other")])
check(cache.count == 0, "prune forgets paragraphs no longer in the document")

print("ProofreadLanguage")
eq(ProofreadLanguage.resolve(text: "x", setting: "en-US", detected: "ru"), "en-US",
   "an explicit setting overrides detection")
eq(ProofreadLanguage.resolve(text: "x", setting: "auto", detected: nil), "ru",
   "auto with no detection uses the fallback")
eq(ProofreadLanguage.resolve(text: "hello there", setting: "auto", detected: "en"), "en",
   "auto uses the detected language")
eq(ProofreadLanguage.disambiguateCyrillic("привет как дела", candidate: "uk", preferred: "ru"), "ru",
   "Russian text misdetected as Ukrainian falls back to Russian")
eq(ProofreadLanguage.disambiguateCyrillic("привіт як справи", candidate: "uk", preferred: "ru"), "uk",
   "real Ukrainian keeps its detected language")
eq(ProofreadLanguage.disambiguateCyrillic("hello", candidate: "en", preferred: "ru"), "en",
   "non-Cyrillic detection is left alone")
eq(ProofreadLanguage.baseCode("en-US"), "en", "baseCode strips the region")

print("")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) TEST(S) FAILED")
    exit(1)
}
