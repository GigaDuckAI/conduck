// SPDX-License-Identifier: Apache-2.0
// Conduck
// WorkboardCopyTruthGuardTests.swift
//
// COPY GUARD over the Work desk's user-facing strings, read from the shipped
// catalog on disk rather than through `String(localized:)` — the catalog's `en`
// value is what a user actually reads, and it wins over a source
// `defaultValue:` at runtime, so a guard that resolves the string proves
// nothing about the row that ships.
//
// Three rules, each of which held false copy in front of a user before it
// existed:
//
// (1) VOCABULARY. Work opens, keeps and removes; it never sends, dispatches,
// briefs, or holds a draft. There is no code path from the desk to a gateway,
// so any Work string implying one describes software that does not exist.
// (2) THE SYNC PROMISE. `WorkMaterialStoragePolicy` keeps a payload over
// `Constants.workboardSyncCeilingBytes` in the device-local vault behind a
// reattach, so the tutorial's sync line must name that lane instead of
// promising every byte on every device.
// (3) BOTH DIRECTIONS OF THE CATALOG. A key referenced in source with no row
// renders from its `defaultValue:` and can never be translated; a row no
// source references is dead weight that outlives the surface it was written
// for. Neither is visible in a diff.
//
// Scope is deliberately `workboard.*` only. `intent.workboardCapture.*` is
// Shortcut-facing identity whose copy legitimately says "without sending it to
// an AI", and it is declared twice (app and Watch) so the one-target scan
// below cannot see both halves.

import XCTest

final class WorkboardCopyTruthGuardTests: XCTestCase {

    private static let keyPrefix = "workboard."

    /// The one Work-prefixed string that may talk about sending: the menu bar's
    /// Ask button is the CHAT lane, and it really does reach the gateway. It
    /// lives under a `workboard.` key because it shares the quick-capture
    /// popover, not because Work sends anything.
    private static let chatLaneKeys: Set<String> = ["workboard.menuBar.ask.help"]

    /// The inertness promise. Removed before the vocabulary scan so the one
    /// sentence Work is allowed to say about sending does not trip the rule
    /// that exists to keep every OTHER sentence from saying it.
    private static let inertnessPhrases = [
        "nothing is sent",
        "nothing was sent",
        "nothing has been sent"
    ]

    private static let retiredWords = [
        "send", "sends", "sending", "sent",
        "draft", "drafts",
        "brief", "briefs", "briefing",
        "dispatch", "dispatches", "dispatched"
    ]

    // MARK: - Catalog access

    private func catalogStrings() throws -> [String: Any] {
        let url = RefusalLaneSource.projectContainerURL
            .appendingPathComponent("Conduck/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(json?["strings"] as? [String: Any], "the catalog has no strings table")
    }

    /// The `en` value of one row, or nil for a row that carries none (a
    /// bare-English literal whose key IS the string).
    private func englishValue(_ entry: Any) -> String? {
        guard let entry = entry as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let english = localizations["en"] as? [String: Any],
              let unit = english["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }

    /// Every `.swift` file in the app target, concatenated. The Watch app and
    /// the two share extensions are deliberately excluded: they own their own
    /// catalogs, and a key they alone reference would read as dead here.
    private func appTargetSource() throws -> String {
        let root = RefusalLaneSource.projectContainerURL.appendingPathComponent("Conduck")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "the app target's source tree is unreadable — update this guard's path derivation"
        )
        var combined = ""
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            combined += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        XCTAssertFalse(combined.isEmpty, "no Swift source found under \(root.path)")
        return combined
    }

    // MARK: - (1) Vocabulary

    func testNoWorkStringDescribesSendingDispatchingOrADraft() throws {
        let strings = try catalogStrings()

        for (key, entry) in strings where key.hasPrefix(Self.keyPrefix) {
            guard !Self.chatLaneKeys.contains(key), let value = englishValue(entry) else { continue }

            var scanned = value.lowercased()
            for phrase in Self.inertnessPhrases {
                scanned = scanned.replacingOccurrences(of: phrase, with: " ")
            }
            let words = Set(scanned.split(whereSeparator: { !$0.isLetter }).map(String.init))
            let offenders = words.intersection(Self.retiredWords).sorted()

            XCTAssertTrue(
                offenders.isEmpty,
                "\(key) says \(offenders.joined(separator: ", ")): \(value)\n"
                    + "Work opens, keeps and removes. It has no gateway API, so a Work "
                    + "string may not describe sending, dispatching, or a draft."
            )
        }
    }

    // MARK: - (2) The sync promise

    func testTheTutorialSyncLineNamesTheDeviceLocalLane() throws {
        let strings = try catalogStrings()
        let value = try XCTUnwrap(
            englishValue(try XCTUnwrap(strings["workboard.tutorial.point.review"])),
            "the tutorial's third line must carry an English value"
        )
        let lowered = value.lowercased()

        XCTAssertTrue(
            lowered.contains("icloud"),
            "the line still has to teach that the desk syncs: \(value)"
        )
        XCTAssertFalse(
            lowered.contains("everything"),
            "a payload over Constants.workboardSyncCeilingBytes never leaves the device "
                + "that captured it, so the line may not promise everything: \(value)"
        )
        XCTAssertFalse(
            lowered.contains("all your devices"),
            "an oversized payload reaches no other device until it is reattached there: \(value)"
        )
    }

    // MARK: - (3) Both directions of the catalog

    func testEveryWorkKeyInSourceHasACatalogRow() throws {
        let strings = try catalogStrings()
        let source = try appTargetSource()

        for key in workKeys(in: source) {
            XCTAssertNotNil(
                strings[key],
                "\(key) is referenced in the app target but has no catalog row — it would "
                    + "render from its defaultValue and could never be translated."
            )
        }
    }

    func testEveryWorkCatalogRowIsReferencedInSource() throws {
        let strings = try catalogStrings()
        let source = try appTargetSource()

        for key in strings.keys where key.hasPrefix(Self.keyPrefix) {
            XCTAssertTrue(
                source.contains("\"\(key)\""),
                "\(key) has a catalog row no app-target source references — it outlived "
                    + "the surface it was written for."
            )
        }
    }

    /// Every `"workboard.…"` literal in the given text. Work keys are always
    /// written out in full at the call site, so a literal scan is exact here in
    /// a way it would not be for the catalog's formatted-literal rows.
    private func workKeys(in source: String) -> Set<String> {
        var keys: Set<String> = []
        var remainder = Substring(source)
        while let open = remainder.range(of: "\"\(Self.keyPrefix)") {
            let afterQuote = remainder.index(after: open.lowerBound)
            guard let close = remainder[afterQuote...].firstIndex(of: "\"") else { break }
            let candidate = String(remainder[afterQuote..<close])
            if candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) {
                keys.insert(candidate)
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        return keys
    }
}
