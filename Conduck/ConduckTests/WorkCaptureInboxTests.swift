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
            "share.section.work",
            "share.destination.choose",
            "share.destination.noAI",
            "share.work.error.empty",
            "share.work.error.title",
            "share.work.error.tooLarge",
            "share.work.error.unavailable",
            "share.work.error.invalidContent",
            "share.work.error.unsupportedItem",
        ]
        // Work is ONE desk: the Add to Work row names no card, so neither appex
        // may carry a Work target list, a "New Work" row or an untitled-card
        // placeholder. And Work is a DESTINATION ROW, not a mode: the segmented
        // Work/Send picker, the panel that replaced the list in Work mode, and
        // the two mode-dependent titles are gone with it. Guarded positively so
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
                    "\(relativePath) must not reintroduce the Work destination key \(key)"
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
                    "\(relativePath) must not keep the retired Work destination key \(key)"
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
        XCTAssertTrue(iosShareView.contains("defaultValue: \"Where to?\""))
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

    // MARK: - The share sheet picks nothing, and remembers nothing

    /// The names of the rules `shareSheetPicksNothing` can report, so a negative
    /// control names the rule it expects rather than an index.
    private enum ShareSheetRule {
        static let noInitializer = "a (the destination state carries no initializer)"
        static let rowScoped = "b (every destination assignment is a row's action)"
        static let fiveAssignments = "b (exactly five destination assignment sites)"
        static let notOnAppear = "c (no destination inside onAppear / task)"
        static let noModeNoMemory = "d (no mode picker, no stored pick)"
        static let targetHasNoWork = "e (ShareTarget carries no work case)"
        static let dispatchIsBound = "f (commit dispatches to inbox-bound helpers)"
        static let retryIsWork = "g (Try Again is a Work retry)"
        static let lockedWhileCommitting = "h (the button and the rows lock)"
        static let disabledLooksDisabled = "i (the disabled button is drawn disabled)"
    }

    /// Every way the forbidden mechanisms — a pre-selection, a remembered pick, a
    /// retry that follows whatever row is lit, a refusing button drawn as a live
    /// one — were written at the tip or could plausibly be re-written, as ONE pure
    /// predicate over the source. Returns the rules the source violates; `[]` is a
    /// pass.
    ///
    /// Each rule is evaluated on the source AFTER collapsing every run of
    /// whitespace (newlines included) to a single space, so a line break cannot
    /// split a token a rule looks for.
    ///
    /// What this proves, stated honestly: these are TARGETED REGRESSION CHECKS on
    /// the source's shape. They do not execute the view and they do not prove
    /// absence in general — a novel construction the rules do not name would pass,
    /// which is why the negative controls in the test below sit beside them and
    /// are extended whenever a new dodge is found. The invocation-lifetime
    /// property (a fresh appex process per share) is the system's, not ours.
    private static func shareSheetPicksNothing(source raw: String) -> [String] {
        let source = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var violations: [String] = []

        // (a) The pick starts nil: the declaration is followed by no `=`.
        let declaration = "@State private var destination: ShareDestination? "
        if let declared = source.range(of: declaration) {
            if source[declared.upperBound...].first == "=" {
                violations.append(ShareSheetRule.noInitializer)
            }
        } else {
            violations.append(ShareSheetRule.noInitializer)
        }

        // (b) Every assignment sits in a row's OWN action closure, and there are
        //     exactly five sites: the Work row, the collapsed single-gateway row,
        //     the per-gateway row, the recent row, and the legacy row. An
        //     assignment anywhere else — an onAppear, a task, an init, a didSet,
        //     however it is wrapped or line-broken — breaks the prefix or the count.
        var assignments = 0
        var everyAssignmentIsARowAction = true
        var cursor = source.startIndex
        while let assignment = source.range(of: "destination = ", range: cursor..<source.endIndex) {
            assignments += 1
            let prefixStart = source.index(assignment.lowerBound, offsetBy: -10,
                                           limitedBy: source.startIndex)
            if prefixStart == nil || String(source[prefixStart!..<assignment.lowerBound]) != "action: { " {
                everyAssignmentIsARowAction = false
            }
            cursor = assignment.upperBound
        }
        if !everyAssignmentIsARowAction { violations.append(ShareSheetRule.rowScoped) }
        if assignments != 5 { violations.append(ShareSheetRule.fiveAssignments) }

        // (c) Neither lifecycle hook touches the pick.
        let lifecycleBodies = bracedBodies(in: source, after: ".onAppear {")
            + bracedBodies(in: source, after: ".task {")
        if lifecycleBodies.contains(where: { $0.contains("destination") }) {
            violations.append(ShareSheetRule.notOnAppear)
        }

        // (d) No mode control, and nothing that could hold a pick between shares.
        //     The view reads the snapshot through the host; a view that opens
        //     files is a view that could read a remembered pick.
        let forbidden = ["ShareDisposition", ".pickerStyle(.segmented)", "UserDefaults",
                         "@AppStorage", "@SceneStorage", "NSUbiquitousKeyValueStore",
                         "FileManager"]
        if forbidden.contains(where: { source.contains($0) }) {
            violations.append(ShareSheetRule.noModeNoMemory)
        }

        // (e) The send manifest's target type never learns about the desk.
        if let target = bracedBodies(in: source, after: "enum ShareTarget").first {
            if target.contains("case work") { violations.append(ShareSheetRule.targetHasNoWork) }
        } else {
            violations.append(ShareSheetRule.targetHasNoWork)
        }

        // (f) One read of the pick, then two helpers each bound to ONE inbox.
        let commitBody = bracedBodies(in: source, after: "private func commit()").first ?? ""
        let workHelper = bracedBodies(in: source, after: "private func addToWorkboard()").first ?? ""
        let sendHelper = bracedBodies(in: source, after: "private func send(_ target: ShareTarget)").first ?? ""
        let dispatchIsBound = commitBody.contains("case .work: addToWorkboard()")
            && commitBody.contains("case .send(let target): send(target)")
            && workHelper.contains("onAddToWorkboard(") && !workHelper.contains("destination")
            && sendHelper.contains("onSend(") && !sendHelper.contains("destination")
        if !dispatchIsBound { violations.append(ShareSheetRule.dispatchIsBound) }

        // (g) The retry replays what the person approved, not the current row.
        let retryClosure = bracedBodies(in: source,
                                        after: "primaryButton: .default(Text(Strings.retry))").first ?? ""
        if !retryClosure.contains("addToWorkboard()") || retryClosure.contains("commit()") {
            violations.append(ShareSheetRule.retryIsWork)
        }

        // (h) Nothing commits without a pick, and no tap moves the pick under a
        //     commit already running. The button's predicate is pinned by its
        //     SHAPE, not by a prefix: a `.disabled(destination == nil` check
        //     passed whatever operator came next, so an `&&` — which leaves the
        //     button live with no pick — read as a pass (Codex S-R1-4). The two
        //     permitted bodies are the whole predicate, so a flipped operator, a
        //     dropped clause and an added escape hatch all fail here.
        let primaryPredicate = bracedBodies(in: source, after: "private var isPrimaryDisabled: Bool")
            .first?
            .trimmingCharacters(in: .whitespaces)
        let permittedPredicates = [
            // iOS: a pick is made, and no commit is already running.
            "destination == nil || submissionState.isCommitting",
            // macOS: the same, plus the whole-share attachment-limit refusal.
            "destination == nil || submissionState.isCommitting || attachmentLimitExceeded",
        ]
        let buttonLocked = permittedPredicates.contains(primaryPredicate ?? "")
            && source.contains(".disabled(isPrimaryDisabled)")
            // Nothing may disable the button on its own reading of the pick: the
            // one predicate is the only source, or the look and the behaviour can
            // drift apart again.
            && !source.contains(".disabled(destination")
        if !buttonLocked
            || !source.contains(".disabled(!selectable || submissionState.isCommitting)") {
            violations.append(ShareSheetRule.lockedWhileCommitting)
        }

        // (i) A disabled primary button LOOKS disabled. `.buttonStyle(.plain)` over
        //     an explicit amber fill and an explicit foreground dims neither, so
        //     the mute has to be drawn — and it reads the SAME property as the
        //     `.disabled(…)` above, which is the whole point of that property.
        if !source.contains(".opacity(isPrimaryDisabled ? 0.45 : 1)") {
            violations.append(ShareSheetRule.disabledLooksDisabled)
        }

        return violations
    }

    /// Every `{ … }` body that follows an occurrence of `marker`, brace-matched.
    private static func bracedBodies(in source: String, after marker: String) -> [String] {
        var bodies: [String] = []
        var cursor = source.startIndex
        while let found = source.range(of: marker, range: cursor..<source.endIndex) {
            cursor = found.upperBound
            guard let open = source[found.lowerBound...].firstIndex(of: "{") else { break }
            var depth = 0
            var index = open
            var close: String.Index?
            while index < source.endIndex {
                if source[index] == "{" {
                    depth += 1
                } else if source[index] == "}" {
                    depth -= 1
                    if depth == 0 { close = index; break }
                }
                index = source.index(after: index)
            }
            guard let close else { break }
            bodies.append(String(source[source.index(after: open)..<close]))
            cursor = source.index(after: close)
        }
        return bodies
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

    /// The share sheet picks NOTHING for the person and remembers NOTHING between
    /// invocations, and a button that refuses a commit says so on screen. Both
    /// `ShareView` copies are read off disk and run through the one predicate
    /// above; then seven negative controls mutate that same real source into
    /// shapes the rules exist to reject, and each must be reported — without them
    /// a predicate could pass by being vacuous.
    ///
    /// The fifth control reconstructs the shape this branch replaced (a mode
    /// enum, a pre-selected mode, a pick-reading dispatch). It is a mutation
    /// rather than the tip's file itself because an iOS test host cannot run
    /// `git show`; the tip's real `ShareView` was additionally run through these
    /// same rules from the command line while they were written, and is red on
    /// (a), (d) and (f) there for exactly the reasons the control names.
    func testTheShareSheetPicksNoDestinationAndRemembersNone() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()

        for relativePath in [
            "ConduckShareExtension/ShareView.swift",
            "ConduckShareExtensionMac/ShareView.swift",
        ] {
            let source = try String(
                contentsOf: projectDirectory.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertEqual(
                Self.shareSheetPicksNothing(source: source), [],
                "\(relativePath) broke a rule that keeps the share sheet from picking, remembering or rerouting a destination"
            )

            // 1. A pre-selection restored on appear — the mechanism this branch
            //    deleted, and the one Codex round 1 showed the first draft missed.
            let onAppearPreselect = Self.replacingFirst(
                ".task {", with: ".onAppear { destination = .work }\n        .task {", in: source)
            let onAppearViolations = Self.shareSheetPicksNothing(source: onAppearPreselect)
            XCTAssertTrue(onAppearViolations.contains(ShareSheetRule.rowScoped), relativePath)
            XCTAssertTrue(onAppearViolations.contains(ShareSheetRule.notOnAppear), relativePath)

            // 2. The same thing LINE-BROKEN inside a `.task` — Codex round 2's
            //    dodge of an unnormalised line rule.
            let taskPreselect = Self.replacingFirst(
                ".task {",
                with: ".task {\n            destination =\n                .work\n        }\n        .task {",
                in: source)
            let taskViolations = Self.shareSheetPicksNothing(source: taskPreselect)
            XCTAssertTrue(taskViolations.contains(ShareSheetRule.rowScoped), relativePath)
            XCTAssertTrue(taskViolations.contains(ShareSheetRule.notOnAppear), relativePath)

            // 3. A default written straight onto the state.
            let initializedState = Self.replacingFirst(
                "destination: ShareDestination?", with: "destination: ShareDestination? = .work",
                in: source)
            XCTAssertTrue(
                Self.shareSheetPicksNothing(source: initializedState).contains(ShareSheetRule.noInitializer),
                relativePath)

            // 4. A retry that follows whatever row is lit when the alert closes.
            let reroutingRetry = Self.replacingFirst(
                "addToWorkboard()", with: "commit()", in: source,
                after: "primaryButton: .default(Text(Strings.retry))")
            XCTAssertTrue(
                Self.shareSheetPicksNothing(source: reroutingRetry).contains(ShareSheetRule.retryIsWork),
                relativePath)

            // 5. The shape this branch replaced: a mode enum, a mode pre-selected
            //    to Work, and a dispatch that reads the mode instead of the pick.
            let tipShape = Self.replacingFirst(
                "@State private var destination: ShareDestination?",
                with: "@State private var disposition: ShareDisposition = .work\n    @State private var selection: ShareTarget?",
                in: Self.replacingFirst("addToWorkboard()", with: "break", in: source,
                                        after: "switch destination {"))
            let tipViolations = Self.shareSheetPicksNothing(source: tipShape)
            XCTAssertTrue(tipViolations.contains(ShareSheetRule.noInitializer), relativePath)
            XCTAssertTrue(tipViolations.contains(ShareSheetRule.noModeNoMemory), relativePath)
            XCTAssertTrue(tipViolations.contains(ShareSheetRule.dispatchIsBound), relativePath)

            // 6. The full-strength amber pill this branch shipped with: the button
            //    still refuses every tap, and still looks exactly like the one that
            //    commits (U-66).
            let undimmedButton = Self.replacingFirst(
                ".opacity(isPrimaryDisabled ? 0.45 : 1)", with: "", in: source)
            XCTAssertTrue(
                Self.shareSheetPicksNothing(source: undimmedButton)
                    .contains(ShareSheetRule.disabledLooksDisabled),
                relativePath)

            // 7. The operator the old prefix rule could not see: `&&` leaves the
            //    button live — and, bound to the same property, drawn live — with
            //    no destination picked (Codex S-R1-4).
            let flippedPredicate = Self.replacingFirst(
                "destination == nil ||", with: "destination == nil &&", in: source,
                after: "private var isPrimaryDisabled: Bool")
            XCTAssertTrue(
                Self.shareSheetPicksNothing(source: flippedPredicate)
                    .contains(ShareSheetRule.lockedWhileCommitting),
                relativePath)
        }

        // The send manifest writer takes a gateway target BY TYPE in both hosts,
        // so a Work pick cannot reach it however either view is edited.
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
