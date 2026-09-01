# desk-upsert — plan §A's ONE authoritative store op (Codex #1). DONE, iOS + macOS green, 39 targeted tests / 0 failures.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. **No `.xcstrings` file opened** (I added zero user-facing strings). Nothing under `docs/qa/desk-cloudkit/` touched. I edited exactly TWO files: `Conduck/Conduck/Services/ConversationStore+Workboard.swift` and the new `Conduck/ConduckTests/WorkboardDeskUpsertTests.swift`. `Models/WorkboardRecords.swift` and `Utilities/Constants.swift` needed nothing — **untouched**, every Foundation addition intact. **Zero call-site touches** in `WorkboardLiveRepository.swift` (see §Call-site touches).

---

## 1. The EXACT signature

```swift
func upsertDeskMaterial(
    _ draft: WorkMaterialDraft,
    sourceFileURL: URL? = nil,
    sourceFileByteSize: Int64? = nil,
    repairPayload: Data? = nil,
    expectedOwnerRevision: Int64? = nil,
    onProgress: @escaping @Sendable (Double) -> Void = { _ in }
) async throws -> WorkMaterialRecord
```

`ConversationStore+Workboard.swift`, under the new `// MARK: - Desk` (first thing in the file after `captureMessageToWork`, ahead of `// MARK: - Materials`). Returns the MATERIAL record, not the desk: the desk id is a compile-time constant, so no caller needs it back, and projecting the whole board on every capture would pay for a fetch nobody asked for. Callers that need the board re-fetch `fetchWorkItem(id: Constants.workboardDeskItemID)`.

Every parameter defaults, so the common lane is `try await store.upsertDeskMaterial(draft)`.

## 2. Semantics (what the op guarantees)

| Situation | Result |
|---|---|
| No desk row | Creates it at `Constants.workboardDeskItemID`, **not** through `apply(_ content:)` — title/objective/context/desiredOutcome/constraints stay **nil columns**, only `id`/`createdAt`/`updatedAt` are written |
| Desk row exists (incl. several physical rows) | Adopts it. Never deletes, never dedups, never adds a uniqueness constraint |
| Material `draft.id` absent | Inserts it, owner `updatedAt` advances, `postDidChange()` fires |
| Material `draft.id` present, bytes readable | Returns the existing record **unchanged** — no save, no notification, `updatedAt` identical |
| Material `draft.id` present, owned by a DIFFERENT item | `WorkboardStoreError.invalidMaterialOwner`, nothing written (not even the desk row) |
| Material present + `.localVault` + `.unavailableOnThisDevice` + caller carries bytes | **Repairs**: restages bytes, rewrites `localVaultKey`/`byteSize`/`updatedAt` on EVERY physical row of that material |
| Material present + `.metadataOnly` + caller carries bytes | **Refused** — nothing staged, nothing written. Giving a card bytes it never claimed is reattach (`replaceWorkMaterialPayloadFile`), not repair |
| `expectedOwnerRevision` non-nil, desk absent | `.staleRevision` — a token for a row that does not exist cannot be honestly compared, and the desk is NOT created |
| `expectedOwnerRevision` non-nil, desk revision differs | `.staleRevision`, nothing written |
| Byte staging fails (unreadable source) | Throws before the transaction opens → no desk row, no material, staged bytes reclaimed |

**Sequence is decided by the op, not the caller.** New materials get `max(sequence over the owner's rows) + 1` computed INSIDE the write transaction. A headless lane (drainer, App Intent, watch) cannot know how many cards the desk holds, and reading the count outside the transaction races the write it is meant to order. `draft.sequence` is ignored for this path; `addWorkMaterial`/`addWorkMaterialFile` still honour it (chat capture passes explicit ranks).

**Concurrency.** The op holds the existing `workInitialMaterialClaims` claim on the OWNER id for the whole call, staging included. Reason: vault leaves are `makeKey(id: materialID, …)`, so two replays of one capture would otherwise `storeFileStreaming` into the same file at once and interleave bytes. Desk captures therefore serialize **within a process**; across processes both callers create a physical desk row and `deduplicatedWorkItems` + the `workItemID IN` material fetch union them, exactly as plan §A requires. Measured: two `async let` first captures land as sequences `0` and `1` on ONE desk row.

**`expectedOwnerRevision` is nil for everything except the VM.** Documented at the parameter: the view model's serialized board path is the only caller that knows which revision the person was looking at; drainer / App Intent / chat capture pass nil because a CAS refusal there would drop a capture the person already made.

## 3. The repair-hook seam (for ByteSync)

`repairPayload: Data?` is the named hook. It falls back to `draft.payload`, so an ordinary replay needs no second copy of the bytes; `sourceFileURL` repairs too (it streams to the same deterministic leaf).

Today the repair predicate is, verbatim in `publishWorkMaterial`:

```swift
let repairsPayload = existing.map {
    $0.storageMode == .localVault
        && $0.availability == .unavailableOnThisDevice
        && carriesBytes
} ?? false
```

**ByteSync: this is your seam.** Add the `.syncedPayload` / `.syncedPending` arm here and the matching blob write inside the transaction's `if !materialRows.isEmpty { … }` branch (it already loops EVERY physical row and already saves + notifies through `WorkMaterialWriteOutcome.repairedMaterial`). Two more repair states are already handled and need no work from you:

- **material-without-owner**: the desk is re-ensured on EVERY call, so a material stranded without its desk row (CloudKit imported them out of order) becomes visible again on the next capture — `createdOwner` forces the save even when the material already existed.
- **duplicate physical material rows**: repair writes all of them, so a later CloudKit merge cannot pick a row that still points at nothing.

Staging is deliberately still `.localVault`-only (`stageWorkMaterialBytes` never returns `.syncedPayload` unless the draft declares it with no payload, which is today's behaviour). `WorkMaterialStoragePolicy` is **not** wired — foundation.md assigns that to you, and `WorkboardPersistenceTests.testCaptureIdempotencyAndLocalMaterialPrivacy`'s `.localVault` assertion is the one you must flip (test-compile.md Request #4).

## 4. What happened to `createWorkItemWithInitialMaterial`

**Refactored onto the op, not patched, and NOT deleted.** Its signature and its error contract are byte-for-byte what they were; its ~95-line body is gone. It is now a five-line delegation to the same shared engine with `owner: .createNew(itemDraft)`.

Why not deleted: it still has three callers I do not own — `WorkboardLiveRepository.swift:470` (the capture agent's retarget) and three call sites in `ConduckTests/ConversationStoreAtomicWorkCaptureTests.swift`, one of which (`testTransactionRejectionRemovesStagedInitialBytes`) asserts exactly the throw-on-existing branch. Deleting it in a parallel wave would have broken a file I do not own. The *duplication* the plan objected to is gone: there is now ONE write path.

The shared engine is `private func publishWorkMaterial(_:owner:sourceFileURL:sourceFileByteSize:repairPayload:expectedOwnerRevision:onProgress:)`, and the throw-on-existing branch survives only as one case of

```swift
private nonisolated enum WorkMaterialOwnerPolicy: Sendable {
    case desk                      // adopt or create the fixed-id row; never refuses
    case createNew(WorkItemDraft)  // refuses an existing id / envelope / material
}
```

**Retarget agent: once `WorkboardLiveRepository.importMaterial`'s `owner == nil` arm calls `upsertDeskMaterial` instead, `createWorkItemWithInitialMaterial` + `.createNew` + the three atomic-capture test cases can all go in one serial step.** Nothing else depends on them.

### Behaviour deltas inside `createWorkItemWithInitialMaterial` (both deliberate, both verified green)
1. Its vault leaf is now keyed on the **material id** instead of a random `UUID()`. Deterministic keys are what make a replay restage onto the same file instead of leaving an orphan for `reconcileWorkAssetVault` to sweep. `ConversationStoreAtomicWorkCaptureTests` (3/3) and `WorkAssetVaultTests` (9/9) stay green.
2. It now does one `fetchWorkMaterial(id:)` read before staging (the shared idempotency probe). For a fresh capture that is a single-row read; the collision it can see was already an `.identifierCollision` throw.

## 5. Other things I added in `ConversationStore+Workboard.swift`

- `private static func insertDeskRow(in:)` — the desk row, nil brief columns, with the header comment saying why it bypasses `apply(_ content:)`.
- `private static func appendRank(forWorkItemID:in:)` — the in-transaction rank.
- `private static func workMaterialRows(id:in:)` — EVERY physical row of one logical material, same newest-first ordering `workMaterialRow(id:)` and `deduplicatedWorkMaterials` use.
- `private func stageWorkMaterialBytes(id:filename:payload:declaredByteSize:declaredStorageMode:sourceFileURL:sourceFileByteSize:onProgress:)` — the one byte-staging path (payload → vault, URL → `storeFileStreaming`), returning `StagedWorkMaterialBytes`.
- `private nonisolated struct WorkMaterialWriteOutcome` — what the transaction actually did, so `markReferenced` / `remove` / `postDidChange` follow the database rather than the caller's intent.
- **`private static func apply(_ draft:…)` gained `sequence: Int? = nil`** (defaulted, inserted before `updatedAt:`). `insertWorkMaterial`'s existing call is unchanged and still uses `draft.sequence`.

Header comment carrying the desk-identity contract, the no-dedup reason and the crash-repair states sits on `upsertDeskMaterial` itself, per the task.

## 6. Tests + counts

New file `Conduck/ConduckTests/WorkboardDeskUpsertTests.swift`, **10 cases**:

| Case | Holds |
|---|---|
| `testFirstCaptureCreatesTheDeskLazilyAtTheFixedIdentity` | no desk before the first capture; after it exactly one item at the fixed id, empty title/objective, nil `captureEnvelopeID` |
| `testTwoConcurrentFirstCapturesBothLandOnOneDesk` | two `async let` first captures → ONE desk, projection unions both, ranks `{0, 1}` |
| `testDeletingAMaterialLeavesTheDeskStanding` | `deleteWorkMaterial` leaves the desk with the SAME `createdAt`; the next capture reuses it; still one board |
| `testDeskCoexistsWithALegacyProjectRow` | a model-15 project row keeps its title and stays material-free; the capture lands on the desk |
| `testReplayingOneCaptureReturnsTheSameCardWithoutASecondRow` | same id back, `updatedAt` unchanged, ONE physical row (`_workMaterialRowsForTesting`), payload readable |
| `testAFailedFirstCaptureLeavesNoDeskRow` | unreadable source → throws, **no half-created desk**, `reconcileWorkAssetVault() == 0` (test-compile.md Request #3) |
| `testOwnerRevisionIsRefusedWhenStaleAndWhenTheDeskDoesNotExistYet` | CAS against an absent desk refused and creates nothing; matching token accepted; superseded token refused; board unchanged |
| `testReplayRepairsACardWhoseVaultBytesAreGone` | vault leaf deleted → `.unavailableOnThisDevice`; replay restores `.availableLocally` + the exact bytes, still ONE row |
| `testRepairBytesOfferedToACardThatClaimsNoneAreRefused` | `.metadataOnly` stays `.metadataOnly`, no payload, nothing staged |
| `testAMaterialIdOwnedByAnotherItemIsRefusedRatherThanMoved` | `.invalidMaterialOwner`; the other item keeps its card; no desk row is created by the refusal |

Not written, stated plainly: I could not construct a **material-without-desk-row** fixture — no delete-desk API exists any more (`deleteWorkItem` died in the purge) and the store has no seam to drop an item row. The behaviour (desk re-ensured on every call, `createdOwner` forces the save) is implemented and reviewed but **unverified by a test**. A CloudKit-import fixture or a new `#if CONDUCK_TESTING` seam would be needed.

## 7. Gates run (exact lines)

Slug `desk-upsert`, derivedData `~/Library/Caches/gigaduck-builds/desk-upsert/`, logs written there and grepped. No `-configuration` passed anywhere.

- iOS `build-for-testing`, sim `6C3FB33E-D89F-4D1E-9F0D-3FAC0C089228` → `bft-2.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
- iOS `test-without-building`, six quoted `-only-testing:` flags → `test-1.log`, `** TEST EXECUTE SUCCEEDED **`:

| Class | Result |
|---|---|
| `ConversationStoreAtomicWorkCaptureTests` | `Executed 3 tests, with 0 failures (0 unexpected) in 0.021 (0.022) seconds` |
| `ConversationStoreWorkCaptureTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.450 (0.452) seconds` |
| `WorkAssetVaultTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.096 (0.098) seconds` |
| `WorkCaptureDrainerTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.054 (0.056) seconds` |
| `WorkboardDeskUpsertTests` | `Executed 10 tests, with 0 failures (0 unexpected) in 0.081 (0.083) seconds` |
| `WorkboardPersistenceTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.043 (0.044) seconds` |
| **total** | `Executed 39 tests, with 0 failures (0 unexpected) in 0.745 (0.755) seconds` |

- macOS `xcodebuild build -destination 'platform=macOS'` → `mac-1.log`: `grep -c ': error: '` = **0**, `** BUILD SUCCEEDED **`. Signed through the identity override; **no `CODE_SIGNING_ALLOWED=NO` fallback was needed**. (Not required by my brief — run as insurance because the store extension compiles for macOS too.)
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 762 Swift files scanned…`.
- `git diff --check` → clean.
- **Not run:** the full iOS suite and the watch suite (orchestrator's gate). The watch target does not compile this file, and I touched nothing it does compile.
- Build cache removed: `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-upsert` → `removed: desk-upsert`. The logs no longer exist; re-run if you need them.

Note for the record: another agent's `WorkCaptureInbox.swift` edits and `WorkCaptureInboxLeaseTests.swift` were present in the tree during my builds, and both builds were green with them in.

---

## Call-site touches

**NONE.** `createWorkItemWithInitialMaterial` kept its exact signature and error contract, so `WorkboardLiveRepository.swift` needed no edit. I did not open it.

---

## Catalog

**Keys I ADDED in source: NONE.** The op is headless; it produces no user-facing copy. No `.xcstrings` file was opened.

**Keys I found DEAD: NONE.** I deleted no code that referenced a key.

---

## Requests

1. **Capture / retarget agent (plan §A):** route `WorkboardLiveRepository.importMaterial`'s `owner == nil` arm at `:470` to `upsertDeskMaterial(draft, sourceFileURL:…, sourceFileByteSize:…, expectedOwnerRevision:…, onProgress:)` and stop computing `sequence` there (the op decides it inside the transaction — your value is ignored on that path). Note the repository maps "no owner yet" to `expectedRevision == 0`; pass **nil**, not 0, to the op — `expectedOwnerRevision: 0` would be refused against an absent desk, which is the correct contract but not what that arm means. When that lands, delete `createWorkItemWithInitialMaterial`, the `.createNew` case of `WorkMaterialOwnerPolicy`, and the three `ConversationStoreAtomicWorkCaptureTests` cases in one step.
2. **Capture / chat agent:** `captureMessageToWork` still calls `createWorkItem` + `addWorkMaterial(_:to:)` against a minted item id. Retarget it to `upsertDeskMaterial`; when it is the last caller to go, `addWorkMaterial` / `addWorkMaterialFile` / `insertWorkMaterial` become dead and should be deleted rather than left as a second write path. `addWorkMaterial`'s post-transaction `try? await workAssetVault.remove(newVaultKey)` on the not-inserted branch is unsafe with deterministic keys (it can delete the winner's file); the desk op guards that case explicitly, `addWorkMaterial` does not — another reason to retire it rather than fix it.
3. **ByteSync agent:** §3 above is your seam, and the `.syncedPending` availability projection foundation.md pinned is still at `StoredWorkMaterial.record(availableLocalKeys:)` — untouched by me. Note `stageWorkMaterialBytes` is the single place a storage decision is made now; wire `WorkMaterialStoragePolicy.mode(kind:byteSize:)` there and nowhere else.
4. **Orchestrator / test-surgery agent:** `WorkboardDeskUpsertTests` is a NEW file in `ConduckTests` (synchronized group, no pbxproj edit needed — it compiled and ran). Expect **+10** on the iOS executed count.
5. **Anyone touching `ConversationStore.swift`:** `workInitialMaterialClaims`' doc comment still says "Work item ids whose first material is currently being staged" — still literally true (the desk id is a work item id), but the claim now covers **every** desk capture, not only the first. A one-line doc widening there would be honest; I did not edit that file.
