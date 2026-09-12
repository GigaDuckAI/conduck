// SPDX-License-Identifier: Apache-2.0

// A microphone capture belongs to the project visible when recording starts,
// including after its recorder disappears. Real recorder seams and a disk retry
// queue protect that boundary without requiring microphone permission or a
// speech provider. A deleted project changes the reported location, never the
// survival of the words; stale retries cannot undo later user organization.

#if !os(watchOS)
import XCTest
@testable import Conduck

@MainActor
final class WorkVoiceContextualCaptureTests: XCTestCase {
    private let isolated = IsolatedWorkStores()
    private var roots: [URL] = []
    private static let audio = Data(repeating: 0x7F, count: 4_096)

    override func tearDown() async throws {
        WorkVoiceCaptureCoordinator.projectFallbackPauseForTesting = nil
        for root in roots { try? FileManager.default.removeItem(at: root) }
        await isolated.cleanUp()
        try await super.tearDown()
    }

    private func makeRecorder(
        store: ConversationStore, destination: WorkboardCaptureDestination
    ) throws -> (InAppAudioRecorder, PendingRetryStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-voice-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let queue = PendingRetryStore(containerURL: root, defaults: InMemoryDefaultsStore())
        let recorder = InAppAudioRecorder(retryDestination: .work, workProjectID: destination.projectID)
        recorder.workStoreForTesting = store
        recorder.retryLaneForTesting = queue
        recorder.workInboxForTesting = WorkCaptureInbox(baseURL: root.appendingPathComponent("inbox"))
        recorder.capturedAudioForTesting = Self.audio
        recorder.speechAuthorizationForTesting = .authorized
        return (recorder, queue, root)
    }

    func testFrozenDestinationSurvivesMetadataCopiesAndCannotBeRetargetedOnRearm() throws {
        let id = UUID()
        let project = UUID()
        let other = UUID()
        func metadata(projectID: UUID?) -> PendingRetryMetadata {
            PendingRetryMetadata(id: id, createdAt: Date(),
                audioFileURL: URL(fileURLWithPath: "/tmp/contextual-recording.m4a"),
                preferredLanguage: nil, attemptCount: 1, lastErrorCode: nil,
                destination: .work, workProjectID: projectID)
        }
        let original = metadata(projectID: project)
        let decoded = try JSONDecoder().decode(PendingRetryMetadata.self,
            from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.workProjectID, project)
        XCTAssertEqual(decoded.recordingAttempt(lastErrorCode: 1).workProjectID, project)
        XCTAssertEqual(decoded.recording(transcript: "Words", publicationState: .published).workProjectID, project)
        XCTAssertEqual(metadata(projectID: other).keepingPublication(of: decoded).workProjectID, project)
        XCTAssertEqual(metadata(projectID: nil).keepingPublication(of: decoded).workProjectID, project)
        XCTAssertNil(original.keepingPublication(of: metadata(projectID: nil)).workProjectID,
            "an originally external capture cannot inherit a later window's project")

        // A legacy JSON record has no field at all. Optional decoding keeps it
        // unfiled without a migration or a lookup of the current workspace.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "workProjectID")
        let legacy = try JSONDecoder().decode(PendingRetryMetadata.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.workProjectID)
    }

    func testMicrophoneUsesLaunchProjectWhenNavigationChangesDuringSpeechHop() async throws {
        let store = isolated.make()
        let organization = WorkDeskOrganization(store: store)
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let projectValue = await organization.createProject(title: "Original")
        let projectID = try XCTUnwrap(projectValue)
        workspace.selectScope(.project(projectID))
        let frozen = WorkboardCaptureDestination(workspace: workspace)
        let (recorder, _, _) = try makeRecorder(store: store, destination: frozen)
        recorder.transcriptionHopForTesting = { _ in
            workspace.selectScope(.all)
            return .success("Keep these spoken words")
        }

        let result = await recorder._finishCaptureForTesting()

        XCTAssertEqual(try result.get(), "Keep these spoken words")
        let materialID = try XCTUnwrap(recorder.workRecordingMaterialID)
        let snapshot = try await store.fetchWorkDeskOrganization()
        let material = try await store.fetchWorkMaterial(id: materialID)
        XCTAssertEqual(snapshot.placements[materialID]?.projectID, projectID)
        XCTAssertEqual(material?.kind, .transcript)
        XCTAssertEqual(workspace.scope, .all)
        XCTAssertFalse(recorder.workCaptureSavedInAllMaterials)
    }

    func testMicrophoneInAllOrGlobalSearchHasNoProjectDestination() async throws {
        for searching in [false, true] {
            let store = isolated.make()
            let organization = WorkDeskOrganization(store: store)
            let workspace = WorkDeskWorkspaceState(organization: organization)
            let projectValue = await organization.createProject(title: "Underneath")
            let projectID = try XCTUnwrap(projectValue)
            if searching {
                workspace.selectScope(.project(projectID))
                workspace.search = "Across projects"
            }
            let destination = WorkboardCaptureDestination(workspace: workspace)
            XCTAssertNil(destination.projectID)
            let (recorder, _, _) = try makeRecorder(store: store, destination: destination)
            recorder.transcriptionHopForTesting = { _ in .success("An unfiled voice note") }

            let result = await recorder._finishCaptureForTesting()

            XCTAssertEqual(try result.get(), "An unfiled voice note")
            let materialID = try XCTUnwrap(recorder.workRecordingMaterialID)
            let snapshot = try await store.fetchWorkDeskOrganization()
            XCTAssertNil(snapshot.placements[materialID]?.projectID)
        }
    }

    func testFailedSpeechHopKeepsLaunchProjectThroughDurableQueueReopenAndRecovery() async throws {
        let store = isolated.make()
        let organization = WorkDeskOrganization(store: store)
        let workspace = WorkDeskWorkspaceState(organization: organization)
        let projectValue = await organization.createProject(title: "Original")
        let projectID = try XCTUnwrap(projectValue)
        workspace.selectScope(.project(projectID))
        let (recorder, _, root) = try makeRecorder(store: store,
            destination: WorkboardCaptureDestination(workspace: workspace))
        recorder.transcriptionHopForTesting = { _ in
            workspace.selectScope(.all)
            return .failure(.sttProviderUnreachable)
        }

        let result = await recorder._finishCaptureForTesting()
        guard case .failure = result else { return XCTFail("the speech hop must fail") }
        let captureID = try XCTUnwrap(recorder.pendingWorkCapture?.id)
        let beforeRecovery = try await store.fetchWorkMaterial(id: captureID)
        XCTAssertNil(beforeRecovery)

        // Recreate the queue from its files: no recorder field can carry the
        // destination into this recovery, and the workspace points elsewhere.
        let reopened = PendingRetryStore(containerURL: root, defaults: InMemoryDefaultsStore())
        let offered = await reopened.claimNext(surface: .work)
        let claim = try XCTUnwrap(offered)
        XCTAssertEqual(claim.id, captureID)
        XCTAssertEqual(claim.entry.metadata.workProjectID, projectID)
        XCTAssertEqual(claim.entry.audioData, Self.audio)
        let outcome = try await WorkVoiceCaptureCoordinator.recover(claim,
            transcript: "Recovered words", store: store, queue: reopened)

        XCTAssertEqual(outcome, .wordsPublished)
        let snapshot = try await store.fetchWorkDeskOrganization()
        let material = try await store.fetchWorkMaterial(id: captureID)
        XCTAssertEqual(snapshot.placements[captureID]?.projectID, projectID)
        XCTAssertEqual(material?.textContent, "Recovered words")
        let cleared = await reopened.clear(claim)
        XCTAssertTrue(cleared)
    }

    func testProjectArchivedDuringMicrophoneHopSavesWordsWithExplicitFallbackReceipt() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Completed")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let (recorder, queue, _) = try makeRecorder(store: store, destination: .project(project.id, title: project.title))
        recorder.transcriptionHopForTesting = { _ in
            _ = try? await store.applyWorkDeskMutation(.archiveProject(id: project.id, isArchived: true))
            return .success("Keep the words spoken before archiving")
        }
        let result = await recorder._finishCaptureForTesting()
        XCTAssertEqual(try result.get(), "Keep the words spoken before archiving")
        XCTAssertTrue(recorder.workCaptureSavedInAllMaterials)
        let materialID = try XCTUnwrap(recorder.workRecordingMaterialID)
        let material = try await store.fetchWorkMaterial(id: materialID)
        let snapshot = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(material?.textContent, "Keep the words spoken before archiving")
        XCTAssertNil(snapshot.placements[materialID])
        XCTAssertEqual(snapshot.projects.first?.isArchived, true)
        let replay = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "Keep the words spoken before archiving", forCapture: materialID, createdAt: Date(),
            projectID: project.id, store: store)
        XCTAssertEqual(replay, .wordsPublishedInAllMaterials(materialID: materialID))
        let pending = await queue.load()
        XCTAssertTrue(pending.isEmpty)
    }

    func testProjectDeletedDuringMicrophoneHopSavesWordsWithExplicitFallbackReceipt() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Temporary")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let (recorder, queue, _) = try makeRecorder(store: store, destination: .project(project.id, title: project.title))
        recorder.transcriptionHopForTesting = { _ in
            _ = try? await store.applyWorkDeskMutation(.deleteProject(id: project.id))
            return .success("Do not lose these words")
        }

        let result = await recorder._finishCaptureForTesting()

        XCTAssertEqual(try result.get(), "Do not lose these words")
        XCTAssertTrue(recorder.workCaptureSavedInAllMaterials)
        let materialID = try XCTUnwrap(recorder.workRecordingMaterialID)
        let material = try await store.fetchWorkMaterial(id: materialID)
        let snapshot = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(material?.textContent, "Do not lose these words")
        XCTAssertNil(snapshot.placements[materialID]?.projectID)
        let pending = await queue.load()
        XCTAssertTrue(pending.isEmpty, "the durable words safely replace the retry recording")
    }

    func testRecoveryReportsDeletedDestinationAndLaterRetryPreservesUserFiling() async throws {
        let store = isolated.make()
        let original = WorkDeskProjectRecord(title: "Original")
        let later = WorkDeskProjectRecord(title: "Later")
        _ = try await store.applyWorkDeskMutation(.createProject(original, materialIDs: []))
        _ = try await store.applyWorkDeskMutation(.createProject(later, materialIDs: []))
        let (recorder, queue, _) = try makeRecorder(store: store, destination: .project(original.id, title: original.title))
        recorder.transcriptionHopForTesting = { _ in .failure(.sttProviderUnreachable) }
        let result = await recorder._finishCaptureForTesting()
        guard case .failure = result else { return XCTFail("the speech hop must fail") }
        _ = try await store.applyWorkDeskMutation(.deleteProject(id: original.id))
        let offered = await queue.claimNext(surface: .work)
        let claim = try XCTUnwrap(offered)

        let recovered = try await WorkVoiceCaptureCoordinator.recover(claim,
            transcript: "Words to keep", store: store, queue: queue)

        XCTAssertEqual(recovered, .wordsPublishedInAllMaterials)
        XCTAssertTrue(recovered.savedInAllMaterials)
        XCTAssertTrue(recovered.isTerminal)
        // A process lost before presenting the receipt reconstructs it from
        // the durable destination and the standing card without re-filing it.
        let receiptWithWords = try await WorkVoiceCaptureCoordinator.recover(claim,
            transcript: "Words to keep", store: store, queue: queue)
        XCTAssertEqual(receiptWithWords, .wordsPublishedInAllMaterials)
        _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [claim.id], projectID: later.id))
        // Replaying the durable claim after the user files its card models a
        // publication that succeeded but whose retry clear did not complete.
        let replayed = try await WorkVoiceCaptureCoordinator.recover(claim,
            transcript: "Words to keep", store: store, queue: queue)

        XCTAssertEqual(replayed, .wordsPublished)
        let snapshot = try await store.fetchWorkDeskOrganization()
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(snapshot.placements[claim.id]?.projectID, later.id)
        XCTAssertEqual(desk?.materials.count, 1)
        let cleared = await queue.clear(claim)
        XCTAssertTrue(cleared)
    }

    func testLegacyRecordingArrivingDuringProjectFallbackKeepsAttachedOutcome() async throws {
        let store = isolated.make()
        let captureID = UUID()
        let recordingID = WorkMaterialCollisionEscape.materialID(forCapture: captureID)
        WorkVoiceCaptureCoordinator.projectFallbackPauseForTesting = {
            _ = try await store.upsertDeskMaterial(WorkMaterialDraft(
                id: recordingID, kind: .audio, title: "Earlier recording",
                filename: "recording.m4a", mimeType: "audio/mp4",
                payload: Self.audio, byteSize: Int64(Self.audio.count)
            ))
        }
        defer { WorkVoiceCaptureCoordinator.projectFallbackPauseForTesting = nil }

        let outcome = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "Words for the recording", forCapture: captureID, createdAt: Date(),
            projectID: UUID(), store: store
        )

        XCTAssertEqual(outcome, .attachedToRecording(materialID: recordingID))
        XCTAssertFalse(outcome.savedInAllMaterials)
        let recording = try await store.fetchWorkMaterial(id: recordingID)
        let desk = try await store.fetchWorkItem(id: Constants.workboardDeskItemID)
        XCTAssertEqual(recording?.kind, .audio)
        XCTAssertEqual(recording?.textContent, "Words for the recording")
        XCTAssertEqual(desk?.materials.map(\.id), [recordingID])
    }

    func testSuccessfullyFiledCaptureDoesNotReportFallbackAfterProjectDeletion() async throws {
        let store = isolated.make()
        let project = WorkDeskProjectRecord(title: "Completed project")
        _ = try await store.applyWorkDeskMutation(.createProject(project, materialIDs: []))
        let captureID = UUID()
        let published = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "Already filed words", forCapture: captureID, createdAt: Date(),
            projectID: project.id, store: store
        )
        XCTAssertEqual(published, .wordsPublished(materialID: captureID))
        _ = try await store.applyWorkDeskMutation(.deleteProject(id: project.id))
        let beforeReplay = try await store.fetchWorkDeskOrganization()

        let replayed = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "Already filed words", forCapture: captureID, createdAt: Date(),
            projectID: project.id, store: store
        )

        XCTAssertEqual(replayed, .wordsPublished(materialID: captureID))
        XCTAssertFalse(replayed.savedInAllMaterials)
        XCTAssertTrue(beforeReplay.deletedProjectIDs.contains(project.id))
        XCTAssertNotNil(beforeReplay.placements[captureID], "deletion preserves filing evidence")
        let afterReplay = try await store.fetchWorkDeskOrganization()
        XCTAssertEqual(afterReplay.placements, beforeReplay.placements, "a replay does not rewrite organization")
    }

    func testFallbackReplayHonorsExplicitMoveToAllMaterials() async throws {
        let store = isolated.make()
        let captureID = UUID()
        let missingProjectID = UUID()
        let initial = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "Keep these words", forCapture: captureID, createdAt: Date(),
            projectID: missingProjectID, store: store
        )
        XCTAssertEqual(initial, .wordsPublishedInAllMaterials(materialID: captureID))
        _ = try await store.applyWorkDeskMutation(.assign(materialIDs: [captureID], projectID: nil))

        let replayed = try await WorkVoiceCaptureCoordinator.publishTranscript(
            "Keep these words", forCapture: captureID, createdAt: Date(),
            projectID: missingProjectID, store: store
        )

        XCTAssertEqual(replayed, .wordsPublished(materialID: captureID))
    }
}
#endif
