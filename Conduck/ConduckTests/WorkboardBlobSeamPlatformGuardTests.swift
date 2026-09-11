// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardBlobSeamPlatformGuardTests.swift
//
// SOURCE DRIFT GUARD for the platform gating of `ConversationStore`'s payload
// test seams.
//
// `ConversationStore.swift` is a member of the Watch app target, and the Watch
// app's Debug-Testing configuration defines `CONDUCK_TESTING` exactly as the
// phone's does. So every seam under that flag compiles into the wrist build —
// including the two that reach `WorkMaterialBlob`, an entity the wrist mounts
// NO store for (`storeDescriptions` returns `[core]` under `os(watchOS)`, and
// that omission IS the payload exclusion). A blob insert there has no store to
// land in; a blob fetch there can only come back empty. Either way a watch
// test could call the seam and draw a conclusion the topology cannot support.
//
// This guard cannot live in the Watch suite: what it asserts is the ABSENCE of
// declarations, which compiles to nothing there is anything to call. So it
// reads the source off disk (via #filePath, independent of the runner's working
// directory), tracks the conditional-compilation regions line by line, and
// pins which flags each seam sits under.
//
// The other direction — that `_mountedStoresForTesting` stays available on the
// wrist — needs no source guard: `ConduckWatchSmokeTests` calls that seam from
// the Watch suite, so the compiler refuses the build if it is ever swept into
// the payload guard, and the call proves the Core-only mount at the same time.

import XCTest

final class WorkboardBlobSeamPlatformGuardTests: XCTestCase {

    /// `.../Conduck/Conduck` — the Xcode project container. Derived from this
    /// file's compile-time absolute path
    /// (#filePath → .../Conduck/Conduck/ConduckTests/<thisFile>).
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)            // .../ConduckTests/<thisFile>
            .deletingLastPathComponent()           // .../ConduckTests
            .deletingLastPathComponent()           // .../Conduck/Conduck
    }

    private static let storePath = "Conduck/Services/ConversationStore.swift"

    /// The compilation conditions wrapping each line of `source`, outermost
    /// first, whitespace stripped. Directives are recognised only at the start
    /// of a line, which is where the file writes them; a `#if` quoted inside a
    /// doc comment (this file's subject documents several) starts with `//` and
    /// is skipped, so prose cannot unbalance the stack.
    private func conditionsByLine(of source: String) throws -> [[String]] {
        var stack: [String] = []
        var perLine: [[String]] = []
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") {
                perLine.append(stack)
                continue
            }
            if line.hasPrefix("#if ") {
                stack.append(Self.normalised(String(line.dropFirst(4))))
                perLine.append(stack)
            } else if line.hasPrefix("#elseif ") {
                if !stack.isEmpty { stack.removeLast() }
                stack.append(Self.normalised(String(line.dropFirst(8))))
                perLine.append(stack)
            } else if line == "#else" {
                let inverted = stack.last.map { "!(\($0))" } ?? "?"
                if !stack.isEmpty { stack.removeLast() }
                stack.append(inverted)
                perLine.append(stack)
            } else if line == "#endif" {
                perLine.append(stack)
                if !stack.isEmpty { stack.removeLast() }
            } else {
                perLine.append(stack)
            }
        }
        XCTAssertTrue(
            stack.isEmpty,
            "Unbalanced #if/#endif in \(Self.storePath) — the region walk cannot be trusted."
        )
        return perLine
    }

    private static func normalised(_ condition: String) -> String {
        let withoutTrailingComment = condition.components(separatedBy: "//")[0]
        return withoutTrailingComment.filter { !$0.isWhitespace }
    }

    /// The conditions wrapping the first line whose trimmed text starts with
    /// `declaration`.
    private func conditions(
        wrapping declaration: String,
        in source: String,
        _ perLine: [[String]]
    ) throws -> [String] {
        let lines = source.components(separatedBy: "\n")
        let index = try XCTUnwrap(
            lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(declaration) },
            "\(Self.storePath) no longer declares `\(declaration)` — rename this guard with it."
        )
        return perLine[index]
    }

    private func loadStoreSource() throws -> (String, [[String]]) {
        let source = try String(
            contentsOf: projectContainerURL().appendingPathComponent(Self.storePath),
            encoding: .utf8
        )
        return (source, try conditionsByLine(of: source))
    }

    func testThePayloadSeamsAreCompiledOutOfTheWatchBuild() throws {
        let (source, perLine) = try loadStoreSource()

        let payloadSeams = [
            "struct MaterialBlobStoresForTesting",
            "func _writeMaterialAndBlobForTesting(",
            "struct MaterialBlobSnapshotForTesting",
            "func _materialAndBlobForTesting(",
            "var publicationConfirmationHookForTesting",
            "var projectionVaultReadabilityCallsForTesting",
            "var workMaterialPublicationLockHoldForTesting",
            "func _removeIsolatedVaultDirectoryForTesting("
        ]

        for seam in payloadSeams {
            let conditions = try self.conditions(wrapping: seam, in: source, perLine)
            XCTAssertTrue(
                conditions.contains("CONDUCK_TESTING"),
                "`\(seam)` escaped #if CONDUCK_TESTING — a test seam must not ship."
            )
            XCTAssertTrue(
                conditions.contains("!os(watchOS)"),
                """
                `\(seam)` compiles into the Watch app, whose Debug-Testing build defines \
                CONDUCK_TESTING and mounts no Blobs store. It reaches WorkMaterialBlob, so on the \
                wrist it has no store to write into and nothing but an empty fetch to read. \
                Guard it with #if !os(watchOS). Conditions found: \(conditions).
                """
            )
        }
    }

}
