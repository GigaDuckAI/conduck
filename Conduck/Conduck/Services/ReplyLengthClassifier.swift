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
    static func containsFencedCode(_ text: String) -> Bool {
        for pattern in ["(?m)^\\s*```", "(?m)^\\s*~~~"] {
            if text.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// Whether the reply warrants the long-reply treatment (faded preview +
    /// prominent "Open in Window" CTA). `measuredHeight` is the reply Markdown's
    /// natural height as measured in the popover; `cap` is the popover's scroll
    /// cap (content taller than the cap is scrolled, i.e. "there's more"). A
    /// fenced code block always qualifies.
    static func isLong(text: String, measuredHeight: CGFloat, cap: CGFloat) -> Bool {
        measuredHeight > cap || containsFencedCode(text)
    }
}
