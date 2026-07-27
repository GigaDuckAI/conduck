// SPDX-License-Identifier: Apache-2.0

// Conduck
// RelayWireSourceDriftGuardTests.swift
//
// Cross-target DRIFT GUARD for the relay wire contract. `AppleSpeechRelayCoordinator.Wire`
// is a LITERAL DUPLICATE in two files (the Watch can't reach the iOS target's
// symbols, and vice-versa — there is no shared module yet; extract to shared
// constants at the next refactor):
//   • iOS:   Conduck/Services/AppleSpeechRelayCoordinator.swift
//   • Watch: ConduckWatch Watch App/Services/AppleSpeechRelayCoordinator.swift
//
// `RelayWireContractTests` pins the iOS copy to its raw strings, but the WATCH
// copy is invisible to this test target (TEST_HOST = Conduck.app) and can drift
// silently — a one-character rename on the Watch side breaks ALL Watch→iPhone
// relay transcription on a real paired device, with NO compile error and no
// failing test. Standing up a watchOS unit-test target is heavy for one enum;
// instead this guard reads BOTH source files off disk (via #filePath) and asserts
// the two `Wire` enums declare the SAME `static let NAME = "VALUE"` string pairs.
// It compares the extracted name→value maps (not raw bytes), so it is immune to
// comment / whitespace / ordering differences and fails ONLY on real contract
// drift. Pairs with RelayWireContractTests: that locks iOS↔raw-strings, this
// locks Watch↔iOS — together the cross-target contract is fully pinned.
//
// Retire this guard when the two copies are replaced by one shared-constants
// source (the planned refactor) — at which point drift becomes impossible.

import XCTest
@testable import Conduck

final class RelayWireSourceDriftGuardTests: XCTestCase {

    /// `.../Conduck/Conduck` — the Xcode project container holding both the iOS
    /// app source (`Conduck/`) and the Watch app source (`ConduckWatch Watch App/`).
    /// Derived from this test file's compile-time absolute path (#filePath →
    /// .../Conduck/Conduck/ConduckTests/<thisFile>), so it is independent of the
    /// test runner's working directory.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)            // .../ConduckTests/RelayWireSourceDriftGuardTests.swift
            .deletingLastPathComponent()           // .../ConduckTests
            .deletingLastPathComponent()           // .../Conduck/Conduck
    }

    /// Extract every `static let NAME = "VALUE"` (string-valued) pair declared
    /// inside the brace-balanced `enum Wire { … }` block of the given source file.
    private func wireStringLiterals(inFileAt url: URL) throws -> [String: String] {
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let anchor = source.range(of: "enum Wire") else {
            throw XCTSkip("No `enum Wire` found in \(url.lastPathComponent) — source layout changed.")
        }
        // Walk from the anchor, capturing the brace-balanced enum body.
        var depth = 0
        var started = false
        var body = ""
        for ch in source[anchor.lowerBound...] {
            if ch == "{" { depth += 1; started = true }
            if started { body.append(ch) }
            if ch == "}" {
                depth -= 1
                if depth == 0 { break }
            }
        }

        var map: [String: String] = [:]
        let regex = try NSRegularExpression(pattern: #"static\s+let\s+(\w+)\s*=\s*"([^"]*)""#)
        let ns = body as NSString
        regex.enumerateMatches(in: body, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges == 3 else { return }
            let name = ns.substring(with: match.range(at: 1))
            let value = ns.substring(with: match.range(at: 2))
            map[name] = value
        }
        return map
    }

    func testWatchAndIOSWireEnumsHaveIdenticalStringLiterals() throws {
        let container = projectContainerURL()
        let iosURL = container.appendingPathComponent("Conduck/Services/AppleSpeechRelayCoordinator.swift")
        let watchURL = container.appendingPathComponent("ConduckWatch Watch App/Services/AppleSpeechRelayCoordinator.swift")

        // Both source files must exist where we expect them (catches a file move).
        XCTAssertTrue(FileManager.default.fileExists(atPath: iosURL.path),
                      "iOS relay source not found at \(iosURL.path) — update this guard's path derivation.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: watchURL.path),
                      "Watch relay source not found at \(watchURL.path) — update this guard's path derivation.")

        let iosLiterals = try wireStringLiterals(inFileAt: iosURL)
        let watchLiterals = try wireStringLiterals(inFileAt: watchURL)

        // Sanity: the iOS side must have parsed the known relay literals (guards a
        // broken extractor masquerading as "no drift").
        XCTAssertEqual(iosLiterals.count, 11,
                       "Expected 11 relay Wire string literals on iOS; parsed \(iosLiterals.count). Update this guard if the contract intentionally grew/shrank.")
        XCTAssertEqual(iosLiterals["kindValue"], "apple-speech-relay",
                       "Extractor sanity check failed — the parser is not reading the Wire literals correctly.")

        XCTAssertEqual(
            watchLiterals, iosLiterals,
            "iOS and Watch AppleSpeechRelayCoordinator.Wire string literals have DRIFTED. The relay protocol is a literal-duplicated contract across targets; a mismatch silently breaks Watch↔iPhone relay on real devices. Re-sync both copies (or extract to shared constants)."
        )
    }
}
