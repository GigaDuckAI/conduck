// Conduck
// LegalNoticesResourceTests.swift
//
// Drift guard for the in-app Open Source Licenses screen (`LicensesView`).
// Two obligations are pinned here:
//
//   (a) The three legal files bundled under `Conduck/Resources/Legal/`
//       (LICENSE.txt, NOTICE.txt, THIRD_PARTY_NOTICES.md) are BYTE-IDENTICAL
//       to their submodule-root originals (LICENSE, NOTICE,
//       THIRD_PARTY_NOTICES.md). The app displays the copies; the repo root
//       is canonical. If someone edits one side without the other, the app
//       ships stale legal text — this fails.
//
//   (b) EVERY package pin in `Package.resolved` is named in
//       THIRD_PARTY_NOTICES.md. Add an SPM dependency without documenting its
//       license and this fails — Apache-2.0 §4 / MIT notice preservation is a
//       per-distribution obligation, not a one-time write.
//
// Reads files off disk via `#filePath` anchoring (same idiom as
// `WebPageCaptureTests`' mirror guard). Pure Foundation — no Keychain, no
// network, no store. Runs on the unsigned Simulator.

import XCTest
@testable import Conduck

final class LegalNoticesResourceTests: XCTestCase {

    // MARK: - Path anchors

    /// …/Conduck/Conduck — the Xcode-project subdir (holds `Conduck/`,
    /// `ConduckTests/`, `Conduck.xcodeproj/`).
    private var projectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/ConduckTests
            .deletingLastPathComponent()   // …/Conduck (Xcode-project subdir)
    }

    /// …/Conduck — the public submodule root (holds LICENSE / NOTICE /
    /// THIRD_PARTY_NOTICES.md).
    private var submoduleRoot: URL {
        projectDir.deletingLastPathComponent()
    }

    /// …/Conduck/Conduck/Resources/Legal — the bundled copies.
    private var legalResourceDir: URL {
        projectDir
            .appendingPathComponent("Conduck")
            .appendingPathComponent("Resources")
            .appendingPathComponent("Legal")
    }

    private var thirdPartyNoticesURL: URL {
        submoduleRoot.appendingPathComponent("THIRD_PARTY_NOTICES.md")
    }

    private var packageResolvedURL: URL {
        projectDir
            .appendingPathComponent("Conduck.xcodeproj")
            .appendingPathComponent("project.xcworkspace")
            .appendingPathComponent("xcshareddata")
            .appendingPathComponent("swiftpm")
            .appendingPathComponent("Package.resolved")
    }

    // MARK: - (a) Bundled copies are byte-identical to the root originals

    /// `(rootFile, bundledCopy)` pairs. The bundled `.txt` extension is a
    /// resource-friendly rename of the extension-less root files; contents must
    /// match to the byte.
    private var copyPairs: [(root: String, copy: String)] {
        [
            ("LICENSE", "LICENSE.txt"),
            ("NOTICE", "NOTICE.txt"),
            ("THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md"),
        ]
    }

    func testBundledLegalFilesAreByteIdenticalToRootOriginals() throws {
        for pair in copyPairs {
            let rootURL = submoduleRoot.appendingPathComponent(pair.root)
            let copyURL = legalResourceDir.appendingPathComponent(pair.copy)

            let rootData = try Data(contentsOf: rootURL)
            let copyData = try Data(contentsOf: copyURL)

            XCTAssertEqual(
                rootData, copyData,
                "\(pair.copy) has drifted from the repo-root \(pair.root) — the in-app Open Source Licenses screen would ship stale legal text. Re-copy the root file into Conduck/Resources/Legal/."
            )
        }
    }

    // MARK: - (b) Every Package.resolved pin is documented in the notices

    func testEveryResolvedPackageAppearsInThirdPartyNotices() throws {
        let notices = try String(contentsOf: thirdPartyNoticesURL, encoding: .utf8).lowercased()

        struct Resolved: Decodable {
            struct Pin: Decodable { let identity: String }
            let pins: [Pin]
        }
        let data = try Data(contentsOf: packageResolvedURL)
        let resolved = try JSONDecoder().decode(Resolved.self, from: data)

        XCTAssertFalse(resolved.pins.isEmpty, "Package.resolved has no pins — the resolver path is wrong")

        for pin in resolved.pins {
            XCTAssertTrue(
                notices.contains(pin.identity.lowercased()),
                "SPM package '\(pin.identity)' is pinned in Package.resolved but is NOT named in THIRD_PARTY_NOTICES.md — a dependency was added without recording its license (Apache-2.0 §4 / MIT notice preservation)."
            )
        }
    }
}
