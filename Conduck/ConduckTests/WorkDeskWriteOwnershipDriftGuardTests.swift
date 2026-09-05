// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkDeskWriteOwnershipDriftGuardTests.swift
//
// OWNERSHIP GUARD over the Work desk's Core Data writes, read from the app's
// own sources on disk.
//
// The desk has exactly ONE write door per target: `upsertDeskMaterial`, in
// `ConversationStore+Workboard.swift` on the phone and Mac, and in the wrist's
// own `WorkboardCaptureIntent.swift`. Everything a person can capture — picker,
// drop, camera, chat capture, the share sheet, a Shortcut, the menu bar, the
// car, the watch relay — lands through that one door, and the door is where the
// desk's invariants live: storage mode from `WorkMaterialStoragePolicy`, rank
// read inside the writing transaction, idempotency on `id`, the desk row
// ensured, thumbnails generated at the single import site.
//
// A second file that inserts a `WorkMaterial` or a `WorkItem` does not fail:
// it writes a card that is subtly wrong — unranked, unpoliced storage, a
// duplicate on replay, or payload bytes in the conversations store — and every
// one of those is invisible in a diff, because the offending code looks exactly
// like the code in the door. This guard is cheap precisely because the door is
// small: the whole rule is "the insert lives here", which a reviewer can check
// in a second and a new surface cannot quietly break.
//
// TWO EXEMPTIONS, both narrow by construction:
//
// (1) `ConversationStore.swift` carries `_writeMaterialAndBlobForTesting`, the
// seam that proves Core Data routes a material and its blob into two physical
// files by configuration membership alone. It has to insert the row itself —
// that is the property under test — and it refuses on anything but the
// isolated test store. It is exempted by its EXACT call shape, not by its
// file: exempting the file would hand a 5,000-line store blanket permission to
// grow a second desk writer.
//
// (2) The Watch app is its own target with its own store mount, so its writer
// is a separate file scanned by a separate method below.
//
// The scan reads squeezed, comment-stripped source, so a multi-line call and a
// one-line call read the same and a header that DESCRIBES an insert cannot
// stand in for one. `RefusalLaneSource.stripComments` does not model string
// literals; a `//` inside a literal would drop the rest of that line, so the
// one direction this guard can miss in is a false pass on an insert written
// after such a literal on the same line — vanishingly unlikely, and the strict
// direction would be a false failure nobody could act on.

import XCTest

final class WorkDeskWriteOwnershipDriftGuardTests: XCTestCase {

    // MARK: - The rule's addresses

    /// The app target's source root, relative to the project container. The
    /// Watch app and the two share extensions are separate directories and are
    /// deliberately not walked here — each is its own target with its own
    /// writer question.
    private static let appTargetDirectory = "Conduck"

    /// The Watch app target. Its store mounts Core alone (no `Blobs`), so its
    /// writer is a different file answering a different question.
    private static let watchTargetDirectory = "ConduckWatch Watch App"

    /// The one app-target door.
    private static let appWriter = "Services/ConversationStore+Workboard.swift"

    /// The one Watch-target door.
    private static let watchWriter = "WorkboardCaptureIntent.swift"

    /// The file holding exemption (1).
    private static let seamPath = "Services/ConversationStore.swift"

    private static let seamFunction = "_writeMaterialAndBlobForTesting"

    /// The desk's two entities. The closing quote is part of the token on
    /// purpose: `"WorkMaterialBlob"` is a different entity in a different
    /// store, written beside the material in the seam above, and matching it
    /// here would flag a row this rule says nothing about.
    private static let entityLiterals = ["\"WorkMaterial\"", "\"WorkItem\""]

    /// Every way Core Data mints a row that is not the generated subclass
    /// initializer. Each is scanned with a window rather than a fixed token so
    /// the entity name may sit on the next line, which is how the seam writes
    /// it and how a formatter will eventually write the others.
    ///
    /// `NSEntityDescription.entity(forEntityName:in:)` is in the list although
    /// it inserts nothing by itself: it is the first half of the
    /// `NSManagedObject(entity:insertInto:)` route, and when that route is
    /// written as two statements the entity name is nowhere near the insert.
    /// Nothing outside the door needs a desk entity's description — reads go
    /// through `NSFetchRequest(entityName:)` — so naming one is signal enough.
    private static let insertionVerbs = [
        "insertNewObject(",
        "NSManagedObject(entity:",
        "NSEntityDescription.entity(forEntityName:"
    ]

    /// The generated-subclass route, where the entity name PRECEDES the call.
    /// The app has no `NSManagedObject` subclasses today; the tokens are here
    /// because generating them is a one-checkbox change that would otherwise
    /// walk straight past this guard.
    private static let subclassInitializers = ["WorkMaterial(context:", "WorkItem(context:"]

    /// Squeezed characters after an insertion verb in which the entity literal
    /// still belongs to THAT call. Long enough for `forEntityName:` on its own
    /// line plus an `NSEntityDescription.entity(forEntityName:in:)` lookup,
    /// short enough that it cannot reach the next statement's literal.
    private static let windowLength = 160

    /// Exemption (1), written in the seam's own shape and squeezed by the same
    /// function that squeezes the source, so this constant stays readable while
    /// matching exactly. Reformatting the seam turns this guard red, which is
    /// the point: an exemption nobody re-reads is a hole nobody remembers.
    private static let exemptSeamCall = squeezed("""
        let material = NSEntityDescription.insertNewObject(
            forEntityName: "WorkMaterial", into: context
        )
        """)

    // MARK: - (1) The app target

    func testOnlyTheWorkboardStoreFileInsertsADeskEntityInTheAppTarget() throws {
        for file in try swiftFiles(under: Self.appTargetDirectory) {
            var source = file.squeezedSource
            if file.relativePath == Self.seamPath {
                source = source.replacingOccurrences(
                    of: Self.exemptSeamCall, with: "", options: [], range: nil
                )
            }
            let sites = Self.deskEntityInsertionSites(in: source)

            XCTAssertTrue(
                sites.isEmpty || file.relativePath == Self.appWriter,
                "\(file.relativePath) inserts a desk entity (\(sites.joined(separator: ", "))). "
                    + "Every in-app capture lands through upsertDeskMaterial in \(Self.appWriter), "
                    + "which is where storage mode, rank, the desk row and idempotency on id are "
                    + "decided. A second writer produces cards that look right and are not."
            )
        }
    }

    /// Non-vacuity. The scan above passes trivially if the entity is renamed or
    /// the insert changes shape, so the door itself is asserted to still be one.
    func testTheDoorStillInsertsBothDeskEntities() throws {
        let source = try Self.squeezedSource(at: Self.containerPath(Self.appWriter))

        for entity in Self.entityLiterals {
            XCTAssertTrue(
                Self.deskEntityInsertionSites(in: source).contains(where: { $0.contains(entity) }),
                "No \(entity) insert left in \(Self.appWriter) — either the desk moved its writes "
                    + "or the entity was renamed, and until this guard's tokens follow, the scan "
                    + "above asserts nothing about anything."
            )
        }
    }

    // MARK: - (2) The one exemption

    /// The seam is exempted by its call shape, and the shape is only tolerable
    /// because the function refuses on the founder's real data. Both halves are
    /// asserted here rather than assumed: an exemption whose justification has
    /// quietly gone is a writer with a permanent pass.
    func testTheIsolatedStoreSeamIsExemptedByItsCallShapeAndStillRefusesTheRealStore() throws {
        let source = try Self.squeezedSource(at: Self.containerPath(Self.seamPath))
        let occurrences = source.components(separatedBy: Self.exemptSeamCall).count - 1

        XCTAssertEqual(
            occurrences, 1,
            "\(Self.seamPath) must carry exactly one copy of the exempted seam call. Zero means "
                + "the seam moved or was reformatted and this exemption is now dead weight "
                + "hiding nothing; two means a second writer was pasted in under cover of it."
        )

        let stripped = source.replacingOccurrences(of: Self.exemptSeamCall, with: "")
        XCTAssertEqual(
            Self.deskEntityInsertionSites(in: stripped), [],
            "\(Self.seamPath) inserts a desk entity outside the exempted seam. The exemption is "
                + "one CALL, never the file: the store is 5,000 lines and every one of them would "
                + "otherwise be allowed to grow a second desk writer."
        )

        let body = try RefusalLaneSource.body(
            ofFunction: Self.seamFunction,
            in: try RefusalLaneSource.source(at: Self.containerPath(Self.seamPath)),
            path: Self.seamPath
        )
        XCTAssertTrue(
            Self.squeezed(body).contains("guardisIsolatedTestStore"),
            "\(Self.seamFunction) may insert a WorkMaterial only because it refuses on anything "
                + "but the isolated test store. Without that gate a signed test run writes a "
                + "fixture card into the founder's own desk, and the exemption above is a hole."
        )
        XCTAssertTrue(
            Self.squeezed(body).contains(Self.exemptSeamCall),
            "The exempted call must live inside \(Self.seamFunction). Exempting a shape that "
                + "has drifted into some other function exempts whatever moved there."
        )
    }

    // MARK: - (3) The Watch target

    func testOnlyTheWatchCaptureIntentInsertsADeskEntityOnTheWrist() throws {
        var writers: [String] = []
        for file in try swiftFiles(under: Self.watchTargetDirectory) {
            let sites = Self.deskEntityInsertionSites(in: file.squeezedSource)
            guard !sites.isEmpty else { continue }
            writers.append(file.relativePath)

            XCTAssertEqual(
                file.relativePath, Self.watchWriter,
                "\(file.relativePath) inserts a desk entity (\(sites.joined(separator: ", "))). "
                    + "The wrist mounts no Blobs store, so its writes have to stay in the one "
                    + "note-only door that knows it — a second writer there produces a card whose "
                    + "payload has no store to land in."
            )
        }
        XCTAssertEqual(
            writers, [Self.watchWriter],
            "The wrist's one desk writer must still be \(Self.watchWriter) — a scan that finds "
                + "none is a renamed entity, not a clean target."
        )
    }

    // MARK: - (4) Controls

    /// The detector's own proof. Each shape below is one a reviewer would read
    /// as an ordinary Core Data insert, and a guard that recognised only the
    /// shape the code happens to use today would pass the day someone reformats.
    func testTheDetectorRecognisesEveryInsertShapeAndIgnoresProseAndFetches() {
        let oneLine = Self.squeezed("""
        let row = NSEntityDescription.insertNewObject(forEntityName: "WorkMaterial", into: context)
        """)
        XCTAssertFalse(Self.deskEntityInsertionSites(in: oneLine).isEmpty)

        let wrapped = Self.squeezed("""
        let row = NSEntityDescription.insertNewObject(
            forEntityName: "WorkItem",
            into: context
        )
        """)
        XCTAssertFalse(Self.deskEntityInsertionSites(in: wrapped).isEmpty)

        let described = Self.squeezed("""
        let entity = NSEntityDescription.entity(forEntityName: "WorkMaterial", in: context)!
        let row = NSManagedObject(entity: entity, insertInto: context)
        """)
        XCTAssertFalse(
            Self.deskEntityInsertionSites(in: described).isEmpty,
            "The NSManagedObject(entity:) route writes exactly the same row and must not be a "
                + "way around the rule."
        )

        let subclass = Self.squeezed("let row = WorkMaterial(context: context)")
        XCTAssertFalse(
            Self.deskEntityInsertionSites(in: subclass).isEmpty,
            "Generated subclasses name the entity BEFORE the call, so they need their own token."
        )

        let fetch = Self.squeezed("""
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        request.fetchLimit = 1
        """)
        XCTAssertEqual(
            Self.deskEntityInsertionSites(in: fetch), [],
            "Reading the desk is what every surface does; only writing it is owned."
        )

        let blob = Self.squeezed("""
        let blob = NSEntityDescription.insertNewObject(forEntityName: "WorkMaterialBlob", into: context)
        """)
        XCTAssertEqual(
            Self.deskEntityInsertionSites(in: blob), [],
            "WorkMaterialBlob is a different entity in a different store; flagging it would make "
                + "the rule say something it does not mean."
        )

        let prose = RefusalLaneSource.stripComments("""
        // Inserts a WorkMaterial via NSEntityDescription.insertNewObject(forEntityName: "WorkMaterial").
        let x = 1
        """)
        XCTAssertEqual(
            Self.deskEntityInsertionSites(in: Self.squeezed(prose)), [],
            "A file that DESCRIBES the door must not read as a second door — every Work file "
                + "discusses this rule at length."
        )
    }

    /// The window has to be short enough that one statement's literal cannot be
    /// credited to the previous statement's verb, or the guard flags the file
    /// that reads the desk beside the file that writes it.
    func testTheWindowDoesNotReachPastTheCallItIsScanning() {
        let neighbours = Self.squeezed("""
        let convo = NSEntityDescription.insertNewObject(forEntityName: "Conversation", into: context)
        convo.setValue(id, forKey: "id")
        convo.setValue(now, forKey: "createdAt")
        convo.setValue(now, forKey: "updatedAt")
        convo.setValue(title, forKey: "title")
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        """)
        XCTAssertEqual(Self.deskEntityInsertionSites(in: neighbours), [])
    }

    // MARK: - Detection

    /// Every place `source` mints a `WorkMaterial` or `WorkItem` row, described
    /// well enough for the failure message to be actionable.
    private static func deskEntityInsertionSites(in source: String) -> [String] {
        var sites: [String] = []

        for verb in insertionVerbs {
            var searchStart = source.startIndex
            while let found = source.range(of: verb, range: searchStart..<source.endIndex) {
                let end = source.index(
                    found.upperBound, offsetBy: windowLength, limitedBy: source.endIndex
                ) ?? source.endIndex
                let window = source[found.upperBound..<end]
                for entity in entityLiterals where window.contains(entity) {
                    sites.append("\(verb)…\(entity)")
                }
                searchStart = found.upperBound
            }
        }

        for initializer in subclassInitializers where source.contains(initializer) {
            sites.append(initializer)
        }

        return sites
    }

    /// Comment-stripped and whitespace-free, so line breaks and indentation
    /// cannot change what the code says.
    private static func squeezed(_ source: String) -> String {
        RefusalLaneSource.stripComments(source).filter { !$0.isWhitespace }
    }

    private static func squeezedSource(at relativePath: String) throws -> String {
        squeezed(try RefusalLaneSource.rawSource(at: relativePath))
    }

    /// `RefusalLaneSource` addresses files from the PROJECT CONTAINER, while the
    /// walk below keys them by their path inside one target directory. Both
    /// spellings of the same file are needed, and mixing them is a guard that
    /// throws "missing file" instead of asserting anything.
    private static func containerPath(_ appTargetRelativePath: String) -> String {
        "\(appTargetDirectory)/\(appTargetRelativePath)"
    }

    // MARK: - Source access

    private struct ScannedFile {
        let relativePath: String
        let squeezedSource: String
    }

    /// Every `.swift` file under one target directory, keyed by its path
    /// relative to that directory. Walking the tree rather than a list is the
    /// whole value: a guard that names the files it checks cannot see the file
    /// somebody adds.
    private func swiftFiles(under directory: String) throws -> [ScannedFile] {
        let root = RefusalLaneSource.projectContainerURL.appendingPathComponent(directory)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "\(directory) is unreadable — update this guard's path derivation"
        )
        var files: [ScannedFile] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = url.path.replacingOccurrences(
                of: root.path + "/", with: "", options: .anchored, range: nil
            )
            files.append(ScannedFile(relativePath: relative, squeezedSource: Self.squeezed(text)))
        }
        XCTAssertFalse(files.isEmpty, "no Swift source found under \(root.path)")
        return files
    }
}
