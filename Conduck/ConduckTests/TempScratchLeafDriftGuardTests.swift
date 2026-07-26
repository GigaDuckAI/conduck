// Conduck
// TempScratchLeafDriftGuardTests.swift
//
// EVERY platform, not just the wrist. `TempScratchSweeper` can only reclaim a
// stranded temp file by matching its filename against `ownedPrefixes`, so a writer
// that builds an unprefixed leaf is not merely unswept — it is unreclaimable by
// construction. No sweep can ever be widened to catch it, because the only rule
// loose enough (bare UUID, or bare `.m4a`) would also delete files the system and
// other frameworks stage in the same shared directory.
//
// That defect has now been found three times independently — the watchOS recorder
// (`<UUID>.m4a`), the completed-download body (`<UUID>`), and the wrist converse
// body (`conduck-watch-converse-body-`, which silently failed to prefix-match
// `conduck-converse-body-` because of the `watch-` infix). Three is a pattern, and
// a guard scoped to one platform would have missed at least two of them. So this
// scan covers the WHOLE project container: app, watch app, widget extension, and
// both share extensions.
//
// WHAT IT CHECKS: for every `temporaryDirectory` in shipping code, the leaf
// appended to it must begin with a string literal claimed by `ownedPrefixes`. A
// leaf built from a non-literal expression fails too — it is the exact shape the
// watchOS bug took.
//
// Paths come from `#filePath`, so the scan is independent of the runner's working
// directory — the same derivation `LoggingPrivacyDriftGuardTests` and
// `MarkdownAttachmentPolicyDriftGuardTests` use. Both test bundles are excluded:
// test code never ships, and it stages temp files under computed names by design.

import Foundation
import XCTest
@testable import Conduck

final class TempScratchLeafDriftGuardTests: XCTestCase {

    // MARK: - The exemptions, as data

    /// PERMANENT exemptions — leaves that are unclaimed by design. None is a defect,
    /// so none is expected to change and none belongs in the debt list below: an
    /// entry that will never legitimately shrink teaches the next reader to ignore
    /// the whole catalogue.
    private static let exemptLeaves: Set<String> = [
        // The Quick Look scratch ROOT, swept by `AgentDownloadScratch.sweep()` on
        // its own age bound. `TempScratchSweeperTests.testForeignNamesAreNotClaimed`
        // asserts `TempScratchSweeper` must NEVER claim it — a relaunch could
        // otherwise yank a file an Open-with app is holding open.
        "AgentFileDownloads",
        // `#if os(macOS) && DEBUG` — never ships.
        "conduck-hierarchy-",
        // A FIXED name, deleted before each copy, so it overwrites in place instead
        // of accumulating. A bundled resource holding no user data.
        "GigaAction.shortcut",
    ]

    /// PERMANENT exemptions for non-literal leaves, keyed by filename because there
    /// is no leaf to key on. Consequence of keying by file: a genuinely new
    /// non-literal writer added to one of these files would not be caught. That is
    /// accepted — the alternative is pinning line numbers, which rot on every edit.
    private static let exemptNonLiteralWriters: Set<String> = [
        // `Constants.sharedInboxDirectoryName` — a fallback BASE DIRECTORY used when
        // the App Group container is nil, not a file write.
        "SharedInboxDrainer.swift",
    ]

    /// TEMPORARY debt: sites that are unclaimed today and are real orphan risks.
    /// Nothing here is blessed.
    ///
    /// THIS LIST MUST ONLY EVER SHRINK. It lets the guard land ahead of a fix
    /// without turning the suite red, while new instances of the defect still fail
    /// immediately. `testKnownUnclaimedSitesHaveNotRotted` fails if an entry is
    /// fixed but left here, so the catalogue cannot go stale.
    private static let knownUnclaimedLeaves: Set<String> = [
        // Empty, and that is the point: every temp leaf this app writes is claimed by
        // `ownedPrefixes`. An entry here means a known orphan risk shipped unclaimed,
        // so it must be justified in review and removed as soon as the site is claimed.
    ]

    private static let excludedDirectoryNames: Set<String> = [
        "ConduckTests", "ConduckWatchTests",
    ]

    // MARK: - A single unclaimed write site

    private struct Finding: Hashable, CustomStringConvertible {
        let file: String
        let line: Int
        /// `nil` when the leaf is built from a non-literal expression.
        let leaf: String?

        var description: String {
            let what = leaf.map { "leaf \"\($0)…\"" } ?? "a non-literal leaf"
            return "\(file):\(line) — \(what)"
        }
    }

    // MARK: - Source access

    /// `.../Conduck/Conduck` — the project container holding every target's sources.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../ConduckTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
    }

    /// Drops `//`-to-end-of-line so prose about `temporaryDirectory` is never read
    /// as a write site. A `//` inside a string literal truncates that line early;
    /// the failure mode is a MISSED site, so the two behavioural checks in
    /// `TempScratchSweeperTests` remain the backstop, not this scan alone.
    private func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// Every temp write site in shipping code whose leaf is NOT claimed by
    /// `ownedPrefixes`. Exemptions are filtered by the callers, not here, so both
    /// tests read the same raw truth.
    private func unclaimedWriteSites() throws -> [Finding] {
        let container = projectContainerURL()
        guard let walker = FileManager.default.enumerator(
            at: container, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            throw XCTSkip("Could not enumerate \(container.path) — update this guard's path derivation.")
        }

        var findings: [Finding] = []
        for case let url as URL in walker {
            guard url.pathExtension == "swift" else { continue }
            guard Set(url.pathComponents).isDisjoint(with: Self.excludedDirectoryNames) else { continue }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let code = strippingComments(raw)
            var cursor = code.startIndex
            while let hit = code.range(of: "temporaryDirectory", range: cursor..<code.endIndex) {
                cursor = hit.upperBound

                // The leaf is appended within a line or two of the directory in
                // every writer; a wider window would start reading the next
                // statement's business. No match means this use is not a write
                // (e.g. `sweep()` enumerating the root).
                let end = code.index(hit.upperBound, offsetBy: 240, limitedBy: code.endIndex) ?? code.endIndex
                let window = code[hit.upperBound..<end]
                guard let call = window.range(of: ".appendingPathComponent(") else { continue }

                let line = code[code.startIndex..<hit.lowerBound].lazy.filter { $0 == "\n" }.count + 1
                let argument = window[call.upperBound...].drop(while: { $0 == " " || $0 == "\n" })

                guard argument.first == "\"" else {
                    findings.append(Finding(file: url.lastPathComponent, line: line, leaf: nil))
                    continue
                }
                // Up to the closing quote or the first `\(` interpolation.
                let literal = String(argument.dropFirst().prefix { $0 != "\"" && $0 != "\\" })
                guard !TempScratchSweeper.ownedPrefixes.contains(where: { literal.hasPrefix($0) }) else { continue }
                findings.append(Finding(file: url.lastPathComponent, line: line, leaf: literal))
            }
        }
        return findings
    }

    // MARK: - The guard

    func testNoNewUnclaimedTempLeafAppears() throws {
        let unexpected = try unclaimedWriteSites().filter { finding in
            guard let leaf = finding.leaf else {
                return !Self.exemptNonLiteralWriters.contains(finding.file)
            }
            return !Self.exemptLeaves.contains(leaf)
                && !Self.knownUnclaimedLeaves.contains(leaf)
        }

        XCTAssertTrue(
            unexpected.isEmpty,
            """
            New temp write site(s) whose leaf no `TempScratchSweeper.ownedPrefixes` entry claims:

            \(unexpected.map(\.description).joined(separator: "\n"))

            A file written here is deleted only in-process, so a jetsam, crash, or force-quit \
            strands it — and an unprefixed leaf can never be reclaimed by any later sweep, \
            because the only rule broad enough to match it would also delete other frameworks' \
            files. Give the leaf a distinctive prefix and add that prefix to `ownedPrefixes` \
            (plus the writer list in TempScratchSweeperTests). Do NOT add it to this file's \
            baseline — that list is for pre-existing debt and only ever shrinks.
            """
        )
    }

    /// Only the DEBT list is held to this. The exemption sets are permanent by
    /// definition, so demanding they shrink would be demanding they be wrong.
    func testKnownUnclaimedSitesHaveNotRotted() throws {
        let observedLeaves = Set(try unclaimedWriteSites().compactMap(\.leaf))
        let fixedLeaves = Self.knownUnclaimedLeaves.subtracting(observedLeaves).sorted()

        XCTAssertTrue(
            fixedLeaves.isEmpty,
            """
            These leaves are listed as known-unclaimed debt but are no longer unclaimed \
            (fixed, or the write site is gone): \(fixedLeaves.joined(separator: ", ")).

            Remove them from `knownUnclaimedLeaves`. The list only ever shrinks — leaving a \
            fixed entry in it would silently re-permit the defect at that leaf, and a list \
            that never shrinks is one the next reader learns to skip.
            """
        )
    }

    /// The scan is only meaningful if it actually reaches the sources. A path
    /// derivation that silently resolves to an empty tree would make both tests
    /// above pass for the wrong reason.
    func testScanReachesEveryTargetsSources() throws {
        let container = projectContainerURL()
        for target in ["Conduck", "ConduckWatch Watch App", "ConduckShareExtension", "ConduckShareExtensionMac"] {
            var isDirectory: ObjCBool = false
            let path = container.appendingPathComponent(target).path
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue,
                "\(target) is missing from \(container.path) — this guard is scanning the wrong tree and proves nothing."
            )
        }
        // The known sites are the proof the matcher works end-to-end, not just that
        // the directories exist: if the scan found nothing at all, every assertion
        // in this file would pass vacuously.
        let findings = try unclaimedWriteSites()
        XCTAssertFalse(
            findings.isEmpty,
            "The scan found zero unclaimed sites. That would be good news, but the baseline says otherwise — far more likely the matcher stopped matching. Verify by hand before trusting it."
        )
    }
}
