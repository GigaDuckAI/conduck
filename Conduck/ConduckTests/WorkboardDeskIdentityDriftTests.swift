// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardDeskIdentityDriftTests.swift
//
// SOURCE DRIFT GUARD for the single Work desk's identity.
//
// Every capture surface — in-app drop, Chat → Work, the App Intent, the share
// inbox drainer, and the Watch's own raw-Core-Data lane — writes materials onto
// one work item whose id is a compile-time constant. If any surface names a
// different id, its captures land on a desk nothing displays: no compile error,
// no failing behaviour test, and the cards are simply missing from the board on
// every device.
//
// The Watch is the surface at risk, because it cannot call the app's
// `upsertDeskMaterial` (`ConversationStore+Workboard.swift` is not a member of
// that target) and writes the row itself. `Utilities/Constants.swift` IS a
// member of both targets, so the wrist reads `Constants.workboardDeskItemID`
// rather than a copy of it — and this guard exists to keep it that way: it
// reads the sources off disk (via #filePath, so it is independent of the test
// runner's working directory) and fails if the canonical UUID string is ever
// restated anywhere outside `Constants.swift`, or if the Watch capture intent
// stops naming the constant.
//
// A mirrored literal is the repo's fallback for symbols two targets genuinely
// cannot share (see `RelayWireSourceDriftGuardTests`). It is not the fallback
// here, and a duplicate would only reintroduce the drift this guard prevents.

import XCTest
@testable import Conduck

final class WorkboardDeskIdentityDriftTests: XCTestCase {

    /// `.../Conduck/Conduck` — the Xcode project container holding both the iOS
    /// app source (`Conduck/`) and the Watch app source
    /// (`ConduckWatch Watch App/`). Derived from this file's compile-time
    /// absolute path (#filePath → .../Conduck/Conduck/ConduckTests/<thisFile>).
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)            // .../ConduckTests/<thisFile>
            .deletingLastPathComponent()           // .../ConduckTests
            .deletingLastPathComponent()           // .../Conduck/Conduck
    }

    private static let watchCaptureIntentPath = "ConduckWatch Watch App/WorkboardCaptureIntent.swift"
    private static let constantsPath = "Conduck/Utilities/Constants.swift"

    /// Every `.swift` file shipped in the app or the Watch app.
    private func shippedSwiftFiles() throws -> [URL] {
        let container = projectContainerURL()
        var found: [URL] = []
        for directory in ["Conduck", "ConduckWatch Watch App"] {
            let root = container.appendingPathComponent(directory)
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
                "Source directory missing: \(directory)"
            )
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                found.append(url)
            }
        }
        XCTAssertFalse(found.isEmpty, "Enumerated no Swift sources — project layout changed.")
        return found
    }

    func testTheDeskIdentityLiteralExistsOnlyInConstants() throws {
        let identity = Constants.workboardDeskItemID.uuidString
        let container = projectContainerURL()

        let constantsSource = try String(
            contentsOf: container.appendingPathComponent(Self.constantsPath),
            encoding: .utf8
        )
        XCTAssertTrue(
            constantsSource.contains(identity),
            "Constants.swift no longer declares \(identity) — the desk id moved or was rewritten."
        )

        let restating = try shippedSwiftFiles()
            .filter { url in
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return source.range(of: identity, options: .caseInsensitive) != nil
            }
            .map(\.lastPathComponent)
            .sorted()

        XCTAssertEqual(
            restating,
            ["Constants.swift"],
            """
            The desk id is restated outside Constants.swift (\(restating.joined(separator: ", "))). \
            Both the app and the Watch target compile Constants.swift, so every surface must read \
            Constants.workboardDeskItemID; a second copy can drift and silently strand captures on \
            a desk nothing displays.
            """
        )
    }

    func testTheWatchCaptureIntentNamesTheCanonicalDeskConstant() throws {
        let watchSource = try String(
            contentsOf: projectContainerURL().appendingPathComponent(Self.watchCaptureIntentPath),
            encoding: .utf8
        )

        XCTAssertTrue(
            watchSource.contains("Constants.workboardDeskItemID"),
            """
            The Watch capture intent no longer reads Constants.workboardDeskItemID. It writes the \
            desk row with raw Core Data, so nothing else pins the id it captures onto.
            """
        )
        XCTAssertFalse(
            watchSource.contains("UUID(uuidString:"),
            """
            The Watch capture intent builds a UUID from a string literal. Desk identity comes from \
            Constants.workboardDeskItemID; a literal here is exactly the drift this guard prevents.
            """
        )
    }
}
