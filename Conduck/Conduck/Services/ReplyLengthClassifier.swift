// Conduck
// ReplyLengthClassifier.swift
//
// Pure, platform-neutral classification of an agent reply for the macOS
// menu-bar popover's long-reply presentation. The popover is a GLANCE surface
// (300pt wide, capped scroll); a long or code-heavy answer reads far better in
// the full window, so the popover shows a faded preview + a prominent
// "Open in Window" CTA for those. This helper is the testable predicate behind
// that decision (the height side is measured in the view; this owns the
// content side). Unit-tested by `ReplyLengthClassifierTests`.

import Foundation

enum ReplyLengthClassifier {
    /// True when the reply contains a fenced code block (``` ``` ``` or `~~~`
    /// at the start of a line). Fenced code overflows / wraps badly at the
    /// popover's 300pt width regardless of height, so it always routes to the
    /// "read in window" treatment. Mirrors the fence shapes `ReplySanitizer`
    /// recognises (kept here as a standalone predicate — that one's matcher is
    /// private and replaces, this one just detects).
    ///
    /// WHY THIS IS A LINE WALK AND NOT A REGEX: the previous predicate was
    /// `(?m)^\s*```` (plus the `~~~` twin), and `\s` matches `\n` — so at every
    /// one of the O(n) line starts, ICU expanded `\s*` across the whole remaining
    /// whitespace run and then backtracked looking for the fence. On reply text
    /// that has NO fence that is O(n²): measured (`swiftc -O`, arm64) 8 000
    /// newlines = 2.1 s, 16 000 = 8.3 s. Reply text is UNTRUSTED (a hostile
    /// gateway, or a prompt-injected agent on an honest one) and unbounded, and
    /// this runs on the main actor from `DictationPopoverView` every time a reply
    /// renders in the macOS menu-bar popover — so a reply of blank lines froze it.
    ///
    /// EQUIVALENCE: `(?m)^\s*```` asks "is there a line start from which only
    /// whitespace separates us from a fence". This carries that exact question
    /// forward in a single scalar pass as `atCleanLineStart` — "every scalar since
    /// the current line start has been whitespace" — and answers yes the first time
    /// a fence sits at such a position. `^` in ICU's multiline mode starts a new
    /// line after ANY Unicode line terminator, not just `\n`, so
    /// `lineTerminators` enumerates them rather than splitting on `\n` (splitting
    /// misses `"a\r   ```"`, which the regex does match).
    /// Differential-tested against the original pattern in
    /// `ReplyLengthClassifierTests`.
    ///
    /// WHY IT WALKS THE VIEW'S INDICES AND NEVER `Array(text.unicodeScalars)`:
    /// the reply is untrusted and length-unbounded (the only ceiling left is the
    /// 16 MiB background-response cap), a materialized scalar array costs 4 bytes
    /// per scalar, and this runs from `DictationPopoverView` on EVERY body
    /// evaluation. A predicate that answers yes/no has no business allocating a
    /// second copy of the reply to do it — the walk below allocates nothing and
    /// returns at the first fence. `ReplySanitizer.collapseMarkdownLinks` scans
    /// the same way for the same reason; keep them consistent.
    static func containsFencedCode(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        let end = scalars.endIndex
        var atCleanLineStart = true
        var index = scalars.startIndex
        while index < end {
            let scalar = scalars[index]
            // Three IDENTICAL fence scalars at a clean line start. Checked before
            // the line-start bookkeeping below so a fence is never disqualified
            // by its own first backtick.
            if atCleanLineStart, scalar == "`" || scalar == "~" {
                let second = scalars.index(after: index)
                if second < end, scalars[second] == scalar {
                    let third = scalars.index(after: second)
                    if third < end, scalars[third] == scalar { return true }
                }
            }
            if lineTerminators.contains(scalar.value) {
                atCleanLineStart = true
            } else if !scalar.properties.isWhitespace {
                atCleanLineStart = false
            }
            index = scalars.index(after: index)
        }
        return false
    }

    /// The scalars after which ICU's multiline `^` begins a new line: LF, VT, FF,
    /// CR, NEL, LINE SEPARATOR, PARAGRAPH SEPARATOR. Handled explicitly (rather
    /// than via `isWhitespace`) because VT and NEL are Unicode `White_Space` but
    /// are NOT in ICU's `\s` — so only their line-start role makes the two agree.
    private static let lineTerminators: Set<UInt32> = [
        0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029,
    ]

    /// Whether the reply warrants the long-reply treatment (faded preview +
    /// prominent "Open in Window" CTA). `measuredHeight` is the reply Markdown's
    /// natural height as measured in the popover; `cap` is the popover's scroll
    /// cap (content taller than the cap is scrolled, i.e. "there's more"). A
    /// fenced code block always qualifies.
    static func isLong(text: String, measuredHeight: CGFloat, cap: CGFloat) -> Bool {
        measuredHeight > cap || containsFencedCode(text)
    }
}
