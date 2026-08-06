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

print("Autocomplete precedingWords")
func eqArr(_ a: [String], _ b: [String], _ message: String) {
    check(a == b, "\(message)  (got: \(a))")
}
eqArr(AutocompleteEngine.precedingWords(in: "hello wor", caretUTF16Offset: 9, count: 2),
      ["hello"], "word before the partial")
eqArr(AutocompleteEngine.precedingWords(in: "hello world ", caretUTF16Offset: 12, count: 2),
      ["world", "hello"], "two words back after a space")
eqArr(AutocompleteEngine.precedingWords(in: "я хочу пойд", caretUTF16Offset: 11, count: 2),
      ["хочу", "я"], "russian context, most recent first")
eqArr(AutocompleteEngine.precedingWords(in: "привет,", caretUTF16Offset: 7, count: 2),
      ["привет"], "comma-terminated word still collected")
eqArr(AutocompleteEngine.precedingWords(in: "a b c d", caretUTF16Offset: 7, count: 2),
      ["c", "b"], "count limits the walk")
eqArr(AutocompleteEngine.precedingWords(in: "пойд", caretUTF16Offset: 4, count: 2),
      [], "no context at the start")

print("Autocomplete context ranking")
let ctxBase = ["пойдем", "пойду", "пойдешь"]
let scored = AutocompleteEngine.suggestions(request: .init(
    partial: "пойд", languages: ["ru"], learned: ctxBase, limit: 3,
    mode: .context,
    contextScorer: { w in w == "пойду" ? 100 : 0 }))
eqArr(Array(scored.prefix(3)), ["пойду", "пойдем", "пойдешь"], "context scorer re-ranks the pool")
let unscored = AutocompleteEngine.suggestions(request: .init(
    partial: "пойд", languages: ["ru"], learned: ctxBase, limit: 3, mode: .context))
eqArr(unscored, ["пойдем", "пойду", "пойдешь"], "no scorer keeps the pool order")
let guessesOff = AutocompleteEngine.suggestions(request: .init(
    partial: "коф", languages: ["ru"], learned: [], limit: 5, mode: .context))
check(!guessesOff.contains("кафе"), "context mode does not use spelling guesses (коф -> кафе)")


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

print("TextIssue context capture")
let ctxIssues = LanguageToolEngine.issues(
    from: [LTMatch(offset: 4, length: 3, message: "m", shortMessage: "s", replacements: ["the"],
                   ruleId: "R", issueType: "misspelling", categoryId: "TYPOS")],
    text: "one teh two")
eq(ctxIssues[0].contextBefore, "one ", "context before captured (clipped at text start)")
eq(ctxIssues[0].contextAfter, " two", "context after captured (clipped at text end)")
let ctxMoved = ctxIssues[0].withRange(NSRange(location: 14, length: 3))
eq(ctxMoved.contextBefore, "one ", "withRange preserves contextBefore")
eq(ctxMoved.contextAfter, " two", "withRange preserves contextAfter")
check(ctxIssues[0].id == TextIssue(range: NSRange(location: 4, length: 3), kind: .spelling,
                                   shortMessage: "s", message: "m", replacements: ["the"],
                                   ruleId: "R", source: .languageTool, original: "teh").id,
      "identity does not depend on context")

print("IssueMerger.relocate with context")
// Build an issue the way the engine does, from the text it was checked against.
func ctxIssue(in text: String, location: Int, length: Int) -> TextIssue {
    LanguageToolEngine.issues(
        from: [LTMatch(offset: location, length: length, message: "", shortMessage: "",
                       replacements: [], ruleId: nil, issueType: nil, categoryId: nil)],
        text: text)[0]
}
// Two identical words; a prefix edit shifted everything. Context picks the right occurrence.
let dogTeh = ctxIssue(in: "teh cat teh dog", location: 8, length: 3)
check(IssueMerger.relocate(dogTeh, in: "X teh cat teh dog") == NSRange(location: 10, length: 3),
      "context relocates the right one of two identical words after a prefix edit")
// A different identical occurrence now sits at the old offset; context still finds the true one.
let aaTail = ctxIssue(in: "start aa end", location: 6, length: 2)
check(IssueMerger.relocate(aaTail, in: "aa xx start aa end") == NSRange(location: 12, length: 2),
      "context rejects a wrong identical word at a shifted position")
// The only occurrence in the window has completely different surroundings: refuse.
check(IssueMerger.relocate(dogTeh, in: "xxxxxxxx teh yyyyy") == nil,
      "a single occurrence with zero context agreement is stale (was wrongly accepted before)")
// Identical contexts on both candidates: genuinely ambiguous.
check(IssueMerger.relocate(ctxIssue(in: "ab teh cd", location: 3, length: 3),
                           in: "x ab teh cd ab teh cd") == nil,
      "two candidates with identical contexts stay ambiguous")
// Unchanged text with context still resolves to the same spot.
check(IssueMerger.relocate(dogTeh, in: "teh cat teh dog") == NSRange(location: 8, length: 3),
      "unchanged text with context relocates to the same range")

print("IssueMerger.shift by the applied range")
// The applier replaced at the RELOCATED range (10), not the stale stored one (4).
let shiftInput = [issue(2, 2, original: "aa"), issue(20, 3, original: "bbb")]
let shifted = IssueMerger.shift(shiftInput, replacedRange: NSRange(location: 10, length: 3),
                                replacementUTF16Length: 5)
check(shifted[0].range == NSRange(location: 2, length: 2),
      "issue before the applied range is untouched")
check(shifted[1].range == NSRange(location: 22, length: 3),
      "issue after the applied range slides by the exact delta")

print("UnderlineGeometry")
// Quartz -> AppKit flip. Primary screen 1000 pt tall; a rect whose top is 100 from the top ends up
// with its bottom at 1000 - 120 = 880 in AppKit coordinates.
let flipped = UnderlineGeometry.appKitRect(fromQuartz: CGRect(x: 10, y: 100, width: 50, height: 20),
                                           primaryScreenHeight: 1000)
check(flipped == CGRect(x: 10, y: 880, width: 50, height: 20), "quartz rect flips to AppKit")
// A window on a taller secondary display can have a negative AppKit y; the formula must not clamp.
let below = UnderlineGeometry.appKitRect(fromQuartz: CGRect(x: 0, y: 1190, width: 10, height: 20),
                                         primaryScreenHeight: 1000)
check(below.origin.y == -210, "conversion is unclamped for secondary-display geometry")

let squiggle = UnderlineGeometry.squigglePoints(width: 10, amplitude: 2, wavelength: 4)
check(squiggle.first == CGPoint(x: 0, y: 0), "squiggle starts at x = 0, baseline")
check(squiggle.last?.x == 10, "squiggle ends at x = width")
check(zip(squiggle, squiggle.dropFirst()).allSatisfy { $0.x < $1.x }, "x is strictly increasing")
check(squiggle.allSatisfy { $0.y == 0 || $0.y == 2 }, "y alternates between 0 and amplitude")
check(UnderlineGeometry.squigglePoints(width: 0, amplitude: 2, wavelength: 4).count == 2,
      "degenerate width yields just the endpoints")

check(UnderlineGeometry.isSingleLine(rangeRect: CGRect(x: 0, y: 0, width: 100, height: 16),
                                     probeRect: CGRect(x: 0, y: 0, width: 8, height: 16)),
      "equal heights are single-line")
check(!UnderlineGeometry.isSingleLine(rangeRect: CGRect(x: 0, y: 0, width: 100, height: 32),
                                      probeRect: CGRect(x: 0, y: 0, width: 8, height: 16)),
      "a doubled height (wrapped range) is not single-line")
check(!UnderlineGeometry.isSingleLine(rangeRect: CGRect(x: 0, y: 0, width: 100, height: 16),
                                      probeRect: .zero),
      "a zero probe rect is rejected")

print("ProofreadSupport")
check(!ProofreadSupport.verified.isEmpty, "the tested-apps table is not empty")
check(ProofreadSupport.verified.allSatisfy { !$0.bundleID.isEmpty && !$0.name.isEmpty },
      "every entry has a bundle id and a name")
check(Set(ProofreadSupport.verified.map(\.bundleID)).count == ProofreadSupport.verified.count,
      "bundle ids are unique")
check(ProofreadSupport.entry(for: "com.apple.TextEdit")?.name == "TextEdit",
      "lookup finds a listed app")
check(ProofreadSupport.entry(for: "com.example.unknown") == nil,
      "lookup returns nothing for an app that was never tested")

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

print("WordBoundary")
check(WordBoundary.wordRange(at: 2, in: "hello world") == NSRange(location: 0, length: 5),
      "caret mid-word finds the word")
check(WordBoundary.wordRange(at: 0, in: "hello world") == NSRange(location: 0, length: 5),
      "caret at word start finds the word")
check(WordBoundary.wordRange(at: 5, in: "hello world") == NSRange(location: 0, length: 5),
      "caret at word end (right edge click) finds the word just ended")
check(WordBoundary.wordRange(at: 6, in: "hello  world") == nil,
      "caret in whitespace between words finds nothing")
check(WordBoundary.wordRange(at: 0, in: "") == nil, "empty text finds nothing")
check(WordBoundary.wordRange(at: 999, in: "hello") == NSRange(location: 0, length: 5),
      "out-of-bounds caret is clamped to the end")
check(WordBoundary.wordRange(at: 5, in: "a😉bad end") == NSRange(location: 3, length: 3),
      "UTF-16 offsets stay correct past an emoji")
check(WordBoundary.wordRange(at: 3, in: "привет мир") == NSRange(location: 0, length: 6),
      "Cyrillic word found")
check(WordBoundary.wordRange(at: 9, in: "привет мир") == NSRange(location: 7, length: 3),
      "second Cyrillic word found")
check(WordBoundary.wordRange(at: 3, in: "don't stop") == NSRange(location: 0, length: 5),
      "apostrophe stays inside the word")
// Foundation segments "cat.dog" as a single word (hostname-style); pin that behaviour.
check(WordBoundary.wordRange(at: 4, in: "cat.dog") == NSRange(location: 0, length: 7),
      "dotted compound is treated as one word")
check(WordBoundary.wordRange(at: 3, in: "cat. dog") == NSRange(location: 0, length: 3),
      "caret before a sentence dot picks the preceding word")

print("IssueMerger.capReplacements")
let capIssue = TextIssue(range: NSRange(location: 0, length: 4), kind: .spelling,
                         shortMessage: "s", message: "m",
                         replacements: ["one", "two", "three", "four", "five"],
                         ruleId: nil, source: .languageTool, original: "orig")
let capped = IssueMerger.capReplacements([capIssue], limit: 3)
check(capped[0].replacements == ["one", "two", "three"], "cap 3 keeps the first three in order")
check(capped[0].id == capIssue.id, "capping preserves identity")
check(IssueMerger.capReplacements([capIssue], limit: 9)[0].replacements.count == 5,
      "cap larger than the list keeps everything")
check(IssueMerger.capReplacements([capIssue], limit: 0)[0].replacements == ["one"],
      "limit below 1 is clamped to 1")
check(IssueMerger.capReplacements([capIssue], limit: 99)[0].replacements.count == 5,
      "limit above 10 is clamped to 10 (list shorter anyway)")

print("Settings proofread and popup keys")
func decodeSettings(_ json: String) -> Settings {
    try! JSONDecoder().decode(Settings.self, from: json.data(using: .utf8)!)
}
let sDefaults = decodeSettings("{}")
check(sDefaults.proofreadMaxReplacements == 3, "missing key defaults max replacements to 3")
check(sDefaults.popupFontSize == 13, "missing key defaults the popup font size to 13")
// autocompleteFontSize is the old name; the setting now drives both popups.
check(decodeSettings(#"{"autocompleteFontSize": 17}"#).popupFontSize == 17,
      "legacy autocompleteFontSize key still honoured")
check(decodeSettings(#"{"autocompleteFontSize": 17, "popupFontSize": 11}"#).popupFontSize == 11,
      "new popupFontSize key wins over the legacy one")
// Keys of removed settings must not break decoding of everything else.
check(decodeSettings(#"{"proofreadAutoOnClick": false, "proofreadMaxReplacements": 5}"#).proofreadMaxReplacements == 5,
      "a removed key is ignored without losing the rest")
var sRound = Settings()
sRound.popupFontSize = 18
sRound.proofreadMaxReplacements = 7
let sBack = try! JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(sRound))
check(sBack.popupFontSize == 18 && sBack.proofreadMaxReplacements == 7,
      "encode/decode round-trip preserves the keys")
print("LanguageToolMode.defaultURL")
eq(LanguageToolMode.free.defaultURL ?? "", "https://api.languagetool.org/v2", "free presets the public URL")
eq(LanguageToolMode.premium.defaultURL ?? "", "https://api.languagetoolplus.com/v2", "premium presets the plus URL")
check(LanguageToolMode.selfHosted.defaultURL == nil, "self-hosted has no preset")

print("Settings.languageToolConnection")
var s = Settings()
s.languageToolUsername = "me@x.com"
s.languageToolBaseURL = "http://home.lan:8081/v2"

s.languageToolMode = .free
let free = s.languageToolConnection(token: "secret")
eq(free.baseURL, "http://home.lan:8081/v2", "free uses the (editable) stored URL")
check(free.username.isEmpty && free.apiKey.isEmpty, "free never sends credentials, even if filled in")

s.languageToolMode = .premium
let prem = s.languageToolConnection(token: "secret")
eq(prem.baseURL, "http://home.lan:8081/v2", "premium uses the stored URL")
eq(prem.username, "me@x.com", "premium sends the username")
eq(prem.apiKey, "secret", "premium sends the token")

s.languageToolMode = .selfHosted
let selfh = s.languageToolConnection(token: "secret")
eq(selfh.baseURL, "http://home.lan:8081/v2", "self-hosted uses the user URL")
eq(selfh.apiKey, "secret", "self-hosted forwards the token when present")

print("Settings default and resilient decoding")
func decode(_ json: String) -> Settings {
    try! JSONDecoder().decode(Settings.self, from: Data(json.utf8))
}
check(decode("{}").languageToolMode == .free, "mode defaults to free when absent (no migration)")
check(decode("{\"languageToolMode\":\"premium\"}").languageToolMode == .premium, "a stored mode is kept")
check(decode("{\"autocompleteHorizontal\":true}").autocompleteLayout == .line,
      "legacy autocompleteHorizontal=true maps to line")
check(decode("{\"autocompleteHorizontal\":false}").autocompleteLayout == .column,
      "legacy autocompleteHorizontal=false maps to column")
check(decode("{\"autocompleteLayout\":\"tile\"}").autocompleteLayout == .tile,
      "the new autocompleteLayout wins over the legacy key")
check(decode("{}").proofreadLayout == .column, "proofread layout defaults to column")

print("PopupLayout tile grid")
check(PopupLayout.tileColumns(forCount: 1) == 1, "one item: one column")
check(PopupLayout.tileColumns(forCount: 2) == 1, "two items: one column")
check(PopupLayout.tileColumns(forCount: 3) == 2, "three items: two columns")
check(PopupLayout.tileColumns(forCount: 5) == 3, "five items: three columns")
check(PopupLayout.tileColumns(forCount: 6) == 3, "six items: three columns")
// Horizontal movement walks row-major order and wraps.
check(PopupLayout.tileIndex(from: 0, deltaX: 1, deltaY: 0, count: 5) == 1, "tile right")
check(PopupLayout.tileIndex(from: 2, deltaX: 1, deltaY: 0, count: 5) == 3, "tile right crosses rows")
check(PopupLayout.tileIndex(from: 4, deltaX: 1, deltaY: 0, count: 5) == 0, "tile right wraps")
check(PopupLayout.tileIndex(from: 0, deltaX: -1, deltaY: 0, count: 5) == 4, "tile left wraps")
// Vertical movement steps a whole row and clamps at the ends.
check(PopupLayout.tileIndex(from: 0, deltaX: 0, deltaY: 1, count: 5) == 3, "tile down row 0 -> row 1")
check(PopupLayout.tileIndex(from: 1, deltaX: 0, deltaY: 1, count: 5) == 4, "tile down col 2")
check(PopupLayout.tileIndex(from: 2, deltaX: 0, deltaY: 1, count: 5) == 4, "tile down clamps at the end")
check(PopupLayout.tileIndex(from: 3, deltaX: 0, deltaY: -1, count: 5) == 0, "tile up row 1 -> row 0")
check(PopupLayout.tileIndex(from: 4, deltaX: 0, deltaY: -1, count: 5) == 1, "tile up col 2")
check(PopupLayout.tileIndex(from: 0, deltaX: 0, deltaY: -1, count: 5) == 0, "tile up clamps at the start")
check(PopupLayout.tileIndex(from: 3, deltaX: 1, deltaY: 0, count: 2) == 0, "tile wraps in a one-column grid")
// A width-measured first row changes the vertical jump, not the horizontal walk.
check(PopupLayout.tileIndex(from: 0, deltaX: 0, deltaY: 1, count: 6, topRowCount: 4) == 4,
      "measured top row: down lands under the same column")
check(PopupLayout.tileIndex(from: 1, deltaX: 0, deltaY: 1, count: 6, topRowCount: 4) == 5,
      "measured top row: down col 2")
check(PopupLayout.tileIndex(from: 2, deltaX: 0, deltaY: 1, count: 6, topRowCount: 4) == 5,
      "measured top row: down clamps when the second row is shorter")
check(PopupLayout.tileIndex(from: 5, deltaX: 0, deltaY: -1, count: 6, topRowCount: 4) == 1,
      "measured top row: up col 2")
check(PopupLayout.tileIndex(from: 4, deltaX: 1, deltaY: 0, count: 6, topRowCount: 4) == 5,
      "measured top row: horizontal walk unchanged")
check(PopupLayout.tileIndex(from: 5, deltaX: 1, deltaY: 0, count: 6, topRowCount: 4) == 0,
      "measured top row: horizontal wraps")
check(PopupLayout.tileIndex(from: 0, deltaX: 0, deltaY: 1, count: 6) == 3,
      "default topRowCount keeps the even split")

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
