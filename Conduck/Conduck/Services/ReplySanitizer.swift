// Conduck
// ReplySanitizer.swift
//
// Shared text-to-speech preparation. Agent replies arrive as Markdown (the
// gateway's upstream LLM renders ` **bold** `, fenced code, links, lists,
// headings, emoji). Feeding raw Markdown into `AVSpeechSynthesizer` makes it
// read literal asterisks, backticks, URLs, and emoji aloud — jarring on
// hands-busy surfaces. `ReplySanitizer.spoken(_:)` strips the markup while
// keeping the human-meaningful inner text, so every speaking surface
// (CarPlay · macOS auto-speak · Watch) shares ONE canonical strip.
//
// This is intentionally pure Foundation (no `AVFoundation`, no platform
// import) so it compiles into every target — including the watchOS app —
// and is trivially unit-testable. It transforms text only; it does not
// synthesize speech.
//
// Scope: a pragmatic Markdown-for-speech strip, NOT a spec-complete Markdown
// parser. It handles the constructs LLM replies actually emit. Order matters:
// fenced code blocks are replaced first (so their inner backticks/asterisks
// aren't mistaken for inline markup), then line-level prefixes, then inline
// spans, then emoji, then whitespace collapse.
//
// ─────────────────────────────────────────────────────────────────────────────
// UNTRUSTED INPUT — COST BOUNDS ARE LOAD-BEARING
//
// Every caller runs on the MAIN ACTOR (`ConversationListView`'s preview row,
// `WatchConversationThreadView`'s bubble inside `body`, `CarPlaySpeechService` /
// `ReplyVoice` / `WatchReplySpeaker` before a speak boundary), and the input is
// agent reply text: adversary-controlled (a hostile gateway, or an
// honest gateway whose agent was prompt-injected by a shared web page) and
// length-unbounded. A regex whose cost is superlinear in that length is
// therefore a remote main-thread freeze, and the reply is persisted +
// CloudKit-synced BEFORE it renders — so the freeze reproduces on every device
// every time the row appears, with the delete affordance sitting behind the
// frozen surface. Three shapes here were superlinear; the fix for each is
// stated at its call site, and each keeps its match extent BYTE-IDENTICAL:
//
//   1. `[label](url)` — `!?\[([^\]]*)\]\([^)]*\)` backtracks O(n²) over a run
//      of unmatched `[` (measured, `swiftc -O` arm64: 8 KB → 0.62 s, 32 KB →
//      10.1 s). Replaced by `collapseMarkdownLinks`, a one-pass scanner proved
//      equivalent to that exact pattern (`ReplySanitizerLinkScannerTests`).
//   2. `[ \t]+$` per line — the WORST of the three: 8 KB of spaces followed by
//      one letter = 5.9 s, 32 KB = 101 s. Replaced by a linear trailing trim.
//   3. The two MULTI-LINE fenced-code patterns — cost is (fence markers) ×
//      (line length), so one long line of ` ``` ` is quadratic (12 KB →
//      0.54 s). Pattern kept verbatim, guarded by `maxFenceMarkerScalars`.
//
// The remaining patterns were measured linear at 32 KB of their own worst-case
// input (emphasis / inline code / strikethrough: ≤ 0.7 ms each), and
// `maxSpokenInputCount` bounds what any of them can ever see.

import Foundation

/// Strips Markdown from an agent reply so it reads naturally through TTS.
enum ReplySanitizer {

    // MARK: - Cost bounds

    /// Input ceiling for the FULL strip (`spoken`). A reply longer than this is
    /// spoken up to the last word boundary at the ceiling; the on-screen text is
    /// untouched, and `linkCollapsed` (the display variant) has no ceiling at
    /// all. 20 000 characters is ~3 300 words ≈ 22 minutes of continuous
    /// synthesis — an order of magnitude past any reply a user listens through,
    /// and `SpeechSegmenter` chunks whatever it receives anyway, so the ceiling
    /// costs nothing on real content while bounding every pass below.
    nonisolated static let maxSpokenInputCount = 20_000

    /// Window searched backwards from `maxSpokenInputCount` for a whitespace
    /// break, so the ceiling never clips mid-word (a clipped word reads as a
    /// glitch). One unbroken 20 000-character token has no break and takes the
    /// hard cut.
    nonisolated static let spokenCutBackoffCount = 200

    /// Budget for ` ``` ` / `~~~` scalars before the two MULTI-LINE fenced-code
    /// patterns are skipped. Their cost is (marker count) × (line length), so
    /// this bounds the pass to ≤ 512 × `maxSpokenInputCount` character steps
    /// (~0.1 s). 512 markers is ~85 fenced blocks, or ~250 inline-code spans,
    /// in ONE reply — far past real content. Over budget, a multi-line fenced
    /// body is read aloud instead of collapsing to "[code block]": degraded
    /// speech, never a freeze, and single-line fences still collapse.
    nonisolated static let maxFenceMarkerScalars = 512

    // MARK: - Compiled-once patterns
    //
    // These three run PER LINE. Compiling them inside the loop made a reply
    // with N lines pay 3N ICU compiles, and the blockquote peel paid one more
    // per `>` marker.

    nonisolated private static let headingPrefixRegex =
        try? NSRegularExpression(pattern: "^[ \\t]*#{1,6}[ \\t]+")
    nonisolated private static let blockquotePrefixRegex =
        try? NSRegularExpression(pattern: "^[ \\t]*>[ \\t]?")
    nonisolated private static let listPrefixRegex =
        try? NSRegularExpression(pattern: "^[ \\t]*([-*+]|\\d+[.)])[ \\t]+")

    /// Convert a Markdown reply into plain speakable text.
    ///
    /// Transformations (in application order):
    ///   0. Input bounded to `maxSpokenInputCount` (see Cost Bounds).
    ///   1. Fenced code blocks ```` ```…``` ```` → the literal "[code block]".
    ///   2. Line-level prefixes per line: heading `#`…, blockquote `> `,
    ///      and leading list markers (`- `, `* `, `+ `, `1. `).
    ///   3. Inline spans: `[label](url)` → `label`; `` `code` `` → `code`;
    ///      `**bold**` / `__bold__` / `*italic*` / `_italic_` → inner text.
    ///   4. Emoji (any scalar with the `Emoji_Presentation` property, plus
    ///      common zero-width joiners / variation selectors) → removed.
    ///   5. Whitespace collapse: trailing spaces trimmed per line, runs of
    ///      blank lines collapsed to a single blank line, leading/trailing
    ///      whitespace of the whole string trimmed.
    static func spoken(_ text: String) -> String {
        var working = boundedSpokenInput(text)

        working = replaceFencedCodeBlocks(in: working)
        working = stripLinePrefixes(in: working)
        working = stripInlineSpans(in: working)
        working = stripEmoji(from: working)
        working = collapseWhitespace(in: working)

        return working
    }

    /// DISPLAY variant for plaintext surfaces (Watch reply bubbles, the
    /// conversation-list preview line): collapse Markdown links ONLY —
    /// `[label](url)` / `![alt](url)` → `label` — leaving every other construct
    /// verbatim. A raw link target is the one construct that actively harms a
    /// glance surface: it's unreadable line-wrapped noise, and an agent's file
    /// link can carry its host-side filesystem path (e.g.
    /// `[poem.md](/Users/…/poem.md)`). The FULL strip stays TTS-only —
    /// flattening emphasis/structure is a speech need, not a display one.
    ///
    /// Deliberately UNCAPPED: `collapseMarkdownLinks` is one linear pass that
    /// allocates nothing unless it actually collapses a link, so the Watch bubble
    /// keeps rendering the whole reply (truncating it there would hide content
    /// with no other route to it on the wrist) at a per-evaluation cost that does
    /// not scale beyond the scan itself.
    static func linkCollapsed(_ text: String) -> String {
        collapseMarkdownLinks(in: text)
    }

    // MARK: - 0. Input bound

    /// Clamp the full strip's input to `maxSpokenInputCount`, cutting on the
    /// last whitespace inside `spokenCutBackoffCount` so the ceiling lands
    /// between words. Returns the input untouched when it is already inside the
    /// ceiling (the case for every real reply).
    private static func boundedSpokenInput(_ text: String) -> String {
        guard text.count > maxSpokenInputCount else { return text }
        let head = text.prefix(maxSpokenInputCount)
        let tail = head.suffix(spokenCutBackoffCount)
        if let breakIndex = tail.lastIndex(where: { $0.isWhitespace }) {
            return String(head[head.startIndex..<breakIndex])
        }
        return String(head)
    }

    // MARK: - 1. Fenced code blocks

    /// Replace ```` ```lang\n…\n``` ```` (and `~~~` fences) with "[code block]".
    /// Matched non-greedily, multiline, dot-matches-newline so the body spans
    /// lines. The optional language hint after the opening fence is consumed.
    ///
    /// The two MULTI-LINE patterns are gated on `maxFenceMarkerScalars` — their
    /// `[^\n]*` re-scans the rest of the line from EVERY fence marker, so one
    /// long line of ` ``` ` is quadratic. The marker budget is measured ONCE on
    /// the input: the passes only ever REMOVE markers, so an in-budget input is
    /// still in budget by the time the `~~~` pass runs. The single-line pattern
    /// needs no gate (it matches as soon as a second fence exists, so it cannot
    /// accumulate failing start positions) and always runs, which keeps the
    /// over-budget degradation to multi-line bodies only.
    private static func replaceFencedCodeBlocks(in text: String) -> String {
        let scansMultiLine = fenceMarkerScalarCount(in: text) <= maxFenceMarkerScalars
        var result = text
        if scansMultiLine {
            result = result.replacingMatches(
                of: "```[^\\n]*\\n[\\s\\S]*?```", with: "[code block]"   // ``` fences with content
            )
        }
        result = result.replacingMatches(
            of: "```[^\\n]*```", with: "[code block]"                     // single-line ``` fence
        )
        if scansMultiLine {
            result = result.replacingMatches(
                of: "~~~[^\\n]*\\n[\\s\\S]*?~~~", with: "[code block]"   // ~~~ fences with content
            )
        }
        return result
    }

    /// Count of backtick + tilde scalars, short-circuited the moment the budget
    /// is blown (the exact value past that point is not needed).
    private static func fenceMarkerScalarCount(in text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars where scalar == "`" || scalar == "~" {
            count += 1
            if count > maxFenceMarkerScalars { return count }
        }
        return count
    }

    // MARK: - 2. Line-level prefixes

    /// Strip per-line Markdown prefixes (headings, blockquotes, list markers).
    /// Applied line-by-line so a `#`/`-`/`>` mid-sentence is never touched.
    private static func stripLinePrefixes(in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let cleaned = lines.map { line -> String in
            var current = line

            // Heading: leading optional whitespace + 1–6 `#` + at least one
            // space. Keep the heading text.
            current = current.replacingMatches(of: headingPrefixRegex, with: "")

            // Blockquote: one or more leading `>` (with optional spaces). Keep
            // the quoted text. Repeated to peel nested `> > `.
            if let regex = blockquotePrefixRegex {
                while let stripped = current.replacingFirstMatch(of: regex, with: ""),
                      stripped != current {
                    current = stripped
                }
            }

            // List marker: leading `- ` / `* ` / `+ ` (unordered) or `1. ` /
            // `1) ` (ordered). Keep the item text; drop the bullet.
            current = current.replacingMatches(of: listPrefixRegex, with: "")

            return current
        }
        return cleaned.joined(separator: "\n")
    }

    // MARK: - 3. Inline spans

    /// Strip inline Markdown spans, keeping inner text. Order: links first
    /// (so a `[text](url)` isn't mangled by emphasis/code passes), then inline
    /// code, then bold (double markers) before italic (single markers) so
    /// `**x**` doesn't get half-eaten by the italic rule.
    private static func stripInlineSpans(in text: String) -> String {
        // Links: [label](url) → label. Image links ![alt](url) → alt (the
        // leading `!` is dropped by leaving the alt text only). Linear scanner,
        // not a regex — see `collapseMarkdownLinks`.
        var result = collapseMarkdownLinks(in: text)

        // Inline code: `code` → code. Non-greedy between single backticks,
        // no embedded backtick or newline.
        result = result.replacingMatches(
            of: "`([^`\\n]+)`", with: "$1"
        )

        // Bold: **text** or __text__ → text. Run before italic.
        result = result.replacingMatches(
            of: "\\*\\*([^*]+?)\\*\\*", with: "$1"
        )
        result = result.replacingMatches(
            of: "__([^_]+?)__", with: "$1"
        )

        // Italic: *text* or _text_ → text.
        result = result.replacingMatches(
            of: "\\*([^*\\n]+?)\\*", with: "$1"
        )
        result = result.replacingMatches(
            of: "_([^_\\n]+?)_", with: "$1"
        )

        // Strikethrough: ~~text~~ → text (cheap, LLMs occasionally emit it).
        result = result.replacingMatches(
            of: "~~([^~]+?)~~", with: "$1"
        )

        return result
    }

    // MARK: - Markdown link collapse (linear, regex-equivalent)

    /// One-pass equivalent of `stringByReplacingMatches` for the pattern
    /// `!?\[([^\]]*)\]\([^)]*\)` with template `$1`. Same matches, same extents,
    /// same captures — O(n) instead of O(n²).
    ///
    /// WHY the regex had to go: `[^\]]*` followed by a required `\]` is the
    /// canonical catastrophic-backtracking shape, so a reply of unmatched `[`
    /// characters costs O(n) per start position over O(n) start positions
    /// (measured `swiftc -O`, arm64: 8 KB → 0.62 s, 16 KB → 2.52 s, 32 KB →
    /// 10.1 s), on the main actor, on the conversation-list row that mounts as
    /// the iPad/macOS split-view sidebar at launch. Bounding the quantifiers
    /// instead was rejected: `[^)\s]` would stop matching `[label](url "title")`
    /// (valid Markdown that LLMs emit), leaking raw markup into Watch bubbles
    /// and TTS — a correctness regression in the exact code that exists to
    /// prevent it.
    ///
    /// WHY it is equivalent, term by term:
    ///   • `[^\]]*\]` — `]` is excluded from the class, so greedy-plus-backtrack
    ///     can only ever settle on the FIRST `]` after the `[`. Same for
    ///     `[^)]*\)` and the first `)`. Both are therefore deterministic scans,
    ///     not searches.
    ///   • `!?` is greedy, so when the character immediately before the `[` is
    ///     `!` (and still inside the unconsumed region) the match starts there —
    ///     that position is strictly leftmost, which is the one ICU picks.
    ///   • On failure the scan resumes at `close + 1`, skipping the `[`
    ///     characters in between: each of those has the SAME first `]` (there is
    ///     none in between, by definition of first), so ICU fails on them
    ///     identically. This skip is what makes the pass linear.
    ///   • A missing `]` (or a missing `)` after a `(`) means no LATER start
    ///     position can match either, so the scan stops outright.
    ///
    /// Operates on unicode scalars to keep ICU's UTF-16 view of the ASCII
    /// delimiters: a combining mark that fuses with a `[` into one `Character`
    /// must not hide the bracket. Cut points are always at ASCII scalars, so no
    /// copied run ever splits a surrogate pair.
    ///
    /// WHY IT WALKS `String.UnicodeScalarView` INDICES AND NEVER
    /// `Array(text.unicodeScalars)`: this is the DISPLAY path, and its most
    /// constrained caller is the Watch reply bubble — inside `body`, so it re-runs
    /// on every view evaluation, on the device with the least memory headroom. The
    /// input is untrusted and length-unbounded (the only ceiling left is the
    /// 16 MiB background-response cap), and a materialized scalar array costs
    /// 4 bytes per scalar on top of the string it was copied from. The view's own
    /// indices give the same deterministic scan with ZERO added allocation: a
    /// reply with no collapsible link (the overwhelming majority, and every reply
    /// at all once the `[` bail and the `matched` bail are counted) now allocates
    /// nothing whatsoever. What remains is the output string itself, which is
    /// inherent — the wrist bubble is the only route to a long reply's text, so
    /// this function must return all of it (`testLinkCollapsedHasNoCeiling`).
    ///
    /// A LENGTH CAP WAS REJECTED for the same reason bounding the regex's
    /// quantifiers was: skipping the collapse past some size leaves raw
    /// `[label](target)` markup on screen — wrap-noise on a 40mm line, and the
    /// target can carry the gateway host's filesystem path — i.e. a regression in
    /// the exact code that exists to prevent it, just gated on a length the
    /// adversary picks.
    ///
    /// Differential-tested against the live regex in
    /// `ReplySanitizerLinkScannerTests`.
    private static func collapseMarkdownLinks(in text: String) -> String {
        // Allocation-free bail for the common link-free reply: no `[`, no match.
        guard text.utf8.contains(UInt8(ascii: "[")) else { return text }

        let scalars = text.unicodeScalars
        let end = scalars.endIndex

        var output = String.UnicodeScalarView()
        var emitted = scalars.startIndex   // scalars[..<emitted] already copied out
        var search = scalars.startIndex    // next index to look for an opening `[` from
        var matched = false

        while search < end {
            guard let open = scalars[search...].firstIndex(of: "[") else { break }
            let afterOpen = scalars.index(after: open)
            // No `]` in the remainder ⇒ no match here and none later.
            guard let close = scalars[afterOpen...].firstIndex(of: "]") else { break }
            let afterClose = scalars.index(after: close)
            guard afterClose < end, scalars[afterClose] == "(" else {
                // Every `[` between `open` and `close` resolves to this same
                // `]` and fails the same way — resume past it.
                search = afterClose
                continue
            }
            // No `)` in the remainder ⇒ no match here and none later.
            let afterParen = scalars.index(after: afterClose)
            guard let closeParen = scalars[afterParen...].firstIndex(of: ")") else { break }

            var start = open
            if open > emitted, scalars[scalars.index(before: open)] == "!" {
                start = scalars.index(before: open)
            }
            output.append(contentsOf: scalars[emitted..<start])     // text before the link
            output.append(contentsOf: scalars[afterOpen..<close])   // the `$1` capture (label)
            emitted = scalars.index(after: closeParen)
            search = emitted
            matched = true
        }

        guard matched else { return text }
        output.append(contentsOf: scalars[emitted..<end])
        return String(output)
    }

    // MARK: - 4. Emoji

    /// Remove emoji and their joiners/modifiers. A scalar is dropped when it
    /// carries the Unicode `Emoji_Presentation` property (the
    /// default-presented-as-emoji set), or is a skin-tone modifier, a
    /// variation selector (`U+FE0F`/`U+FE0E`), a zero-width joiner, or a
    /// regional-indicator (flag) symbol. Plain text scalars are kept.
    private static func stripEmoji(from text: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isEmojiScalar(scalar) { continue }
            output.append(scalar)
        }
        return String(output)
    }

    private static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isEmojiPresentation { return true }

        switch scalar.value {
        case 0x200D,                 // zero-width joiner
             0xFE0E, 0xFE0F,         // variation selectors (text / emoji)
             0x1F3FB...0x1F3FF,      // skin-tone modifiers
             0x1F1E6...0x1F1FF:      // regional indicators (flags)
            return true
        default:
            return false
        }
    }

    // MARK: - 5. Whitespace collapse

    /// Trim trailing whitespace per line, collapse 2+ consecutive blank lines
    /// into one, and trim the whole string. Single newlines (intra-paragraph)
    /// are preserved so the synthesizer keeps natural sentence pacing.
    private static func collapseWhitespace(in text: String) -> String {
        // Trim trailing spaces/tabs on every line.
        let trimmedLines = text
            .components(separatedBy: "\n")
            .map { trimmingTrailingSpacesAndTabs($0) }
        var joined = trimmedLines.joined(separator: "\n")

        // Collapse runs of 3+ newlines (i.e. 2+ blank lines) into exactly two
        // (one blank line).
        joined = joined.replacingMatches(of: "\\n{3,}", with: "\n\n")

        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drop the maximal run of trailing spaces/tabs — the exact effect of
    /// `[ \t]+$` on a newline-free line, in one linear pass.
    ///
    /// WHY not the regex: `[ \t]+$` is the most expensive shape in this file.
    /// `$` (no `.anchorsMatchLines`) means end-of-string, so a long run of
    /// spaces that does NOT end the line makes ICU expand the class fully and
    /// then retry every shorter expansion, from every start position — measured
    /// `swiftc -O`, arm64: 8 KB of spaces + one letter = 5.9 s, 16 KB = 24.5 s,
    /// 32 KB = 101 s. It ran on every line of untrusted reply text, so a reply
    /// of N such lines multiplied that. Equivalence: the class holds only ASCII
    /// space/tab, and a space fused with a combining mark is neither a match for
    /// `[ \t]` under ICU (the mark would have to satisfy `$`) nor equal to `" "`
    /// as a `Character` — both leave it in place.
    private static func trimmingTrailingSpacesAndTabs(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let previous = line.index(before: end)
            guard line[previous] == " " || line[previous] == "\t" else { break }
            end = previous
        }
        return end == line.endIndex ? line : String(line[line.startIndex..<end])
    }
}

// MARK: - Regex helpers

private extension String {
    /// Replace every match of a regex `pattern` with `template`
    /// (`$1`…-style capture references supported). Falls back to the
    /// unmodified string if the pattern fails to compile (it won't for the
    /// literals above — defensive only).
    func replacingMatches(of pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return self
        }
        return replacingMatches(of: regex, with: template)
    }

    /// Compiled-regex overload for the PER-LINE patterns, which must not pay an
    /// ICU compile per line. A nil regex (compile failed at init) leaves the
    /// string unmodified — same defensive posture as the pattern overload.
    func replacingMatches(of regex: NSRegularExpression?, with template: String) -> String {
        guard let regex else { return self }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(
            in: self, range: range, withTemplate: template
        )
    }

    /// Replace only the FIRST match. Returns nil when the regex does not match,
    /// so the caller's peel loop can distinguish "no change" from a rewrite
    /// without comparing strings first.
    func replacingFirstMatch(of regex: NSRegularExpression, with template: String) -> String? {
        guard let match = regex.firstMatch(
            in: self,
            range: NSRange(startIndex..<endIndex, in: self)
        ) else {
            return nil
        }
        return regex.stringByReplacingMatches(
            in: self,
            range: match.range,
            withTemplate: template
        )
    }
}
