// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkDeskHandoffTests.swift
//
// The Work-to-Chat boundary exercised with isolated stores and injected egress:
// preparation is private, reviewed content and routing cannot silently change,
// failed uploads leave no accepted turn, and a packet can be submitted once.

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Conduck

@MainActor
final class WorkDeskHandoffTests: XCTestCase {
    private let gatewayRef = RemoteAgentRef.builtin(.openclaw)

    /// Runs on the authoritative iOS test host without creating the macOS
    /// coordinator (which owns real app lifecycle observers). The registry's
    /// runtime identity contract is covered by MenuBarCoordinatorRegistryTests;
    /// this guard proves Work and the window both use that same owner.
    func testMacHandoffUsesTheWindowCoordinatorsConversationRegistry() throws {
        let path = "Conduck/Services/Workboard/WorkDeskHandoff.swift"
        let source = try RefusalLaneSource.source(at: path)
        let submitStart = try XCTUnwrap(source.range(of: "submit: {"))
        let submitSource = String(source[submitStart.lowerBound...])
        let submit = try RefusalLaneSource.trailingClosure(after: "submit:", in: submitSource, path: path)
        let macStart = try XCTUnwrap(submit.range(of: "#if os(macOS)"))
        let alternative = try XCTUnwrap(submit.range(of: "#else", range: macStart.upperBound..<submit.endIndex))
        let branchEnd = try XCTUnwrap(submit.range(of: "#endif", range: alternative.upperBound..<submit.endIndex))
        let mac = String(submit[macStart.upperBound..<alternative.lowerBound])
        let ios = String(submit[alternative.upperBound..<branchEnd.lowerBound])
        XCTAssertTrue(mac.contains("guard let viewModel = conversationResolver.resolve(id)"))
        XCTAssertFalse(mac.contains("NSApp.delegate"))
        XCTAssertTrue(mac.contains("return false"), "An absent app owner must refuse instead of minting a detached VM")
        XCTAssertFalse(mac.contains("ConversationDetailViewModel(conversationID:"))
        XCTAssertTrue(ios.contains("ConversationDetailViewModel(conversationID: id)"))
        XCTAssertTrue(submit.contains("expectedGatewaySnapshot: agent"))

        let app = try RefusalLaneSource.source(at: "Conduck/ConduckApp.swift")
        XCTAssertTrue(app.contains("MainWindowView(coordinator: appDelegate.coordinator)"))
        let window = try RefusalLaneSource.source(at: "Conduck/Views/Conversation/MainWindowView.swift")
        XCTAssertTrue(window.contains(".environment(\\.workDeskConversationResolver, WorkDeskConversationResolver("))
        XCTAssertTrue(window.contains("coordinator.retainWorkViewModel(for: id, ownerID: owner)"))
        XCTAssertTrue(window.contains("coordinator.clearWindowVisibleConversation(ifCurrent: id)"))
        let coordinatorPath = "Conduck/MenuBar/MenuBarCoordinator.swift"
        let coordinator = try RefusalLaneSource.source(at: coordinatorPath)
        let bind = try RefusalLaneSource.body(ofFunction: "bindWindowViewModel", in: coordinator, path: coordinatorPath)
        XCTAssertTrue(bind.contains("windowViewModel = viewModel(for: id)"))
    }

    func testPromptKeepsAllWordsLinksAndFoldedTranscriptExactlyOnce() {
        let words = WorkboardMaterialSnapshot(kind: .transcript, name: "Spoken thought", textContent: "Keep this exact idea")
        let picture = WorkboardMaterialSnapshot(kind: .image, name: "Reference.jpg", companion: WorkboardCompanionSnapshot(words))
        let link = WorkboardMaterialSnapshot(kind: .link, name: "Research", textContent: "A useful source", urlString: "https://example.invalid/reference")
        let expanded = WorkDeskHandoffPolicy.expanded([picture, words, link])
        XCTAssertEqual(expanded.map(\.id), [picture.id, words.id, link.id])
        let prompt = WorkDeskHandoffPolicy.prompt(title: "My project", brief: "Prepare a plan", materials: expanded)
        XCTAssertTrue(prompt.contains("My project\n\nPrepare a plan"))
        XCTAssertEqual(prompt.components(separatedBy: "Keep this exact idea").count, 2)
        XCTAssertTrue(prompt.contains("https://example.invalid/reference"))
    }

    func testProjectContextAndTaskAreReviewedWithoutOverwritingEither() async {
        let fixture = Fixture()
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        let projectID = UUID()
        await model.prepare(title: "Website", brief: "Review the copy", cards: [], ref: gatewayRef,
                            projectID: projectID, projectContext: "Use a warm tone")
        XCTAssertEqual(model.prepared?.projectID, projectID)
        XCTAssertEqual(model.prepared?.taskTitle, "Review the copy")
        XCTAssertEqual(model.prepared?.prompt, "Website\n\nProject context:\nUse a warm tone\n\nReview the copy")
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testRemoteResultCannotBeSentAsAFileBySelectingItsReferenceCard() async {
        let fixture = Fixture()
        let reference = fixture.add(kind: .note, name: "Report.pdf", text: "")
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Project", brief: "Read this report", cards: [reference], ref: gatewayRef,
                            remoteResultIDs: [reference.id])
        XCTAssertNil(model.prepared)
        XCTAssertEqual(model.errorMessage, WorkDeskHandoffError.remoteResult.localizedDescription)
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testRefreshingStandingContextPreservesTaskAndItsDiscardBaseline() {
        let draft = WorkDeskBriefDraft(brief: "Old context", preferredGatewayRef: gatewayRef.rawString)
        draft.brief = "Keep my task"
        draft.refreshProjectContext("Updated in another window")
        XCTAssertEqual(draft.brief, "Keep my task")
        XCTAssertEqual(draft.projectContext, "Updated in another window")
        draft.projectContext = "Unsaved change"
        draft.discardUnsavedChanges()
        XCTAssertEqual(draft.projectContext, "Updated in another window")
    }

    func testResettingTaskNeverAutomaticallyIncludesExistingResults() {
        let resultID = UUID()
        let draft = WorkDeskBriefDraft(brief: "Context", preferredGatewayRef: gatewayRef.rawString)
        draft.projectResultIDs = [resultID]
        draft.excludedIDs = [] // Deliberately included for the previous task.
        draft.discardUnsavedChanges()
        XCTAssertEqual(draft.excludedIDs, [resultID])
        draft.excludedIDs = []
        draft.startAnotherConversation()
        XCTAssertEqual(draft.excludedIDs, [resultID])
    }

    func testRemoteResultMarkerBlocksBeforeItsProvenanceReceiptArrives() async {
        let fixture = Fixture()
        let reference = WorkboardMaterialSnapshot(kind: .note, name: "Report.pdf", projectResultKind: .reference)
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        XCTAssertNotNil(WorkDeskHandoffPolicy.blockingReason(reference, gateway: nil))
        await model.prepare(title: "Project", brief: "Read the report", cards: [reference], ref: gatewayRef)
        XCTAssertNil(model.prepared)
        XCTAssertEqual(model.errorMessage, WorkDeskHandoffError.remoteResult.localizedDescription)
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testAvailabilityAndHostedBinaryReasonsFailClosedWithoutBlockingWords() {
        let hosted = WorkDeskGatewayOption(ref: .builtin(.openrouter), name: "OpenRouter", hasFileTransfer: false)
        let audio = WorkboardMaterialSnapshot(kind: .audio, name: "Recording.m4a", mimeType: "audio/mp4")
        let pendingImage = WorkboardMaterialSnapshot(kind: .image, name: "Photo.jpg", availability: .syncPending)
        let words = WorkboardMaterialSnapshot(kind: .transcript, name: "Words", textContent: "Use the words", availability: .unavailableOnThisDevice)
        XCTAssertNotNil(WorkDeskHandoffPolicy.blockingReason(audio, gateway: hosted))
        XCTAssertNotNil(WorkDeskHandoffPolicy.blockingReason(pendingImage, gateway: hosted))
        XCTAssertNil(WorkDeskHandoffPolicy.blockingReason(words, gateway: hosted))
    }

    func testPreparationNeverCreatesConversationUploadsOrSubmits() async {
        let fixture = Fixture()
        let note = fixture.add(kind: .note, name: "Idea", text: "Make a prototype")
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Project", brief: "Plan the next step", cards: [note], ref: gatewayRef)
        XCTAssertNotNil(model.prepared)
        XCTAssertTrue(fixture.events.isEmpty)
        XCTAssertEqual(model.prepared?.prompt, "Project\n\nPlan the next step\n\nMaterial 1: Idea\nMake a prototype")
        model.discardPreparation()
    }

    func testNoGatewayAndEmptyBriefDoNotReachAnyExternalBoundary() async {
        let fixture = Fixture()
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Project", brief: "", cards: [], ref: gatewayRef)
        XCTAssertNil(model.prepared)
        XCTAssertEqual(model.errorMessage, WorkDeskHandoffError.emptyBrief.localizedDescription)
        await model.prepare(title: "Project", brief: "Prepare a plan", cards: [], ref: nil)
        XCTAssertNil(model.prepared)
        XCTAssertEqual(model.errorMessage, WorkDeskHandoffError.noGateway.localizedDescription)
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testChangedMaterialRefusesPreparation() async {
        let fixture = Fixture()
        let note = fixture.add(kind: .note, name: "Idea", text: "Original")
        fixture.materials[note.id]?.revision += 1
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Project", brief: "Prepare a plan", cards: [note], ref: gatewayRef)
        XCTAssertNil(model.prepared)
        XCTAssertEqual(model.errorMessage, WorkDeskHandoffError.materialChanged.localizedDescription)
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testChangeAfterReviewRefusesSendBeforeUploadOrConversationCreation() async {
        let fixture = Fixture()
        let note = fixture.add(kind: .note, name: "Idea", text: "Original")
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Project", brief: "Prepare a plan", cards: [note], ref: gatewayRef)
        fixture.materials[note.id]?.textContent = "Edited elsewhere"
        let result = await model.send()
        XCTAssertNil(result)
        XCTAssertEqual(model.errorMessage, WorkDeskHandoffError.materialChanged.localizedDescription)
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testReplacedConnectionAndRemovedConnectionNeverReroute() async {
        for remove in [false, true] {
            let fixture = Fixture()
            let model = WorkDeskHandoff(dependencies: fixture.dependencies)
            await model.prepare(title: "Project", brief: "Prepare a plan", cards: [], ref: gatewayRef)
            fixture.connections = remove ? [] : [Fixture.connection(url: "https://different.example.invalid")]
            let result = await model.send()
            XCTAssertNil(result)
            XCTAssertEqual(model.errorMessage, WorkDeskHandoffError.connectionChanged.localizedDescription)
            XCTAssertTrue(fixture.events.isEmpty)
        }
    }

    func testTextFileWithoutFileServerCarriesActualExtractedAttachmentAndCleansCopy() async {
        let fixture = Fixture()
        let file = fixture.add(kind: .file, name: "Research.txt", data: Data("Exact file body".utf8), mime: "text/plain")
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Project", brief: "Summarize this", cards: [file], ref: gatewayRef)
        XCTAssertEqual(model.prepared?.textAttachments.first?.text, "Exact file body")
        let path = model.prepared?.files.first?.snapshot.url
        let result = await model.send()
        XCTAssertNotNil(result)
        XCTAssertEqual(fixture.events, ["create", "submit"])
        guard case .dualText(_, let text, let filename, _, let storedKey) = fixture.submittedAttachments.first else {
            return XCTFail("The real text must reach the normal attachment pipeline")
        }
        XCTAssertEqual(text, "Exact file body")
        XCTAssertEqual(filename, "Research.txt")
        XCTAssertNil(storedKey)
        XCTAssertEqual(fixture.submittedRef, gatewayRef)
        XCTAssertEqual(model.acceptedConversationID, result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path!.path))
        let repeated = await model.send()
        XCTAssertNil(repeated)
    }

    func testImageIsPreparedAsValidatedVisionBytesAndKeepsCompanionWords() async throws {
        let fixture = Fixture()
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let source = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let words = fixture.add(kind: .transcript, name: "My instructions", text: "Use the amber palette")
        var image = fixture.add(kind: .image, name: "Reference.png", data: bytes as Data, mime: "image/png")
        image.companion = WorkboardCompanionSnapshot(words)
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Design", brief: "Make a concept", cards: [image], ref: gatewayRef)
        XCTAssertTrue(model.prepared?.prompt.contains("Use the amber palette") == true)
        let result = await model.send()
        XCTAssertNotNil(result)
        guard case .dualImage(let jpeg, let thumbnail, let width, let height, _, let key, let filename) = fixture.submittedAttachments.first else {
            return XCTFail("Image processing must finish before accepting the reviewed packet")
        }
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xff, 0xd8])
        XCTAssertFalse(thumbnail.isEmpty)
        XCTAssertEqual(width, 8)
        XCTAssertEqual(height, 8)
        XCTAssertNil(key)
        XCTAssertEqual(filename, "Reference.png")
    }

    func testInvalidImageNeverSilentlyDropsASelectedAttachment() async {
        let fixture = Fixture()
        let image = fixture.add(kind: .image, name: "Damaged.jpg", data: Data("not an image".utf8), mime: "image/jpeg")
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Project", brief: "Review", cards: [image], ref: gatewayRef)
        XCTAssertNil(model.prepared)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(fixture.events.isEmpty)
        XCTAssertTrue(fixture.exported.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    }

    func testUnavailablePayloadNeverBecomesFilenameOnlyHandoff() async {
        let fixture = Fixture()
        let file = fixture.add(kind: .file, name: "Missing.txt", mime: "text/plain")
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Project", brief: "Review", cards: [file], ref: gatewayRef)
        XCTAssertNil(model.prepared)
        XCTAssertEqual(model.errorMessage, WorkDeskHandoffError.bytesUnavailable.localizedDescription)
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testBinaryWithoutFileTransferRefusesAndReclaimsPreparation() async {
        let fixture = Fixture()
        let audio = fixture.add(kind: .audio, name: "Sound.m4a", data: Data([0, 255, 0, 255]), mime: "audio/mp4")
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Project", brief: "Analyze this", cards: [audio], ref: gatewayRef)
        XCTAssertNil(model.prepared)
        XCTAssertEqual(model.errorMessage, WorkDeskHandoffError.needsFileTransfer.localizedDescription)
        XCTAssertTrue(fixture.events.isEmpty)
        XCTAssertTrue(fixture.exported.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    }

    func testBinaryUsesSelectedFileLaneBeforeOrdinaryChatSubmission() async {
        let fixture = Fixture(files: true)
        let file = fixture.add(kind: .file, name: "Document.pdf", data: Data([0, 255, 0, 255]), mime: "application/pdf")
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Project", brief: "Review the document", cards: [file], ref: gatewayRef)
        let packetID = model.prepared?.id
        let result = await model.send()
        XCTAssertEqual(result, packetID)
        XCTAssertEqual(fixture.events, ["upload", "create", "submit"])
        guard case .serverFile(_, let name, let mime, let key) = fixture.submittedAttachments.first else {
            return XCTFail("Binary bytes need a real uploaded file reference")
        }
        XCTAssertEqual(name, "Document.pdf")
        XCTAssertEqual(mime, "application/pdf")
        XCTAssertTrue(key.hasPrefix(packetID!.uuidString + "/"))
        XCTAssertEqual(fixture.submittedLaneID, fixture.connections[0].files?.durableLaneID)
    }

    func testUploadFailureCleansAllAttemptedKeysAndNeverCreatesConversation() async {
        let fixture = Fixture(files: true)
        fixture.failUpload = true
        let file = fixture.add(kind: .file, name: "Document.pdf", data: Data([0, 255]), mime: "application/pdf")
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Project", brief: "Review", cards: [file], ref: gatewayRef)
        let result = await model.send()
        XCTAssertNil(result)
        XCTAssertEqual(fixture.events, ["upload", "remove-upload"])
        XCTAssertNil(model.prepared)
        XCTAssertNil(model.acceptedConversationID)
        XCTAssertTrue(fixture.exported.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    }

    func testLocalSubmissionRefusalCleansEmptyChatAndUploadedFile() async {
        let fixture = Fixture(files: true)
        fixture.accepts = false
        let file = fixture.add(kind: .audio, name: "Audio.m4a", data: Data([0, 255]), mime: "audio/mp4")
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Project", brief: "Listen", cards: [file], ref: gatewayRef)
        let result = await model.send()
        XCTAssertNil(result)
        XCTAssertEqual(fixture.events, ["upload", "create", "submit", "remove-conversation", "remove-upload"])
        XCTAssertEqual(model.errorMessage, WorkDeskHandoffError.submissionRefused.localizedDescription)
    }

    func testRapidRepeatedSendSubmitsReviewedPacketOnlyOnce() async {
        let fixture = Fixture()
        fixture.holdSubmission = true
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Project", brief: "Prepare a plan", cards: [], ref: gatewayRef)
        let first = Task { await model.send() }
        while fixture.submissionContinuation == nil { await Task.yield() }
        let second = await model.send()
        XCTAssertNil(second)
        model.discardPreparation()
        XCTAssertNotNil(model.prepared, "A dismissal must not reclaim files under a live send")
        fixture.submissionContinuation?.resume(returning: true)
        fixture.submissionContinuation = nil
        let result = await first.value
        XCTAssertNotNil(result)
        let third = await model.send()
        XCTAssertNil(third)
        XCTAssertEqual(fixture.events, ["create", "submit"])
    }

    func testSuspendedDraftKeepsEditsAndExclusionsButDiscardsReviewCopies() async {
        let fixture = Fixture()
        let file = fixture.add(kind: .file, name: "Notes.txt", data: Data("File content".utf8), mime: "text/plain")
        let handoff = WorkDeskHandoff(dependencies: fixture.dependencies)
        let draft = WorkDeskBriefDraft(brief: "Saved", preferredGatewayRef: gatewayRef.rawString, handoff: handoff)
        let token = draft.beginPresentation()
        draft.brief = "My unsaved changes"
        draft.selectedGateway = .builtin(.openrouter)
        draft.excludedIDs = [UUID()]
        let exclusions = draft.excludedIDs
        await handoff.prepare(title: "Project", brief: "Read this", cards: [file], ref: gatewayRef)
        XCTAssertNotNil(handoff.prepared)
        draft.endPresentation(token)
        XCTAssertFalse(draft.isCurrentPresentation(token))
        XCTAssertNil(handoff.prepared)
        XCTAssertTrue(fixture.exported.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
        let reopened = draft.beginPresentation()
        XCTAssertEqual(draft.brief, "My unsaved changes")
        XCTAssertEqual(draft.selectedGateway, .builtin(.openrouter))
        XCTAssertEqual(draft.excludedIDs, exclusions)
        XCTAssertTrue(draft.handoff === handoff)
        draft.endPresentation(token)
        XCTAssertTrue(draft.isCurrentPresentation(reopened), "An old sheet disappearing must not suspend its replacement")
    }

    func testHostSuspensionRevokesNavigationBeforeSheetDisappear() {
        let fixture = Fixture()
        let draft = WorkDeskBriefDraft(brief: "Standing context", preferredGatewayRef: nil, task: "Keep this", handoff: WorkDeskHandoff(dependencies: fixture.dependencies))
        let token = draft.beginPresentation()
        XCTAssertTrue(draft.isCurrentPresentation(token))
        draft.suspendPresentation()
        XCTAssertFalse(draft.isCurrentPresentation(token))
        XCTAssertEqual(draft.brief, "Keep this")
        let replacement = draft.beginPresentation()
        draft.endPresentation(token)
        XCTAssertTrue(draft.isCurrentPresentation(replacement))
    }

    func testSuspendingUnfinishedPreparationCannotPublishAStaleReview() async {
        let fixture = Fixture()
        fixture.holdExport = true
        let file = fixture.add(kind: .file, name: "Notes.txt", data: Data("File content".utf8), mime: "text/plain")
        let handoff = WorkDeskHandoff(dependencies: fixture.dependencies)
        let draft = WorkDeskBriefDraft(brief: "Standing context", preferredGatewayRef: gatewayRef.rawString, task: "Read this", handoff: handoff)
        let token = draft.beginPresentation()
        let preparing = Task { await handoff.prepare(title: "Project", brief: draft.brief, cards: [file], ref: gatewayRef) }
        while fixture.exportContinuation == nil { await Task.yield() }
        draft.endPresentation(token)
        fixture.exportContinuation?.resume()
        fixture.exportContinuation = nil
        await preparing.value
        XCTAssertNil(handoff.prepared)
        XCTAssertTrue(fixture.events.isEmpty)
        XCTAssertTrue(fixture.exported.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    }

    func testSuspendedSendRetainsOwnerAndDoesNotAuthorizeOldNavigation() async {
        let fixture = Fixture()
        fixture.holdSubmission = true
        let handoff = WorkDeskHandoff(dependencies: fixture.dependencies)
        let draft = WorkDeskBriefDraft(brief: "Standing context", preferredGatewayRef: gatewayRef.rawString, task: "Plan this", handoff: handoff)
        let token = draft.beginPresentation()
        await handoff.prepare(title: "Project", brief: draft.brief, cards: [], ref: gatewayRef)
        let sending = Task { await handoff.send() }
        while fixture.submissionContinuation == nil { await Task.yield() }
        draft.endPresentation(token)
        let reopened = draft.beginPresentation()
        XCTAssertTrue(draft.handoff.isSending)
        let duplicate = await draft.handoff.send()
        XCTAssertNil(duplicate)
        fixture.submissionContinuation?.resume(returning: true)
        fixture.submissionContinuation = nil
        let accepted = await sending.value
        XCTAssertNotNil(accepted)
        XCTAssertEqual(draft.handoff.acceptedConversationID, accepted)
        XCTAssertFalse(draft.isCurrentPresentation(token))
        XCTAssertTrue(draft.isCurrentPresentation(reopened))
        XCTAssertEqual(fixture.events, ["create", "submit"])
    }

    func testDiscardResetsToLastSuccessfulSaveWithoutReplacingCurrentEditsAtCheckpoint() {
        let fixture = Fixture()
        let draft = WorkDeskBriefDraft(brief: "Original", preferredGatewayRef: gatewayRef.rawString, handoff: WorkDeskHandoff(dependencies: fixture.dependencies))
        draft.projectContext = "Latest unsaved context"
        draft.brief = "This conversation task"
        draft.markSaved(projectContext: "Earlier accepted save", selectedGateway: .builtin(.hermes))
        XCTAssertEqual(draft.projectContext, "Latest unsaved context", "A delayed save receipt is a baseline, not an edit")
        XCTAssertEqual(draft.brief, "This conversation task", "Saving project context cannot replace the task")
        draft.excludedIDs = [UUID()]
        draft.discardUnsavedChanges()
        XCTAssertEqual(draft.projectContext, "Earlier accepted save")
        XCTAssertEqual(draft.brief, "")
        XCTAssertEqual(draft.selectedGateway, .builtin(.hermes))
        XCTAssertTrue(draft.excludedIDs.isEmpty)
    }

    func testProjectContextDoesNotSeedAConversationTask() {
        let fixture = Fixture()
        let draft = WorkDeskBriefDraft(brief: "Build our launch website", preferredGatewayRef: nil,
                                      handoff: WorkDeskHandoff(dependencies: fixture.dependencies))
        XCTAssertEqual(draft.projectContext, "Build our launch website")
        XCTAssertTrue(draft.brief.isEmpty)
        draft.brief = "Review the wording"
        draft.markSaved(projectContext: draft.projectContext, selectedGateway: nil)
        draft.suspendPresentation()
        _ = draft.beginPresentation()
        XCTAssertEqual(draft.projectContext, "Build our launch website")
        XCTAssertEqual(draft.brief, "Review the wording")
    }

    func testStartingAnotherConversationClearsTaskAndReviewButKeepsProjectContext() async {
        let fixture = Fixture()
        let handoff = WorkDeskHandoff(dependencies: fixture.dependencies)
        let draft = WorkDeskBriefDraft(brief: "Standing project context", preferredGatewayRef: gatewayRef.rawString,
                                      task: "First task", handoff: handoff)
        await handoff.prepare(title: "Project", brief: draft.brief, cards: [], ref: gatewayRef)
        let first = await handoff.send()
        XCTAssertNotNil(first)
        draft.excludedIDs = [UUID()]
        draft.startAnotherConversation()
        XCTAssertEqual(draft.projectContext, "Standing project context")
        XCTAssertEqual(draft.selectedGateway, gatewayRef)
        XCTAssertTrue(draft.brief.isEmpty)
        XCTAssertTrue(draft.excludedIDs.isEmpty)
        XCTAssertNil(handoff.acceptedConversationID)
        XCTAssertNil(handoff.prepared)
        let unreviewed = await handoff.send()
        XCTAssertNil(unreviewed)
        XCTAssertEqual(fixture.events, ["create", "submit"])
    }

    func testAnotherHandoffRequiresDeliberateResetAndFreshReview() async {
        let fixture = Fixture()
        let model = WorkDeskHandoff(dependencies: fixture.dependencies)
        await model.prepare(title: "Project", brief: "First task", cards: [], ref: gatewayRef)
        let first = await model.send()
        await model.prepare(title: "Project", brief: "Second task", cards: [], ref: gatewayRef)
        XCTAssertNil(model.prepared)
        model.beginAnotherHandoff()
        XCTAssertNil(model.acceptedConversationID)
        XCTAssertEqual(fixture.events, ["create", "submit"])
        let withoutReview = await model.send()
        XCTAssertNil(withoutReview)
        await model.prepare(title: "Project", brief: "Second task", cards: [], ref: gatewayRef)
        let second = await model.send()
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(fixture.events, ["create", "submit", "create", "submit"])
    }

    func testPresentationOnlyChangesDoNotInvalidateReviewedContent() {
        let original = WorkboardMaterialSnapshot(kind: .note, name: "Idea", textContent: "Keep", revision: 3)
        var moved = original
        moved.sequence = 7
        moved.cardSize = .large
        moved.thumbnailData = Data([1, 2])
        XCTAssertTrue(WorkDeskHandoffPolicy.hasSameContent(original, moved))
        moved.revision = 4
        XCTAssertFalse(WorkDeskHandoffPolicy.hasSameContent(original, moved))
    }

    @MainActor private final class Fixture {
        var connections: [WorkDeskGatewayConnection]
        var materials: [UUID: WorkboardMaterialSnapshot] = [:]
        var payloads: [UUID: Data] = [:]
        var exported: [WorkMaterialExportSnapshot] = []
        var events: [String] = []
        var failUpload = false
        var accepts = true
        var holdSubmission = false
        var holdExport = false
        var exportContinuation: CheckedContinuation<Void, Never>?
        var submissionContinuation: CheckedContinuation<Bool, Never>?
        var submittedAttachments: [PendingAttachment] = []
        var submittedRef: RemoteAgentRef?
        var submittedLaneID: String?

        init(files: Bool = false) { connections = [Self.connection(files: files)] }

        static func connection(url: String = "https://example.invalid", files: Bool = false) -> WorkDeskGatewayConnection {
            let ref = RemoteAgentRef.builtin(.openclaw)
            let agent = SettingsManager.RemoteAgentSnapshot(backend: .openclaw, ref: ref, url: URL(string: url)!, token: nil, authScheme: .none, model: nil, certFingerprintHex: nil, activeSessionID: nil)
            let lane: SettingsManager.FileTransferSnapshot? = files ? .init(baseURL: URL(string: "https://files.example.invalid")!, username: "test", credential: "fixture", certFingerprintHex: nil, available: true, folderCapable: true, returnCapable: true, autoDeliver: true, filenamePolicy: "preserve") : nil
            return WorkDeskGatewayConnection(option: .init(ref: ref, name: "Test AI", hasFileTransfer: files), agent: agent, files: lane)
        }

        func add(kind: WorkboardMaterialKind, name: String, text: String? = nil, data: Data? = nil, mime: String? = nil) -> WorkboardMaterialSnapshot {
            let material = WorkboardMaterialSnapshot(kind: kind, name: name, textContent: text, mimeType: mime, byteCount: data.map { Int64($0.count) }, revision: 1)
            materials[material.id] = material
            payloads[material.id] = data
            return material
        }

        var dependencies: WorkDeskHandoff.Dependencies {
            .init(
                connections: { [self] in connections },
                material: { [self] in materials[$0] },
                export: { [self] material in
                    guard let payload = payloads[material.id] else { throw WorkMaterialExportError.bytesUnavailable }
                    let result = try await WorkMaterialExportSnapshot.writing(payload, displayName: material.name, mimeType: material.mimeType)
                    exported.append(result)
                    if holdExport {
                        await withCheckedContinuation { exportContinuation = $0 }
                    }
                    return result
                },
                upload: { [self] _, _, _ in
                    events.append("upload")
                    if failUpload { throw WorkDeskHandoffError.submissionRefused }
                },
                removeUpload: { [self] _, _ in events.append("remove-upload") },
                createConversation: { [self] _, _, _, _ in events.append("create") },
                removeConversation: { [self] _ in events.append("remove-conversation") },
                submit: { [self] _, _, attachments, ref, lane, _ in
                    events.append("submit")
                    submittedAttachments = attachments
                    submittedRef = ref
                    submittedLaneID = lane
                    if holdSubmission {
                        return await withCheckedContinuation { submissionContinuation = $0 }
                    }
                    return accepts
                }
            )
        }
    }
}
