// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkCaptureInboxTests.swift
//
// Pure filesystem/contract coverage for inert Workboard capture ingress: bounded
// metadata, cross-process wire parity, atomic claim/release/acknowledge, strict
// payload containment, and crash reconciliation. No gateway, Keychain, network,
// Core Data, or notification permission is touched.

import XCTest
@testable import Conduck

private final class OneShotManifestAccessFailureFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        lock.lock()
        let failNow = shouldFail
            && path.contains("/processing/")
            && path.hasSuffix("/manifest.json")
        if failNow { shouldFail = false }
        lock.unlock()

        if failNow {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadNoPermissionError
            )
        }
        return try super.attributesOfItem(atPath: path)
    }
}

private final class OneShotClaimMoveFailureFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        lock.lock()
        let failNow = shouldFail
            && UUID(uuidString: srcURL.lastPathComponent) != nil
            && dstURL.deletingLastPathComponent().lastPathComponent == "processing"
        if failNow { shouldFail = false }
        lock.unlock()

        if failNow {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteNoPermissionError
            )
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

final class WorkCaptureInboxTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-work-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    @discardableResult
    private func writePublished(
        id: UUID = UUID(),
        version: Int = WorkCaptureEnvelope.currentVersion,
        note: String = "Review this",
        entries: [WorkCaptureEnvelope.Entry]? = nil,
        extraFile: Bool = false
    ) throws -> UUID {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let effectiveEntries = entries ?? [
            WorkCaptureEnvelope.Entry(
                kind: .file,
                sequence: 0,
                relativePath: "payload-000.pdf",
                displayName: "proposal.pdf",
                mimeType: "application/pdf",
                typeIdentifier: "com.adobe.pdf",
                byteCount: 4
            ),
            WorkCaptureEnvelope.Entry(
                kind: .url,
                sequence: 1,
                text: "https://example.com/context"
            ),
        ]
        if effectiveEntries.contains(where: { $0.relativePath == "payload-000.pdf" }) {
            try Data("test".utf8).write(to: directory.appendingPathComponent("payload-000.pdf"))
        }
        if extraFile {
            try Data("unexpected".utf8).write(to: directory.appendingPathComponent("secret.bin"))
        }
        let envelope = WorkCaptureEnvelope(
            version: version,
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            note: note,
            source: .shareExtension,
            entries: effectiveEntries
        )
        try envelope.encoded().write(to: directory.appendingPathComponent("manifest.json"))
        return id
    }

    private func mutateManifest(
        id: UUID,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws {
        let manifestURL = root
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        let data = try Data(contentsOf: manifestURL)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        try mutation(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)
    }

    /// A claimed directory is named for its acquisition, not for the capture, so
    /// nothing can spell its path: identity is read back out of the name.
    private func claimedDirectoryCount(for id: UUID) -> Int {
        let processing = root.appendingPathComponent("processing", isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: processing,
            includingPropertiesForKeys: nil
        )) ?? []
        return children.filter { $0.lastPathComponent.hasPrefix(id.uuidString) }.count
    }

    // MARK: - Wire and sanitation

    func testWireRoundTripPreservesMaterialsAndHasNoDispatchFields() throws {
        let id = UUID()
        let targetWorkItemID = UUID()
        let envelope = WorkCaptureEnvelope(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            note: "Compare these",
            source: .shareExtension,
            targetWorkItemID: targetWorkItemID,
            entries: [
                .init(kind: .text, sequence: 0, text: "source note"),
                .init(kind: .url, sequence: 1, text: "https://example.com"),
                .init(
                    kind: .image,
                    sequence: 2,
                    relativePath: "payload-002.heic",
                    displayName: "IMG.heic",
                    mimeType: "image/heic",
                    typeIdentifier: "public.heic",
                    byteCount: 42
                ),
            ]
        )

        let data = try envelope.encoded()
        let decoded = try WorkCaptureEnvelope.decode(data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.targetWorkItemID, targetWorkItemID)
        let wire = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(wire.contains("gateway"))
        XCTAssertFalse(wire.contains("conversation"))
        XCTAssertFalse(wire.contains("autosend"))
        XCTAssertFalse(wire.contains("dispatch"))
    }

    func testOlderEnvelopeWithoutWorkDestinationDecodesAsNewWork() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","note":"Legacy capture","entries":[]}
        """

        let decoded = try WorkCaptureEnvelope.decode(Data(json.utf8))

        XCTAssertEqual(decoded.id, id)
        XCTAssertNil(decoded.targetWorkItemID)
        XCTAssertEqual(decoded.source, .shareExtension)
    }

    func testConstructorsPreserveOversizedValuesAndPublicationValidationRejectsThem() {
        let oversizedNote = String(
            repeating: "n",
            count: WorkCaptureEnvelope.maximumNoteCharacters + 30
        )
        let noteEnvelope = WorkCaptureEnvelope(
            note: oversizedNote,
            source: .app,
            entries: []
        )
        XCTAssertEqual(noteEnvelope.note, oversizedNote)
        XCTAssertThrowsError(try noteEnvelope.validateForPublication()) { error in
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .noteTooLong
            )
        }

        let entries = (0..<(WorkCaptureEnvelope.maximumEntryCount + 4)).map {
            WorkCaptureEnvelope.Entry(
                kind: .text,
                sequence: $0,
                text: "Material \($0)"
            )
        }
        let entryEnvelope = WorkCaptureEnvelope(source: .app, entries: entries)
        XCTAssertEqual(entryEnvelope.entries.count, entries.count)
        XCTAssertThrowsError(try entryEnvelope.validateForPublication()) { error in
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .tooManyEntries
            )
        }

        let oversizedText = String(
            repeating: "t",
            count: WorkCaptureEnvelope.maximumTextCharacters + 30
        )
        let textEnvelope = WorkCaptureEnvelope(
            source: .app,
            entries: [
                .init(
                    kind: .text,
                    sequence: 0,
                    text: oversizedText
                )
            ]
        )
        XCTAssertEqual(textEnvelope.entries.first?.text, oversizedText)
        XCTAssertThrowsError(try textEnvelope.validateForPublication()) { error in
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .textTooLong
            )
        }

        let unsafeName = String(repeating: "x", count: 121) + ".pdf"
        let metadataEnvelope = WorkCaptureEnvelope(
            source: .app,
            entries: [
                .init(
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.pdf",
                    displayName: unsafeName,
                    byteCount: 1
                )
            ]
        )
        XCTAssertEqual(metadataEnvelope.entries.first?.displayName, unsafeName)
        XCTAssertThrowsError(try metadataEnvelope.validateForPublication()) { error in
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .unsafeMetadata
            )
        }
    }

    func testPublicationValidationAcceptsACompleteBoundedEnvelope() throws {
        let envelope = WorkCaptureEnvelope(
            note: "Compare these",
            source: .shareExtension,
            entries: [
                .init(kind: .text, sequence: 0, text: "Source note"),
                .init(kind: .url, sequence: 1, text: "https://example.com/context"),
                .init(
                    kind: .file,
                    sequence: 2,
                    relativePath: "payload-002.pdf",
                    displayName: "proposal.pdf",
                    mimeType: "application/pdf",
                    typeIdentifier: "com.adobe.pdf",
                    byteCount: 42
                ),
            ]
        )

        XCTAssertNoThrow(try envelope.validateForPublication())
    }

    func testShareSurfacesUseDistinctWorkVocabularyAndAdaptivePrimaryActions() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let expectedWorkKeys = [
            "share.addToWork",
            "share.addToWork.progress",
            "share.send.to",
            "share.destination.noAI.work",
            "share.work.error.empty",
            "share.work.error.title",
            "share.work.error.tooLarge",
            "share.work.error.unavailable",
            "share.work.error.invalidContent",
            "share.work.error.unsupportedItem",
        ]
        // Work is ONE desk: the Add to Work button names no card, so neither appex
        // may carry a Work target list, a "New Work" row or an untitled-card
        // placeholder. And Work is an ACTION on the floor beside Send — not a row
        // in the destination list, and not a mode: there is no Work section
        // header, no segmented Work/Send picker, no panel that replaces the list
        // in Work mode, and no mode-dependent title. The Send button NAMES the
        // destination it would send to, so the sheet never asks the person to
        // "choose a destination"; and where the roster holds no gateway, the line
        // that stands in for the rows points at Work — still one press away on the
        // floor — rather than at a send that cannot happen. Guarded positively so
        // a revert shows up here first.
        let retiredWorkKeys = [
            "share.work.new",
            "share.work.new.detail",
            "share.work.section.destination",
            "share.work.section.recent",
            "share.work.untitled",
            "share.work.desk.detail",
            "share.mode.work",
            "share.mode.send",
            "share.mode.accessibility",
            "share.work.title",
            "share.title",
            "share.send",
            "share.section.work",
            "share.destination.choose",
            "share.destination.noAI",
        ]
        for relativePath in [
            "ConduckShareExtension/ShareView.swift",
            "ConduckShareExtensionMac/ShareView.swift",
        ] {
            let source = try String(
                contentsOf: projectDirectory.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("defaultValue: \"Add to Work\""), relativePath)
            XCTAssertTrue(source.contains("defaultValue: \"Adding to Work…\""), relativePath)
            XCTAssertFalse(source.contains("defaultValue: \"Add to Workboard\""), relativePath)
            XCTAssertTrue(source.contains(".frame(minHeight:"), relativePath)
            XCTAssertTrue(source.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"), relativePath)
            XCTAssertTrue(source.contains(".accessibilityAddTraits(.isHeader)"), relativePath)
            for key in expectedWorkKeys {
                XCTAssertTrue(
                    source.contains("String(localized: \"\(key)\""),
                    "\(relativePath) must use the exact catalog key \(key)"
                )
            }
            for key in retiredWorkKeys {
                XCTAssertFalse(
                    source.contains("String(localized: \"\(key)\""),
                    "\(relativePath) must not reintroduce the retired share key \(key)"
                )
            }
            XCTAssertFalse(source.contains("String(localized: \"share.addToWorkboard"), relativePath)
            XCTAssertFalse(source.contains("String(localized: \"share.workboard."), relativePath)
            XCTAssertFalse(
                source.contains("snapshot.recentWorkItems"),
                "\(relativePath) must not read Work targets — the snapshot publishes none"
            )
        }

        for relativePath in [
            "ConduckShareExtension/Localizable.xcstrings",
            "ConduckShareExtensionMac/Localizable.xcstrings",
        ] {
            let catalog = try String(
                contentsOf: projectDirectory.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for key in expectedWorkKeys {
                XCTAssertTrue(
                    catalog.contains("\"\(key)\" :"),
                    "\(relativePath) must carry the exact source key \(key)"
                )
            }
            for key in retiredWorkKeys {
                XCTAssertFalse(
                    catalog.contains("\"\(key)\" :"),
                    "\(relativePath) must not keep the retired share key \(key)"
                )
            }
            XCTAssertFalse(catalog.contains("\"share.addToWorkboard\" :"), relativePath)
            XCTAssertFalse(catalog.contains("\"share.workboard."), relativePath)
        }

        // The chooser's title is iOS-ONLY. The iOS sheet asks the wrist's own
        // question over the one destination list; the macOS panel has no title
        // bar at all, so the key must exist on exactly one side — a Mac copy that
        // grew it would be carrying a string nothing can render.
        let iosShareView = try String(
            contentsOf: projectDirectory.appendingPathComponent("ConduckShareExtension/ShareView.swift"),
            encoding: .utf8
        )
        let macShareView = try String(
            contentsOf: projectDirectory.appendingPathComponent("ConduckShareExtensionMac/ShareView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(iosShareView.contains("String(localized: \"share.destination.title\""))
        XCTAssertFalse(macShareView.contains("String(localized: \"share.destination.title\""))
        let iosCatalog = try String(
            contentsOf: projectDirectory.appendingPathComponent("ConduckShareExtension/Localizable.xcstrings"),
            encoding: .utf8
        )
        let macCatalog = try String(
            contentsOf: projectDirectory.appendingPathComponent("ConduckShareExtensionMac/Localizable.xcstrings"),
            encoding: .utf8
        )
        XCTAssertTrue(iosCatalog.contains("\"share.destination.title\" :"))
        XCTAssertFalse(macCatalog.contains("\"share.destination.title\" :"))
    }

    // MARK: - The share sheet sends only on a press, and remembers nothing

    /// The names of the rules `shareSheetSendsOnlyOnAPress` can report, so a
    /// negative control names the rule it expects rather than an index.
    private enum ShareSheetRule {
        static let seededOnce = "a (one snapshot-derived seed, no initializer on the declaration)"
        static let rowScoped = "b (every destination assignment is a row's action)"
        static let fourAssignments = "b (exactly four destination assignment sites)"
        static let noActionOffAPress = "c (no pick or dispatch in a lifecycle hook or a row action)"
        static let noModeNoMemory = "d (no mode picker, no stored pick, no destination enum)"
        static let targetHasNoWork = "e (ShareTarget lives in the filter and carries no work case)"
        static let dispatchIsBound = "f (commit sends, each helper is inbox-bound, each button binds to one)"
        static let retryIsWork = "g (Try Again is a Work retry)"
        static let lockedWhileCommitting = "h (both buttons and the rows lock)"
        static let disabledLooksDisabled = "i (a disabled button is drawn disabled)"
        static let shortcutsAreDistinct = "j (Send and Work carry their own shortcuts)"
    }

    /// The boundary this sheet keeps: NOTHING is sent without a press on a button
    /// that names where it goes; nothing survives from one share to the next; the
    /// Work button never reads the pick; and a retry is a Work retry. The sheet
    /// opens with the default gateway's new conversation HIGHLIGHTED — a
    /// highlight, not a decision, derived from the published snapshot alone — so
    /// the rules below police the difference between highlighting a row and
    /// acting on it. Expressed as ONE pure predicate over the view's source and
    /// the `ShareTargetFilter` mirror beside it, which owns the target type;
    /// returns the rules the pair violates, `[]` is a pass.
    ///
    /// Each rule is evaluated AFTER normalizing the source: comments are replaced
    /// by a space and every run of whitespace collapses to one. So a line break
    /// cannot split a token a rule looks for, a comment cannot weld two tokens
    /// together, and a comment parked between a modifier and its closure —
    /// `.task /* resolve */ { commit() }` — cannot hide the closure from the
    /// scanner that reads it.
    ///
    /// Where a rule can be satisfied in more than one shape it pins the WHOLE
    /// body rather than a token inside it — the two commit bodies, the two
    /// helpers, the two predicates, the retry closure. A token check answers
    /// "does the right call appear"; a whole-body check also answers "and nothing
    /// else, in that order", which is what stops a dispatch being reordered ahead
    /// of the guard that makes it exactly-once. Modifiers that belong to one
    /// button are read only inside that button's own stretch of source, so the
    /// two floor actions cannot swap their locks, their mutes or their shortcuts.
    ///
    /// What this proves, stated honestly: these are TARGETED REGRESSION CHECKS on
    /// the source's shape. They do not execute the view and they do not prove
    /// absence in general — a novel construction the rules do not name would pass,
    /// which is why the negative controls in the test below sit beside them and
    /// are extended whenever a new dodge is found. The invocation-lifetime
    /// property (a fresh appex process per share) is the system's, not ours.
    private static func shareSheetSendsOnlyOnAPress(source raw: String, filter rawFilter: String) -> [String] {
        let source = normalized(raw)
        let filter = normalized(rawFilter)
        var violations: [String] = []

        // (a) The highlight has exactly ONE origin: the pure, unit-tested
        //     `ShareTargetFilter.preselectedTarget` adapter, read off the snapshot
        //     the app published and seeded once into the backing store. The
        //     declaration carries no initializer of its own, and no second
        //     `State(initialValue:` exists to smuggle a different opening pick
        //     past that one call.
        let declaration = "@State private var destination: ShareTarget? "
        var seededOnce = true
        if let declared = source.range(of: declaration) {
            if source[declared.upperBound...].first == "=" { seededOnce = false }
        } else {
            seededOnce = false
        }
        let seed = "_destination = State(initialValue: ShareTargetFilter.preselectedTarget(snapshot: snapshot))"
        if occurrences(of: seed, in: source) != 1 { seededOnce = false }
        if occurrences(of: "State(initialValue", in: source) != 1 { seededOnce = false }
        if !seededOnce { violations.append(ShareSheetRule.seededOnce) }

        // (b) The highlight moves only when a row is pressed. Every assignment
        //     that is not that one seed — which writes the backing store and is
        //     rule (a)'s business — sits in a row's OWN action closure, and there
        //     are exactly four: the collapsed single-gateway row, the per-gateway
        //     row, the recent row, and the legacy row. An assignment anywhere else
        //     — an onAppear, a task, an init, a didSet, however it is wrapped or
        //     line-broken — breaks the prefix or the count.
        var assignments = 0
        var everyAssignmentIsARowAction = true
        var cursor = source.startIndex
        while let assignment = source.range(of: "destination = ", range: cursor..<source.endIndex) {
            cursor = assignment.upperBound
            if let before = source.index(assignment.lowerBound, offsetBy: -1,
                                         limitedBy: source.startIndex),
               source[before] == "_" {
                continue
            }
            assignments += 1
            let prefixStart = source.index(assignment.lowerBound, offsetBy: -10,
                                           limitedBy: source.startIndex)
            if prefixStart == nil || String(source[prefixStart!..<assignment.lowerBound]) != "action: { " {
                everyAssignmentIsARowAction = false
            }
        }
        if !everyAssignmentIsARowAction { violations.append(ShareSheetRule.rowScoped) }
        if assignments != 4 { violations.append(ShareSheetRule.fourAssignments) }

        // (c) A press on a named button is the ONLY thing that acts.
        //
        //     A lifecycle hook is read WITH ITS ARGUMENTS, not just its trailing
        //     closure: `.task(id: includePageText) { commit() }` and
        //     `.onAppear(perform: commit)` are hooks too, and the second passes
        //     the dispatcher as a value, so the tokens here are bare identifiers
        //     rather than call sites. `.onChange` counts as one: with
        //     `initial: true` it fires on the first render, which is an appearance
        //     hook wearing another name. A row's action likewise only SELECTS — a row
        //     that dispatched, whether in its closure or by taking the helper as
        //     its action, would send on a single tap, past the button that names
        //     where the share goes.
        let dispatchNames = ["send", "commit", "addToWorkboard", "onSend", "onAddToWorkboard"]
        let lifecycleRegions = attachedRegions(in: source, after: ".onAppear")
            + attachedRegions(in: source, after: ".task")
            + attachedRegions(in: source, after: ".onChange")
        let lifecycleIsQuiet = !lifecycleRegions.contains { region in
            region.contains("destination") || dispatchNames.contains(where: { region.contains($0) })
        }
        let rowsOnlySelect = !bracedBodies(in: source, after: "action: {").contains { body in
            dispatchNames.contains(where: { body.contains($0) })
        }
        // A row may not take a dispatcher AS its action either. The two floor
        // buttons do exactly that and are pinned by (f), so they are the only
        // `action:` bindings allowed to name one.
        var everyDispatcherActionIsAFloorButton = true
        var actionCursor = source.startIndex
        while let bound = source.range(of: "action: ", range: actionCursor..<source.endIndex) {
            actionCursor = bound.upperBound
            let rest = source[bound.upperBound...]
            guard dispatchNames.contains(where: { rest.hasPrefix($0) }) else { continue }
            let prefixStart = source.index(bound.lowerBound, offsetBy: -7,
                                           limitedBy: source.startIndex)
            if prefixStart == nil || String(source[prefixStart!..<bound.lowerBound]) != "Button(" {
                everyDispatcherActionIsAFloorButton = false
            }
        }
        if !lifecycleIsQuiet || !rowsOnlySelect || !everyDispatcherActionIsAFloorButton {
            violations.append(ShareSheetRule.noActionOffAPress)
        }

        // (d) No mode control, and nothing that could hold a pick between shares.
        //     The view reads the snapshot through the host; a view that opens
        //     files is a view that could read a remembered pick. `ShareDestination`
        //     is the retired pick-or-desk enum — the pick is a `ShareTarget` now
        //     that Work is a button rather than a row, so nothing routes through a
        //     type that can carry either.
        let forbidden = ["ShareDisposition", ".pickerStyle(.segmented)", "UserDefaults",
                         "@AppStorage", "@SceneStorage", "NSUbiquitousKeyValueStore",
                         "FileManager", "ShareDestination"]
        if forbidden.contains(where: { source.contains($0) }) {
            violations.append(ShareSheetRule.noModeNoMemory)
        }

        // (e) The send manifest's target type lives in the filter file, beside the
        //     pure route rule that seeds it and the tests that cover both — not in
        //     the view — and it never learns about the desk.
        var targetIsClean = !source.contains("enum ShareTarget:")
        if let target = bracedBodies(in: filter, after: "enum ShareTarget:").first {
            if target.contains("case work") { targetIsClean = false }
        } else {
            targetIsClean = false
        }
        if !targetIsClean { violations.append(ShareSheetRule.targetHasNoWork) }

        // (f) Commit reads the pick ONCE and hands it to the send helper; the two
        //     helpers are each bound to ONE inbox by construction; and each button
        //     names the helper it fires. All three bodies are pinned WHOLE, so a
        //     second call added beside the right one, or a dispatch moved ahead of
        //     the `begin(…)` guard that makes it exactly-once, fails here.
        let commitBody = bracedBodies(in: source, after: "private func commit()")
            .first?
            .trimmingCharacters(in: .whitespaces)
        let permittedCommits = [
            // iOS: read the pick once, hand it to the one send helper.
            "guard let destination else { return } send(destination)",
            // macOS: the same, behind the whole-share attachment-limit refusal.
            "guard !attachmentLimitExceeded else { return } guard let destination else { return } send(destination)",
        ]
        let workHelper = bracedBodies(in: source, after: "private func addToWorkboard()")
            .first?
            .trimmingCharacters(in: .whitespaces)
        let permittedWorkHelpers = [
            "guard submissionState.begin(.addingToWorkboard) else { return } onAddToWorkboard(caption, includePageText)",
            "guard !attachmentLimitExceeded else { return } guard submissionState.begin(.addingToWorkboard) else { return } onAddToWorkboard(caption, includePageText)",
        ]
        let sendHelper = bracedBodies(in: source, after: "private func send(_ target: ShareTarget)")
            .first?
            .trimmingCharacters(in: .whitespaces)
        let permittedSendHelpers = [
            "guard submissionState.begin(.sending) else { return } onSend(caption, target, includePageText)",
            "guard !attachmentLimitExceeded else { return } guard submissionState.begin(.sending) else { return } onSend(caption, target, includePageText)",
        ]
        let dispatchIsBound = permittedCommits.contains(commitBody ?? "")
            && permittedWorkHelpers.contains(workHelper ?? "")
            && permittedSendHelpers.contains(sendHelper ?? "")
            && source.contains("Button(action: addToWorkboard)")
            && source.contains("Button(action: commit)")
        if !dispatchIsBound { violations.append(ShareSheetRule.dispatchIsBound) }

        // (g) The retry replays what the person approved. Only a Work capture can
        //     fail into this alert, so Try Again is a Work retry and NOTHING else
        //     — not a send, not the highlighted row, which may have moved while
        //     the alert stood, and not a direct call on the host's send closure.
        let retryClosure = bracedBodies(in: source,
                                        after: "primaryButton: .default(Text(Strings.retry))")
            .first?
            .trimmingCharacters(in: .whitespaces)
        let retryDispatches = ["send(", "onSend(", "commit("]
        if retryClosure != "addToWorkboard()"
            || retryDispatches.contains(where: { (retryClosure ?? "").contains($0) }) {
            violations.append(ShareSheetRule.retryIsWork)
        }

        // (h) Nothing sends without a pick, Work needs none, and no press moves
        //     anything under a commit already running. Each button's predicate is
        //     pinned by its SHAPE, not by a prefix: a `.disabled(destination == nil`
        //     check passed whatever operator came next, so an `&&` — which leaves
        //     the button live with no pick — read as a pass (Codex S-R1-4). The
        //     permitted bodies are the WHOLE predicate, so a flipped operator, a
        //     dropped clause and an added escape hatch all fail here. Each
        //     `.disabled(…)` is read inside its own button's stretch of source, so
        //     the two cannot be swapped onto each other, and the Work stretch
        //     names the pick nowhere at all.
        let sendSegment = buttonSegment(in: source, action: "commit")
        let workSegment = buttonSegment(in: source, action: "addToWorkboard")
        let primaryPredicate = bracedBodies(in: source, after: "private var isPrimaryDisabled: Bool")
            .first?
            .trimmingCharacters(in: .whitespaces)
        let permittedPrimaryPredicates = [
            // iOS: a pick is highlighted, and no commit is already running.
            "destination == nil || submissionState.isCommitting",
            // macOS: the same, plus the whole-share attachment-limit refusal.
            "destination == nil || submissionState.isCommitting || attachmentLimitExceeded",
        ]
        let workPredicate = bracedBodies(in: source, after: "private var isWorkDisabled: Bool")
            .first?
            .trimmingCharacters(in: .whitespaces)
        let permittedWorkPredicates = [
            // Work asks nothing of the list — one desk, named on the button.
            "submissionState.isCommitting",
            "submissionState.isCommitting || attachmentLimitExceeded",
        ]
        let buttonsLocked = permittedPrimaryPredicates.contains(primaryPredicate ?? "")
            && permittedWorkPredicates.contains(workPredicate ?? "")
            && sendSegment.contains(".disabled(isPrimaryDisabled)")
            && workSegment.contains(".disabled(isWorkDisabled)")
            // Work needs no pick, so its whole stretch names none: a second
            // `.disabled(…)` appended beside the first, written the other way
            // round, would otherwise lock the desk behind the highlight.
            && !workSegment.contains("destination")
            // Nothing may disable a button on its own reading of the pick: the two
            // predicates are the only sources, or the look and the behaviour can
            // drift apart again.
            && !source.contains(".disabled(destination")
        if !buttonsLocked
            || !source.contains(".disabled(!selectable || submissionState.isCommitting)") {
            violations.append(ShareSheetRule.lockedWhileCommitting)
        }

        // (i) A disabled button LOOKS disabled — both of them, each reading its
        //     OWN predicate. `.buttonStyle(.plain)` over an explicit fill and an
        //     explicit foreground dims neither, so the mute has to be drawn, and
        //     it reads the same property as that button's `.disabled(…)` above,
        //     which is the whole point of those two properties.
        if !sendSegment.contains(".opacity(isPrimaryDisabled ? 0.45 : 1)")
            || !workSegment.contains(".opacity(isWorkDisabled ? 0.45 : 1)") {
            violations.append(ShareSheetRule.disabledLooksDisabled)
        }

        // (j) The keyboard reaches both floor actions, and reaches them apart:
        //     ⌘-Return sends, ⌘⇧-Return files to Work. Read per button, so the two
        //     shortcuts cannot be swapped onto each other's action — which would
        //     be the same keypress with the other destination.
        let sendShortcut = ".keyboardShortcut(.return, modifiers: .command)"
        let workShortcut = ".keyboardShortcut(.return, modifiers: [.command, .shift])"
        if !sendSegment.contains(sendShortcut) || sendSegment.contains(workShortcut)
            || !workSegment.contains(workShortcut) || workSegment.contains(sendShortcut) {
            violations.append(ShareSheetRule.shortcutsAreDistinct)
        }

        return violations
    }

    /// The source as every rule sees it: each comment replaced by a single space
    /// — a space, not nothing, so a block comment between two tokens cannot weld
    /// them into one — and then every run of whitespace collapsed to one space.
    /// String literals are tracked, so a `//` inside one is never read as a
    /// comment. Idempotent: a mutant built from an already-normalized source
    /// normalizes to itself, which is what lets the controls below mutate the
    /// normalized text directly.
    private static func normalized(_ raw: String) -> String {
        var output = ""
        var index = raw.startIndex
        var insideString = false
        while index < raw.endIndex {
            let character = raw[index]
            if insideString {
                output.append(character)
                if character == "\\" {
                    let escaped = raw.index(after: index)
                    if escaped < raw.endIndex {
                        output.append(raw[escaped])
                        index = raw.index(after: escaped)
                        continue
                    }
                } else if character == "\"" {
                    insideString = false
                }
                index = raw.index(after: index)
                continue
            }
            if character == "\"" {
                insideString = true
                output.append(character)
                index = raw.index(after: index)
                continue
            }
            let following = raw.index(after: index)
            if character == "/", following < raw.endIndex, raw[following] == "/" {
                while index < raw.endIndex, raw[index] != "\n" { index = raw.index(after: index) }
                output.append(" ")
                continue
            }
            if character == "/", following < raw.endIndex, raw[following] == "*" {
                var depth = 0
                while index < raw.endIndex {
                    let next = raw.index(after: index)
                    if raw[index] == "/", next < raw.endIndex, raw[next] == "*" {
                        depth += 1
                        index = raw.index(after: next)
                        continue
                    }
                    if raw[index] == "*", next < raw.endIndex, raw[next] == "/" {
                        depth -= 1
                        index = raw.index(after: next)
                        if depth == 0 { break }
                        continue
                    }
                    index = raw.index(after: index)
                }
                output.append(" ")
                continue
            }
            output.append(character)
            index = raw.index(after: index)
        }
        return output.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Every `{ … }` body that follows an occurrence of `marker`, brace-matched.
    private static func bracedBodies(in source: String, after marker: String) -> [String] {
        var bodies: [String] = []
        var cursor = source.startIndex
        while let found = source.range(of: marker, range: cursor..<source.endIndex) {
            cursor = found.upperBound
            guard let open = source[found.lowerBound...].firstIndex(of: "{") else { break }
            guard let close = balancedEnd(in: source, from: open) else { break }
            bodies.append(String(source[source.index(after: open)..<close]))
            cursor = source.index(after: close)
        }
        return bodies
    }

    /// The argument list and/or trailing closure attached to each occurrence of
    /// `marker`, as one string per occurrence — so `.task { … }`,
    /// `.task(id: x) { … }` and `.onAppear(perform: f)` are all read, arguments
    /// included. An occurrence with neither attached (a mention in a comment)
    /// contributes an empty string.
    private static func attachedRegions(in source: String, after marker: String) -> [String] {
        var regions: [String] = []
        var cursor = source.startIndex
        while let found = source.range(of: marker, range: cursor..<source.endIndex) {
            cursor = found.upperBound
            var index = found.upperBound
            var region = ""
            for opener in ["(", "{"] {
                var scan = index
                while scan < source.endIndex, source[scan] == " " { scan = source.index(after: scan) }
                guard scan < source.endIndex, String(source[scan]) == opener,
                      let end = balancedEnd(in: source, from: scan) else { continue }
                region += String(source[scan...end])
                index = source.index(after: end)
            }
            regions.append(region)
            if index > cursor { cursor = index }
        }
        return regions
    }

    /// The stretch of source one floor button owns: from its `Button(action: …)`
    /// to the next `Button(`, or the end. A modifier is then only ever read for
    /// the button it actually sits on.
    private static func buttonSegment(in source: String, action: String) -> String {
        guard let start = source.range(of: "Button(action: \(action))") else { return "" }
        guard let next = source.range(of: "Button(", range: start.upperBound..<source.endIndex) else {
            return String(source[start.upperBound...])
        }
        return String(source[start.upperBound..<next.lowerBound])
    }

    /// The index of the `)` or `}` that closes the group opening at `open`.
    private static func balancedEnd(in source: String, from open: String.Index) -> String.Index? {
        let opener = source[open]
        let closer: Character = opener == "(" ? ")" : "}"
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == opener {
                depth += 1
            } else if source[index] == closer {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// How many times `needle` appears in `source` — non-overlapping.
    private static func occurrences(of needle: String, in source: String) -> Int {
        var count = 0
        var cursor = source.startIndex
        while let found = source.range(of: needle, range: cursor..<source.endIndex) {
            count += 1
            cursor = found.upperBound
        }
        return count
    }

    /// Replace the first occurrence of `needle` (optionally, the first one after
    /// `anchor`) — the negative controls' one editing primitive.
    private static func replacingFirst(
        _ needle: String,
        with replacement: String,
        in source: String,
        after anchor: String? = nil
    ) -> String {
        var start = source.startIndex
        if let anchor {
            guard let anchored = source.range(of: anchor) else { return source }
            start = anchored.upperBound
        }
        guard let found = source.range(of: needle, range: start..<source.endIndex) else { return source }
        return source.replacingCharacters(in: found, with: replacement)
    }

    /// The share sheet sends only on a press of a button that names where the
    /// share goes, and it remembers nothing between invocations: the one thing it
    /// starts with is a HIGHLIGHT derived from the snapshot the app published.
    /// Both `ShareView` copies are read off disk with the `ShareTargetFilter`
    /// mirror beside them and run through the one predicate above; then
    /// thirty negative controls mutate that same real source into shapes the rules
    /// exist to reject, and each must report EXACTLY the rules named for it —
    /// without the controls a predicate could pass by being vacuous, and without
    /// the exactness a control could be passing for the wrong reason.
    ///
    /// The controls mutate the NORMALIZED source — comments stripped, whitespace
    /// collapsed — rather than the file's own formatting, because the contract
    /// they encode is a set of normalized literals: a view whose row action is
    /// split over three lines, or carries a comment mid-expression, is the same
    /// shape to every rule here, and a control anchored on the raw text would
    /// silently mutate nothing and pass. Two controls put a line break and a
    /// comment back in, which is the property that makes that safe: the predicate
    /// normalizes whatever it is handed.
    func testTheShareSheetSendsOnlyOnAPressAndRemembersNothing() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let sendShortcut = ".keyboardShortcut(.return, modifiers: .command)"
        let workShortcut = ".keyboardShortcut(.return, modifiers: [.command, .shift])"

        for (relativePath, filterPath) in [
            ("ConduckShareExtension/ShareView.swift", "ConduckShareExtension/ShareTargetFilter.swift"),
            ("ConduckShareExtensionMac/ShareView.swift", "ConduckShareExtensionMac/ShareTargetFilter.swift"),
        ] {
            let source = try String(
                contentsOf: projectDirectory.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let filterSource = try String(
                contentsOf: projectDirectory.appendingPathComponent(filterPath),
                encoding: .utf8
            )
            XCTAssertEqual(
                Self.shareSheetSendsOnlyOnAPress(source: source, filter: filterSource), [],
                "\(relativePath) broke a rule that keeps the share sheet from sending, remembering or rerouting a share without a press"
            )
            let collapsed = Self.normalized(source)
            let collapsedFilter = Self.normalized(filterSource)

            /// One control: the mutated source (and optionally a mutated filter)
            /// must report EXACTLY `expected`.
            func control(
                _ name: String,
                _ mutant: String,
                filter mutantFilter: String? = nil,
                _ expected: [String],
                line: UInt = #line
            ) {
                XCTAssertNotEqual(
                    [mutant, mutantFilter ?? collapsedFilter], [collapsed, collapsedFilter],
                    "\(relativePath) — control \(name) changed nothing, so it proves nothing",
                    line: line
                )
                XCTAssertEqual(
                    Set(Self.shareSheetSendsOnlyOnAPress(source: mutant,
                                                        filter: mutantFilter ?? collapsedFilter)),
                    Set(expected),
                    "\(relativePath) — control \(name)",
                    line: line
                )
            }

            // 1. A dispatch in a lifecycle hook — the share leaves before the sheet
            //    is even on screen. It names no destination, so only the dispatch
            //    half of (c) can catch it.
            control("a send on appearance", Self.replacingFirst(
                ".task {", with: ".task { send(.newConversation(gatewayRef: nil)) } .task {",
                in: collapsed), [ShareSheetRule.noActionOffAPress])

            // 2. A pick written on appear — a highlight that came from somewhere
            //    other than the one snapshot-derived seed.
            control("a highlight written on appear", Self.replacingFirst(
                ".task {", with: ".onAppear { destination = .newConversation(gatewayRef: nil) } .task {",
                in: collapsed),
                [ShareSheetRule.rowScoped, ShareSheetRule.fourAssignments,
                 ShareSheetRule.noActionOffAPress])

            // 3. The same thing LINE-BROKEN inside a `.task` — Codex round 2's
            //    dodge of an unnormalised line rule.
            control("a line-broken highlight in a task", Self.replacingFirst(
                ".task {",
                with: ".task {\n            destination =\n                .newConversation(gatewayRef: nil)\n        }\n        .task {",
                in: collapsed),
                [ShareSheetRule.rowScoped, ShareSheetRule.fourAssignments,
                 ShareSheetRule.noActionOffAPress])

            // 4. A row that selects AND sends — one tap on the list and the share
            //    is gone, past the button that would have named where it went.
            control("a row that also sends", Self.replacingFirst(
                "action: { destination = ",
                with: "action: { send(.newConversation(gatewayRef: nil)); destination = ",
                in: collapsed),
                [ShareSheetRule.rowScoped, ShareSheetRule.noActionOffAPress])

            // 5. A Work helper that also sends — the button says Work, the share
            //    reaches a gateway too.
            control("a Work helper that also sends", Self.replacingFirst(
                "onAddToWorkboard(caption, includePageText)",
                with: "send(.newConversation(gatewayRef: nil)); onAddToWorkboard(caption, includePageText)",
                in: collapsed), [ShareSheetRule.dispatchIsBound])

            // 6. A retry that sends as well as files — and keeps the Work call, so
            //    a rule that only looked for `addToWorkboard()` would pass it.
            control("a retry that also sends", Self.replacingFirst(
                "addToWorkboard()", with: "send(destination!); addToWorkboard()", in: collapsed,
                after: "primaryButton: .default(Text(Strings.retry))"),
                [ShareSheetRule.retryIsWork])

            // 7. A retry that follows whatever row is highlighted when the alert
            //    closes — which, since commit sends, is a send off a Work failure.
            control("a retry that follows the highlight", Self.replacingFirst(
                "addToWorkboard()", with: "commit()", in: collapsed,
                after: "primaryButton: .default(Text(Strings.retry))"),
                [ShareSheetRule.retryIsWork])

            // 8. A pick remembered from the last share, read back out of defaults.
            control("a remembered pick", Self.replacingFirst(
                "@State private var destination: ShareTarget?",
                with: "@State private var destination: ShareTarget? = UserDefaults.standard.string(forKey: \"share.lastPick\").map { ShareTarget.newConversation(gatewayRef: $0) }",
                in: collapsed),
                [ShareSheetRule.seededOnce, ShareSheetRule.noModeNoMemory])

            // 9. A default written straight onto the declaration, bypassing the
            //    one adapter that decides what opens highlighted.
            control("an initializer on the declaration", Self.replacingFirst(
                "@State private var destination: ShareTarget?",
                with: "@State private var destination: ShareTarget? = .newConversation(gatewayRef: nil)",
                in: collapsed), [ShareSheetRule.seededOnce])

            // 10. A SECOND seed beside the first — here pre-picking the legacy
            //     nil-ref route when the roster is unknown, which is exactly the
            //     case `preselectedRoute` refuses to decide.
            control("a second seed", Self.replacingFirst(
                "_destination = State(initialValue: ShareTargetFilter.preselectedTarget(snapshot: snapshot))",
                with: "_destination = State(initialValue: ShareTargetFilter.preselectedTarget(snapshot: snapshot)); if snapshot == nil { _destination = State(initialValue: .newConversation(gatewayRef: nil)) }",
                in: collapsed), [ShareSheetRule.seededOnce])

            // 11. A flipped Send predicate: the button goes live precisely when
            //     there is nothing to send to.
            control("a flipped Send predicate", Self.replacingFirst(
                "destination == nil ||", with: "destination != nil ||", in: collapsed,
                after: "private var isPrimaryDisabled: Bool"),
                [ShareSheetRule.lockedWhileCommitting])

            // 12. The operator the old prefix rule could not see: `&&` leaves the
            //     button live — and, bound to the same property, drawn live — with
            //     no destination picked (Codex S-R1-4).
            control("an && in the Send predicate", Self.replacingFirst(
                "destination == nil ||", with: "destination == nil &&", in: collapsed,
                after: "private var isPrimaryDisabled: Bool"),
                [ShareSheetRule.lockedWhileCommitting])

            // 13. The Work button drawn at full strength while it refuses every
            //     press — the U-66 shape, now on the second button.
            control("an undimmed Work button", Self.replacingFirst(
                ".opacity(isWorkDisabled ? 0.45 : 1)", with: "", in: collapsed),
                [ShareSheetRule.disabledLooksDisabled])

            // 14. The same on the Send button.
            control("an undimmed Send button", Self.replacingFirst(
                ".opacity(isPrimaryDisabled ? 0.45 : 1)", with: "", in: collapsed),
                [ShareSheetRule.disabledLooksDisabled])

            // 15. A Work button wired to the send path — the label says Work and
            //     the press dispatches to the highlighted gateway. Every modifier
            //     the Work button owned goes with it, which is why this one control
            //     reports five rules rather than one.
            control("a Work button wired to send", Self.replacingFirst(
                "Button(action: addToWorkboard)", with: "Button(action: { send(destination!) })",
                in: collapsed),
                [ShareSheetRule.noActionOffAPress, ShareSheetRule.dispatchIsBound,
                 ShareSheetRule.lockedWhileCommitting, ShareSheetRule.disabledLooksDisabled,
                 ShareSheetRule.shortcutsAreDistinct])

            // 16. One keypress for both floor actions — with the Work shortcut
            //     gone the keyboard can only reach the desk by way of the highlight
            //     it is supposed to be independent of.
            control("a missing Work shortcut", Self.replacingFirst(
                workShortcut, with: "", in: collapsed),
                [ShareSheetRule.shortcutsAreDistinct])

            // 17. The desk taught to the send manifest's target type, in the filter
            //     file that now owns it — the one thing that would let a Work
            //     capture reach the gateway writer.
            control("a work case on the target",
                collapsed,
                filter: Self.replacingFirst("enum ShareTarget: Equatable {",
                                            with: "enum ShareTarget: Equatable { case work;",
                                            in: collapsedFilter),
                [ShareSheetRule.targetHasNoWork])

            // 18. The retired pick-or-desk enum brought back — a type that can
            //     carry either inbox, which is what made the two confusable.
            control("the retired pick-or-desk enum", Self.replacingFirst(
                "struct ShareView: View {",
                with: "enum ShareDestination: Equatable { case work; case send(ShareTarget) } struct ShareView: View {",
                in: collapsed), [ShareSheetRule.noModeNoMemory])

            // 19. A hook with ARGUMENTS — a rule that only read `.task {` bodies
            //     saw nothing here, and the share leaves whenever the toggle moves.
            control("a parameterised task that commits", Self.replacingFirst(
                ".task {", with: ".task(id: includePageText) { commit() } .task {", in: collapsed),
                [ShareSheetRule.noActionOffAPress])

            // 20. The dispatcher passed as a VALUE rather than called — no call
            //     parentheses anywhere, which is why the tokens for a hook are bare
            //     identifiers.
            control("a hook that performs the dispatcher", Self.replacingFirst(
                ".task {", with: ".onAppear(perform: commit) .task {", in: collapsed),
                [ShareSheetRule.noActionOffAPress])

            // 21. The host's send closure called STRAIGHT from the Work helper,
            //     skipping the send helper entirely — `send(` is case-sensitive and
            //     never sees `onSend(`.
            control("onSend inside the Work helper", Self.replacingFirst(
                "onAddToWorkboard(caption, includePageText)",
                with: "onSend(caption, .newConversation(gatewayRef: nil), includePageText); onAddToWorkboard(caption, includePageText)",
                in: collapsed), [ShareSheetRule.dispatchIsBound])

            // 22. The same trick in the retry closure.
            control("onSend inside the retry", Self.replacingFirst(
                "addToWorkboard()",
                with: "onSend(caption, destination!, includePageText); addToWorkboard()",
                in: collapsed, after: "primaryButton: .default(Text(Strings.retry))"),
                [ShareSheetRule.retryIsWork])

            // 23. The dispatch moved AHEAD of the guard that makes it
            //     exactly-once: every token a rule looked for is still present, in
            //     the wrong order, and a double press sends twice.
            control("a send ahead of its guard", Self.replacingFirst(
                "guard submissionState.begin(.sending) else { return } onSend(caption, target, includePageText)",
                with: "onSend(caption, target, includePageText); guard submissionState.begin(.sending) else { return }",
                in: collapsed), [ShareSheetRule.dispatchIsBound])

            // 24. The two shortcuts SWAPPED — both still present, so a file-wide
            //     check passed, and ⌘-Return now files to Work while ⌘⇧-Return
            //     sends.
            control("swapped shortcuts", Self.replacingFirst(
                workShortcut, with: sendShortcut,
                in: Self.replacingFirst(sendShortcut, with: workShortcut, in: collapsed)),
                [ShareSheetRule.shortcutsAreDistinct])

            // 25. A row handed the dispatcher as its action rather than calling it
            //     — here as an accessibility action, so VoiceOver sends without the
            //     button that names the destination ever being reached.
            control("a row action bound to a dispatcher", Self.replacingFirst(
                ".disabled(!selectable || submissionState.isCommitting)",
                with: ".disabled(!selectable || submissionState.isCommitting) .accessibilityAction(action: commit)",
                in: collapsed), [ShareSheetRule.noActionOffAPress])

            // 26. The two mutes SWAPPED onto one predicate: both `.opacity(…)`
            //     literals still appear in the file, and the Work button now dims
            //     for a missing pick it does not need.
            control("swapped mutes", Self.replacingFirst(
                ".opacity(isWorkDisabled ? 0.45 : 1)", with: ".opacity(isPrimaryDisabled ? 0.45 : 1)",
                in: collapsed), [ShareSheetRule.disabledLooksDisabled])

            // 27. The target type moved back into the view, away from the pure
            //     route rule and the tests that cover it together.
            control("the target type back in the view", Self.replacingFirst(
                "struct ShareView: View {",
                with: "enum ShareTarget: Equatable { case newConversation(gatewayRef: String?) } struct ShareView: View {",
                in: collapsed), [ShareSheetRule.targetHasNoWork])

            // 28. A second lock appended beside the Work button's own, written the
            //     other way round so the file-wide `.disabled(destination` check
            //     never sees it: Work then refuses every press until a row is
            //     highlighted, which is the one thing the desk never needs.
            control("a Work lock that reads the pick", Self.replacingFirst(
                ".disabled(isWorkDisabled)", with: ".disabled(isWorkDisabled) .disabled(nil == destination)",
                in: collapsed), [ShareSheetRule.lockedWhileCommitting])

            // 29. An appearance hook under another name: `.onChange` with
            //     `initial: true` runs on the first render, so the share leaves
            //     before anyone has pressed anything.
            control("an initial onChange that commits", Self.replacingFirst(
                ".task {", with: ".onChange(of: includePageText, initial: true) { commit() } .task {",
                in: collapsed), [ShareSheetRule.noActionOffAPress])

            // 30. A comment parked between the modifier and its closure — the
            //     scanner skips whitespace, not commentary, so without the
            //     normalizer stripping it first this hook reads as a bare mention.
            control("a comment between a hook and its closure", Self.replacingFirst(
                ".task {", with: ".task /* Resolve the preview */ { commit() } .task {",
                in: collapsed), [ShareSheetRule.noActionOffAPress])
        }

        // The send manifest writer takes a gateway target BY TYPE in both hosts,
        // so a Work capture cannot reach it however either view is edited.
        for relativePath in [
            "ConduckShareExtension/ShareViewController.swift",
            "ConduckShareExtensionMac/ShareViewController.swift",
        ] {
            let source = try String(
                contentsOf: projectDirectory.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let collapsed = source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            XCTAssertTrue(
                collapsed.contains("private func writeEnvelope(uuid: UUID, caption: String, target: ShareTarget,"),
                "\(relativePath) must keep the send writer closed over gateway targets"
            )
        }
    }

    /// The Shortcuts action row and the parameter summary directly beneath it
    /// are two strings for one feature on one screen, and they come from two
    /// declarations. Renaming only the title leaves an action reading "Add to
    /// Work" over a summary reading "Add [thought] to Workboard".
    func testBothCaptureIntentsNameWorkInTheirTitleAndTheirParameterSummary() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let sources = [
            "Conduck/Intents/CaptureWorkboardIntent.swift",
            "ConduckWatch Watch App/WorkboardCaptureIntent.swift",
        ]
        for relativePath in sources {
            let source = try String(
                contentsOf: projectDirectory.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("defaultValue: \"Add to Work\""), relativePath)
            XCTAssertTrue(
                source.contains("Summary(\"Add \\(\\.$thought) to Work\")"),
                "\(relativePath) must not offer a summary under a retired name"
            )
        }

        // The summary literal IS the catalog key, so a stale key means Shortcuts
        // still resolves the old wording on a localized device.
        for relativePath in [
            "Conduck/Localizable.xcstrings",
            "ConduckWatch Watch App/Localizable.xcstrings",
        ] {
            let catalog = try String(
                contentsOf: projectDirectory.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(catalog.contains("\"Add ${thought} to Work\" :"), relativePath)
            XCTAssertFalse(catalog.contains("\"Add ${thought} to Workboard\" :"), relativePath)
        }
    }

    func testFilenameSanitationRemovesPathControlsAndBidiWhilePreservingExtension() {
        let raw = "../../folder\\\u{202E}secret\nproposal.pdf"
        let safe = WorkCaptureEnvelope.safeDisplayName(raw)
        XCTAssertEqual(safe, "secretproposal.pdf")
        XCTAssertFalse(safe?.contains("/") == true)
        XCTAssertFalse(safe?.contains("\\") == true)
        XCTAssertLessThanOrEqual(safe?.count ?? .max, WorkCaptureEnvelope.maximumDisplayNameCharacters)
    }

    func testFilenameSanitationIsIdempotentWhenTruncationExposesTrailingSpace() {
        // Both validators assert `safeDisplayName(x) == x`, so a value the
        // sanitizer produced must survive a second pass unchanged.
        let extensionless = String(repeating: "a", count: 119) + " " + String(repeating: "b", count: 40)
        let sanitized = WorkCaptureEnvelope.safeDisplayName(extensionless)
        XCTAssertEqual(sanitized, String(repeating: "a", count: 119))
        XCTAssertEqual(WorkCaptureEnvelope.safeDisplayName(sanitized), sanitized)

        let named = String(repeating: "a", count: 115) + " " + String(repeating: "b", count: 30) + ".pdf"
        let sanitizedName = WorkCaptureEnvelope.safeDisplayName(named)
        XCTAssertEqual(sanitizedName, String(repeating: "a", count: 115) + ".pdf")
        XCTAssertEqual(WorkCaptureEnvelope.safeDisplayName(sanitizedName), sanitizedName)

        let envelope = WorkCaptureEnvelope(
            source: .shareExtension,
            entries: [
                .init(
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.pdf",
                    displayName: sanitizedName,
                    byteCount: 1
                )
            ]
        )
        XCTAssertNoThrow(try envelope.validateForPublication())
    }

    func testOpaqueMetadataSanitationDropsUnusableTypesInsteadOfFailingTheCapture() {
        XCTAssertEqual(WorkCaptureEnvelope.safeOpaqueMetadata("com.adobe.pdf"), "com.adobe.pdf")
        XCTAssertNil(WorkCaptureEnvelope.safeOpaqueMetadata(nil))
        XCTAssertNil(WorkCaptureEnvelope.safeOpaqueMetadata(""))
        XCTAssertNil(WorkCaptureEnvelope.safeOpaqueMetadata(" com.adobe.pdf "))
        XCTAssertNil(WorkCaptureEnvelope.safeOpaqueMetadata("com.example.\u{202E}pdf"))

        let hostileTypeIdentifier = String(repeating: "u", count: 161)
        XCTAssertNil(WorkCaptureEnvelope.safeOpaqueMetadata(hostileTypeIdentifier))

        let rejected = WorkCaptureEnvelope(
            source: .shareExtension,
            entries: [
                .init(
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.pdf",
                    displayName: "proposal.pdf",
                    typeIdentifier: hostileTypeIdentifier,
                    byteCount: 1
                )
            ]
        )
        XCTAssertThrowsError(try rejected.validateForPublication()) { error in
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .unsafeMetadata
            )
        }

        // The same capture publishes once the source app's unusable type is
        // sanitized away: the annotation is descriptive, the material is not.
        let sanitized = WorkCaptureEnvelope(
            source: .shareExtension,
            entries: [
                .init(
                    kind: .file,
                    sequence: 0,
                    relativePath: "payload-000.pdf",
                    displayName: WorkCaptureEnvelope.safeOpaqueMetadata(
                        WorkCaptureEnvelope.safeDisplayName("proposal.pdf")
                    ),
                    typeIdentifier: WorkCaptureEnvelope.safeOpaqueMetadata(hostileTypeIdentifier),
                    byteCount: 1
                )
            ]
        )
        XCTAssertNil(sanitized.entries.first?.typeIdentifier)
        XCTAssertNoThrow(try sanitized.validateForPublication())
    }

    func testURLRuleAllowsWebAndRejectsLocalOrCredentiallessGarbage() {
        XCTAssertTrue(WorkCaptureEnvelope.isAcceptedWebURL("https://example.com/a"))
        XCTAssertTrue(WorkCaptureEnvelope.isAcceptedWebURL("http://192.168.1.4/context"))
        XCTAssertFalse(WorkCaptureEnvelope.isAcceptedWebURL("file:///private/notes.txt"))
        XCTAssertFalse(WorkCaptureEnvelope.isAcceptedWebURL("javascript:alert(1)"))
        XCTAssertFalse(WorkCaptureEnvelope.isAcceptedWebURL("https:///missing-host"))
    }

    func testThreeCrossProcessEnvelopeCopiesAreIdenticalBelowImport() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let urls = [
            projectDirectory.appendingPathComponent("Conduck/Models/WorkCaptureEnvelope.swift"),
            projectDirectory.appendingPathComponent("ConduckShareExtension/WorkCaptureEnvelope.swift"),
            projectDirectory.appendingPathComponent("ConduckShareExtensionMac/WorkCaptureEnvelope.swift"),
        ]
        let bodies = try urls.map { url -> Substring in
            let source = try String(contentsOf: url, encoding: .utf8)
            let anchor = try XCTUnwrap(source.range(of: "import Foundation"))
            return source[anchor.lowerBound...]
        }
        XCTAssertEqual(String(bodies[0]), String(bodies[1]))
        XCTAssertEqual(String(bodies[0]), String(bodies[2]))
    }

    /// The Watch compiles neither `WorkCaptureEnvelope` nor this bundle, so its
    /// capture bound is a restated literal with no compile-time link to the value
    /// every other ingress enforces. Source text is the only link available.
    ///
    /// Without it, lowering the envelope's bound leaves the wrist accepting a
    /// longer dictation, confirming the capture out loud, and then having
    /// `upsertDeskMaterial` refuse the note — losing words the person has no
    /// other copy of.
    func testTheWatchCaptureBoundStillRestatesTheEnvelopeBound() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let source = try String(
            contentsOf: projectDirectory
                .appendingPathComponent("ConduckWatch Watch App/WorkboardCaptureIntent.swift"),
            encoding: .utf8
        )
        let expected = "maximumNoteCharacters = "
            + Self.swiftIntegerLiteral(WorkCaptureEnvelope.maximumNoteCharacters)

        XCTAssertTrue(
            source.contains(expected),
            "The Watch literal must be moved with WorkCaptureEnvelope.maximumNoteCharacters — expected \(expected)"
        )
    }

    /// Rendered the way the literal is written in source, underscore separators
    /// included, so a value that drifts fails on the exact spelling.
    private static func swiftIntegerLiteral(_ value: Int) -> String {
        let digits = Array(String(value))
        var grouped: [Character] = []
        for (offset, digit) in digits.enumerated() {
            if offset > 0, (digits.count - offset).isMultiple(of: 3) { grouped.append("_") }
            grouped.append(digit)
        }
        return String(grouped)
    }

    // MARK: - Claim lifecycle

    func testAppCapturePublishesNoteAndScreenshotAsOneClaim() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)
        let screenshot = Data([0x89, 0x50, 0x4E, 0x47])

        let id = try await inbox.publishAppCapture(
            note: "Compare this layout",
            screenshotPNG: screenshot,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1)
        let claimedValue = try await inbox.claimNext()
        let claimed = try XCTUnwrap(claimedValue)
        XCTAssertEqual(claimed.id, id)
        XCTAssertEqual(claimed.envelope.source, .app)
        XCTAssertEqual(claimed.envelope.note, "Compare this layout")
        let image = try XCTUnwrap(claimed.envelope.entries.first)
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.byteCount, Int64(screenshot.count))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(claimed.payloadURL(for: image))), screenshot)
    }

    func testAppCaptureReplayAfterAcknowledgementKeepsEnvelopeAndEntryIdentity() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)
        let captureID = UUID(uuidString: "E50E9C29-C4FB-40F3-9C68-3D3AA141356B")!
        let screenshot = Data([0x89, 0x50, 0x4E, 0x47])

        _ = try await inbox.publishAppCapture(
            note: "Keep this once",
            screenshotPNG: screenshot,
            captureID: captureID
        )
        let firstValue = try await inbox.claimNext()
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.id, captureID)
        XCTAssertEqual(first.envelope.entries.map(\.id), [captureID])
        try await inbox.acknowledge(first)

        // Simulates an intent killed after publish + drain but before clearing
        // its audio guard. Re-publication has the same identities even though
        // the acknowledged queue directory no longer exists.
        _ = try await inbox.publishAppCapture(
            note: "Keep this once",
            screenshotPNG: screenshot,
            captureID: captureID
        )
        let replayValue = try await inbox.claimNext()
        let replay = try XCTUnwrap(replayValue)
        XCTAssertEqual(replay.id, captureID)
        XCTAssertEqual(replay.envelope.entries.map(\.id), [captureID])
        XCTAssertEqual(replay.envelope.note, first.envelope.note)
    }

    func testEmptyAppCaptureFailsWithoutPublishingPartialDirectory() async throws {
        let inbox = WorkCaptureInbox(baseURL: root)

        do {
            _ = try await inbox.publishAppCapture(note: "   ", screenshotPNG: nil)
            XCTFail("An empty quick capture must not be published")
        } catch {
            XCTAssertEqual(
                error as? WorkCaptureEnvelope.PublicationValidationFailure,
                .emptyCapture
            )
        }
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testClaimReturnsValidatedPayloadThenAcknowledgeDeletesIt() async throws {
        let id = try writePublished()
        let inbox = WorkCaptureInbox(baseURL: root)

        let nextClaim = try await inbox.claimNext()
        let claim = try XCTUnwrap(nextClaim)
        XCTAssertEqual(claim.id, id)
        let pendingAfterClaim = try await inbox.pendingCount()
        XCTAssertEqual(pendingAfterClaim, 0)
        let fileEntry = try XCTUnwrap(claim.envelope.entries.first(where: { $0.kind == .file }))
        let payloadURL = try XCTUnwrap(claim.payloadURL(for: fileEntry))
        XCTAssertEqual(try Data(contentsOf: payloadURL), Data("test".utf8))

        try await inbox.acknowledge(claim)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claim.directoryURL.path))
        do {
            try await inbox.acknowledge(claim)
            XCTFail("A completed token must not acknowledge a later claim")
        } catch {
            XCTAssertEqual(error as? WorkCaptureInbox.InboxError, .staleClaim)
        }
    }

    func testReleaseMakesClaimPendingAgainWithoutChangingIdentity() async throws {
        let id = try writePublished()
        let inbox = WorkCaptureInbox(baseURL: root)
        let firstResult = try await inbox.claimNext()
        let first = try XCTUnwrap(firstResult)

        try await inbox.release(first)
        let pendingAfterRelease = try await inbox.pendingCount()
        XCTAssertEqual(pendingAfterRelease, 1)
        let secondResult = try await inbox.claimNext()
        let second = try XCTUnwrap(secondResult)
        XCTAssertEqual(second.id, id)
        XCTAssertNotEqual(second.token, first.token)
    }

    func testActiveClaimCannotBeClaimedTwice() async throws {
        _ = try writePublished()
        let inbox = WorkCaptureInbox(baseURL: root)
        let first = try await inbox.claimNext()
        _ = try XCTUnwrap(first)
        let second = try await inbox.claimNext()
        XCTAssertNil(second)
    }

    // MARK: - Validation and reconciliation

    func testUnsupportedEnvelopeVersionIsRejectedAndRemoved() async throws {
        let id = try writePublished(version: WorkCaptureEnvelope.currentVersion + 1)
        let inbox = WorkCaptureInbox(baseURL: root)

        do {
            _ = try await inbox.claimNext()
            XCTFail("A future wire version must not be interpreted with v1 semantics")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .invalidEnvelope(id, .unsupportedVersion))
        }
        XCTAssertEqual(claimedDirectoryCount(for: id), 0)
    }

    func testDecodedUnsafeFilenameMIMEAndTypeMetadataAreRejected() async throws {
        let mutations: [(String, String)] = [
            ("displayName", "report\u{2028}spoof.pdf"),
            ("mimeType", String(repeating: "x", count: 161)),
            ("typeIdentifier", "public.text\nspoofed"),
        ]

        for (key, value) in mutations {
            let id = try writePublished()
            try mutateManifest(id: id) { manifest in
                var entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
                entries[0][key] = value
                manifest["entries"] = entries
            }
            let inbox = WorkCaptureInbox(baseURL: root)

            do {
                _ = try await inbox.claimNext()
                XCTFail("Unsafe decoded \(key) metadata must not enter persistence")
            } catch let error as WorkCaptureInbox.InboxError {
                XCTAssertEqual(error, .invalidEnvelope(id, .unsafeMetadata), key)
            }
        }
    }

    func testHiddenUnreferencedPayloadIsIncludedInExactChildValidation() async throws {
        let id = try writePublished()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try Data("hidden".utf8).write(to: directory.appendingPathComponent(".private"))
        let inbox = WorkCaptureInbox(baseURL: root)

        do {
            _ = try await inbox.claimNext()
            XCTFail("Hidden unreferenced bytes must not bypass containment")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .invalidEnvelope(id, .unexpectedPayload))
        }
    }

    func testTransientManifestAccessFailurePreservesCaptureForRetry() async throws {
        let id = try writePublished()
        let fileManager = OneShotManifestAccessFailureFileManager()
        let inbox = WorkCaptureInbox(baseURL: root, fileManager: fileManager)

        do {
            _ = try await inbox.claimNext()
            XCTFail("A transient protection failure must surface")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .filesystemFailure)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(id.uuidString).path
        ), "Transient I/O must roll the claim back to pending")
        XCTAssertEqual(claimedDirectoryCount(for: id), 0)

        let retried = try await inbox.claimNext()
        XCTAssertEqual(try XCTUnwrap(retried).id, id)
    }

    func testTransientClaimMoveFailureSurfacesAndLeavesCapturePending() async throws {
        let id = try writePublished()
        let fileManager = OneShotClaimMoveFailureFileManager()
        let inbox = WorkCaptureInbox(baseURL: root, fileManager: fileManager)

        do {
            _ = try await inbox.claimNext()
            XCTFail("A protected pending directory must not look like an empty queue")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .filesystemFailure)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(id.uuidString).path
        ))

        let retried = try await inbox.claimNext()
        XCTAssertEqual(try XCTUnwrap(retried).id, id)
    }

    func testScaffoldFailureIsReportedAndRetriedInsteadOfLatched() async throws {
        let blockedBase = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedBase)
        let inbox = WorkCaptureInbox(baseURL: blockedBase)

        do {
            _ = try await inbox.pendingCount()
            XCTFail("A failed scaffold must not masquerade as an empty queue")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .filesystemFailure)
        }
        let report = await inbox.reconcile()
        XCTAssertTrue(report.encounteredFilesystemFailure)

        try FileManager.default.removeItem(at: blockedBase)
        let recoveredPendingCount = try await inbox.pendingCount()
        XCTAssertEqual(recoveredPendingCount, 0,
                       "didScaffold must stay false so a later call can recover")
    }

    func testTraversalPathIsRejectedAndPrivateBytesAreRemoved() async throws {
        let id = UUID()
        let entries = [WorkCaptureEnvelope.Entry(
            kind: .file,
            sequence: 0,
            relativePath: "../escape.pdf",
            displayName: "escape.pdf",
            byteCount: 4
        )]
        _ = try writePublished(id: id, entries: entries)
        let inbox = WorkCaptureInbox(baseURL: root)

        do {
            _ = try await inbox.claimNext()
            XCTFail("Unsafe relative paths must not be imported")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .invalidEnvelope(id, .unsafeRelativePath))
        }
        XCTAssertEqual(claimedDirectoryCount(for: id), 0)
    }

    func testUnexpectedUnreferencedPayloadIsRejected() async throws {
        let id = try writePublished(extraFile: true)
        let inbox = WorkCaptureInbox(baseURL: root)
        do {
            _ = try await inbox.claimNext()
            XCTFail("Unreferenced bytes must not ride into a draft")
        } catch let error as WorkCaptureInbox.InboxError {
            XCTAssertEqual(error, .invalidEnvelope(id, .unexpectedPayload))
        }
    }

    func testReconcileReleasesCrashStrandedClaimAndSweepsOnlyOldTmp() async throws {
        let id = try writePublished()
        let processing = root.appendingPathComponent("processing", isDirectory: true)
        try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: root.appendingPathComponent(id.uuidString),
            to: processing.appendingPathComponent(id.uuidString)
        )
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        let old = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fresh = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: old.path
        )

        let inbox = WorkCaptureInbox(baseURL: root)
        let report = await inbox.reconcile(now: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(report, .init(releasedClaimCount: 1, removedTemporaryCount: 1, collisionCount: 0))
        let pending = try await inbox.pendingCount()
        XCTAssertEqual(pending, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    @MainActor
    func testCaptureDrainOwnsDurableTaskAcrossItsOwnChangeNotification() async {
        let refreshed = expectation(description: "board refreshes after durable drain")
        var coordinator: WorkCaptureRefreshCoordinator!
        var drainPassCount = 0
        var refreshCount = 0
        var durableMutationCompleted = false

        coordinator = WorkCaptureRefreshCoordinator(
            refreshDelay: .seconds(30),
            boardIsVisible: { true },
            drainCaptures: {
                drainPassCount += 1
                if drainPassCount == 1 {
                    // Mirrors claim/ack posting `didChangeNotification` while the
                    // owning drain is suspended. An unrelated UI notification is
                    // also queued to prove only its debounce task is cancelable.
                    coordinator.schedule(includeCaptureDrain: false)
                    coordinator.schedule(includeCaptureDrain: true)
                    await Task.yield()
                    XCTAssertFalse(Task.isCancelled)
                    durableMutationCompleted = true
                }
                return true
            },
            refresh: {
                refreshCount += 1
                XCTAssertTrue(durableMutationCompleted)
                refreshed.fulfill()
            }
        )

        coordinator.schedule(includeCaptureDrain: true)
        await fulfillment(of: [refreshed], timeout: 2)

        XCTAssertEqual(drainPassCount, 2, "The self-notification is serialized as one follow-up pass")
        XCTAssertEqual(refreshCount, 1, "UI reload happens once after queue ownership is released")
    }

    @MainActor
    func testFailedCaptureDrainDefersRetryInsteadOfSpinningOnReleaseNotification() async {
        let refreshed = expectation(description: "board refreshes after failed durable drain")
        var coordinator: WorkCaptureRefreshCoordinator!
        var drainPassCount = 0

        coordinator = WorkCaptureRefreshCoordinator(
            refreshDelay: .seconds(30),
            boardIsVisible: { true },
            drainCaptures: {
                drainPassCount += 1
                // Mirrors the failed claim being released to pending, which
                // posts another inbox-change notification before returning.
                coordinator.schedule(includeCaptureDrain: true)
                return false
            },
            refresh: { refreshed.fulfill() }
        )

        coordinator.schedule(includeCaptureDrain: true)
        await fulfillment(of: [refreshed], timeout: 2)
        await Task.yield()

        XCTAssertEqual(drainPassCount, 1, "A persistent store failure waits for a later app wake")
    }
}
