// SPDX-License-Identifier: Apache-2.0

// Conduck
// WebPageCaptureTests.swift
//
// Safari page-text capture — coverage for the pure `WebPageCapture` contract:
// tolerant payload parse (untrusted JS input, re-clamp, scope fallback), the
// synthetic Markdown + sanitized filename, both truncation stages (Character-
// boundary-safe UTF-8 cut + the no-file-server inline clamp with its honest
// note counted INSIDE the cap), the URL-equivalence gate for `urls[]`, the
// paired-literal pin against `Constants.webPageCaptureMaxBytes`, and the
// appex-mirror byte-identity drift guard.
//
// Pure Foundation — no Keychain, no signing, no store. Runs on any sim.

import XCTest
@testable import Conduck

final class WebPageCaptureTests: XCTestCase {

    // MARK: - Fixtures

    private func payloadDict(
        title: Any? = "Example Page",
        url: Any? = "https://example.com/article",
        selection: Any? = "",
        pageText: Any? = "Body text of the page.",
        originalByteCount: Any? = nil,
        truncated: Any? = false,
        scope: Any? = "page"
    ) -> [AnyHashable: Any] {
        var dict: [AnyHashable: Any] = [:]
        if let title { dict["title"] = title }
        if let url { dict["url"] = url }
        if let selection { dict["selection"] = selection }
        if let pageText { dict["pageText"] = pageText }
        if let originalByteCount { dict["originalByteCount"] = originalByteCount }
        if let truncated { dict["truncated"] = truncated }
        if let scope { dict["scope"] = scope }
        return dict
    }

    // MARK: - Parse: happy paths

    func testParseFullPagePayload() throws {
        let payload = try XCTUnwrap(WebPageCapture.parse(payloadDict()))
        XCTAssertEqual(payload.title, "Example Page")
        XCTAssertEqual(payload.url, "https://example.com/article")
        XCTAssertEqual(payload.scope, .page)
        XCTAssertFalse(payload.isSelection)
        XCTAssertEqual(payload.capturedText, "Body text of the page.")
        XCTAssertEqual(payload.returnedByteCount, "Body text of the page.".utf8.count,
                       "returned byte count is RECOMPUTED from the text, never trusted from JS")
        XCTAssertFalse(payload.truncated)
    }

    func testParseSelectionScope() throws {
        let dict = payloadDict(selection: "just this sentence", pageText: "", scope: "selection")
        let payload = try XCTUnwrap(WebPageCapture.parse(dict))
        XCTAssertEqual(payload.scope, .selection)
        XCTAssertTrue(payload.isSelection)
        XCTAssertEqual(payload.capturedText, "just this sentence")
    }

    // MARK: - Parse: tolerance + defense (JS output = untrusted input)

    func testParseSelectionScopeWithEmptySelectionFallsBackToPage() throws {
        // A claimed "selection" scope that carries no selection text is
        // self-inconsistent — fall back to page scope rather than return an
        // empty capture.
        let dict = payloadDict(selection: "   \n ", scope: "selection")
        let payload = try XCTUnwrap(WebPageCapture.parse(dict))
        XCTAssertEqual(payload.scope, .page)
        XCTAssertEqual(payload.capturedText, "Body text of the page.")
    }

    func testParseNilDictReturnsNil() {
        XCTAssertNil(WebPageCapture.parse(nil))
    }

    func testParseNoUsableTextReturnsNil() {
        // Whitespace-only page text = graceful absence (share proceeds as a
        // plain URL share; no toggle row, no synthetic item).
        XCTAssertNil(WebPageCapture.parse(payloadDict(pageText: "  \n\t ")))
        XCTAssertNil(WebPageCapture.parse(payloadDict(pageText: "")))
        XCTAssertNil(WebPageCapture.parse([:]))
    }

    func testParseWrongTypesDefaultFill() throws {
        // A hostile/buggy page script can put ANYTHING in the bridge payload —
        // every non-string field must default-fill, not crash or poison.
        let dict = payloadDict(
            title: 42, url: ["not", "a", "string"], selection: nil,
            pageText: "still fine", originalByteCount: "NaN", truncated: "yes", scope: 7
        )
        let payload = try XCTUnwrap(WebPageCapture.parse(dict))
        XCTAssertEqual(payload.title, "")
        XCTAssertEqual(payload.url, "")
        XCTAssertEqual(payload.scope, .page)
        XCTAssertEqual(payload.capturedText, "still fine")
        XCTAssertFalse(payload.truncated)
    }

    func testParseReclampsOverCapPageText() throws {
        // The Swift side re-validates the 128 KiB cap even if the JS claims
        // otherwise (untrusted input).
        let huge = String(repeating: "a", count: WebPageCapture.maxCaptureBytes + 4096)
        let dict = payloadDict(pageText: huge, truncated: false)
        let payload = try XCTUnwrap(WebPageCapture.parse(dict))
        XCTAssertLessThanOrEqual(payload.returnedByteCount, WebPageCapture.maxCaptureBytes)
        XCTAssertTrue(payload.truncated, "a re-clamp must surface as truncated")
        XCTAssertEqual(payload.originalByteCount, huge.utf8.count,
                       "originalByteCount floors at the actual pre-clamp size")
    }

    func testParseOriginalByteCountFlooredAtReturned() throws {
        // A lying JS that claims a SMALLER original than what it returned
        // can't make the honest note understate the size.
        let dict = payloadDict(pageText: "twenty-two byte body..", originalByteCount: 3)
        let payload = try XCTUnwrap(WebPageCapture.parse(dict))
        XCTAssertEqual(payload.originalByteCount, payload.returnedByteCount)
    }

    func testParseHonorsClaimedOriginalWhenLarger() throws {
        // The JS cut a 500 KB page to the cap — its pre-truncation figure is
        // the only source of the true size, so it rides through.
        let dict = payloadDict(pageText: "short", originalByteCount: 500_000, truncated: true)
        let payload = try XCTUnwrap(WebPageCapture.parse(dict))
        XCTAssertEqual(payload.originalByteCount, 500_000)
        XCTAssertTrue(payload.truncated)
    }

    // MARK: - Filename

    func testSuggestedFilenamePlainTitle() {
        XCTAssertEqual(WebPageCapture.suggestedFilename(title: "Example Page"),
                       "Captured Page — Example Page.md")
    }

    func testSuggestedFilenameSanitizesSeparatorsAndControlChars() {
        // `/` + `:` + `\` become spaces (path/legacy-separator safety for the
        // envelope file name + upload key); control chars drop; runs collapse.
        let name = WebPageCapture.suggestedFilename(title: "a/b:c\\d\u{0007}e\n f")
        XCTAssertEqual(name, "Captured Page — a b c d\u{0007}e f.md".replacingOccurrences(of: "\u{0007}", with: ""))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    func testSuggestedFilenameCapsTitleAt80() {
        let name = WebPageCapture.suggestedFilename(title: String(repeating: "x", count: 300))
        XCTAssertEqual(name, "Captured Page — \(String(repeating: "x", count: 80)).md")
    }

    func testSuggestedFilenameEmptyTitle() {
        XCTAssertEqual(WebPageCapture.suggestedFilename(title: ""), "Captured Page.md")
        XCTAssertEqual(WebPageCapture.suggestedFilename(title: " /:\n "), "Captured Page.md")
    }

    // MARK: - Markdown

    func testMarkdownFullPage() throws {
        let payload = try XCTUnwrap(WebPageCapture.parse(payloadDict()))
        let md = WebPageCapture.markdown(for: payload)
        XCTAssertTrue(md.hasPrefix("# Captured Page: Example Page\n"))
        XCTAssertTrue(md.contains("- Source: https://example.com/article"))
        XCTAssertTrue(md.contains("- Scope: Full page text"))
        XCTAssertFalse(md.contains("- Note:"), "no truncation note when nothing was cut")
        XCTAssertTrue(md.hasSuffix("---\n\nBody text of the page."))
    }

    func testMarkdownSelectionScopeAndTruncationNote() throws {
        let dict = payloadDict(
            selection: "the selection", pageText: "",
            originalByteCount: 400_000, truncated: true, scope: "selection"
        )
        let payload = try XCTUnwrap(WebPageCapture.parse(dict))
        let md = WebPageCapture.markdown(for: payload)
        XCTAssertTrue(md.contains("- Scope: Selected text"))
        XCTAssertTrue(md.contains("- Note: capture truncated at 128 KB — the full selection was 391 KB."))
    }

    func testMarkdownOmitsEmptyTitleAndURL() throws {
        let payload = try XCTUnwrap(WebPageCapture.parse(payloadDict(title: "", url: "")))
        let md = WebPageCapture.markdown(for: payload)
        XCTAssertTrue(md.hasPrefix("# Captured Page\n"), "bare heading when the page has no title")
        XCTAssertFalse(md.contains("- Source:"), "no Source line for an empty URL")
    }

    // MARK: - UTF-8 truncation (Character-boundary-safe)

    func testTruncateUTF8ExactFitUnchanged() {
        XCTAssertEqual(WebPageCapture.truncateUTF8("abcd", maxBytes: 4), "abcd")
        XCTAssertEqual(WebPageCapture.truncateUTF8("abcd", maxBytes: 5), "abcd")
    }

    func testTruncateUTF8CutsASCII() {
        XCTAssertEqual(WebPageCapture.truncateUTF8("abcdef", maxBytes: 3), "abc")
    }

    func testTruncateUTF8NeverSplitsMultibyteScalar() {
        // "é" is 2 UTF-8 bytes — a 2-byte budget after "a" can't fit it whole,
        // so it drops whole (never a dangling continuation byte).
        XCTAssertEqual(WebPageCapture.truncateUTF8("aé", maxBytes: 2), "a")
        XCTAssertEqual(WebPageCapture.truncateUTF8("aé", maxBytes: 3), "aé")
    }

    func testTruncateUTF8NeverSplitsGraphemeCluster() {
        // The ZWJ family emoji is ONE Character of 25 UTF-8 bytes — any budget
        // below 25 (after the prefix) must drop the whole grapheme, not leave
        // a partial woman-and-half-a-child sequence.
        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦"
        let text = "hi" + family
        XCTAssertEqual(WebPageCapture.truncateUTF8(text, maxBytes: 10), "hi")
        XCTAssertEqual(WebPageCapture.truncateUTF8(text, maxBytes: 2 + family.utf8.count), text)
    }

    func testTruncateUTF8ZeroAndNegativeBudget() {
        XCTAssertEqual(WebPageCapture.truncateUTF8("abc", maxBytes: 0), "")
        XCTAssertEqual(WebPageCapture.truncateUTF8("abc", maxBytes: -5), "")
    }

    // MARK: - Inline clamp (drainer stage, honest note INSIDE the cap)

    func testTruncatedForInlineUnderLimitUnchanged() {
        let md = "# Captured Page\n\nshort body"
        XCTAssertEqual(
            WebPageCapture.truncatedForInline(md, limit: 32 * 1024, originalByteCount: md.utf8.count),
            md)
    }

    func testTruncatedForInlineClampsWithinLimitIncludingNote() {
        let limit = 32 * 1024
        let original = 300 * 1024
        let md = String(repeating: "line of page text\n", count: 20_000) // ~360 KB
        let out = WebPageCapture.truncatedForInline(md, limit: limit, originalByteCount: original)
        XCTAssertLessThanOrEqual(out.utf8.count, limit,
                                 "the note's bytes count INSIDE the cap — result must be ≤ limit by construction")
        XCTAssertTrue(out.contains("> **Truncated by Conduck** — this capture document was 300 KB"),
                      "honest note names the true original size")
        XCTAssertTrue(out.contains("no file server configured"), "honest note names the cause")
        XCTAssertTrue(out.contains("32 KB inline limit"), "honest note names the cap")
        XCTAssertTrue(out.hasSuffix("ends mid-page."), "honest note admits the cut")
    }

    func testTruncatedForInlineLimitBelowNoteStillWithinLimit() {
        // Hardening: a `limit` SMALLER than the note itself has NO content budget
        // — the note alone is returned, clamped to `limit`, so the documented
        // "≤ limit by construction" holds for ANY limit (not just limits that
        // exceed the note's own byte length).
        let md = String(repeating: "page body ", count: 500) // ~5 KB, well over 100
        let out = WebPageCapture.truncatedForInline(md, limit: 100, originalByteCount: md.utf8.count)
        XCTAssertLessThanOrEqual(out.utf8.count, 100,
                                 "even a tiny limit must produce a result ≤ limit")
    }

    // MARK: - URL equivalence gate (envelope `urls[]`)

    func testNormalizedForEquivalenceCaseFoldAndStrip() {
        XCTAssertEqual(WebPageCapture.normalizedForEquivalence("HTTPS://Example.COM/Path/#frag"),
                       WebPageCapture.normalizedForEquivalence("https://example.com/Path"))
        XCTAssertNotEqual(WebPageCapture.normalizedForEquivalence("https://example.com/PATH"),
                          WebPageCapture.normalizedForEquivalence("https://example.com/path"),
                          "path case is significant — only scheme/host fold")
        XCTAssertNotEqual(WebPageCapture.normalizedForEquivalence("https://example.com/a?p=1"),
                          WebPageCapture.normalizedForEquivalence("https://example.com/a?p=2"),
                          "query strings are genuinely different pages — preserved")
    }

    func testNormalizedForEquivalenceRejectsNonHTTP() {
        XCTAssertNil(WebPageCapture.normalizedForEquivalence("file:///etc/passwd"))
        XCTAssertNil(WebPageCapture.normalizedForEquivalence("javascript:alert(1)"))
        XCTAssertNil(WebPageCapture.normalizedForEquivalence("not a url at all"))
        XCTAssertNil(WebPageCapture.normalizedForEquivalence(""))
    }

    func testShouldAppendGates() {
        // Fresh URL → append (toggle-OFF must not lose the share's only URL —
        // Safari vends NO public.url provider once the JS key is declared).
        XCTAssertTrue(WebPageCapture.shouldAppend(
            url: "https://example.com/article", toExisting: []))
        // Equivalent (fragment/slash/case variant) already present → don't
        // double-post (appex de-dupe + drainer splice are exact-string).
        XCTAssertFalse(WebPageCapture.shouldAppend(
            url: "https://example.com/article/#section",
            toExisting: ["HTTPS://EXAMPLE.com/article"]))
        // Genuinely different URL alongside → append.
        XCTAssertTrue(WebPageCapture.shouldAppend(
            url: "https://example.com/other", toExisting: ["https://example.com/article"]))
        // Unparseable / non-http(s) → never append.
        XCTAssertFalse(WebPageCapture.shouldAppend(url: "file:///x", toExisting: []))
        XCTAssertFalse(WebPageCapture.shouldAppend(url: "", toExisting: []))
    }

    // MARK: - Paired literals (Constants ↔ WebPageCapture ↔ JS)

    func testCaptureCapMatchesConstants() {
        // The appexes can't import `Constants` and the JS can't read Swift —
        // the 128 KiB cap is deliberately duplicated. This pins the two Swift
        // copies; the JS `MAX_BYTES` literals are pinned by the grep test below.
        XCTAssertEqual(WebPageCapture.maxCaptureBytes, Constants.webPageCaptureMaxBytes)
        XCTAssertEqual(WebPageCapture.maxCaptureBytes, 128 * 1024)
    }

    func testJSCapLiteralMatchesSwiftCap() throws {
        // Each appex bundles `ConduckWebCapture.js`, whose `MAX_BYTES` literal
        // must equal `WebPageCapture.maxCaptureBytes` — the JS is the first
        // truncation stage, the Swift re-clamp the second; a drifted literal
        // silently changes which stage cuts (and what `originalByteCount`
        // reports). Greps the source files off disk like the mirror guard.
        let expected = "var MAX_BYTES = \(WebPageCapture.maxCaptureBytes);"
        for js in try jsPairContents() {
            XCTAssertTrue(js.contains(expected),
                          "ConduckWebCapture.js MAX_BYTES literal has drifted from WebPageCapture.maxCaptureBytes — expected `\(expected)`")
        }
    }

    func testJSPairIsByteIdentical() throws {
        // The two appex copies of the capture JS are a byte-identical pair —
        // same header, same body (unlike the Swift mirrors there is no
        // per-target header, so FULL-file identity is the contract).
        let pair = try jsPairContents()
        XCTAssertEqual(pair[0], pair[1],
                       "the two ConduckWebCapture.js copies have drifted — iOS and macOS would capture differently")
    }

    /// Both appex `ConduckWebCapture.js` sources, `[iOS, macOS]`, read off
    /// disk via the same `#filePath` anchoring as the mirror guard.
    private func jsPairContents() throws -> [String] {
        let projectDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/ConduckTests
            .deletingLastPathComponent()   // …/Conduck (the Xcode-project subdir)
        return try [
            projectDir.appendingPathComponent("ConduckShareExtension/ConduckWebCapture.js"),
            projectDir.appendingPathComponent("ConduckShareExtensionMac/ConduckWebCapture.js")
        ].map { try String(contentsOf: $0, encoding: .utf8) }
    }

    // MARK: - Byte-identical mirror guard (canonical ↔ iOS appex)

    // The canonical copy (`ConduckShareExtensionMac/WebPageCapture.swift`) is
    // compiled into the macOS appex + the MAIN APP (explicit pbxproj file
    // reference — the `ShareTargetFilter` precedent); the iOS appex compiles
    // its own VERBATIM MIRROR. Both must stay byte-identical below their
    // header comments or the appex writer and the drainer reader diverge on
    // parse/truncate/filename behavior. Same anchoring as the
    // `SharedInboxManifestTests` 3-way guard: `#filePath` → sibling dirs.
    func testAppexMirrorIsByteIdenticalToCanonicalBelowHeader() throws {
        let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDir = testDir.deletingLastPathComponent()  // …/Conduck (the Xcode-project subdir)
        let canonicalURL = projectDir
            .appendingPathComponent("ConduckShareExtensionMac/WebPageCapture.swift")
        let iosMirrorURL = projectDir
            .appendingPathComponent("ConduckShareExtension/WebPageCapture.swift")

        let canonical = try String(contentsOf: canonicalURL, encoding: .utf8)
        let iosMirror = try String(contentsOf: iosMirrorURL, encoding: .utf8)

        XCTAssertEqual(bodyBelowHeader(of: canonical), bodyBelowHeader(of: iosMirror),
                       "iOS appex WebPageCapture has drifted from the canonical below the header — the appex-writer ↔ drainer-reader contract is at risk")
    }

    private func bodyBelowHeader(of source: String) -> Substring {
        guard let range = source.range(of: "import Foundation") else { return source[...] }
        return source[range.lowerBound...]
    }
}
