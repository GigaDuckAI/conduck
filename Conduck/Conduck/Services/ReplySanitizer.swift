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

import Foundation

/// Strips Markdown from an agent reply so it reads naturally through TTS.
enum ReplySanitizer {

    /// Convert a Markdown reply into plain speakable text.
    ///
    /// Transformations (in application order):
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
        var working = text

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
    static func linkCollapsed(_ text: String) -> String {
        text.replacingMatches(of: "!?\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1")
    }

    // MARK: - 1. Fenced code blocks

    /// Replace ```` ```lang\n…\n``` ```` (and `~~~` fences) with "[code block]".
    /// Matched non-greedily, multiline, dot-matches-newline so the body spans
    /// lines. The optional language hint after the opening fence is consumed.
    private static func replaceFencedCodeBlocks(in text: String) -> String {
        let patterns = [
            "```[^\\n]*\\n[\\s\\S]*?```",   // ``` fences with content
            "```[^\\n]*```",                 // single-line ``` fence
            "~~~[^\\n]*\\n[\\s\\S]*?~~~",   // ~~~ fences with content
        ]
        var result = text
        for pattern in patterns {
            result = result.replacingMatches(of: pattern, with: "[code block]")
        }
        return result
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
            current = current.replacingMatches(
                of: "^[ \\t]*#{1,6}[ \\t]+", with: ""
            )

            // Blockquote: one or more leading `>` (with optional spaces). Keep
            // the quoted text. Repeated to peel nested `> > `.
            while let stripped = try? current.replacingFirstMatch(
                of: "^[ \\t]*>[ \\t]?", with: ""
            ), stripped != current {
                current = stripped
            }

            // List marker: leading `- ` / `* ` / `+ ` (unordered) or `1. ` /
            // `1) ` (ordered). Keep the item text; drop the bullet.
            current = current.replacingMatches(
                of: "^[ \\t]*([-*+]|\\d+[.)])[ \\t]+", with: ""
            )

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
        var result = text

        // Links: [label](url) → label. Image links ![alt](url) → alt (the
        // leading `!` is dropped by leaving the alt text only).
        result = result.replacingMatches(
            of: "!?\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1"
        )

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
            .map { line in
                line.replacingMatches(of: "[ \\t]+$", with: "")
            }
        var joined = trimmedLines.joined(separator: "\n")

        // Collapse runs of 3+ newlines (i.e. 2+ blank lines) into exactly two
        // (one blank line).
        joined = joined.replacingMatches(of: "\\n{3,}", with: "\n\n")

        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(
            in: self, range: range, withTemplate: template
        )
    }

    /// Replace only the FIRST match. Throws if the pattern fails to compile so
    /// the caller's loop can distinguish "no change" from "compile error".
    func replacingFirstMatch(of pattern: String, with template: String) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(
            in: self,
            range: NSRange(startIndex..<endIndex, in: self)
        ) else {
            return self
        }
        return regex.stringByReplacingMatches(
            in: self,
            range: match.range,
            withTemplate: template
        )
    }
}
