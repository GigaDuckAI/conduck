**No remaining P1 identified. B remains viable, but R2/R3 still contain two P2 defects.** R7–R9 also need several concrete amendments.

**Q1 — The two possible image IDs are complete; the fallback condition needs fixing.**

The voice screenshot lane publishes at `L`; the drainer tries `escape(L)` once and treats another refusal as terminal. Replay starts from the original envelope, so it does not accumulate escapes. See [WorkCaptureDrainer.swift:364](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift:364), especially the catch at line 407.

**P2: “at L, else escape(L)” must mean first eligible candidate, not first existing row.** A wrong-kind row at `L` is precisely why the screenshot escaped. If that existing row prevents examining `escape(L)`, collision recovery never folds.

Resolve `[L, escape(L)]` in that order, selecting the first candidate satisfying **all** parent conditions.

Escaped audio needs no different parent derivation. Both audio publication attempts must receive the same explicit link derived from the **original capture ID**. The current escape call passes the escaped ID as `publishRecording(captureID:)`, so deriving the screenshot ID inside that function from its `captureID` parameter would be wrong: [WorkVoiceCaptureCoordinator.swift:427](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift:427). Pass the link separately.

**Q2 — Adjacent parent/child IDs are accepted, but sequence-based companion selection conflicts with R3.**

The actual entry point is `reorderWorkMaterials`, followed by `rewriteWorkMaterialSequence`; there is no `reorderDeskMaterials`. It accepts any permutation containing every logical ID exactly once, then writes dense ranks to every physical duplicate: [ConversationStore+Workboard.swift:3557](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/ConversationStore+Workboard.swift:3557). `[parent, child]` adjacency is valid.

**P2: choosing the lowest-sequence child makes an unrelated reorder change the screenshot’s recording.**

Concrete counterexample:

```text
Persisted: A, B, P, X       A and B both link to P; A folds.
Displayed: B, P[A], X
Move X first.
Expanded:  X, B, P, A       B now has the lower sequence.
Reload:    X, P[B], A       The screenshot changed companions.
```

Use an ordering independent of arrangement—**lowest child UUID**, for example. “Lowest sequence” also lacks a tie-break for equal ranks.

Other consumers:

- Drag slots, relative moves and keyboard/VoiceOver moves all converge on `performMaterialReorder`: [WorkboardViewModel.swift:711](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/ViewModels/WorkboardViewModel.swift:711), line 744 and line 825.
- Mosaic geometry and drag payloads use displayed array order: [WorkboardCaptureCanvas.swift:1107](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1107). Keep these displayed-only.
- Accessibility position announcements use displayed indices/counts: [WorkboardCaptureCanvas.swift:1276](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1276). That remains correct.
- **The optimistic update needs adjustment:** `applyMaterialOrder` currently assigns displayed indices directly to `.sequence`: [WorkboardViewModel.swift:863](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/ViewModels/WorkboardViewModel.swift:863). Keep displayed order separate from expanded persisted ranks, including the companion’s rank. Expand only the store request; do not insert hidden children into the rendered collection.

**Q3 — One group mutation is feasible. No orphan sweep is needed.**

The current delete chain is:

| Layer | Entry point |
|---|---|
| Canvas | `remove(_:)`, [WorkboardCaptureCanvas.swift:1293](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1293) |
| View model | `removeMaterialFromBoard`, [WorkboardViewModel.swift:795](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/ViewModels/WorkboardViewModel.swift:795) |
| Repository | `removeMaterial(_:expectedRevision:)`, [WorkboardLiveRepository.swift:554](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift:554) |
| Store | `deleteWorkMaterial(id:workItemID:expectedOwnerRevision:)`, [ConversationStore+Workboard.swift:2840](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/ConversationStore+Workboard.swift:2840) |

Specify the new signature with **`expectedOwnerRevision` explicitly included**. Inside one `context.perform`:

1. Resolve and validate the exact displayed parent/child pair, including which child wins folding; validate owners and kinds across physical rows.
2. Compare the desk’s `updatedAt` revision, as the existing delete does at line 2864. The revision uses the date’s floating-point bit pattern, not a rounded timestamp.
3. Delete both materials’ physical rows and call `deleteBlobRows(materialID:in:)` for each.
4. Advance the desk timestamp once and save once.
5. After successful save, remove the collected vault keys and post one change notification.

Collect **all distinct vault keys**, rather than copying the existing single-material operation’s `.first` at line 2859. Filesystem cleanup happens after the save; it is not part of an atomic database transaction.

Pass the displayed `childID` through the UI/dependency chain. Do not silently select a different child when confirmation executes.

**P3, accepted convergence:** A cannot delete a child or physical duplicate it has not imported. A child published on B concurrently with A’s parent deletion can subsequently arrive and render standalone. The owner revision is a local conflict check, not a distributed deletion marker. CloudKit imports changes asynchronously. [Apple’s synchronization documentation](https://developer.apple.com/documentation/coredata/syncing-a-core-data-store-with-cloudkit).

**No sweep.** That surviving audio still owns its payload. The existing prohibition on sweeping early/orphaned blobs remains applicable: [ConversationStore+Workboard.swift:1868](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/ConversationStore+Workboard.swift:1868).

**Q4 — Add the field to metadata; preserve the complete value through these sites.**

The exact type is `PendingRetryMetadata: Codable, Sendable, Equatable`. Existing fields are `id`, `createdAt`, `audioFileURL`, `preferredLanguage`, `attemptCount`, `lastErrorCode`, `destination`, `transcript`, and `publicationState`.

These locations are all in [PendingRetryStore.swift](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/PendingRetryStore.swift):

| Site | Lines | Required treatment |
|---|---:|---|
| Metadata declaration / initializer | 149 / 197 | Add optional UUID, default nil. Codable synthesis carries it; old records decode without it. |
| `PendingRetrySidecar` | 357 | Embeds the complete metadata; no parallel field needed. |
| `save` | 721, 748, 795 | Preserve sidecar → bytes → index write order. |
| Queue and legacy-slot decode | 566, 1290 | Both decode `PendingRetryMetadata`. |
| Sidecar decode / encode | 1813 / 1824 | Both carry the added nested field automatically. |
| Queue encode | 1542 | Encodes `[PendingRetryMetadata]`. |
| Sidecar reconciliation / interrupted-arm adoption | 1353 / 1366 | Preserve sidecar authority. Synthesized equality must include the link. |
| Attempt reconstruction | 270 | Explicitly copy the field in `recordingAttempt`. |
| Publication-state reconstruction | 287 | Explicitly copy it in `recording(transcript:publicationState:)`. |
| Update entry points / durable restatement | 1086, 1106 / 1520 | Existing transforms write sidecar first, index second. |
| Claim handoff | 1606 | Already carries complete metadata. |
| Legacy filename-only reconstruction | 1749 | Leave link nil; do not infer an association. |

Outside that file, the important producers and handoffs are:

- [InAppAudioRecorder.swift:2224](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:2224): set the link when preserving the capture, independently of the screenshot bytes omitted at line 2249.
- [ConverseIntent.swift:310](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Intents/ConverseIntent.swift:310): set it **before arming**; copy it in `stamped` at line 788. `heldCapture` at line 832 already carries metadata intact while deliberately setting image bytes nil.
- [PendingRetryGuard.swift:130](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/PendingRetryGuard.swift:130): forwards complete metadata to `save`.
- [ContentView.swift:1998](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/ContentView.swift:1998) and [DictationService.swift:669](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/DictationService.swift:669): forward the claim to recovery. Read the link from its metadata there; do not reconstruct it from remaining image bytes.
- Watch relay, CarPlay, Chat-only constructors, and old metadata retain nil. Notably, `DictationService.preserveForRetry` at line 1154 is **Chat-only**; the Mac Work capture producer is `InAppAudioRecorder`.

The TTL reads only destination, publication state and `createdAt`: `publishedWorkRetryTTL` at line 234, exemption at 244, TTL selection at 250, expiry at 260. The final sweep additionally excludes live reservations and captures with a parked image file at lines 1478–1480. **The new field need not disturb any of these.** Test link retention after `discardWorkImage`, and expiration after 24 hours with link present but image bytes absent.

Three further **P2** amendments remain:

- **R7, Open Recording:** `currentDeskCard` searches only top-level materials and otherwise uses the old tapped snapshot: [PersonalWorkbenchView.swift:546](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift:546). Hidden children would always take that fallback. Make current-member lookup include companions. Sharing already resolves directly from the store by member ID and fits R7.
- **R7, recording repair:** retain component-specific Reattach when audio is unavailable. The current `reattachMaterial` rejects IDs absent from top-level `current.materials`: [WorkboardViewModel.swift:651](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/ViewModels/WorkboardViewModel.swift:651). Folding must not remove the existing repair route.
- **R8/R9, missing preview and escaped presence:** standard/large images **without thumbnails also use the inline variant**, so that variant must carry the companion band: [WorkboardCaptureCanvas.swift:1325](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1325). Separately, screenshot presence currently checks only `L`, and checks ID without kind: [InAppAudioRecorder.swift:1288](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:1288), line 1971. Keep the sentences, but use the corrected eligible-image resolution for presence too.

No files changed. This round verified source paths and contracts; no runtime tests were run.
