# desk-drainer — plan §A drainer retarget (Codex #2). DONE, iOS build green, 9 drainer tests / 0 failures.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. **No `.xcstrings` file opened.** Nothing under `docs/qa/desk-cloudkit/` touched. No mirror triplet touched. I edited exactly TWO files:

- `Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift` (411 → 336 lines)
- `Conduck/ConduckTests/WorkCaptureDrainerTests.swift` (5 cases → 9)

`WorkCaptureRetryCoordinator.swift` was **not** needed and is untouched (it only calls `drainAvailableCaptures()`, whose signature is unchanged). No new file was added — extending the existing test class was cleaner than a second one.

---

## 1. Resolution flow (what the drainer now does)

`destination(for:)` and the whole `Destination` struct are **deleted**. `persist(_:)` resolves nothing: every material goes to `ConversationStore.upsertDeskMaterial(...)`, which owns desk identity, rank and idempotency.

```
drainAvailableCaptures()
  reconcile → claimNext → persist(claim) → confirmDurablyImported(ids) → acknowledge(claim)
                              │                                              ↑
                              └─ any throw ──→ release(claim) ──→ rethrow ───┘ (never reached)
```

`persist(_:)`, in order:
1. `expectedIDs = materialIDs(for: envelope)`; `wasReplay = !deskMaterialIDs().isDisjoint(with: expectedIDs)` — ONE desk fetch, no per-material probe.
2. **The note, always, whenever it is non-empty** — `upsertDeskMaterial(WorkMaterialDraft(id: noteMaterialID(for:), kind: .note, …))`. The `destination.appendsToExistingItem` gate that used to guard this is gone with the struct, so the first targetless capture is no longer silently dropped (Codex #2).
3. Each entry in `entryOrder` order → `upsertDeskMaterial(draft)`, or `upsertDeskMaterial(draft, sourceFileURL:sourceFileByteSize:)` when the claim carries a payload leaf.
4. Returns `PersistedCapture(wasReplay:materialIDs:)` — `materialCount` is now derived (`materialIDs.count`).

**`targetWorkItemID` is read exactly nowhere.** The envelope still carries it (mirror triplet untouched, share extension unchanged), and a capture naming a live item leaves that item byte-for-byte alone. Menu-bar / GigaAction envelopes are targetless already and take the identical path.

**No CAS.** `expectedOwnerRevision` is left at its `nil` default on every call, per plan §A and desk-upsert §2.

**Rank.** `materialDraft(for:…)` lost its `sequence:` parameter and leaves `WorkMaterialDraft.sequence` at its default: the desk write assigns `appendRank` inside its own transaction. Measured: note + 2 entries land as sequences `[0, 1, 2]`.

**Replay = deterministic ids + upsert idempotency.** `fetchWorkItem(captureEnvelopeID:)` is no longer called by the drainer, and no `WorkItemDraft` is minted, so an envelope id never becomes an item's `captureEnvelopeID` (scout-capture §c). The store call is idempotent on `draft.id`, so a second drain of the same envelope rewrites nothing and adds nothing.

## 2. The durable-ack hook (for ByteSync)

```swift
private func confirmDurablyImported(_ materialIDs: [UUID]) async throws
```

Sits between `persist` and `inbox.acknowledge`, inside the same `do` block, so a failure releases the claim instead of consuming it. Today it re-reads the desk once and requires every published id to be present; a missing one throws `WorkboardStoreError.materialNotFound`.

**ByteSync: this function is your extension point**, and it carries a `BYTE-SYNC EXTENSION POINT:` comment saying so. Plan §C's write order is (1) blob durable → (2) material row `.syncedPayload` → (3) acknowledge; step (3) waits here. Widen the predicate so a material whose row names a blob is not "durable" until the blob row is readable (`WorkMaterialBlobRecord.isComplete`, per foundation.md). Everything else about acknowledgement stays where it is — one barrier, not one per capture surface.

Note the shape you will need: `ConversationStore.fetchWorkMaterial(id:)` is **`private`** (`ConversationStore+Workboard.swift:1068`), so the drainer cannot probe a single material. I used the desk projection (`fetchWorkItem(id: Constants.workboardDeskItemID)` → `.materials`) instead, which is also the batch shape plan §C asks for. If you want blob completeness in the same read, the cheapest place is a batch projection on the store side rather than a loop here — see Requests #1.

Inbox-lease contract honoured: `acknowledge` is still the last statement, signatures unchanged, `refreshLease` untouched (a drain that approaches the 5-minute horizon is a byte-sync-era concern, not one today).

## 3. What died

| Symbol / behaviour | Note |
|---|---|
| `private struct Destination` | whole struct |
| `destination(for:)` | replay lookup, `.done`-target branch, target acceptance, fallback mint |
| `content(for:fellBackFromUnavailableTarget:)` | the fallback item's brief |
| `inferredTitle(note:entries:)`, `firstUsefulLine(in:)` | title inference for that item |
| `PersistedCapture.materialCount` stored property | now computed from `materialIDs` |
| `materialDraft(…, sequence:)` parameter | rank belongs to the desk write |

`WorkItemDraft` / `WorkItemContent` / `WorkItemState` are no longer referenced by this file at all.

## 4. Tests + counts

`WorkCaptureDrainerTests` **5 → 9 cases** (net **+4** on the iOS executed count). No assertion was weakened or deleted to reach green; the two cases that asserted deleted behaviour were rewritten to assert the behaviour that replaces it.

| Case | Holds | Fate |
|---|---|---|
| `testTheFirstTargetlessCaptureBecomesAMaterialOnAFreshDesk` | empty store + targetless `.app` envelope → desk exists at the fixed id, the note IS the one material (`importedMaterialCount == 1`), title "Share note" | NEW (the Codex #2 regression) |
| `testCapturesFromDifferentSurfacesShareTheOneDesk` | share-sheet + menu-bar envelopes → exactly one item, both notes on it | NEW |
| `testTheNoteAndEveryAttachmentLandOnTheDeskTogether` | note + text + image-with-payload → 3 materials, sequences `[0,1,2]`, image `.availableLocally`, `loadWorkMaterialPayload` returns the exact bytes | NEW |
| `testANamedTargetIsIgnoredAndLeftUntouched` | a live named item keeps 0 materials and its exact title/objective/context; both cards land on the desk | rewrite of `testOpenTargetReceivesVisibleNoteAndMaterials…` (its brief-preservation assertions kept, aimed at the ignored item) |
| `testAnUnknownTargetStillLandsOnTheDesk` | unknown `targetWorkItemID` → note on the desk, `fetchWorkItem(captureEnvelopeID:)` nil, exactly one item in the store | rewrite of `testMissingTargetFallsBackToClearlyExplainedNewDraft` |
| `testReplayingTheSameEnvelopeYieldsOneMaterialSet` | drain, republish, drain → `replayedCaptureCount == 1`, `importedCaptureCount == 0`, still 2 materials | adapted (target dropped) |
| `testNoteIdentityNeverMasksAnEntryThatUsesTheEnvelopeID` | envelope id reused as an entry id → 2 distinct cards | adapted (target dropped) |
| `testTheQueueIsConsumedOnlyOnceTheMaterialsReadBackFromTheStore` | after a durable import: both ids on the desk, `pendingCount == 0`, the queue directory is gone, the file bytes read back from the desk | NEW (acknowledge-after-write, success half) |
| `testAPersistenceFailureReleasesTheClaimAndPreservesItsPayload` | second write throws `.invalidMaterialOwner` → `pendingCount == 1`, queue payload byte-identical, **and the card written before the failure is on the desk** | kept + strengthened (the new line proves acknowledgement did NOT run despite a partial write — the ordering half) |

I could not construct a case where the material write *succeeds* and the read-back *fails*, so `confirmDurablyImported`'s throwing arm is unverified by a test; the release-on-throw path around it is covered by the persistence-failure case. Stated plainly rather than faked with a seam I do not own.

## 5. Gates run (exact lines)

Slug `desk-drainer`, derivedData `~/Library/Caches/gigaduck-builds/desk-drainer/DerivedData`, logs written there and grepped. No `-configuration` passed anywhere. Sim `5C851D88-959C-445E-ACC8-A4C6ADB2876C`.

- `build-for-testing` → `bft-1.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
- `test-without-building`, 5 quoted `-only-testing:` flags → `test-1.log`, `** TEST EXECUTE SUCCEEDED **`:

| Class | Result |
|---|---|
| `WorkCaptureDrainerTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.427 (0.430) seconds` |
| `WorkCaptureInboxLeaseTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.040 (0.042) seconds` |
| `WorkCaptureInboxTests` | `Executed 30 tests, with 0 failures (0 unexpected) in 0.145 (0.151) seconds` |
| `WorkCaptureRefreshCoordinatorTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 1.006 (1.008) seconds` |
| `WorkboardDeskUpsertTests` | `Executed 10 tests, with 0 failures (0 unexpected) in 0.087 (0.089) seconds` |
| **total** | `Executed 64 tests, with 0 failures (0 unexpected) in 1.705 (1.721) seconds` |

- Insurance run (not in my brief) → `test-2.log`, `** TEST EXECUTE SUCCEEDED **`: `ConversationStoreAtomicWorkCaptureTests` 3/0 · `ConversationStoreWorkCaptureTests` 5/0 · `WorkAssetVaultTests` 9/0 · `WorkboardPersistenceTests` 7/0 — `Executed 24 tests, with 0 failures (0 unexpected) in 0.723 (0.729) seconds`.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 763 Swift files scanned…`.
- `git diff --check` → clean.
- **NOT run:** macOS build, full iOS suite, watch suite. My two files are `#if !os(watchOS)` / test-bundle only and contain no platform-conditional code, but I did not prove the macOS build myself.
- Build cache removed: `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-drainer` → `removed: desk-drainer`. The logs no longer exist; re-run if you need them.

Another agent's edits were present in the tree during my builds (deleted brief/dispatch files, view trims, `CaptureWorkboardIntent.swift`, `ShareTargetsSnapshotWriter.swift`) and every run above was green with them in.

---

## Call-site touches

**NONE.** `WorkCaptureDrainer.Report` kept all four fields and `drainAvailableCaptures()` kept its signature, so `WorkboardLiveRepository.drainCaptures()`, `WorkCaptureRetryCoordinator.publish` and `PersonalWorkbenchView`'s `invalidCaptureCount` banner needed no edit. I did not open those files.

---

## Catalog

**Keys I ADDED in source: NONE.**

**Keys I found DEAD** (zero references left in any `.swift` in the worktree — verified by repo-wide grep after my edit; both were referenced only by the deleted fallback path):

| Key | defaultValue |
|---|---|
| `workboard.capture.targetUnavailable` | `The selected Work item was no longer open, so this capture was saved as a new draft.` |
| `workboard.capture.untitled` | `Captured material` |

Still LIVE in this file, do not prune: `workboard.capture.note` (`Share note`) · `workboard.capture.sharedText` (`Shared text`) · `workboard.capture.image` (`Image`) · `workboard.capture.webPage` (`Web page`) · `workboard.capture.file` (`File`).

---

## Requests

1. **ByteSync agent — a batch material/blob probe.** `confirmDurablyImported` currently proves durability through the desk projection because `ConversationStore.fetchWorkMaterial(id:)` is `private`. When you widen "durable" to include the blob, either make a batch completeness projection non-private on the store (materialID + byteSize + contentHash, never `payload` — plan §C, Codex #7) and call it from `confirmDurablyImported`, or hang the blob check off the same desk fetch. Do **not** add a per-material `await` loop here; that is the exact shape plan §C tells you to remove elsewhere.
2. **String-audit / catalog agent:** delete the two DEAD keys above from `Conduck/Conduck/Localizable.xcstrings` in the serial catalog step. I opened no `.xcstrings` file.
3. **Serial integration:** `WorkCaptureDrainer` no longer calls `store.addWorkMaterial` / `addWorkMaterialFile` / `createWorkItem` / `fetchWorkItem(captureEnvelopeID:)`. If chat capture also stops using `addWorkMaterial(_:to:)` (desk-upsert Request #2), those two write paths lose their last production callers and should be deleted rather than left as a second write path — nothing in the drainer depends on them.
4. **Nobody needs to change the share extension.** `targetWorkItemID` stays in the envelope and stays unread; the appex needs no compile-time desk id and no fourth mirror (scout-capture §g).
5. **Orchestrator:** expect **+4** on the iOS executed count from this slice (`WorkCaptureDrainerTests` 5 → 9). Full iOS and watch suites unrun by me.
