// Conduck — ConduckShareExtension (appex)
// WebPageCapture.swift
//
// ⚠️ VERBATIM MIRROR of `ConduckShareExtensionMac/WebPageCapture.swift` (the
// CANONICAL copy — that one is ALSO compiled into the main Conduck app target
// via an explicit pbxproj file reference, the `ShareTargetFilter` precedent,
// so the drainer + `ConduckTests` resolve it there). Separate compilation
// modules, one source file each — no cross-target membership for this appex.
//
// KEEP THE TWO FILES BYTE-IDENTICAL BELOW THEIR HEADERS — the parse/truncate/
// filename behavior here IS the cross-process contract with the drainer.
// Drift guard: `ConduckTests/WebPageCaptureTests`.
//
// The doc comments below are the canonical file's, kept verbatim for diffability.

import Foundation

/// Pure parse/format/truncate logic for a Safari page-text capture. Stateless
/// namespace — every entry point is a pure function of its inputs, so the
/// appex writer and the drainer reader share ONE tested behavior.
enum WebPageCapture {

    // MARK: - Constants (paired literals)

    /// Hard cap (bytes of UTF-8) on the captured text. Enforced TWICE on
    /// purpose: the appex's `ConduckWebCapture.js` truncates to its own
    /// `MAX_BYTES = 131072` literal before calling `completionFunction` (the
    /// JS cannot read a Swift constant), and `parse(_:)` re-clamps to THIS
    /// constant because the JS output is UNTRUSTED input — any page script
    /// could have replaced the bridge payload. `Constants
    /// .webPageCaptureMaxBytes` carries the same value for main-app
    /// discoverability; a guard test pins all the literals equal.
    static let maxCaptureBytes = 128 * 1024

    /// `SharedInboxManifest.Item.sourceKind` marker for a capture item the
    /// appex SYNTHESIZED (vs. a user-shared file that merely happens to be
    /// named `*.md` — filename convention is not identity). Drives the
    /// drainer's webpage-only behavior: `originalName` as the display
    /// filename + the no-file-server inline clamp.
    static let sourceKindWebpage = "webpage"

    // MARK: - Payload

    /// What was captured: the user's active selection (stronger intent
    /// signal — captured INSTEAD of the page) or the whole page's text.
    enum Scope: String, Sendable {
        case page
        case selection
    }

    /// The parsed JS bridge payload (the dictionary under
    /// `NSExtensionJavaScriptPreprocessingResultsKey`), post-validation: the
    /// scope-matching text picked out, over-cap text re-clamped, byte counts
    /// derived from the actual text.
    struct Payload: Equatable, Sendable {
        /// `document.title`; may be `""`.
        let title: String
        /// `location.href` as reported by the page; may be `""`. With the JS
        /// key declared Safari vends ONLY the property-list item (no
        /// `public.url` provider), so this is the share's one URL source.
        let url: String
        /// The scope-matching captured text that actually rides the envelope:
        /// the user's selection under `.selection` scope, else the page's
        /// `innerText`. Re-clamped `Character`-safely to `maxCaptureBytes`
        /// (the JS output is untrusted).
        let text: String
        /// UTF-8 size of the text BEFORE any truncation (JS-claimed, floored
        /// at the pre-clamp size this parse saw — it can never be smaller
        /// than what actually rides).
        let originalByteCount: Int
        /// Whether any stage (JS cap or Swift re-clamp) cut the text.
        let truncated: Bool
        /// What was captured (drives the metadata header + UI copy).
        let scope: Scope

        /// The text that actually rides the envelope.
        var capturedText: String { text }
        /// Convenience for UI copy ("Page text" vs "Selected text").
        var isSelection: Bool { scope == .selection }
        /// UTF-8 size of `capturedText` — recomputed, never trusted from JS.
        var returnedByteCount: Int { text.utf8.count }
    }

    // MARK: - Parse (tolerant + defensive)

    /// Tolerant parse of the JS results dictionary. Returns `nil` when the
    /// payload carries no usable text — graceful absence: the share proceeds
    /// exactly like a plain URL share (no toggle row, no synthetic item).
    /// Every field default-fills on a key/type miss; a claimed "selection"
    /// scope with an empty selection falls back to page scope; text over
    /// `maxCaptureBytes` is re-clamped `Character`-safely (untrusted input).
    static func parse(_ dict: [AnyHashable: Any]?) -> Payload? {
        guard let dict else { return nil }
        let title = string(dict["title"])
        let url = string(dict["url"])
        let selection = string(dict["selection"])
        let pageText = string(dict["pageText"])
        var truncated = (dict["truncated"] as? NSNumber)?.boolValue ?? false
        let claimedOriginal = (dict["originalByteCount"] as? NSNumber)?.intValue ?? 0

        let scope: Scope
        if string(dict["scope"]) == Scope.selection.rawValue,
           !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scope = .selection
        } else {
            scope = .page
        }

        // Pick the ONE scope-matching text that rides the envelope; the other
        // input is discarded (a selection is captured INSTEAD of the page).
        var text = scope == .selection ? selection : pageText

        // The true pre-truncation size floors at what THIS parse saw before
        // its own re-clamp; the JS's claim only ever RAISES it (the JS may
        // have already cut a bigger page — its figure is the only source of
        // that, but it can never talk the size DOWN).
        let preClampByteCount = text.utf8.count

        // Re-clamp over-cap text — never trust the JS to have honored MAX_BYTES.
        if text.utf8.count > maxCaptureBytes {
            text = truncateUTF8(text, maxBytes: maxCaptureBytes)
            truncated = true
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return Payload(
            title: title,
            url: url,
            text: text,
            originalByteCount: max(claimedOriginal, preClampByteCount),
            truncated: truncated,
            scope: scope
        )
    }

    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    // MARK: - Filename + Markdown

    /// Display filename for the synthetic capture item —
    /// `"Captured Page — <title>.md"`. Sanitized once here for every
    /// downstream consumer (envelope `originalName`, thread chip, upload key,
    /// fence header): path separators + `:` become spaces, control characters
    /// drop, whitespace collapses, title capped at 80 characters. A title
    /// that sanitizes to nothing → `"Captured Page.md"`.
    static func suggestedFilename(title: String) -> String {
        let replaced = String(title.map { (ch: Character) -> Character in
            (ch == "/" || ch == ":" || ch == "\\") ? " " : ch
        })
        var scalars = String.UnicodeScalarView()
        for scalar in replaced.unicodeScalars
        where !CharacterSet.controlCharacters.contains(scalar) {
            scalars.append(scalar)
        }
        var t = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if t.count > 80 {
            t = String(t.prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        guard !t.isEmpty else { return "Captured Page.md" }
        return "Captured Page — \(t).md"
    }

    /// The synthetic Markdown document that rides as the capture attachment:
    /// metadata header (title / source URL / scope), a capture-stage
    /// truncation note when any stage cut the text, `---`, then the captured
    /// text VERBATIM. Rides the existing text-attachment route — fence
    /// hygiene (`ConverseRequest.safeFence`) is applied downstream at splice
    /// time, so backticks in the page need no escaping here.
    static func markdown(for payload: Payload) -> String {
        var lines: [String] = []
        lines.append(payload.title.isEmpty
            ? "# Captured Page"
            : "# Captured Page: \(payload.title)")
        lines.append("")
        if !payload.url.isEmpty {
            lines.append("- Source: \(payload.url)")
        }
        lines.append("- Scope: \(payload.isSelection ? "Selected text" : "Full page text")")
        if payload.truncated {
            lines.append("- Note: capture truncated at \(formatKB(maxCaptureBytes)) — the full \(payload.isSelection ? "selection" : "page text") was \(formatKB(payload.originalByteCount)).")
        }
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append(payload.capturedText)
        return lines.joined(separator: "\n")
    }

    // MARK: - Truncation (both stages)

    /// Cut `text` to at most `maxBytes` of UTF-8 WITHOUT splitting a
    /// `Character` (grapheme cluster) — a multi-scalar emoji either fits
    /// whole or drops whole, so the result is always valid, renderable text.
    static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.utf8.count > maxBytes else { return text }
        var byteCount = 0
        var end = text.startIndex
        while end < text.endIndex {
            let next = text.index(after: end)
            let width = text.utf8.distance(from: end, to: next)
            if byteCount + width > maxBytes { break }
            byteCount += width
            end = next
        }
        return String(text[..<end])
    }

    /// Drainer-side clamp for a webpage capture bound to a gateway with NO
    /// file server (`DeliveryPlan.inlineByteLimit`): this client-owned-history
    /// protocol re-sends the FULL conversation every turn, so an unbounded
    /// page would tax every subsequent turn of the conversation — the capture
    /// is cut to the inline limit with an honest note. The note's bytes count
    /// INSIDE the limit (content budget = `limit` − note bytes), so the result
    /// is ≤ `limit` by construction FOR ANY LIMIT: when `limit` is smaller than
    /// the note itself the note alone is returned, clamped to `limit` (no room
    /// for content). Regular (non-webpage) text never routes here — its
    /// unlimited-inline behavior is unchanged.
    static func truncatedForInline(
        _ markdown: String,
        limit: Int,
        originalByteCount: Int
    ) -> String {
        guard markdown.utf8.count > limit else { return markdown }
        let note = "\n\n> **Truncated by Conduck** — this capture document was "
            + "\(formatKB(originalByteCount)), but the conversation's gateway has "
            + "no file server configured, so it was cut to the \(formatKB(limit)) "
            + "inline limit. The content above ends mid-page."
        let budget = limit - note.utf8.count
        // A limit smaller than the note leaves no content budget — return the
        // note alone, itself clamped to `limit` so the ≤ `limit` guarantee holds.
        guard budget > 0 else { return truncateUTF8(note, maxBytes: limit) }
        return truncateUTF8(markdown, maxBytes: budget) + note
    }

    /// Deterministic "N KB" figure (ceiling, floored at 1) for the honest
    /// notes — pure integer math, no locale-dependent `ByteCountFormatter`
    /// (the notes ride the wire to the agent and are pinned in tests).
    static func formatKB(_ bytes: Int) -> String {
        "\(max(1, (bytes + 1023) / 1024)) KB"
    }

    // MARK: - URL equivalence (envelope `urls[]` gate)

    /// Equivalence-normalized form of an http(s) URL: scheme + host
    /// case-folded, fragment dropped, trailing path slash dropped. Returns
    /// `nil` for anything unparseable or non-http(s) — for the gate that
    /// means "don't append". Deliberately conservative: query strings and
    /// ports are preserved verbatim (URLs differing there are genuinely
    /// different pages).
    static func normalizedForEquivalence(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.string
    }

    /// Whether the JS-payload URL should JOIN the envelope's `urls[]`. It
    /// joins TOGGLE-INDEPENDENTLY — with the JS key declared, Safari vends
    /// the property-list item INSTEAD of `public.url`, so toggle-OFF must
    /// not lose the URL. Gate: (a) the URL parses as http(s), and (b) no
    /// EQUIVALENT URL is already present — the appex de-dupe and the
    /// drainer's URL splice are exact-string, so fragment/trailing-slash
    /// variants would double-post without this.
    static func shouldAppend(url: String, toExisting existing: [String]) -> Bool {
        guard let normalized = normalizedForEquivalence(url) else { return false }
        return !existing.contains { normalizedForEquivalence($0) == normalized }
    }
}
