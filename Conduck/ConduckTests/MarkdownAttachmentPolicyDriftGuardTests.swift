// SPDX-License-Identifier: Apache-2.0

// Conduck
// MarkdownAttachmentPolicyDriftGuardTests.swift
//
// SOURCE DRIFT GUARD for the untrusted-Markdown render policy.
//
// Agent reply text is untrusted, and Textual's Markdown renderers default to two
// behaviours Conduck must not have: their image / emoji attachment loaders FETCH
// markup URLs over the network, and a link tap goes straight to the system open
// handler whatever scheme the reply named. Every render site therefore has to
// apply `.appliesUntrustedMarkdownPolicy()` (see MarkdownAttachmentPolicy.swift).
// Forgetting it at a NEW render site is silent: it compiles, it renders fine, and
// it only shows up as an outbound request to whatever host the agent named, or as
// an unannounced hand-off to another app.
//
// The policy is carried in the SwiftUI environment, whose values aren't readable
// from a unit test, and Textual's `ColorEnvironmentValues` has an internal init so
// the loader can't be invoked directly either. So this guard works at the source
// level: it reads the app's Swift sources off disk (via #filePath, independent of
// the runner's working directory) and asserts every file that CONSTRUCTS one of
// Textual's renderers applies the policy at least as many times.
//
// `testScannerFlagsUnguardedSites` covers the scanner itself against synthetic
// sources — a drift guard that cannot fail is worthless, and this file is excluded
// from its own scan, so those fixtures are safe to write here.

import XCTest

final class MarkdownAttachmentPolicyDriftGuardTests: XCTestCase {

    /// Textual's two Markdown renderers, both of which read the attachment loaders
    /// and the `openURL` action the policy overrides.
    ///
    /// Counted UNQUALIFIED on purpose. This is a plain substring scan, so
    /// `"StructuredText("` already matches a qualified `Textual.StructuredText(`;
    /// counting both spellings would score one site as two and turn the guard red
    /// on correct code — the worst failure mode for a tripwire, because the fix
    /// looks like "loosen the comparison". The trailing `(` is load-bearing too: a
    /// bare `"InlineText"` needle would match `InlineTextFileChip`, which is a
    /// Conduck view in the very file that hosts a real render site.
    private static let renderSiteNeedles = ["StructuredText(", "InlineText("]

    /// The ONE token a render site must carry. Both halves of the policy
    /// (attachment loaders + link-scheme gate) ride this single modifier so there
    /// is exactly one thing to count.
    private static let policyNeedle = ".appliesUntrustedMarkdownPolicy()"

    /// `.../Conduck/Conduck` — the Xcode project container holding the app
    /// source (`Conduck/`), the Watch app and the share extensions. Derived from
    /// this test file's compile-time absolute path (#filePath →
    /// .../Conduck/Conduck/ConduckTests/<thisFile>).
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../ConduckTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
    }

    /// Strip Swift comments so a `StructuredText(...)` mentioned in prose is not
    /// mistaken for a render site. Line comments are cut at the first `//` that
    /// begins a line's content; block comments are tracked with a depth counter.
    /// Deliberately conservative: a trailing `// note` after real code keeps the
    /// code, so guarded sites still count.
    private func codeOnly(_ source: String) -> String {
        var out = ""
        var inBlockComment = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inBlockComment {
                if trimmed.contains("*/") { inBlockComment = false }
                continue
            }
            if trimmed.hasPrefix("//") { continue }
            if trimmed.hasPrefix("/*") {
                if !trimmed.contains("*/") { inBlockComment = true }
                continue
            }
            out.append(contentsOf: line)
            out.append("\n")
        }
        return out
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var index = haystack.startIndex
        while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }

    /// One file's verdict.
    private struct Scan {
        let renderSites: Int
        let guarded: Int
        /// A site that renders untrusted Markdown without the policy on it.
        var hasDrift: Bool { guarded < renderSites }
    }

    private func scan(_ source: String) -> Scan {
        let code = codeOnly(source)
        let renderSites = Self.renderSiteNeedles.reduce(0) { $0 + occurrences(of: $1, in: code) }
        return Scan(renderSites: renderSites, guarded: occurrences(of: Self.policyNeedle, in: code))
    }

    func testEveryUntrustedMarkdownRenderSiteAppliesThePolicy() throws {
        let container = projectContainerURL()
        let fm = FileManager.default

        guard let walker = fm.enumerator(
            at: container,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return XCTFail("Could not enumerate \(container.path) — update this guard's path derivation.")
        }

        var totalRenderSites = 0
        var unguarded: [String] = []

        for case let url as URL in walker {
            guard url.pathExtension == "swift" else { continue }
            // The policy's own definition and this guard both name the symbols in
            // prose/declarations rather than at a render site.
            let name = url.lastPathComponent
            guard name != "MarkdownAttachmentPolicy.swift",
                  name != "MarkdownAttachmentPolicyDriftGuardTests.swift" else { continue }

            let result = scan(try String(contentsOf: url, encoding: .utf8))
            guard result.renderSites > 0 else { continue }

            totalRenderSites += result.renderSites
            if result.hasDrift {
                let relative = url.path.replacingOccurrences(of: container.path + "/", with: "")
                unguarded.append("\(relative): \(result.renderSites) render site(s), \(result.guarded) guarded")
            }
        }

        // Extractor sanity: the two known render sites (the conversation thread
        // bubble and the macOS menu-bar popover reply) must have been found, so a
        // broken scanner can't pass as "no drift". New sites are fine — they just
        // have to be guarded, so this stays a floor and is only raised if the
        // scanner itself is ever narrowed.
        XCTAssertGreaterThanOrEqual(
            totalRenderSites, 2,
            "Expected at least 2 untrusted-Markdown render sites; found \(totalRenderSites). The scanner or the source layout changed — fix this guard before trusting it."
        )

        XCTAssertTrue(
            unguarded.isEmpty,
            """
            Untrusted-Markdown render site(s) are missing `\(Self.policyNeedle)`:
            \(unguarded.joined(separator: "\n"))

            Textual's default attachment loaders FETCH markup image/emoji URLs over \
            the network, and a link tap goes to the system open handler with whatever \
            scheme the reply named. Agent reply text is untrusted, so an unguarded \
            site lets a reply containing `![](https://host/x.png)` beacon an arbitrary \
            third party on render — outside all Conduck networking (no pinning, no \
            auth scheme, no logging) — and lets `[Open report](someapp://…)` hand the \
            device to another app on one tap with the destination never shown. Add \
            `\(Self.policyNeedle)` to the render site.
            """
        )
    }

    // MARK: - The scanner's own coverage
    //
    // Synthetic fixtures, not real source: every needle-counting rule the guard
    // leans on is asserted here, so the guard is known to go RED for the right
    // reasons and — just as important — only those. Safe to write these literals
    // in this file because the disk walk above skips it by name.

    func testScannerFlagsUnguardedSites() {
        // The regression this guard was written for.
        XCTAssertTrue(
            scan("        StructuredText(markdown: text)\n").hasDrift,
            "An unguarded StructuredText site must be reported as drift."
        )

        // Textual's OTHER renderer reads the same environment loaders and the same
        // `openURL` action, so it must count as a render site too.
        XCTAssertTrue(
            scan("        InlineText(markdown: preview)\n").hasDrift,
            "An unguarded InlineText site must be reported as drift — it resolves attachments and links through the same environment."
        )

        // Two sites, one modifier: the per-site count, not per-file presence.
        XCTAssertTrue(
            scan("""
            StructuredText(markdown: a)
                .appliesUntrustedMarkdownPolicy()
            InlineText(markdown: b)
            """).hasDrift,
            "A second, unguarded site in an otherwise guarded file must be reported."
        )
    }

    func testScannerPassesCorrectlyGuardedSites() {
        XCTAssertFalse(
            scan("""
            StructuredText(markdown: text)
                .appliesUntrustedMarkdownPolicy()
                .foregroundStyle(.primary)
            """).hasDrift
        )

        // A QUALIFIED spelling is one site, not two. `"StructuredText("` matches
        // inside `Textual.StructuredText(`, which is exactly why the qualified
        // spelling is not a separate needle.
        let qualified = scan("""
        Textual.StructuredText(markdown: text)
            .appliesUntrustedMarkdownPolicy()
        """)
        XCTAssertEqual(qualified.renderSites, 1, "A qualified render site must not be double-counted — that would make the guard red on correct code.")
        XCTAssertFalse(qualified.hasDrift)

        // `InlineTextFileChip` is a Conduck view, not a Textual renderer, and it
        // lives in the same file as a real render site. The trailing `(` in the
        // needle is what keeps it out.
        XCTAssertEqual(
            scan("InlineTextFileChip(attachment: a, isUserBubble: false)\n").renderSites, 0,
            "`InlineTextFileChip` must not be mistaken for Textual's `InlineText`."
        )

        // Prose mentions are not render sites (this file and the policy file are
        // additionally excluded by name, but the comment strip is the first line
        // of defence).
        XCTAssertEqual(
            scan("// Agent bubbles render via StructuredText(...) and InlineText(...).\n").renderSites, 0
        )
    }
}
