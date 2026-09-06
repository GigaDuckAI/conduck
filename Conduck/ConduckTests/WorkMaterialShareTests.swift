// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkMaterialShareTests.swift
//
// Share is the one Work affordance that puts a card's bytes somewhere this app
// cannot see afterwards, so these tests hold the three things that decide
// whether that is safe:
//
//   WHAT LEAVES. The bytes handed over are the card's ORIGINAL payload, byte
//   for byte, under a filename that states what they are. A thumbnail reaching
//   a share sheet in place of a photograph, or a recording arriving as an
//   extensionless blob, are both silent failures — the sheet opens, something
//   is shared, and only the person on the other end finds out.
//
//   WHETHER IT MAY LEAVE AT ALL. Preparation suspends, and the desk moves under
//   it. Every refusal here is re-asked against the board as it stands when the
//   copy finishes, because the snapshot the menu closed over is a value from
//   the last board load.
//
//   WHAT HAPPENS TO THE COPY. A copy nobody was shown is reclaimed at once; a
//   copy that WAS shown is left to the per-copy age sweep, because no signal
//   comes back from another process. The sweep has to age each copy on its own
//   — the defect it replaces aged the whole preview folder, so a copy made a
//   second ago inside a day-old folder was deleted out from under a live share.

import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import Conduck

// MARK: - Doubles

/// Records what would have been presented. The real presenter needs a window;
/// every decision under test happens before it is reached.
@MainActor
private final class RecordingSharePresenter: WorkSharePresenting {
    private(set) var presented: [PreparedWorkShare] = []
    /// What `present` reports — `false` is the arm where UIKit refused the
    /// request, which must reclaim rather than count as a hand-off.
    var succeeds = true
    /// What the readiness wait reports. `false` is a surface that never settled.
    var isReady = true
    private(set) var readinessCalls = 0
    /// Run while the readiness wait is "in progress", which is the window
    /// between the two store gates. A test moves the store here.
    var duringReadinessWait: (@MainActor () -> Void)?

    func awaitPresentationReadiness(from anchor: SharePresentationAnchor) async -> Bool {
        readinessCalls += 1
        duringReadinessWait?()
        return isReady
    }

    func present(_ share: PreparedWorkShare, from anchor: SharePresentationAnchor) -> Bool {
        guard succeeds else { return false }
        presented.append(share)
        return true
    }
}

/// A real window to attach anchors to.
///
/// The registry keys off actual window attachment, so the two ordering cases
/// below need a window rather than a stub — and they need one on BOTH platforms,
/// because the anchor is a `UIView` on one and an `NSView` on the other while
/// the rule under test is the same for each.
@MainActor
private final class AnchorWindow {
    #if canImport(UIKit)
    private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    #else
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    #endif

    func attach(_ view: SharePresentationAnchorPlatformView) {
        #if canImport(UIKit)
        window.addSubview(view)
        #else
        window.contentView?.addSubview(view)
        #endif
    }
}

/// Holds a preparation open until the test decides the desk has moved.
private actor PreparationGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let resuming = waiting
        waiting.removeAll()
        for continuation in resuming { continuation.resume() }
    }
}

@MainActor
final class WorkMaterialShareTests: XCTestCase {

    /// Only the store-level rollback case needs one; it mints a vault directory
    /// of its own that nothing else removes.
    private let isolated = IsolatedWorkStores()

    override func tearDown() async throws {
        await isolated.cleanUp()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func card(
        id: UUID = UUID(),
        kind: WorkboardMaterialKind = .file,
        name: String = "Report",
        mimeType: String? = "application/pdf",
        availability: WorkboardMaterialAvailability = .available,
        textContent: String? = nil,
        urlString: String? = nil,
        revision: Int64 = 1
    ) -> WorkboardMaterialSnapshot {
        WorkboardMaterialSnapshot(
            id: id,
            kind: kind,
            name: name,
            textContent: textContent,
            urlString: urlString,
            mimeType: mimeType,
            availability: availability,
            revision: revision
        )
    }

    /// The blob a card publishing these bytes names.
    private func hex(_ payload: Data) -> String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    /// A byte source that answers from memory, with no store anywhere near it.
    private func bytes(
        payload: Data?,
        localURL: URL? = nil,
        gate: PreparationGate? = nil
    ) -> WorkMaterialExportBytes {
        WorkMaterialExportBytes(
            localURL: { _ in
                if let gate { await gate.wait() }
                return localURL
            },
            payload: { _ in
                if let gate, localURL == nil { await gate.wait() }
                return payload
            }
        )
    }

    /// Every filename currently sitting inside a live export container.
    ///
    /// A copy nobody presented leaves no URL for a test to hold, so reclaim is
    /// asserted by looking for the copy's NAME on disk. Reading names rather
    /// than counting containers keeps the assertion true whatever else is
    /// staging files in the shared temporary directory at the same moment,
    /// which is why every test below gives its card a name of its own.
    private func liveExportedFilenames() -> Set<String> {
        let root = FileManager.default.temporaryDirectory
        let containers = ((try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )) ?? []).filter {
            $0.lastPathComponent.hasPrefix(WorkMaterialExportSnapshot.containerPrefix)
        }
        return Set(containers.flatMap { container in
            (try? FileManager.default.contentsOfDirectory(atPath: container.path)) ?? []
        })
    }

    // MARK: - What a card resolves to

    /// One row per kind. A note and a link never touch the file system at all —
    /// they are already the thing the share sheet wants — while every byte-
    /// bearing kind resolves to a disposable copy.
    func testEveryKindPreparesAsTheThingItActuallyIs() async throws {
        let note = try await WorkMaterialShareCoordinator.prepare(
            card(kind: .note, name: "Thought", mimeType: nil, textContent: "Ship the thing"),
            bytes: bytes(payload: nil)
        )
        guard case .text(let text) = note else {
            return XCTFail("a note shares its own text, not a file")
        }
        XCTAssertEqual(text, "Ship the thing")

        let link = try await WorkMaterialShareCoordinator.prepare(
            card(kind: .link, name: "Docs", mimeType: nil, urlString: "https://example.com/a"),
            bytes: bytes(payload: nil)
        )
        guard case .link(let url) = link else {
            return XCTFail("a link shares a URL so receiving apps treat it as one")
        }
        XCTAssertEqual(url.absoluteString, "https://example.com/a")

        for kind in [WorkboardMaterialKind.image, .file, .audio] {
            let prepared = try await WorkMaterialShareCoordinator.prepare(
                card(kind: kind, name: "Payload", mimeType: "application/pdf"),
                bytes: bytes(payload: Data("bytes".utf8))
            )
            guard case .file(let snapshot) = prepared else {
                return XCTFail("\(kind) carries bytes, so it shares a file copy")
            }
            snapshot.reclaim()
        }
    }

    /// An empty note would open a share sheet on an empty string, which offers
    /// a person nothing to choose between. Its title is the fallback.
    func testAnEmptyNoteSharesItsTitleRatherThanAnEmptyString() async throws {
        let prepared = try await WorkMaterialShareCoordinator.prepare(
            card(kind: .note, name: "Untitled thought", mimeType: nil, textContent: ""),
            bytes: bytes(payload: nil)
        )
        guard case .text(let text) = prepared else { return XCTFail("a note shares text") }
        XCTAssertEqual(text, "Untitled thought")
    }

    // MARK: - What the person actually receives

    /// The whole point of the feature. A share that quietly hands over a
    /// re-encoded or truncated payload is worse than one that fails.
    func testASharedCopyHoldsTheStoredPayloadByteForByte() async throws {
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let prepared = try await WorkMaterialShareCoordinator.prepare(
            card(kind: .image, name: "Camera original", mimeType: "image/jpeg"),
            bytes: bytes(payload: payload)
        )
        guard case .file(let snapshot) = prepared else { return XCTFail("an image shares a file") }
        defer { snapshot.reclaim() }

        XCTAssertEqual(try Data(contentsOf: snapshot.url), payload)
        XCTAssertEqual(snapshot.contentType, .jpeg)
    }

    /// The vault lane, which COPIES rather than writes. Same guarantee, and the
    /// source is left exactly where it was — an export that moved the vault's
    /// own leaf would take the card's bytes off the desk.
    func testTheVaultLaneCopiesTheOriginalAndLeavesItInPlace() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-workasset-tests-\(UUID().uuidString).m4a")
        let payload = Data("a recording".utf8)
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let prepared = try await WorkMaterialShareCoordinator.prepare(
            card(kind: .audio, name: "Voice note", mimeType: "audio/mp4"),
            bytes: bytes(payload: nil, localURL: source)
        )
        guard case .file(let snapshot) = prepared else { return XCTFail("a recording shares a file") }
        defer { snapshot.reclaim() }

        XCTAssertEqual(try Data(contentsOf: snapshot.url), payload)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.path),
            "the vault's authoritative leaf is copied, never moved"
        )
        XCTAssertNotEqual(
            snapshot.url.path,
            source.path,
            "an external app may mutate what it is given, so it never receives the vault URL"
        )
    }

    // MARK: - Naming parity between the two lanes

    /// The defect this ordering exists to stop: both lanes used to decide
    /// "does this title already carry an extension?" differently, so a card
    /// called "Meeting v1.2" was treated as having the extension `.2` on the
    /// vault path and named properly on the payload path.
    func testTheFilenameRulesAreOneRuleForBothLanes() {
        // A trailing number is not a type, so the bytes still name themselves.
        XCTAssertEqual(
            WorkMaterialExportSnapshot.filename(
                displayName: "Meeting v1.2",
                mimeType: "application/pdf"
            ),
            "Meeting v1.2.pdf"
        )
        XCTAssertEqual(
            WorkMaterialExportSnapshot.filename(
                displayName: "Meeting v1.2",
                mimeType: nil,
                vaultLeafExtension: "m4a"
            ),
            "Meeting v1.2.m4a",
            "the vault lane must reach the same verdict as the payload lane"
        )

        // A recognised extension in the title is kept, and nothing is appended.
        XCTAssertEqual(
            WorkMaterialExportSnapshot.filename(displayName: "rows.csv", mimeType: "text/csv"),
            "rows.csv"
        )
        XCTAssertEqual(
            WorkMaterialExportSnapshot.filename(
                displayName: "rows.csv",
                mimeType: "application/pdf",
                vaultLeafExtension: "bin"
            ),
            "rows.csv",
            "a title that already states its type is not overruled by storage"
        )

        // Mime before vault leaf: the mime type describes the CONTENT, the leaf
        // describes how it happens to be stored. The exact spelling belongs to
        // the system's own type table, not to this test — what must hold is
        // that the extension comes from the MIME rather than from storage.
        let recording = WorkMaterialExportSnapshot.filename(
            displayName: "Voice note",
            mimeType: "audio/mp4",
            vaultLeafExtension: "bin"
        )
        let recordingExtension = (recording as NSString).pathExtension
        XCTAssertNotEqual(recordingExtension, "bin", "the leaf never outranks the recorded type")
        XCTAssertEqual(
            UTType(mimeType: "audio/mp4")?.tags[.filenameExtension]?.contains(recordingExtension),
            true
        )

        // Nothing to derive from is still better than a guess.
        XCTAssertEqual(
            WorkMaterialExportSnapshot.filename(displayName: "Voice note", mimeType: nil),
            "Voice note"
        )
        XCTAssertEqual(
            WorkMaterialExportSnapshot.filename(
                displayName: "Voice note",
                mimeType: "application/x-nonsense-conduck",
                vaultLeafExtension: "blob"
            ),
            "Voice note.blob",
            "an unrecognised mime type falls through to the leaf's own extension"
        )
    }

    /// The type is resolved from the finished NAME first, because that is what
    /// the receiving app reads. `.data` is the answer when there is no answer,
    /// never a substitute for one that exists.
    func testTheContentTypeIsResolvedFromTheNameThenTheMimeThenNothing() {
        XCTAssertEqual(
            WorkMaterialExportSnapshot.contentType(filename: "rows.csv", mimeType: nil),
            .commaSeparatedText
        )
        XCTAssertEqual(
            WorkMaterialExportSnapshot.contentType(
                filename: "Voice note",
                mimeType: "audio/mp4"
            ),
            UTType(mimeType: "audio/mp4")
        )
        XCTAssertEqual(
            WorkMaterialExportSnapshot.contentType(filename: "Voice note", mimeType: nil),
            .data,
            "an unknown type is stated as unknown rather than guessed at"
        )
        XCTAssertEqual(
            WorkMaterialExportSnapshot.contentType(
                filename: "Meeting v1.2",
                mimeType: "application/pdf"
            ),
            .pdf,
            "a trailing number never resolves as a type"
        )
    }

    // MARK: - Which cards may be shared at all

    /// Readable bytes share; the two unreadable states refuse, each with the
    /// sentence that names what the person can actually do about it. Every
    /// answer comes from the STORE — the board is never consulted.
    func testOnlyReadableBytesReachTheShareSheet() async throws {
        for availability in [WorkboardMaterialAvailability.available, .localOnly] {
            let presenter = RecordingSharePresenter()
            let coordinator = WorkMaterialShareCoordinator(
                bytes: bytes(payload: Data("x".utf8)),
                presenter: presenter
            )
            let material = card(availability: availability)
            coordinator.currentMaterial = { _ in material }

            await coordinator.share(materialID: material.id).value

            XCTAssertEqual(
                presenter.presented.count,
                1,
                "\(availability) is readable on this device, so it shares"
            )
            XCTAssertNil(coordinator.failure)
            presenter.presented.forEach { $0.discard() }
        }

        for availability in [
            WorkboardMaterialAvailability.unavailableOnThisDevice,
            .syncPending
        ] {
            let presenter = RecordingSharePresenter()
            let coordinator = WorkMaterialShareCoordinator(
                bytes: bytes(payload: Data("x".utf8)),
                presenter: presenter
            )
            let material = card(availability: availability)
            coordinator.currentMaterial = { _ in material }

            await coordinator.share(materialID: material.id).value

            XCTAssertTrue(
                presenter.presented.isEmpty,
                "\(availability) has no readable bytes here, so nothing may be shared"
            )
            XCTAssertEqual(presenter.readinessCalls, 0, "a refused card reaches no presenter")
            XCTAssertEqual(coordinator.failure, WorkMaterialShareCoordinator.refusal(for: availability))
        }
    }

    /// The refusals name the verb the person asked for. The preview lane's own
    /// sentences say "open", and borrowing them here would tell somebody who
    /// asked to share that the card will open once it lands.
    func testEachRefusalNamesSharingRatherThanOpening() {
        let missing = WorkMaterialShareCoordinator.refusal(for: .unavailableOnThisDevice)
        XCTAssertTrue(missing.message.lowercased().contains("share"))
        let waiting = WorkMaterialShareCoordinator.refusal(for: .syncPending)
        XCTAssertTrue(waiting.message.lowercased().contains("shared"))
        XCTAssertTrue(
            waiting.message.lowercased().contains("icloud"),
            "waiting is the whole answer, so the copy has to say what it is waiting for"
        )
        XCTAssertNotEqual(missing, waiting)
    }

    /// A card the store no longer holds is silent, not an error: the person
    /// removed it, so nothing was promised.
    func testACardTheStoreNoLongerHoldsIsRefusedWithoutASentence() async {
        let presenter = RecordingSharePresenter()
        let coordinator = WorkMaterialShareCoordinator(
            bytes: bytes(payload: Data("x".utf8)),
            presenter: presenter
        )
        coordinator.currentMaterial = { _ in nil }

        await coordinator.share(materialID: UUID()).value

        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertNil(coordinator.failure)
        XCTAssertFalse(coordinator.isPreparing)
    }

    /// The copy is named and typed from the STORE's metadata, not from whatever
    /// the caller happened to be holding — the caller passes an id and nothing
    /// else.
    func testTheExportIsNamedFromTheStoresOwnMetadata() async {
        let presenter = RecordingSharePresenter()
        let coordinator = WorkMaterialShareCoordinator(
            bytes: bytes(payload: Data("x".utf8)),
            presenter: presenter
        )
        let stored = card(name: "Name the store holds", mimeType: "application/pdf")
        coordinator.currentMaterial = { _ in stored }

        await coordinator.share(materialID: stored.id).value

        guard case .file(let snapshot) = presenter.presented.first else {
            return XCTFail("a file card shares a file")
        }
        XCTAssertEqual(snapshot.filename, "Name the store holds.pdf")
        snapshot.reclaim()
    }

    // MARK: - The store moving under a preparation

    /// The pure rule, driven directly: four ways a finished copy stops
    /// describing the card the store holds, and one way it does not.
    func testAPreparedCopyIsAcceptedOnlyWhileItStillDescribesTheCard() {
        let requested = card(revision: 4)

        XCTAssertTrue(
            WorkMaterialShareCoordinator.acceptsPreparedShare(
                requested: requested,
                current: requested
            )
        )

        XCTAssertFalse(
            WorkMaterialShareCoordinator.acceptsPreparedShare(requested: requested, current: nil),
            "the card was deleted while its bytes were being copied"
        )

        var replaced = requested
        replaced.revision = 5
        XCTAssertFalse(
            WorkMaterialShareCoordinator.acceptsPreparedShare(
                requested: requested,
                current: replaced
            ),
            "a reattach replaced the bytes; the copy describes what used to be there"
        )

        var reshaped = requested
        reshaped.kind = .note
        XCTAssertFalse(
            WorkMaterialShareCoordinator.acceptsPreparedShare(
                requested: requested,
                current: reshaped
            ),
            "the card is not even the same kind of thing any more"
        )

        var withdrawn = requested
        withdrawn.availability = .unavailableOnThisDevice
        XCTAssertFalse(
            WorkMaterialShareCoordinator.acceptsPreparedShare(
                requested: requested,
                current: withdrawn
            ),
            "the bytes stopped being readable here while the copy was made"
        )

        // Card size is revision-neutral by contract, so resizing a card mid-copy
        // is not a different card and must not refuse the share.
        var resized = requested
        resized.cardSize = .large
        XCTAssertTrue(
            WorkMaterialShareCoordinator.acceptsPreparedShare(
                requested: requested,
                current: resized
            ),
            "a footprint change is presentation, not content"
        )
    }

    /// End to end, with the replacement landing WHILE the bytes are being
    /// copied. The board would still be drawing the old card for another
    /// debounce, so a board-level gate would pass this.
    func testAReplacementCommittedDuringPreparationIsRefused() async throws {
        let gate = PreparationGate()
        let presenter = RecordingSharePresenter()
        let coordinator = WorkMaterialShareCoordinator(
            bytes: bytes(payload: Data("original".utf8), gate: gate),
            presenter: presenter
        )
        let materialID = UUID()
        let original = card(id: materialID, name: "Replaced during copy", revision: 1)
        var stored = original
        coordinator.currentMaterial = { _ in stored }

        let task = coordinator.share(materialID: materialID)
        // Let gate 1 land and the copy start.
        while !coordinator.isPreparing { await Task.yield() }

        // A peer's reattach commits. Same id, new revision, new title.
        stored = card(id: materialID, name: "Replacement", revision: 2)

        await gate.open()
        await task.value

        XCTAssertTrue(presenter.presented.isEmpty, "the bytes describe a revision that is gone")
        XCTAssertEqual(coordinator.failure, WorkMaterialShareCoordinator.stale)
        XCTAssertFalse(coordinator.isPreparing)
        XCTAssertFalse(
            liveExportedFilenames().contains("Replaced during copy.pdf"),
            "a copy nobody was shown is reclaimed immediately"
        )
    }

    /// The other half of the same window: the replacement lands while the
    /// presenter is waiting for the surface to settle. The store is therefore
    /// read AFTER that wait, not before it.
    func testAReplacementCommittedDuringTheReadinessWaitIsRefused() async throws {
        let presenter = RecordingSharePresenter()
        let coordinator = WorkMaterialShareCoordinator(
            bytes: bytes(payload: Data("original".utf8)),
            presenter: presenter
        )
        let materialID = UUID()
        var stored = card(id: materialID, name: "Replaced while settling", revision: 1)
        var storeReadsWhenReadinessRan = 0
        var storeReads = 0
        coordinator.currentMaterial = { _ in
            storeReads += 1
            return stored
        }
        presenter.duringReadinessWait = {
            storeReadsWhenReadinessRan = storeReads
            stored = self.card(id: materialID, name: "Replacement", revision: 2)
        }

        await coordinator.share(materialID: materialID).value

        XCTAssertEqual(
            storeReadsWhenReadinessRan,
            1,
            "the wait runs between the two gates, so the second gate sees whatever it changed"
        )
        XCTAssertEqual(storeReads, 2, "the store is asked again before anything is presented")
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertEqual(coordinator.failure, WorkMaterialShareCoordinator.stale)
        XCTAssertFalse(liveExportedFilenames().contains("Replaced while settling.pdf"))
    }

    /// Two taps, one sheet. The first copy is finished but superseded, so it is
    /// reclaimed and only the newest card is presented.
    func testANewerRequestSupersedesACopyStillBeingMade() async throws {
        let gate = PreparationGate()
        let presenter = RecordingSharePresenter()
        let coordinator = WorkMaterialShareCoordinator(
            bytes: bytes(payload: Data("shared".utf8), gate: gate),
            presenter: presenter
        )
        let first = card(name: "Superseded copy")
        let second = card(name: "Winning copy")
        coordinator.currentMaterial = { id in
            [first, second].first { $0.id == id }
        }

        let firstTask = coordinator.share(materialID: first.id)
        let secondTask = coordinator.share(materialID: second.id)

        await gate.open()
        await firstTask.value
        await secondTask.value

        XCTAssertEqual(presenter.presented.count, 1, "the newest tap owns the sheet")
        guard case .file(let snapshot) = presenter.presented[0] else {
            return XCTFail("a file card shares a file")
        }
        XCTAssertEqual(
            snapshot.filename,
            "Winning copy.pdf",
            "the sheet holds the card the person tapped last, not whichever copy finished first"
        )
        XCTAssertNil(coordinator.failure, "a superseded copy is silent — the person did not ask twice")

        let onDisk = liveExportedFilenames()
        XCTAssertFalse(onDisk.contains("Superseded copy.pdf"), "the superseded copy is reclaimed")
        XCTAssertTrue(
            onDisk.contains("Winning copy.pdf"),
            "the presented copy is left to the age sweep: nothing reports back from another process"
        )
        snapshot.reclaim()
    }

    /// The shape a ROLLED-BACK reattach leaves behind: the payload columns are
    /// the card's own again, so everything except the revision reads exactly as
    /// it did at gate 1. Only the fresh revision says the bytes moved, and it
    /// is the whole reason a rollback must mint one — a restored revision would
    /// make this indistinguishable from nothing having happened, while the
    /// bytes on disk had been replaced and put back underneath.
    func testACardRolledBackToItsOwnBytesIsStillRefused() async throws {
        let presenter = RecordingSharePresenter()
        let coordinator = WorkMaterialShareCoordinator(
            bytes: bytes(payload: Data("original".utf8)),
            presenter: presenter
        )
        let materialID = UUID()
        let atGateOne = card(id: materialID, name: "Rolled back", revision: 1)
        var stored = atGateOne
        coordinator.currentMaterial = { _ in stored }
        presenter.duringReadinessWait = {
            // A reattach replaced the bytes and its publication could not be
            // proved, so the store put the payload back — under a NEW revision.
            stored = self.card(id: materialID, name: "Rolled back", revision: 2)
        }

        await coordinator.share(materialID: materialID).value

        XCTAssertTrue(
            presenter.presented.isEmpty,
            "the bytes on disk moved while this copy was made, whatever the columns say"
        )
        XCTAssertEqual(coordinator.failure, WorkMaterialShareCoordinator.stale)
        XCTAssertFalse(liveExportedFilenames().contains("Rolled back.pdf"))

        // The counter-example that makes the assertion above mean something: an
        // UNCHANGED revision is accepted, so it really is the revision doing the
        // refusing rather than some other difference.
        XCTAssertTrue(
            WorkMaterialShareCoordinator.acceptsPreparedShare(
                requested: atGateOne,
                current: atGateOne
            )
        )
    }

    // MARK: - A presentation the system did not take

    /// The surface never settled — a context menu still dismissing, a sheet
    /// mid-transition. Nothing is attempted, and the bytes go straight back.
    func testASurfaceThatNeverSettlesIsAFailureRatherThanAHandOff() async throws {
        let presenter = RecordingSharePresenter()
        presenter.isReady = false
        let coordinator = WorkMaterialShareCoordinator(
            bytes: bytes(payload: Data("x".utf8)),
            presenter: presenter
        )
        let material = card(name: "Never settled")
        coordinator.currentMaterial = { _ in material }

        await coordinator.share(materialID: material.id).value

        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertEqual(coordinator.failure, WorkMaterialShareCoordinator.presentationUnavailable)
        XCTAssertFalse(coordinator.isPreparing)
        XCTAssertFalse(
            liveExportedFilenames().contains("Never settled.pdf"),
            "nothing was presented, so the bytes are still ours and go back at once"
        )
    }

    /// The system refused the request. Reporting that as a hand-off would keep
    /// a file alive for a share that never happened AND say nothing to the
    /// person, which is the worst of both.
    func testAPresentationTheSystemRefusedIsReclaimedAndSaysSo() async throws {
        let presenter = RecordingSharePresenter()
        presenter.succeeds = false
        let coordinator = WorkMaterialShareCoordinator(
            bytes: bytes(payload: Data("x".utf8)),
            presenter: presenter
        )
        let material = card(name: "Refused by the system")
        coordinator.currentMaterial = { _ in material }

        await coordinator.share(materialID: material.id).value

        XCTAssertEqual(coordinator.failure, WorkMaterialShareCoordinator.presentationUnavailable)
        XCTAssertFalse(
            liveExportedFilenames().contains("Refused by the system.pdf"),
            "a refused request holds nothing, so the copy is reclaimed"
        )
    }

    /// The final store read THROWS after the copy already exists. The catch
    /// upstack cannot see that copy, so without a deferred reclaim its
    /// directory survives until the next launch sweep — a day of a person's
    /// bytes sitting in a temporary directory for a share that never happened.
    func testAThrowingFinalReadStillGivesTheCopyBack() async throws {
        struct StoreUnavailable: Error {}

        let presenter = RecordingSharePresenter()
        let coordinator = WorkMaterialShareCoordinator(
            bytes: bytes(payload: Data("x".utf8)),
            presenter: presenter
        )
        let materialID = UUID()
        let material = card(id: materialID, name: "Store threw at gate two")
        var reads = 0
        coordinator.currentMaterial = { _ in
            reads += 1
            // Gate 1 answers; gate 2 — after the copy exists — fails.
            if reads > 1 { throw StoreUnavailable() }
            return material
        }

        await coordinator.share(materialID: materialID).value

        XCTAssertEqual(reads, 2, "the throw has to happen AFTER preparation to be the case at hand")
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertNotNil(coordinator.failure, "a throw is still a failure the person is told about")
        XCTAssertFalse(coordinator.isPreparing)
        XCTAssertFalse(
            liveExportedFilenames().contains("Store threw at gate two.pdf"),
            "the copy goes back on every exit, including the one that throws"
        )
    }

    /// A card whose bytes vanished between the gate and the read reports the
    /// missing-bytes sentence rather than a raw file-system message.
    func testBytesThatVanishedMidPreparationReportTheRepair() async throws {
        let presenter = RecordingSharePresenter()
        let coordinator = WorkMaterialShareCoordinator(
            bytes: bytes(payload: nil),
            presenter: presenter
        )
        let material = card()
        coordinator.currentMaterial = { _ in material }

        await coordinator.share(materialID: material.id).value

        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertEqual(
            coordinator.failure,
            WorkMaterialShareCoordinator.refusal(for: .unavailableOnThisDevice)
        )
    }

    /// One failure, cleared by whichever surface drew it, so the same sentence
    /// is never rendered twice.
    func testAFailureIsClearedOnceItHasBeenRead() async {
        let presenter = RecordingSharePresenter()
        let coordinator = WorkMaterialShareCoordinator(
            bytes: bytes(payload: nil),
            presenter: presenter
        )
        let material = card()
        coordinator.currentMaterial = { _ in material }

        await coordinator.share(materialID: material.id).value
        XCTAssertNotNil(coordinator.failure)
        coordinator.clearFailure()
        XCTAssertNil(coordinator.failure)
    }

    // MARK: - Reclaim and the per-copy sweep

    /// Each copy is its OWN top-level directory under the shared temporary
    /// directory. That layout is what makes the launch sweep age copies
    /// individually; a shared parent folder is aged by its own creation date.
    func testEachCopyOwnsItsOwnSweepableContainer() async throws {
        let first = try await WorkMaterialExportSnapshot.writing(
            Data("one".utf8),
            displayName: "One",
            mimeType: "text/plain"
        )
        let second = try await WorkMaterialExportSnapshot.writing(
            Data("two".utf8),
            displayName: "Two",
            mimeType: "text/plain"
        )
        defer {
            first.reclaim()
            second.reclaim()
        }

        XCTAssertNotEqual(first.container, second.container)
        for snapshot in [first, second] {
            XCTAssertTrue(
                snapshot.container.lastPathComponent
                    .hasPrefix(WorkMaterialExportSnapshot.containerPrefix)
            )
            XCTAssertTrue(
                TempScratchSweeper.ownedPrefixes.contains(where: {
                    snapshot.container.lastPathComponent.hasPrefix($0)
                }),
                "a container no owned prefix claims is permanently unreclaimable"
            )
            XCTAssertEqual(
                snapshot.container.deletingLastPathComponent()
                    .resolvingSymlinksInPath().standardizedFileURL.path,
                FileManager.default.temporaryDirectory
                    .resolvingSymlinksInPath().standardizedFileURL.path,
                "the sweep skips subdirectories, so a nested container is never aged at all"
            )
        }
    }

    /// The regression this layout exists for: an aged copy goes, and a copy
    /// made seconds ago survives the same sweep. Under the old shared-parent
    /// layout the fresh one went with it.
    func testTheSweepAgesEachCopyOnItsOwn() async throws {
        let aged = try await WorkMaterialExportSnapshot.writing(
            Data("stale".utf8),
            displayName: "Aged share",
            mimeType: "text/plain"
        )
        let fresh = try await WorkMaterialExportSnapshot.writing(
            Data("live".utf8),
            displayName: "Fresh share",
            mimeType: "text/plain"
        )
        defer {
            aged.reclaim()
            fresh.reclaim()
        }

        let agedDate = Date().addingTimeInterval(-TempScratchSweeper.maxOrphanAge - 3600)
        try FileManager.default.setAttributes(
            [.creationDate: agedDate],
            ofItemAtPath: aged.container.path
        )

        // PRECONDITION, not an assertion about the sweep: a filesystem that
        // refused to backdate would fail the check below for a reason that has
        // nothing to do with `sweep()`.
        let recorded = (try? aged.container.resourceValues(forKeys: [.creationDateKey]))?
            .creationDate
        XCTAssertEqual(
            recorded?.timeIntervalSinceReferenceDate ?? Double.nan,
            agedDate.timeIntervalSinceReferenceDate,
            accuracy: 2,
            "this filesystem would not backdate the container, so the result below means nothing"
        )

        TempScratchSweeper.sweep()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: aged.url.path),
            "a day-old share copy is an orphan nothing will ever come back for"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fresh.url.path),
            "a copy made seconds ago may still be open in whatever the person shared it to"
        )
    }

    /// The reclaim guard. It is handed a directory, and it refuses anything it
    /// did not create — a rule that walked up from a file path could be given a
    /// URL from anywhere and delete a parent it guessed at.
    func testReclaimRefusesADirectoryItDidNotCreate() throws {
        let foreign = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-workasset-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: foreign,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: foreign) }

        WorkMaterialExportSnapshot.reclaimContainer(foreign)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: foreign.path),
            "the prefix is the whole permission to delete"
        )

        // A correctly prefixed directory somewhere OTHER than the temporary
        // directory is refused too: the prefix alone is not the rule.
        let elsewhere = foreign.appendingPathComponent(
            WorkMaterialExportSnapshot.containerPrefix + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        WorkMaterialExportSnapshot.reclaimContainer(elsewhere)
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    // MARK: - The gallery's actions slot

    /// The clamp, on the derivation the slot is fed from.
    func testTheGallerySlotIsHandedTheCurrentSelectionsPageID() {
        let pages = (0..<3).map { index in
            AttachmentGalleryPage(
                id: UUID(),
                thumbnailData: nil,
                accessibilityLabel: "Page \(index)"
            )
        }

        XCTAssertEqual(AttachmentGalleryPage.id(atSelection: 0, in: pages), pages[0].id)
        XCTAssertEqual(AttachmentGalleryPage.id(atSelection: 2, in: pages), pages[2].id)
        // Clamped, for the same reason `startIndex` is: the list can change
        // underneath the caller's index.
        XCTAssertEqual(AttachmentGalleryPage.id(atSelection: 99, in: pages), pages[2].id)
        XCTAssertEqual(AttachmentGalleryPage.id(atSelection: -4, in: pages), pages[0].id)
        XCTAssertNil(AttachmentGalleryPage.id(atSelection: 0, in: []))
    }

    /// Chat asks for no actions and gets none — not an empty container, but
    /// `EmptyView` itself, which is what keeps its two call sites unchanged.
    func testAGalleryWithNoActionsResolvesToEmptyView() {
        let gallery = AttachmentFullScreenView(
            pages: [],
            startIndex: 0,
            loadFullBytes: { _ in Data() }
        )
        XCTAssertTrue(
            type(of: gallery) == AttachmentFullScreenView<EmptyView>.self,
            "the no-actions initialiser must resolve the slot to EmptyView"
        )
    }

    /// The slot's contract, driven through the cursor the PAGER writes: the
    /// caller's closure is invoked with the id of the page on screen, and
    /// moving that cursor — which is what a swipe does — changes it. A slot
    /// wired to `startIndex` would be indistinguishable on the opening page and
    /// wrong on every other one, so the assertion has to move the selection.
    func testASwipeChangesTheIDTheShareCallbackReceives() {
        let pages = (0..<3).map { index in
            AttachmentGalleryPage(
                id: UUID(),
                thumbnailData: nil,
                accessibilityLabel: "Page \(index)"
            )
        }
        var received: [UUID] = []
        let selection = AttachmentGallerySelection(startIndex: 0, pageCount: pages.count)
        let gallery = AttachmentFullScreenView(
            pages: pages,
            startIndex: 0,
            loadFullBytes: { _ in Data() },
            fullDecodeMaxPixel: 4096,
            selection: selection
        ) { pageID in
            received.append(pageID)
            return Color.clear
        }

        // Building the chrome's actions is what invokes the caller's closure.
        _ = gallery.currentPageActions
        // The swipe: the pager writes exactly this.
        selection.index = 2
        _ = gallery.currentPageActions

        XCTAssertEqual(
            received,
            [pages[0].id, pages[2].id],
            "the slot follows the cursor; wired to startIndex it would report page 0 twice"
        )
    }

    /// The same path, all the way into the coordinator: what Work's slot does
    /// is start a share for the page on screen, and the copy that comes out
    /// carries THAT card's name.
    func testTheGallerySlotSharesThePageOnScreen() async throws {
        let pages = (0..<3).map { index in
            AttachmentGalleryPage(
                id: UUID(),
                thumbnailData: nil,
                accessibilityLabel: "Page \(index)"
            )
        }
        let cards = pages.enumerated().map { index, page in
            card(id: page.id, kind: .image, name: "Page \(index)", mimeType: "image/jpeg")
        }
        let presenter = RecordingSharePresenter()
        let coordinator = WorkMaterialShareCoordinator(
            bytes: bytes(payload: Data("pixels".utf8)),
            presenter: presenter
        )
        coordinator.currentMaterial = { id in cards.first { $0.id == id } }

        var started: [Task<Void, Never>] = []
        let selection = AttachmentGallerySelection(startIndex: 0, pageCount: pages.count)
        let gallery = AttachmentFullScreenView(
            pages: pages,
            startIndex: 0,
            loadFullBytes: { _ in Data() },
            fullDecodeMaxPixel: 4096,
            selection: selection
        ) { pageID in
            started.append(coordinator.share(materialID: pageID))
            return Color.clear
        }

        // The person swiped to the third picture, then tapped Share.
        selection.index = 2
        _ = gallery.currentPageActions
        for task in started { await task.value }

        guard case .file(let snapshot) = presenter.presented.first else {
            return XCTFail("an image card shares a file copy of its original bytes")
        }
        XCTAssertEqual(
            snapshot.filename,
            "Page 2.jpeg",
            "the share acts on the picture being looked at"
        )
        snapshot.reclaim()
    }

    /// The cursor clamps on read, because the pages can change under a value
    /// that was valid when the pager wrote it.
    func testTheGalleryCursorClampsToThePagesItHas() {
        let pages = (0..<2).map { index in
            AttachmentGalleryPage(
                id: UUID(),
                thumbnailData: nil,
                accessibilityLabel: "Page \(index)"
            )
        }
        let selection = AttachmentGallerySelection(startIndex: 9, pageCount: pages.count)
        XCTAssertEqual(selection.index, 1, "an out-of-range start still opens on a real page")
        selection.index = 40
        XCTAssertEqual(selection.pageID(in: pages), pages[1].id)
        selection.index = -3
        XCTAssertEqual(selection.pageID(in: pages), pages[0].id)
        XCTAssertNil(selection.pageID(in: []))
    }

    // MARK: - Which surface the share pops out of

    /// The registry's ordering rule. The winner is the newest surface to have
    /// ATTACHED TO A WINDOW, and an ordinary redraw of the surface underneath
    /// must not change that — otherwise a board refresh behind an open gallery
    /// silently moves the anchor, and the next share pops out of the surface
    /// the person is not looking at.
    func testTheAnchorFollowsAttachmentAndNotRedraws() {
        let anchor = SharePresentationAnchor()
        let window = AnchorWindow()

        let desk = SharePresentationAnchorPlatformView(frame: .zero)
        desk.anchor = anchor
        anchor.register(desk)
        XCTAssertNil(
            anchor.presentationView,
            "a mounted anchor with no window can show nothing, so it is not eligible"
        )

        window.attach(desk)
        XCTAssertTrue(anchor.presentationView === desk)

        let gallery = SharePresentationAnchorPlatformView(frame: .zero)
        gallery.anchor = anchor
        anchor.register(gallery)
        window.attach(gallery)
        XCTAssertTrue(anchor.presentationView === gallery, "the newest attached surface wins")

        // A redraw of the desk underneath — a board refresh, a capture landing,
        // a hover. SwiftUI calls the representable's update for each one.
        anchor.register(desk)
        XCTAssertTrue(
            anchor.presentationView === gallery,
            "a redraw is not an arrival: the open gallery keeps the anchor"
        )

        // The gallery is dismissed. The desk wins again without re-registering,
        // because eligibility is read from the window and not from the order.
        gallery.removeFromSuperview()
        XCTAssertTrue(anchor.presentationView === desk)

        // And it can be promoted back by attaching again, which is the only
        // event that reorders anything.
        window.attach(gallery)
        XCTAssertTrue(anchor.presentationView === gallery)
    }

    /// The anchor rect is inside the anchor's own bounds. On iPad a popover
    /// with neither a source view nor a source rect traps, so an anchor that
    /// reported an off-view rect would be a crash waiting for a large screen.
    func testTheAnchorRectSitsInsideTheAnchorView() {
        let anchor = SharePresentationAnchor()
        let window = AnchorWindow()
        let view = SharePresentationAnchorPlatformView(
            frame: CGRect(x: 0, y: 0, width: 200, height: 100)
        )
        view.anchor = anchor
        anchor.register(view)
        window.attach(view)

        XCTAssertTrue(view.bounds.contains(anchor.presentationRect))
        XCTAssertEqual(anchor.presentationRect, CGRect(x: 100, y: 50, width: 1, height: 1))
    }

    // MARK: - The store's own half of the revision contract

    /// The rollback the coordinator's refusal depends on, driven through the
    /// real store.
    ///
    /// A reattach whose publication cannot be proved puts the card back on the
    /// payload it had — that guarantee is asserted here too, because the fix is
    /// only allowed to move the revision. What must NOT be put back is
    /// `updatedAt`: it is the one column any reader has to tell that these
    /// bytes were replaced and restored, and a share resolves BYTES by id
    /// separately from metadata, so a restored revision lets a copy taken
    /// mid-flight pass a check that believes nothing happened.
    func testARolledBackReattachMintsAFreshRevisionAndKeepsTheBytes() async throws {
        let store = isolated.make()
        let originalBytes = Data("the bytes the card already had".utf8)
        let original = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "report.txt",
                filename: "report.txt",
                mimeType: "text/plain",
                payload: originalBytes,
                byteSize: Int64(originalBytes.count)
            )
        )
        let gateOneRecord = try await store.fetchWorkMaterial(id: original.id)
        let atGateOne = try XCTUnwrap(gateOneRecord)

        try await failAReattachOn(store, of: original.id)

        let gateTwoRecord = try await store.fetchWorkMaterial(id: original.id)
        let atGateTwo = try XCTUnwrap(gateTwoRecord)

        let payloadAfterRollback = try await store.loadWorkMaterialPayload(id: original.id)
        XCTAssertEqual(
            payloadAfterRollback,
            originalBytes,
            "the rollback's guarantee: the card keeps the payload it had"
        )
        XCTAssertEqual(atGateTwo.filename, atGateOne.filename, "and the metadata describing it")
        XCTAssertEqual(atGateTwo.mimeType, atGateOne.mimeType)
        XCTAssertEqual(atGateTwo.storageMode, atGateOne.storageMode)
        XCTAssertEqual(atGateTwo.contentHash, atGateOne.contentHash)

        XCTAssertGreaterThan(
            WorkboardRevision.value(for: atGateTwo.updatedAt),
            WorkboardRevision.value(for: atGateOne.updatedAt),
            "the bytes moved and came back, so the revision has to say so — a share prepared "
                + "against the first revision must not pass a check against the second"
        )
        XCTAssertFalse(
            WorkMaterialShareCoordinator.acceptsPreparedShare(
                requested: WorkboardLiveRepository.presentationSnapshotForTesting(atGateOne),
                current: WorkboardLiveRepository.presentationSnapshotForTesting(atGateTwo)
            ),
            "which is the whole point: the share gate refuses it"
        )
    }

    /// What a reader treats as a row's revision, which is what the rollback has
    /// to advance. `updatedAt` is nullable and nobody compares it raw.
    func testAnUndatedRowIsNotRevisionless() {
        let created = Date(timeIntervalSinceReferenceDate: 90)
        let updated = Date(timeIntervalSinceReferenceDate: 160)

        XCTAssertEqual(
            ConversationStore.materialRevisionDate(updatedAt: updated, createdAt: created),
            updated
        )
        XCTAssertEqual(
            ConversationStore.materialRevisionDate(updatedAt: nil, createdAt: created),
            created,
            "a row with no stamp reads at its creation, not at nothing"
        )
        XCTAssertEqual(
            ConversationStore.materialRevisionDate(updatedAt: nil, createdAt: nil),
            .distantPast
        )
    }

    // MARK: - One ordering, both selectors

    /// Every key that can separate two otherwise-identical rows is a SYNCED
    /// column, and each one outranks the device-local `rowKey`.
    ///
    /// This is what the tiebreak keys are actually for. `rowKey` alone would
    /// already make the ordering total, and both selectors on ONE device would
    /// agree — but the row key is an object id, so two devices holding the same
    /// pair would pick different winners and show different bytes for the same
    /// card. Each assertion below gives the row that must win the SMALLER row
    /// key, so a comparator that fell through to the local key would fail it.
    func testEverySyncedKeyOutranksTheDeviceLocalRowKey() {
        let created = Date(timeIntervalSinceReferenceDate: 100)

        func order(
            revision: Date = Date(timeIntervalSinceReferenceDate: 100),
            createdAt: Date? = Date(timeIntervalSinceReferenceDate: 100),
            title: String? = "report.txt",
            contentHash: String? = nil,
            localVaultKey: String? = nil,
            storageMode: String? = "localVault",
            byteSize: Int64? = 0,
            kind: String? = "file",
            textContent: String? = nil,
            urlString: String? = nil,
            filename: String? = nil,
            mimeType: String? = nil,
            caption: String? = nil,
            cardSize: String? = nil,
            thumbnailData: Data? = nil,
            rowKey: String
        ) -> WorkMaterialCanonicalOrder {
            WorkMaterialCanonicalOrder(
                revision: revision,
                createdAt: createdAt,
                title: title,
                contentHash: contentHash,
                localVaultKey: localVaultKey,
                storageMode: storageMode,
                byteSize: byteSize,
                kind: kind,
                textContent: textContent,
                urlString: urlString,
                filename: filename,
                mimeType: mimeType,
                caption: caption,
                cardSize: cardSize,
                thumbnailData: thumbnailData,
                rowKey: rowKey
            )
        }

        /// `winner` must outrank `loser` even though its row key sorts lower.
        func assertSyncedKeyDecides(
            _ what: String,
            winner: WorkMaterialCanonicalOrder,
            loser: WorkMaterialCanonicalOrder,
            line: UInt = #line
        ) {
            XCTAssertLessThan(
                winner.rowKey, loser.rowKey,
                "\(what): the test is only meaningful if the local key disagrees",
                line: line
            )
            XCTAssertEqual(
                [winner, loser].max(), winner,
                "\(what): a synced column has to decide this, not the row's local id",
                line: line
            )
            XCTAssertEqual([loser, winner].max(), winner, "\(what): in either order", line: line)
        }

        // The first four keys, which nothing else here varies.
        assertSyncedKeyDecides(
            "the revision",
            winner: order(revision: created.addingTimeInterval(10), rowKey: "row-a"),
            loser: order(revision: created, rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "the creation date",
            winner: order(createdAt: created.addingTimeInterval(10), rowKey: "row-a"),
            loser: order(createdAt: created, rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "carrying a creation date at all",
            winner: order(createdAt: created, rowKey: "row-a"),
            loser: order(createdAt: nil, rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "the title",
            winner: order(title: "b.txt", rowKey: "row-a"),
            loser: order(title: "a.txt", rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "carrying a title at all — an EMPTY title is a value, not an absence",
            winner: order(title: "", rowKey: "row-a"),
            loser: order(title: nil, rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "the blob a synced row names",
            winner: order(contentHash: "bb", rowKey: "row-a"),
            loser: order(contentHash: "aa", rowKey: "row-b")
        )

        // The vault case Codex named: both rows name NO blob, so `contentHash`
        // ties while the leaves they hold are different bytes.
        assertSyncedKeyDecides(
            "two vault rows naming different leaves",
            winner: order(localVaultKey: "leaf-b", rowKey: "row-a"),
            loser: order(localVaultKey: "leaf-a", rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "a vault row against one naming no leaf at all",
            winner: order(localVaultKey: "leaf", rowKey: "row-a"),
            loser: order(localVaultKey: nil, rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "the lane",
            winner: order(storageMode: "syncedPayload", rowKey: "row-a"),
            loser: order(storageMode: "localVault", rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "the size",
            winner: order(byteSize: 99, rowKey: "row-a"),
            loser: order(byteSize: 1, rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "carrying a size at all — ZERO is a value, not an absence",
            winner: order(byteSize: 0, rowKey: "row-a"),
            loser: order(byteSize: nil, rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "the kind of card",
            winner: order(kind: "image", rowKey: "row-a"),
            loser: order(kind: "file", rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "the text a note holds",
            winner: order(textContent: "b", rowKey: "row-a"),
            loser: order(textContent: "a", rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "the address a link holds",
            winner: order(urlString: "https://b", rowKey: "row-a"),
            loser: order(urlString: "https://a", rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "the filename",
            winner: order(filename: "b.txt", rowKey: "row-a"),
            loser: order(filename: "a.txt", rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "the mime type",
            winner: order(mimeType: "text/plain", rowKey: "row-a"),
            loser: order(mimeType: "application/pdf", rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "the caption",
            winner: order(caption: "b", rowKey: "row-a"),
            loser: order(caption: "a", rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "the card's footprint",
            winner: order(cardSize: "small", rowKey: "row-a"),
            loser: order(cardSize: "large", rowKey: "row-b")
        )

        // The preview. Its digests decide, so which payload wins is whatever
        // SHA-256 says — the test reads that rather than assuming it.
        let onePreview = Data("one".utf8)
        let otherPreview = Data("two".utf8)
        let oneDigest = order(thumbnailData: onePreview, rowKey: "x").thumbnailDigest
        let otherDigest = order(thumbnailData: otherPreview, rowKey: "x").thumbnailDigest
        let higherPreview = (oneDigest ?? "") > (otherDigest ?? "") ? onePreview : otherPreview
        let lowerPreview = higherPreview == onePreview ? otherPreview : onePreview
        assertSyncedKeyDecides(
            "the preview",
            winner: order(thumbnailData: higherPreview, rowKey: "row-a"),
            loser: order(thumbnailData: lowerPreview, rowKey: "row-b")
        )
        // The three preview tiers, in order: nothing, an empty column, real
        // bytes. `"one"` is chosen deliberately — its digest (7692…) sorts
        // BELOW the hash of empty data (e3b0c442…), so a comparator ranking by
        // digest alone would put the empty column above a real preview.
        let emptyDigest = order(thumbnailData: Data(), rowKey: "x").thumbnailDigest
        let realDigest = order(thumbnailData: onePreview, rowKey: "x").thumbnailDigest
        XCTAssertLessThan(
            try XCTUnwrap(realDigest), try XCTUnwrap(emptyDigest),
            "the case is only meaningful while this preview's digest sorts below the empty one's"
        )
        assertSyncedKeyDecides(
            "real preview bytes against an EMPTY column, whatever their digests say",
            winner: order(thumbnailData: onePreview, rowKey: "row-a"),
            loser: order(thumbnailData: Data(), rowKey: "row-b")
        )
        assertSyncedKeyDecides(
            "carrying a preview at all — an EMPTY column is a value, not an absence",
            winner: order(thumbnailData: Data(), rowKey: "row-a"),
            loser: order(thumbnailData: nil, rowKey: "row-b")
        )
        XCTAssertNotEqual(
            oneDigest, otherDigest,
            "two previews must not collide"
        )
        XCTAssertNotNil(
            order(thumbnailData: Data(), rowKey: "x").thumbnailDigest,
            "a present-but-empty preview column has a digest; only an ABSENT one has none"
        )
        XCTAssertNil(order(thumbnailData: nil, rowKey: "x").thumbnailDigest)
    }

    /// The digest is the one key that costs anything, so it is read last and
    /// only when everything before it ties.
    func testTheKeysBeforeThePreviewAreAnsweredWithoutHashingIt() {
        func order(title: String, rowKey: String) -> WorkMaterialCanonicalOrder {
            WorkMaterialCanonicalOrder(
                revision: Date(timeIntervalSinceReferenceDate: 100),
                createdAt: Date(timeIntervalSinceReferenceDate: 100),
                title: title,
                contentHash: nil,
                localVaultKey: nil,
                storageMode: "syncedPayload",
                byteSize: 1,
                kind: "file",
                textContent: nil,
                urlString: nil,
                filename: nil,
                mimeType: nil,
                caption: nil,
                cardSize: nil,
                thumbnailData: Data("a preview nobody should need to hash".utf8),
                rowKey: rowKey
            )
        }

        let left = order(title: "a", rowKey: "row-a")
        let right = order(title: "b", rowKey: "row-b")
        _ = left < right
        XCTAssertFalse(left.hasComputedThumbnailDigest, "the title already decided it")
        XCTAssertFalse(right.hasComputedThumbnailDigest)

        // Everything before the preview ties, so now it has to be read.
        let tiedLeft = order(title: "same", rowKey: "row-a")
        let tiedRight = order(title: "same", rowKey: "row-b")
        _ = tiedLeft < tiedRight
        XCTAssertTrue(tiedLeft.hasComputedThumbnailDigest, "and only then")
    }

    /// The ordering both selectors reduce to is TOTAL, and that is the whole
    /// parity guarantee: `max` over a total order returns the same element
    /// whatever order the candidates arrive in, so the board's
    /// `(sequence, createdAt)` list and the single-row read's timestamp-ordered
    /// fetch cannot reach different answers.
    ///
    /// `sequence` never appears in the ordering. All it can do is permute one
    /// selector's candidate list, which is exactly what the reversed cases here
    /// stand in for.
    func testBothSelectorsAgreeOnEveryCandidateSetInEitherOrder() {
        let created = Date(timeIntervalSinceReferenceDate: 100)

        func order(
            revision: Date = Date(timeIntervalSinceReferenceDate: 100),
            createdAt: Date = Date(timeIntervalSinceReferenceDate: 100),
            title: String = "report.txt",
            contentHash: String? = nil,
            rowKey: String
        ) -> WorkMaterialCanonicalOrder {
            WorkMaterialCanonicalOrder(
                revision: revision,
                createdAt: createdAt,
                title: title,
                contentHash: contentHash,
                localVaultKey: nil,
                storageMode: "syncedPayload",
                byteSize: 3,
                kind: "file",
                textContent: nil,
                urlString: nil,
                filename: title,
                mimeType: "text/plain",
                caption: nil,
                cardSize: nil,
                thumbnailData: nil,
                rowKey: rowKey
            )
        }

        /// What either selector returns for this candidate set, whichever way
        /// round it is handed them.
        func winner(_ candidates: [WorkMaterialCanonicalOrder]) -> WorkMaterialCanonicalOrder? {
            candidates.max()
        }

        func assertOrderIndependent(
            _ pair: [WorkMaterialCanonicalOrder],
            _ message: String,
            line: UInt = #line
        ) {
            let forward = winner(pair)
            let reversed = winner(pair.reversed())
            XCTAssertEqual(forward, reversed, message, line: line)
            XCTAssertNotNil(forward, message, line: line)
        }

        // Dated against dated.
        assertOrderIndependent(
            [
                order(revision: created.addingTimeInterval(10), rowKey: "a"),
                order(revision: created, rowKey: "b"),
            ],
            "two stamped rows"
        )

        // Dated against undated: the undated row arrives already substituted, so
        // the two are compared in one space.
        assertOrderIndependent(
            [
                order(revision: created, createdAt: created, rowKey: "a"),
                order(revision: created.addingTimeInterval(-10), createdAt: created, rowKey: "b"),
            ],
            "a stamped row against a substituted one"
        )

        // Undated against undated: both read at their creation.
        assertOrderIndependent(
            [
                order(revision: created, createdAt: created, rowKey: "a"),
                order(revision: created, createdAt: created, rowKey: "b"),
            ],
            "two substituted rows"
        )

        // Codex's counterexample, in ordering terms: same owner, id, title and
        // createdAt, one row stamped and one substituted to the same instant,
        // different bytes. The rank the two devices gave the card differs, and
        // it is not a key here — so the bytes decide, the same way for both.
        assertOrderIndependent(
            [
                order(revision: created, createdAt: created, contentHash: "aaa", rowKey: "a"),
                order(revision: created, createdAt: created, contentHash: "bbb", rowKey: "b"),
            ],
            "rows differing only in the bytes they name"
        )

        // A full tie on everything a person could see. The row itself settles
        // it, which is what makes the ordering total rather than merely
        // deterministic-in-practice.
        let tied = [
            order(revision: created, createdAt: created, contentHash: "same", rowKey: "row-1"),
            order(revision: created, createdAt: created, contentHash: "same", rowKey: "row-2"),
        ]
        assertOrderIndependent(tied, "a full tie on every human-meaningful key")
        XCTAssertEqual(winner(tied)?.rowKey, "row-2")

        // Totality, stated directly: no two distinct rows compare equal, so no
        // caller ever falls back to a "first of the equals" rule of its own.
        for left in tied {
            for right in tied where left != right {
                XCTAssertTrue(
                    (left < right) != (right < left),
                    "exactly one of any two distinct rows outranks the other"
                )
            }
        }
    }

    /// The stamp rule on its own, so all three properties it has to hold are
    /// provable without staging a rollback.
    func testRestoredRevisionStampsAdvanceEachRowPastItsOwnPriorStamp() {
        let epoch = Date(timeIntervalSinceReferenceDate: 0)
        func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

        // The shape the regression was found on: a loser far below the winner.
        // Each rises by ITS OWN step, and the loser is NOT lifted to the
        // winner's level.
        let stamps = ConversationStore.restoredRevisionStamps(
            advancing: [at(160), at(90)],
            step: 0.001
        )
        XCTAssertEqual(stamps, [at(160.001), at(90.001)])

        // (a) order preserved, and by the same margin as before.
        XCTAssertGreaterThan(stamps[0], stamps[1])

        // (b) every revision moves.
        XCTAssertNotEqual(stamps[0], at(160))
        XCTAssertNotEqual(stamps[1], at(90))

        // (c) a later update of the WINNER row — a peer whose clock corrected,
        // so its stamp lands far below the winner's own prior stamp — still
        // outranks the restored loser. This is the assertion the shared-ceiling
        // rule failed: it put the loser at ~160.001.
        XCTAssertGreaterThan(at(101), stamps[1])

        // Equal priors stay equal: the tie was already being settled by
        // `createdAt`/`title`, and those are untouched, so the same row wins.
        XCTAssertEqual(
            ConversationStore.restoredRevisionStamps(advancing: [at(50), at(50)], step: 0.001),
            [at(50.001), at(50.001)]
        )

        // A prior stamp AHEAD of the wall clock — a peer's skew — is advanced
        // like any other and is never used to lift anything else.
        let skewed = ConversationStore.restoredRevisionStamps(
            advancing: [Date().addingTimeInterval(3600), at(90)],
            step: 0.001
        )
        XCTAssertEqual(skewed[1], at(90.001), "a skewed sibling does not drag this row up")

        XCTAssertEqual(ConversationStore.restoredRevisionStamps(advancing: []), [])
    }

    /// A dated row against an UNDATED one. Both are compared in substituted
    /// space, so both have to be advanced in it, or the winner flips.
    func testAdvancingMixedDatedAndUndatedRowsKeepsTheSameWinner() {
        let created = Date(timeIntervalSinceReferenceDate: 90.0005)

        // Before: the undated row reads at its creation and beats the dated one.
        let datedBefore = ConversationStore.materialRevisionDate(
            updatedAt: Date(timeIntervalSinceReferenceDate: 90),
            createdAt: created
        )
        let undatedBefore = ConversationStore.materialRevisionDate(
            updatedAt: nil,
            createdAt: created
        )
        XCTAssertGreaterThan(undatedBefore, datedBefore)

        let after = ConversationStore.restoredRevisionStamps(
            advancing: [undatedBefore, datedBefore],
            step: 0.001
        )
        XCTAssertGreaterThan(
            after[0], after[1],
            "advancing the RAW column would have left the undated row at 90.0005 while the "
                + "dated one rose to 90.001, handing the card to the loser"
        )
        XCTAssertNotEqual(after[0], undatedBefore, "and the undated row's revision moved too")
    }

    /// The duplicate case, through the real store.
    ///
    /// CloudKit can materialise one logical material as two physical rows, and
    /// two offline devices can publish DIFFERENT bytes under one id — so the
    /// canonical row decides which payload the card serves. A rollback that
    /// stamped every row alike would collapse the key that decision is made on
    /// and could hand the card the other row's bytes, which is the exact
    /// opposite of "a refused reattach returns the previous payload".
    func testARolledBackReattachKeepsTheSameCanonicalRowAmongDuplicates() async throws {
        let store = isolated.make()

        // Row A: the card as this device published it.
        let ownBytes = Data("the bytes this device published".utf8)
        let original = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "report.txt",
                filename: "report.txt",
                mimeType: "text/plain",
                payload: ownBytes,
                byteSize: Int64(ownBytes.count)
            )
        )
        XCTAssertEqual(
            original.storageMode, .syncedPayload,
            "PRECONDITION: rows naming different blobs is a SYNCED-lane state"
        )
        let ownHash = try XCTUnwrap(original.contentHash)

        // Row B: the same material as another device published it, naming its
        // own blob and stamped NEWER — so B is the canonical row, and the card
        // serves B's bytes before anything below happens.
        let peerBytes = Data("the bytes the other device published".utf8)
        let peerHash = hex(peerBytes)
        let peerStamp = Date().addingTimeInterval(60)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: original.id,
            payload: peerBytes,
            byteSize: Int64(peerBytes.count),
            contentHash: peerHash,
            updatedAt: peerStamp
        )
        await store._duplicateWorkMaterialRowForTesting(
            id: original.id,
            updatedAt: peerStamp,
            contentHash: peerHash,
            byteSize: Int64(peerBytes.count)
        )

        let beforePayload = try await store.loadWorkMaterialPayload(id: original.id)
        XCTAssertEqual(
            beforePayload, peerBytes,
            "PRECONDITION: the newer duplicate is canonical, so the card serves its bytes"
        )
        let beforeRecord = try await store.fetchWorkMaterial(id: original.id)
        let atGateOne = try XCTUnwrap(beforeRecord)
        // Per ROW, keyed by the payload each names: the invariant is that every
        // row moves past ITS OWN stamp, not past the highest one on the card.
        let priorRows = await store._workMaterialRowsForTesting(id: original.id)
        let ownPriorStamp = try XCTUnwrap(priorRows.first { $0.contentHash == ownHash }?.updatedAt)
        let peerPriorStamp = try XCTUnwrap(priorRows.first { $0.contentHash == peerHash }?.updatedAt)

        try await failAReattachOn(store, of: original.id)

        // HALF ONE — the same row still wins, so the card serves the same bytes.
        let restoredRows = await store._workMaterialRowsForTesting(id: original.id)
        XCTAssertEqual(restoredRows.count, 2, "the rollback restores rows, it never merges them")
        let restoredStamps = restoredRows.compactMap(\.updatedAt)
        XCTAssertEqual(
            Set(restoredStamps).count, 2,
            "one shared stamp collapses the first sort key and lets the other duplicate win"
        )
        let ownRow = try XCTUnwrap(restoredRows.first { $0.contentHash == ownHash })
        let peerRow = try XCTUnwrap(restoredRows.first { $0.contentHash == peerHash })
        let peerStampAfter = try XCTUnwrap(peerRow.updatedAt)
        let ownStampAfter = try XCTUnwrap(ownRow.updatedAt)
        XCTAssertGreaterThan(
            peerStampAfter, ownStampAfter,
            "the row that was canonical before the replace is canonical after the rollback"
        )
        let afterPayload = try await store.loadWorkMaterialPayload(id: original.id)
        XCTAssertEqual(
            afterPayload, peerBytes,
            "a refused reattach returns the PREVIOUS payload — the one the card was actually on"
        )

        // HALF TWO — and the revision moved anyway, so a share prepared before
        // the replace cannot pass a check taken after it.
        let afterRecord = try await store.fetchWorkMaterial(id: original.id)
        let atGateTwo = try XCTUnwrap(afterRecord)
        XCTAssertGreaterThan(
            WorkboardRevision.value(for: atGateTwo.updatedAt),
            WorkboardRevision.value(for: atGateOne.updatedAt)
        )
        XCTAssertGreaterThan(
            ownStampAfter, ownPriorStamp,
            "no restored row may land on a revision it already had"
        )
        XCTAssertGreaterThan(peerStampAfter, peerPriorStamp)
        XCTAssertLessThan(
            ownStampAfter, peerPriorStamp,
            "and the loser is NOT lifted to the winner's level: a later update of the "
                + "winning row has to be able to outrank it"
        )
        XCTAssertFalse(
            WorkMaterialShareCoordinator.acceptsPreparedShare(
                requested: WorkboardLiveRepository.presentationSnapshotForTesting(atGateOne),
                current: WorkboardLiveRepository.presentationSnapshotForTesting(atGateTwo)
            )
        )
    }

    /// The sibling case the shared-ceiling rule broke: after the rollback, a
    /// later legitimate update of the WINNING row still wins.
    ///
    /// The peer's clock was ahead when it published, so its row carries the
    /// higher stamp and is canonical. Then the clock corrects and it publishes
    /// again with an ordinary `Date()` — a stamp far BELOW its own previous
    /// one. That update must still outrank our row. Lifting every restored row
    /// to the global prior maximum promoted OUR row to the peer's level, so the
    /// corrected update lost and the card served bytes nobody wrote last.
    func testARolledBackCardStillLetsALaterUpdateOfTheWinnerWin() async throws {
        let store = isolated.make()

        let ownBytes = Data("the bytes this device published".utf8)
        let original = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "report.txt",
                filename: "report.txt",
                mimeType: "text/plain",
                payload: ownBytes,
                byteSize: Int64(ownBytes.count)
            )
        )
        let ownHash = try XCTUnwrap(original.contentHash)

        // The peer's row, stamped an hour ahead by a skewed clock, naming its
        // own blob — so it is canonical.
        let peerBytes = Data("the bytes the other device published".utf8)
        let peerHash = hex(peerBytes)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: original.id,
            payload: peerBytes,
            byteSize: Int64(peerBytes.count),
            contentHash: peerHash,
            updatedAt: Date().addingTimeInterval(3600)
        )
        await store._duplicateWorkMaterialRowForTesting(
            id: original.id,
            updatedAt: Date().addingTimeInterval(3600),
            contentHash: peerHash,
            byteSize: Int64(peerBytes.count)
        )

        let priorRows = await store._workMaterialRowsForTesting(id: original.id)
        let ownPrior = try XCTUnwrap(priorRows.first { $0.contentHash == ownHash }?.updatedAt)
        let peerPrior = try XCTUnwrap(priorRows.first { $0.contentHash == peerHash }?.updatedAt)

        try await failAReattachOn(store, of: original.id)

        // The rollback actually restamped, and BOTH rows moved. Without this
        // the test would pass on a no-op restamp: the hour-ahead peer row wins
        // either way.
        let restoredRows = await store._workMaterialRowsForTesting(id: original.id)
        let ownRestored = try XCTUnwrap(restoredRows.first { $0.contentHash == ownHash }?.updatedAt)
        let peerRestored = try XCTUnwrap(restoredRows.first { $0.contentHash == peerHash }?.updatedAt)
        XCTAssertGreaterThan(ownRestored, ownPrior, "our row's revision moved")
        XCTAssertGreaterThan(peerRestored, peerPrior, "and so did the peer row's")
        XCTAssertLessThan(
            ownRestored, peerPrior,
            "our row advanced past its OWN stamp, not up to the peer's"
        )

        // The peer publishes again, clock corrected. Only ITS row moves —
        // CloudKit delivers that record and nothing else — and the stamp is an
        // ordinary `Date()`, far below the hour-ahead one it replaces.
        let correctedStamp = Date()
        await store._setWorkMaterialRowUpdatedAtForTesting(
            id: original.id,
            contentHash: peerHash,
            updatedAt: correctedStamp
        )

        let finalRows = await store._workMaterialRowsForTesting(id: original.id)
        let peerFinal = try XCTUnwrap(finalRows.first { $0.contentHash == peerHash }?.updatedAt)
        XCTAssertEqual(
            peerFinal.timeIntervalSinceReferenceDate,
            correctedStamp.timeIntervalSinceReferenceDate,
            accuracy: 0.0005,
            "the peer's own row carries the peer's own stamp"
        )
        let ownFinal = try XCTUnwrap(finalRows.first { $0.contentHash == ownHash }?.updatedAt)
        XCTAssertLessThan(ownFinal, peerFinal, "so the peer's update outranks our restored row")

        let payload = try await store.loadWorkMaterialPayload(id: original.id)
        XCTAssertEqual(
            payload, peerBytes,
            "the peer's corrected update is the newest write, so its bytes are the card's"
        )
    }

    /// A SINGLE row that carries no `updatedAt` at all. Readers substitute its
    /// `createdAt`, so a rollback that advanced only the raw column would leave
    /// this card at the revision it started on — and a share prepared before
    /// the replace would pass its equality check against bytes that had been
    /// swapped underneath it.
    func testARolledBackUndatedRowStillChangesItsRevision() async throws {
        let store = isolated.make()
        let ownBytes = Data("the bytes an undated row holds".utf8)
        let original = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "undated.txt",
                filename: "undated.txt",
                mimeType: "text/plain",
                payload: ownBytes,
                byteSize: Int64(ownBytes.count)
            )
        )
        // A row written before the column existed, or a peer record carrying
        // none. No public API produces it.
        await store._setWorkMaterialRowUpdatedAtForTesting(
            id: original.id,
            contentHash: try XCTUnwrap(original.contentHash),
            updatedAt: nil
        )

        let beforeRecord = try await store.fetchWorkMaterial(id: original.id)
        let atGateOne = try XCTUnwrap(beforeRecord)
        XCTAssertEqual(
            atGateOne.updatedAt, atGateOne.createdAt,
            "PRECONDITION: with no stamp the projection reports the row's creation"
        )

        try await failAReattachOn(store, of: original.id)

        let afterRecord = try await store.fetchWorkMaterial(id: original.id)
        let atGateTwo = try XCTUnwrap(afterRecord)

        let payload = try await store.loadWorkMaterialPayload(id: original.id)
        XCTAssertEqual(payload, ownBytes, "the payload still goes back verbatim")
        XCTAssertGreaterThan(
            WorkboardRevision.value(for: atGateTwo.updatedAt),
            WorkboardRevision.value(for: atGateOne.updatedAt),
            "an undated row is not revisionless, so its revision has to move too"
        )
        XCTAssertFalse(
            WorkMaterialShareCoordinator.acceptsPreparedShare(
                requested: WorkboardLiveRepository.presentationSnapshotForTesting(atGateOne),
                current: WorkboardLiveRepository.presentationSnapshotForTesting(atGateTwo)
            ),
            "so a copy taken mid-swap is refused rather than passing on an unchanged revision"
        )
    }

    /// A dated duplicate against an UNDATED one, through the real store. The
    /// undated row wins on its substituted revision before the rollback and has
    /// to keep winning after it.
    func testARollbackKeepsTheWinnerWhenOneDuplicateIsUndated() async throws {
        let store = isolated.make()
        let ownBytes = Data("the bytes this device published".utf8)
        let original = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "report.txt",
                filename: "report.txt",
                mimeType: "text/plain",
                payload: ownBytes,
                byteSize: Int64(ownBytes.count)
            )
        )
        let ownHash = try XCTUnwrap(original.contentHash)

        let peerBytes = Data("the bytes the other device published".utf8)
        let peerHash = hex(peerBytes)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: original.id,
            payload: peerBytes,
            byteSize: Int64(peerBytes.count),
            contentHash: peerHash,
            updatedAt: original.createdAt
        )
        await store._duplicateWorkMaterialRowForTesting(
            id: original.id,
            contentHash: peerHash,
            byteSize: Int64(peerBytes.count)
        )
        // The duplicate carries NO stamp, so it reads at the shared `createdAt`;
        // our own row is dated ten seconds before that, so the undated row wins.
        await store._setWorkMaterialRowUpdatedAtForTesting(
            id: original.id,
            contentHash: peerHash,
            updatedAt: nil
        )
        await store._setWorkMaterialRowUpdatedAtForTesting(
            id: original.id,
            contentHash: ownHash,
            updatedAt: original.createdAt.addingTimeInterval(-10)
        )

        let beforePayload = try await store.loadWorkMaterialPayload(id: original.id)
        XCTAssertEqual(
            beforePayload, peerBytes,
            "PRECONDITION: the undated duplicate reads at createdAt and wins"
        )

        try await failAReattachOn(store, of: original.id)

        let afterPayload = try await store.loadWorkMaterialPayload(id: original.id)
        XCTAssertEqual(
            afterPayload, peerBytes,
            "advancing only the raw column would have lifted the dated row past the undated "
                + "one and handed the card the wrong bytes"
        )
        let rows = await store._workMaterialRowsForTesting(id: original.id)
        let peerRow = try XCTUnwrap(rows.first { $0.contentHash == peerHash }?.updatedAt)
        let ownRow = try XCTUnwrap(rows.first { $0.contentHash == ownHash }?.updatedAt)
        XCTAssertGreaterThan(peerRow, ownRow)
        XCTAssertGreaterThan(
            peerRow, original.createdAt,
            "the undated row left the rollback carrying a real stamp above its creation"
        )
    }

    /// The REAL selectors, on real rows, with the candidate list handed to each
    /// in both directions.
    ///
    /// One case per way two physical rows of one card can differ while looking
    /// alike to the keys above them. Every one of these used to be resolved by
    /// "whichever arrived first", and the two selectors' candidate lists are
    /// ordered differently — the board's by rank, the single-row read's by
    /// timestamp — so first meant different rows.
    func testBothRealSelectorsPickTheSameRowInEitherOrder() async throws {
        /// All four answers the seam reports: the projection's winner and the
        /// single-row read's, each forward and reversed.
        func assertOneWinner(
            _ store: ConversationStore,
            _ id: UUID,
            _ what: String,
            line: UInt = #line
        ) async {
            let keys = await store._canonicalRowKeysForTesting(id: id)
            XCTAssertEqual(keys.count, 4, "\(what): all four selections must resolve", line: line)
            XCTAssertEqual(
                Set(keys).count, 1,
                "\(what): the board and the single-row read must name one physical row, "
                    + "whichever order the candidates arrive in",
                line: line
            )
        }

        /// A synced card on the desk, plus a duplicate the caller shapes.
        func card(
            _ store: ConversationStore,
            payload: Data,
            title: String
        ) async throws -> WorkMaterialRecord {
            try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    kind: .file,
                    title: title,
                    filename: title,
                    mimeType: "text/plain",
                    payload: payload,
                    byteSize: Int64(payload.count)
                )
            )
        }

        // 1 — two stamped rows, different bytes and different stamps.
        let datedStore = isolated.make()
        let dated = try await card(datedStore, payload: Data("one".utf8), title: "dated.txt")
        await datedStore._duplicateWorkMaterialRowForTesting(
            id: dated.id,
            updatedAt: dated.createdAt.addingTimeInterval(60),
            contentHash: hex(Data("two".utf8)),
            byteSize: 3
        )
        await assertOneWinner(datedStore, dated.id, "dated against dated")

        // 2 — one stamped, one not: compared in substituted space.
        let mixedStore = isolated.make()
        let mixed = try await card(mixedStore, payload: Data("one".utf8), title: "mixed.txt")
        await mixedStore._duplicateWorkMaterialRowForTesting(
            id: mixed.id,
            contentHash: hex(Data("two".utf8)),
            byteSize: 3
        )
        await mixedStore._setWorkMaterialRowUpdatedAtForTesting(
            id: mixed.id,
            contentHash: hex(Data("two".utf8)),
            updatedAt: nil
        )
        await assertOneWinner(mixedStore, mixed.id, "dated against undated")

        // 3 — neither row carries a stamp.
        let undatedStore = isolated.make()
        let undated = try await card(undatedStore, payload: Data("one".utf8), title: "undated.txt")
        let undatedOwnHash = try XCTUnwrap(undated.contentHash)
        let undatedPeerHash = hex(Data("two".utf8))
        await undatedStore._duplicateWorkMaterialRowForTesting(
            id: undated.id,
            contentHash: undatedPeerHash,
            byteSize: 3
        )
        for hash in [undatedOwnHash, undatedPeerHash] {
            await undatedStore._setWorkMaterialRowUpdatedAtForTesting(
                id: undated.id,
                contentHash: hash,
                updatedAt: nil
            )
        }
        await assertOneWinner(undatedStore, undated.id, "undated against undated")

        // 4 — Codex's counterexample: everything tied except the rank the two
        // devices assigned, which is what makes the two candidate lists differ.
        let rankStore = isolated.make()
        let ranked = try await card(rankStore, payload: Data("one".utf8), title: "ranked.txt")
        await rankStore._duplicateWorkMaterialRowForTesting(
            id: ranked.id,
            contentHash: hex(Data("two".utf8)),
            byteSize: 3,
            sequence: 1
        )
        await rankStore._setWorkMaterialRowUpdatedAtForTesting(
            id: ranked.id,
            contentHash: hex(Data("two".utf8)),
            updatedAt: nil
        )
        // PRECONDITION: the ranks really differ, or the two selectors would be
        // handed the SAME candidate order and this case would prove nothing.
        let ranks = await rankStore._workMaterialRowsForTesting(id: ranked.id)
            .compactMap(\.sequence)
        XCTAssertEqual(Set(ranks).count, 2, "the two devices ranked this card differently")
        await assertOneWinner(rankStore, ranked.id, "rows the two devices ranked differently")

        // 5 — a full tie on the first four keys: BOTH rows are device-local, so
        // neither names a blob and `contentHash` cannot separate them, while the
        // vault leaves they hold are different bytes.
        let vaultStore = isolated.make()
        // `addWorkMaterial` states no measured size, and an unmeasured payload
        // takes the device-local lane by policy — which is the only way to get
        // two rows that BOTH name no blob.
        let vaultItem = try await vaultStore.createWorkItem()
        let vaulted = try await vaultStore.addWorkMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "vaulted.bin",
                filename: "vaulted.bin",
                mimeType: "application/octet-stream",
                payload: Data("device local".utf8)
            ),
            to: vaultItem.id
        )
        XCTAssertEqual(
            vaulted.storageMode, .localVault,
            "PRECONDITION: an unmeasured payload takes the device-local lane"
        )
        XCTAssertNil(vaulted.contentHash, "and a vault row names no blob")
        await vaultStore._duplicateWorkMaterialRowForTesting(
            id: vaulted.id,
            localVaultKey: "a-different-leaf"
        )
        await assertOneWinner(vaultStore, vaulted.id, "two vault rows naming different leaves")

        // 6 — a perfect twin: every column identical, so only the row itself can
        // settle it.
        let twinStore = isolated.make()
        let twinned = try await card(twinStore, payload: Data("one".utf8), title: "twin.txt")
        await twinStore._duplicateWorkMaterialRowForTesting(id: twinned.id)
        await assertOneWinner(twinStore, twinned.id, "a full tie on every synced column")
    }

    /// A desk with no duplicates must not hash a single preview.
    ///
    /// The ordering is built for every material on every board load, and the
    /// digest is the one key that costs anything. Nothing compares a singleton
    /// against anything, so nothing should ever ask.
    func testASingletonDeskLoadHashesNoPreviews() async throws {
        let store = isolated.make()
        for index in 0..<3 {
            _ = try await store.upsertDeskMaterial(
                WorkMaterialDraft(
                    kind: .image,
                    title: "photo-\(index).png",
                    filename: "photo-\(index).png",
                    mimeType: "image/png",
                    payload: Data("pixels \(index)".utf8),
                    thumbnailData: Data("a preview for \(index)".utf8),
                    byteSize: Int64("pixels \(index)".utf8.count)
                )
            )
        }

        WorkMaterialCanonicalOrder.resetDigestCountForTesting()
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        XCTAssertEqual(desk.materials.count, 3, "PRECONDITION: three cards, none duplicated")
        XCTAssertTrue(
            desk.materials.allSatisfy { $0.thumbnailData != nil },
            "PRECONDITION: and every one of them carries a preview to hash"
        )
        XCTAssertEqual(
            WorkMaterialCanonicalOrder.digestCountForTesting, 0,
            "a board of singletons compares nothing, so it must hash nothing"
        )
    }

    /// The same parity end to end: on a card whose duplicates tie on everything
    /// a person can see, the BOARD and the payload read name the same bytes.
    ///
    /// These are the two readers that used to resolve a tie from differently
    /// ordered candidate lists — the board's by `(sequence, createdAt)`, the
    /// single-row read's by timestamp — so a card could describe one duplicate
    /// on the desk and open the other.
    func testTheBoardAndThePayloadReadNameTheSameBytesOnATiedCard() async throws {
        let store = isolated.make()
        let ownBytes = Data("the bytes this device published".utf8)
        let original = try await store.upsertDeskMaterial(
            WorkMaterialDraft(
                kind: .file,
                title: "report.txt",
                filename: "report.txt",
                mimeType: "text/plain",
                payload: ownBytes,
                byteSize: Int64(ownBytes.count)
            )
        )
        let ownHash = try XCTUnwrap(original.contentHash)

        // A duplicate naming different bytes, tied on everything else: the
        // seam copies `title`, `createdAt` and `sequence`, and both rows are
        // then stamped to the same instant.
        let peerBytes = Data("the bytes the other device published".utf8)
        let peerHash = hex(peerBytes)
        await store._insertWorkMaterialBlobRowForTesting(
            materialID: original.id,
            payload: peerBytes,
            byteSize: Int64(peerBytes.count),
            contentHash: peerHash,
            updatedAt: original.createdAt
        )
        await store._duplicateWorkMaterialRowForTesting(
            id: original.id,
            contentHash: peerHash,
            byteSize: Int64(peerBytes.count)
        )
        let tiedStamp = original.createdAt
        await store._setWorkMaterialRowUpdatedAtForTesting(
            id: original.id,
            contentHash: ownHash,
            updatedAt: tiedStamp
        )
        await store._setWorkMaterialRowUpdatedAtForTesting(
            id: original.id,
            contentHash: peerHash,
            updatedAt: tiedStamp
        )

        // PRECONDITION: the tie is real, on every key either reader can see.
        let rows = await store._workMaterialRowsForTesting(id: original.id)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.compactMap(\.updatedAt)).count, 1, "same revision")
        XCTAssertEqual(Set(rows.compactMap(\.title)).count, 1, "same title")
        XCTAssertEqual(Set(rows.compactMap(\.sequence)).count, 1, "same rank")

        // What the BOARD says this card is.
        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        let boardCard = try XCTUnwrap(desk.materials.first { $0.id == original.id })
        let boardHash = try XCTUnwrap(boardCard.contentHash)

        // What the payload read — and therefore Quick Look, the vault URL and
        // the share gate — actually serves.
        let served = try await store.loadWorkMaterialPayload(id: original.id)
        let servedHash = hex(try XCTUnwrap(served))

        XCTAssertEqual(
            boardHash, servedHash,
            "the desk must not describe one duplicate while the card opens the other"
        )
        XCTAssertTrue([ownHash, peerHash].contains(boardHash), "and it is one of the two rows")
    }

    /// Run a reattach whose publication cannot be proved, which is the ONE
    /// route to the rollback. The replacement is empty on purpose: a zero
    /// byte count takes the device-local lane, and only a vault publication
    /// has a proof to refuse.
    private func failAReattachOn(_ store: ConversationStore, of materialID: UUID) async throws {
        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduck-workasset-tests-\(UUID().uuidString).bin")
        try Data().write(to: replacement, options: .atomic)
        defer { try? FileManager.default.removeItem(at: replacement) }

        await store._setPublicationConfirmationHookForTesting { site, _, _, _ in
            site == .reattach ? false : nil
        }
        defer { Task { await store._setPublicationConfirmationHookForTesting(nil) } }

        let deskValue = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        let desk = try XCTUnwrap(deskValue)
        do {
            _ = try await store.replaceWorkMaterialPayloadFile(
                id: materialID,
                from: replacement,
                byteSize: 0,
                filename: replacement.lastPathComponent,
                mimeType: "application/octet-stream",
                sourceDevice: "test",
                expectedOwnerRevision: WorkboardRevision.value(for: desk.updatedAt)
            )
            XCTFail("a publication that cannot be proved must not report success")
        } catch {
            // THE refusal, not any error. `materialPayloadUnavailable` is the
            // one the store raises once the rollback SUCCEEDED, so asserting it
            // is what proves these tests exercised the restore at all rather
            // than failing somewhere earlier and reading an untouched card.
            XCTAssertEqual(
                error as? WorkboardStoreError,
                .materialPayloadUnavailable,
                "the reattach must fail by rolling back, not by some earlier refusal"
            )
        }
    }

    // MARK: - Copy

    /// The keys the share lane renders. `WorkboardCopyTruthGuardTests` holds
    /// both directions of the catalog; this states which rows this feature owns
    /// so deleting one fails here rather than showing a raw key on screen.
    func testTheShareLaneCarriesItsOwnCatalogRows() throws {
        let url = RefusalLaneSource.projectContainerURL
            .appendingPathComponent("Conduck/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let strings = try XCTUnwrap((json as? [String: Any])?["strings"] as? [String: Any])

        let keys = [
            "workboard.material.share",
            "workboard.material.share.preparing",
            "workboard.material.share.dismissFailure",
            "workboard.material.share.failed.title",
            "workboard.material.share.unavailable",
            "workboard.material.share.syncPending",
            "workboard.material.share.stale",
            "workboard.material.share.noAnchor"
        ]
        for key in keys {
            XCTAssertNotNil(strings[key], "\(key) has no catalog row and would render untranslated")
        }
        XCTAssertNil(
            strings["common.share"],
            "the retired key must not come back — the share rows live under workboard.material.share.*"
        )
    }
}
