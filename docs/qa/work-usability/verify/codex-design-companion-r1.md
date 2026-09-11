**I would pick B, with model 17, and ship voice + screenshot first.** The two-row storage model fits the existing invariants. The brief understates the work needed around identity, reordering, sharing, and deletion; it is not ready to implement as written.

Verified against `feature/agent-workboard`. Nothing modified.

1. **P1 — Editing model 16 in place risks making existing stores unopenable.**

   The precedent explicitly depends on model 16 being “on no device”: [desk-cloudkit-handoff.md:40](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/desk-cloudkit-handoff.md:40). Your statement that development devices already have model-16 stores invalidates that exception.

   An optional attribute is suitable for lightweight migration, but automatic migration needs discoverable source and destination models. Replacing the source model is a different proposition from adding an inferable destination model. [Apple’s migration guidance](https://developer.apple.com/documentation/coredata/migrating-your-data-model-automatically).

   **Preserve 16 and add 17.** The existing schema test already requires `contentHash` to be the *only* attribute added in 16: [WorkboardModelMigrationTests.swift:263](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkboardModelMigrationTests.swift:263). Add a real SQLite 16→17 upgrade test, retaining both configurations.

   CloudKit production deployment is a separate concern. Model 17 does not require another container; the additive schema still needs deployment before release. The handoff records that release gate, but I did not verify live CloudKit deployment state.

2. **P2 — A repository-only fold breaks reordering across the desk.**

   The view model builds reorder requests from `current.materials`: [WorkboardViewModel.swift:825](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/ViewModels/WorkboardViewModel.swift:825). The store requires **every logical material ID exactly once**, rejecting incomplete sets as stale: [ConversationStore+Workboard.swift:3552](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/ConversationStore+Workboard.swift:3552).

   Hide one companion from that collection and otherwise-valid drags fail. Keep an explicit distinction between displayed cards and persisted materials. Expand a card order into a complete material order under the existing revision check. Define where the companion ranks when it becomes standalone again.

3. **P2 — The proposed parent ID is not always the picture’s final ID.**

   Screenshot publication returns the derived ID after a **best-effort drain**: [WorkVoiceScreenshotCoordinator.swift:98](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/Workboard/WorkVoiceScreenshotCoordinator.swift:98). But that drain can publish the image under a collision-escape ID: [WorkCaptureDrainer.swift:397](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift:397). Audio recovery can escape too.

   Consequently, “parent present on the same desk” can fold the audio into the **wrong-kind occupant**, while its actual screenshot stands elsewhere. Merely requiring an image parent avoids that incorrect fold but leaves the escaped pair permanently separate.

   Define collision-aware association resolution. Also require image parent, audio/explicitly paired-note child, no self-links or chains, and an explicit rule for multiple children. A singular `companion` must never silently discard another linked material. These rules become especially important once a link authorizes deletion.

4. **P2 — Delete, share, and availability need component-aware contracts.**

   Today’s “paired deletion” means **one material plus its blobs**, not two materials: [ConversationStore+Workboard.swift:2840](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/ConversationStore+Workboard.swift:2840). A group deletion needs one validated membership decision, one owner-revision check, all matching physical rows, and cleanup for both payloads. Calling the existing delete twice is insufficient: the first call advances the owner revision. A local save also does not guarantee simultaneous disappearance on other devices.

   Sharing currently prepares one item and revalidates one material’s revision: [WorkMaterialShareCoordinator.swift:195](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/WorkMaterialShareCoordinator.swift:195), [line 324](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/WorkMaterialShareCoordinator.swift:324). The proposed companion fields omit **revision and MIME type**. Carry a complete child snapshot; revalidate both members and their association before presenting; reclaim every prepared copy on failure.

   Evaluate permission separately: an arriving image must not prevent already-readable audio from playing, and a readable image must not make pending audio shareable. Specify whether “Share both” refuses partial availability or offers an explicit component choice.

   Likewise, the existing source card wraps its tile in a button and ignores accessibility children: [WorkboardCaptureCanvas.swift:1365](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1365). Adding transport inside that wrapper is insufficient. Give gallery activation and playback distinct controls, including named VoiceOver actions.

5. **P2 — Duplicate-row convergence and retry metadata need more than an added draft field.**

   The canonical selector deliberately compares synced presentation fields before its device-local row key: [ConversationStore+Workboard.swift:286](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/ConversationStore+Workboard.swift:286). Include the association in that ordering. Otherwise, duplicates differing only in the link can fold differently across devices.

   Persist the association independently of screenshot bytes. Those bytes are intentionally removed from the retry record once queued: [InAppAudioRecorder.swift:2240](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:2240). Preserve the new metadata through attempt updates, publication-state updates, intent reconstruction, and both audio republication IDs.

   Also, replaying an existing material does **not** reapply its draft: [ConversationStore+Workboard.swift:1020](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/ConversationStore+Workboard.swift:1020). Existing captures will not acquire links automatically. State whether this feature applies only to new captures or includes a separate association backfill.

6. **P2 — Text mode currently loses access to the complete note when folded.**

   A note opens its full body, with selectable text: [PersonalWorkbenchView.swift:448](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift:448), [line 1361](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift:1361). An image opens the gallery. Hiding the note while displaying only two/six lines removes its existing full-text route.

   **Keep text mode as two cards for this iteration.** Pair it later with “Read/copy note” and image-plus-text sharing explicitly designed. Its stored title is also the generic “Share note,” so a useful band label must derive from its body: [WorkCaptureDrainer.swift:309](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift:309).

   Changing the envelope additionally requires updating all three mirrored definitions, even though share-extension behavior remains unchanged.

7. **P2, pre-existing requirement gap — B does not currently preserve full-resolution screenshots.**

   The screenshot coordinator uses `ImageProcessor.process(...).jpegData`: [WorkVoiceScreenshotCoordinator.swift:119](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/Workboard/WorkVoiceScreenshotCoordinator.swift:119). That pipeline caps the long edge at **1,568 pixels**: [ImageProcessor.swift:79](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/ImageProcessor.swift:79).

   Rejecting thumbnail-only C remains sensible, but describe B as preserving the **stored image payload**. If readable, full-resolution code screenshots are an acceptance criterion, the capture pipeline needs separate attention.

8. **P3 — Transient standalone-to-folded movement is acceptable; playback interruption needs a decision.**

   A correct fold over one snapshot does not require a duplicate-card window: each child is either standalone or attached. Separate arrivals can change card count, position, and footprint. I would accept that truthful convergence.

   The brief’s universal publication order is incorrect: **`ConverseIntent` publishes audio before transcription, then publishes the screenshot later**: [ConverseIntent.swift:348](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Intents/ConverseIntent.swift:348), [line 589](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Intents/ConverseIntent.swift:589). Standalone audio is therefore an ordinary intermediate state.

   Folding away a playing audio card currently deactivates its player: [WorkboardAudioCardView.swift:700](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/WorkboardAudioCardView.swift:700). Accept that explicitly or retain playback by audio-material identity across the transition. Duration is only discovered when playback loads; do not promise it beforehand or eagerly load every recording to obtain it.

The remaining invariants look compatible with B, subject to those changes:

| Concern | Assessment |
|---|---|
| Gallery paging | Preserved if parents remain `.image`, child kinds are restricted, and gallery availability stays image-specific. |
| Thumbnail backfill | Preserved: it queries stored image rows directly, independently of the board fold. |
| Search / multiselect | I found neither desk search nor board multiselection in the current surface. Photo-import selection and gallery selection are separate. |
| Retry TTL | Preserve recording publication state and the parked-picture exemption. A persistent association must not itself count as unpublished-picture debt. |
| `unsavedWorkCaptureCount` | Already counts recorder holders, not desk cards; folding should not affect it. |
| Empty audio + picture | Existing code publishes the picture and skips audio publication. Keep the plain image card **and** the existing truthful missing-audio outcome. |
| Failure sentences / fallback note | Compatible if presence checks continue querying materials. The explicitly retained fallback-note behavior can still produce a standalone note after deletion. |

Several tests already expose the shortcuts the brief proposes:

| Test | What it establishes |
|---|---|
| [WorkboardModelMigrationTests.swift:241](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkboardModelMigrationTests.swift:241) | An extra column in model 16 contradicts its exact schema contract. |
| [WorkboardPersistenceTests.swift:270](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkboardPersistenceTests.swift:270) | Reordering with hidden IDs omitted must fail. |
| [WorkCaptureDrainerCollisionTests.swift:58](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkCaptureDrainerCollisionTests.swift:58) | The final material ID can be the escape ID. |
| [WorkMaterialShareTests.swift:559](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkMaterialShareTests.swift:559) | Replacement during export must invalidate the share; extend this to either component. |
| [WorkCaptureInboxTests.swift:857](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkCaptureInboxTests.swift:857) | Editing only the app’s envelope definition fails mirror parity. |

Conversely, the two-material assertions in `WorkboardVoiceScreenshotLaneTests` and the image-only artwork test **do not refute B**: B should preserve two stored materials and an image-kind parent. Add separate assertions for one displayed card.

B remains my choice because it preserves the established byte and transcript ownership. A expands too many storage contracts; C discards the usable image payload. **D’s stated partial-failure objection is weak:** either direction can render unpaired audio standalone, and both IDs are known in advance. B is preferable because the annotation itself records what it belongs to—not because reverse linking inherently handles missing rows worse.

All six source guards passed. I inspected the tests but did not run simulator suites or an actual store migration.
