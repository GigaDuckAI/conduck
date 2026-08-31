Bottom line: the product direction and Shape B are viable, but this draft is not build-ready. Several races can lose or strand bytes, the CloudKit fallback is unsafe, and the audio path is internally contradictory.

Required changes:

1. Add one authoritative desk-material upsert.

   The fixed UUID plus duplicate-row projection is sound: materials from duplicate physical desk rows do union correctly. But changing only the existing-owner branch in [`createWorkItemWithInitialMaterial`](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/ConversationStore+Workboard.swift:709) is insufficient—the cited idempotent shortcut is in a different method at line 821.

   Define a store operation that, in one logical call, ensures the desk, returns an existing same-owner material, repairs missing blob data, or inserts the material. Use it from first in-app capture, Chat→Work, `CaptureWorkboardIntent`, and the drainer. The Watch needs the same one-context logic locally.

2. Fix drainer replay semantics and cross-process ownership.

   The share appex only publishes an envelope; it never writes Core Data. The competing writers are primarily the app/headless intent process, plus the Watch through CloudKit.

   Deterministic material IDs prevent logical duplicates, but do not protect queue ownership. [`WorkCaptureInbox.reconcile()`](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/WorkCaptureInbox.swift:419) treats `activeClaims` as process-local and can requeue a directory another process is actively draining. Add a filesystem lease/lock or stale-claim horizon and test two independent inbox/drainer instances against the same directory.

   Also make every envelope note a material, including the first capture. Currently it is written only when `appendsToExistingItem == true`; retaining the “new destination” value would silently drop the first targetless note.

3. Strengthen Phase 0 into two distinct gates.

   Apple documents named configurations and multiple store descriptions, so the general two-store shape is legitimate. It does not establish that two CloudKit-backed stores using the same private database behave correctly for this topology. [Apple’s setup guide](https://developer.apple.com/documentation/coredata/setting-up-core-data-with-cloudkit)

   Phase 0 must include:

   - A local v15-default-store → v16-`Core` migration and production-like two-SQLite CRUD/reopen test.
   - A signed, real-CloudKit export/import test covering both stores, record-zone behavior, reinstall/reimport, and actual Watch exclusion.
   - The headless App Intent topology. Apple explicitly warns against multiple `NSPersistentCloudKitContainer` instances synchronizing the same shared store across app/extension processes. [TN3164](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer)

   A signed macOS build only compiles this; it does not exercise it.

4. Delete the proposed Watch fallback.

   “Wrist disk cost bounded by the sync ceiling” is false. The ceiling is per material; aggregate blob storage is unbounded. If the configuration approach fails, shipping every blob to the Watch is not an acceptable fallback. Block byte sync, retain `.localVault`, or design another exclusion mechanism.

5. Specify a crash-repairable two-store publication protocol.

   A WorkMaterial row and its blob live in separate SQLite stores and later become separate CloudKit records. The plan must not assume an atomic commit across them.

   Make replay repair every partial state:

   - Blob exists, material absent.
   - Material says `.syncedPayload`, blob absent.
   - Duplicate blob rows.
   - Existing material replayed with mismatching hash/size.
   - Transition between `.localVault` and `.syncedPayload` during reattach.

   Do not acknowledge an inbox claim until metadata and blob are both durably readable. Add injected-failure tests between each publication step.

6. Do not GC blobs merely because a material is currently absent.

   The plan simultaneously permits blob-before-material import and proposes deleting blobs whose material is absent. A reconciliation pass between those imports would export a deletion of valid data. Prefer explicit paired deletion; otherwise require a conservative tombstone/grace protocol. The local-vault GC pattern is not safe to copy because its publication is local and single-store.

7. Make availability prove completeness.

   Fetching only blob `materialID` is not enough: every blob field is optional and duplicate/incomplete rows are permitted. Batch-project scalar completeness evidence—at least `materialID`, nonnil hash, byte size, and update ordering—and choose the newest complete blob. `.syncedPending` must be non-available for opening/playback.

8. Lower the initial sync ceiling and test memory.

   Starting at 100 MiB is aggressive when the only cited published limit is 50 MB. Begin below that with margin, then raise after real-device evidence. Also test peak memory when assigning a large `Data` value; `allowsExternalBinaryDataStorage` permits externalization but does not promise a particular backing file or eliminate materialization.

9. Redesign audio as an explicit two-phase capture.

   The plan cannot both mint before STT and populate the same mint with a transcript that does not exist until STT finishes. The compressed artifact appears at [`InAppAudioRecorder.swift:307`](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:307); the transcript arrives around line 474.

   Mint a stable capture/material ID, durably stage the audio before STT, then either:

   - Insert the audio card after successful STT; or
   - Insert immediately and update its transcript afterward.

   In either case, storage failure must retain the audio. The existing Work retry path currently republishes only transcript plus optional screenshot at [`ContentView.swift:1554`](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/ContentView.swift:1554); it must create or repair the same audio material rather than degrade it into a note or duplicate it.

10. Close the purge-map compile and legacy-data holes.

   - Deleting `WorkBriefPromptBuilder.swift` also deletes `WorkBriefMaterialPacket`, yet surviving repository mapping still calls it at [`WorkboardLiveRepository.swift:415`](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift:415). Re-home direct material-kind/name mapping first.
   - Load only the fixed desk into the one-desk view model. Existing model-15 project rows otherwise make `items.isEmpty`, selection, and provisional-desk logic lie.
   - Specify the macOS sidebar rewrite, not merely deletion of Work’s mount: Chat’s sidebar is currently explicitly hidden when Work is active at [`MainWindowView.swift:547`](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Conversation/MainWindowView.swift:547).
   - Remove the deleted upload journal from the storage-seam allowlist.
   - Add a source drift guard comparing the desk UUID in main and Watch code.

11. Correct the Xcode/test-target instructions.

   Model 15 was added successfully without a project-file edit; this repository’s synchronized source group includes the `.xcdatamodeld`. Do not require a speculative PBX version-group edit for model 16—prove whether one is needed from the compiled `.momd`.

   Conversely, a new file in `ConduckWatchTests` must be manually added to that target. Put the desk test in the existing smoke-test file or explicitly update the project.

12. Update architecture truth and the complete gate.

   The architecture currently says Work file bytes remain device-local and that audio never syncs at [`spec.md:430`](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/ai-context/spec.md:430) and [`spec.md:503`](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/ai-context/spec.md:503). Both become false. Update those decisions and affected source headers.

   Run all source guards, `git diff --check`, the production-like two-store tests, signed macOS build, full iOS/Watch suites, and manual macOS Work/Chats/sidebar/empty-desk QA. The current `check-spec-size.sh` already fails at 19,830 words versus 16,900, so a claimed full repository gate needs either a real reduction or an explicitly recorded pre-existing failure.

VERDICT: SOUND WITH CHANGES
