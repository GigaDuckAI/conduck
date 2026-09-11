# blob-io — plan §C write path + crash-repairable publication (Codex #5) + paired GC (Codex #6). DONE.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. **No `.xcstrings` file opened** (zero user-facing strings). **Zero call-site touches** — `WorkboardLiveRepository.swift` was never opened for editing; no signature I own changed.

I edited exactly THREE files, all mine:
- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (+792 / −83)
- `Conduck/ConduckTests/WorkboardBlobPublicationTests.swift` (new, 12 cases)
- `Conduck/ConduckTests/WorkboardBlobGCTests.swift` (new, 6 cases)

**Headline for the orchestrator: iOS 4747 executed / 1 skip / 4 failures — every failure is a pre-policy assertion in a file I do not own, and all four are the plan's own intended flip.** Exact lines + the exact fix in §Requests 1. Nothing else in the whole suite moved.

---

## 1. The write-path map — every ingest site → policy

`WorkMaterialStoragePolicy.mode(kind:byteSize:)` is now consulted in exactly ONE function, `stageWorkMaterialBytes`, and every production capture reaches it.

| # | Surface | Route | Lane decided at |
|---|---|---|---|
| 1 | Canvas drop / file picker / photo picker / camera / screenshot | `WorkboardCaptureCanvas` → `WorkboardLiveRepository.importMaterial` → `upsertDeskMaterial` | `stageWorkMaterialBytes` |
| 2 | Chat → Work (note + every attachment) | `captureMessageToWork` → `upsertDeskMaterial` | same |
| 3 | Share inbox / menu-bar / GigaAction / Shortcuts | `WorkCaptureDrainer.persist` → `upsertDeskMaterial` (file URL) | same |
| 4 | `CaptureWorkboardIntent` | → `upsertDeskMaterial` | same |
| 5 | Reattach / replace on an unavailable card | `WorkboardLiveRepository.replaceMaterial` → `replaceWorkMaterialPayloadFile` | same (`stageWorkMaterialBytes`, fresh vault key) |
| 6 | Watch | text only, 16k cap, no byte lane, file not in the watch target | n/a |

**`addWorkMaterial` / `addWorkMaterialFile` / `insertWorkMaterial` deliberately stay `.localVault` and do NOT consult the policy.** They have zero production callers (integrate-a §2.2 verified) and survive only as the sole way to mint a material under a NON-desk owner, which ~20 store-test fixtures need — several of them (`WorkAssetVaultTests`, `WorkboardPersistenceTests`) exist precisely to exercise vault behaviour and would go vacuous if a 10-byte fixture started syncing. Both declarations now carry that constraint as a header comment. This is why `WorkboardPersistenceTests` (7/7) and `WorkAssetVaultTests` (9/9) are still green and why **test-compile.md §Requests 4 needs no action** — `testCaptureIdempotencyAndLocalMaterialPrivacy` goes through `addWorkMaterial`, so its `.localVault` assertion is still true and its message is still honest.

### The policy call itself
- **Fresh capture** (`existing == nil`): the policy decides from the MEASURED size — `Self.measuredByteSize(payload:sourceFileURL:declared:)`, which prefers the file's `.fileSizeKey` on disk, then the in-memory `payload.count`, then the caller's declaration. A wrong caller claim can therefore neither strand a syncable payload in the vault nor pull an oversized file into memory.
- **Repair** (`existing != nil`): the lane is FORCED to the one the row already claims (`forcedStorageMode:`). Repair restores what a card promises; it never moves a payload the person did not touch.
- **Reattach**: the policy decides afresh — the arriving bytes are new bytes, so a card legitimately moves between lanes.
- `0 < bytes ≤ 30 MiB` → blob + `.syncedPayload`. Zero, negative, unmeasurable or over-ceiling → `.localVault` with reattach first-class.

### `.syncedPayload` write shape
- `WorkMaterialBlob` row: `materialID`, `payload`, `byteSize` (**measured**, never the caller's claim — it is the completeness proof), `contentHash` = lowercase-hex SHA-256 (`CryptoKit`), `createdAt`/`updatedAt`.
- `WorkMaterial.payload` is now nil in **every** lane (`apply(_ draft:…)` sets it unconditionally). No double-write; the vault serves `.localVault` alone.
- `thumbnailData` is unchanged (`storageMode == .syncedPayload ? draft.thumbnailData : nil`), so a synced card renders before its bytes arrive — plan §C's "thumbnails unchanged".
- `byteSize` on the material equals the blob's, so the two can never disagree.

## 2. Publication + repair semantics

**Order (never reversed):** (1) `publishWorkMaterialBlob` — its OWN `context.save()`; (2) the material transaction — desk row, owner CAS, insert/repair, superseded-blob retirement, one save; (3) the caller's completion. The drainer already acknowledges its inbox claim only after `upsertDeskMaterial` returns (inbox-lease/desk-drainer), so step 3 needed nothing from me.

`publishWorkMaterialBlob` checks for an existing complete blob through the **metadata projection**, not by fetching rows — realizing blob managed objects to compare a hash would fault a ceiling-sized payload in to answer a question about its size.

| State a crash/import can leave | What the replay does |
|---|---|
| Blob durable, material never written | Insert path publishes the card; `publishWorkMaterialBlob` sees the matching complete row and writes **no second row** — the stranded blob is adopted (`createdAt` preserved) |
| Material `.syncedPayload`, blob missing (payload store lost, or import ordering) | Data layer reports incomplete (`workMaterialBlobCompleteness` has no entry, `loadWorkMaterialPayload` → nil); a replay carrying the bytes restages the blob and repoints every physical row |
| Duplicate blobs (CloudKit merge) | Reads resolve to the **newest COMPLETE** row via `WorkMaterialBlobRecord.isComplete` (never re-derived); **no row is deleted to resolve a read** |
| Incomplete blob row (hash/size absent) | Never wins, and is **never deleted** — indistinguishable from an import in flight; deleting it would export the removal of a valid record |
| Replay carrying different bytes under the same material id | New blob inserted (step 1), then the **superseded complete rows are deleted in the same save that repoints the card** — the card is never briefly readable as the wrong payload |
| Identical replay | `.alreadyPresent`, zero superseded → **no save at all**, `updatedAt` unchanged, no notification |
| Refused publication (CAS, `invalidMaterialOwner`, `identifierCollision`) | The staged vault key is reclaimed AND, if this call INSERTED a blob, that blob is deleted — scoped to its exact `(materialID, contentHash, byteSize)`, so a concurrently imported blob and the blob a refused replacement found are both left alone |
| `.localVault` ↔ `.syncedPayload` during reattach | Both directions handled explicitly: leaving the vault deletes the old vault leaf after commit; leaving the synced lane deletes **all** blob rows for the material inside the same save. A CAS-refused reattach restores the previous state exactly (fresh vault key, blob rollback) |
| `.metadataOnly` card offered bytes | Still refused — that is reattach, not repair (unchanged) |

**The one accepted residue:** if a cross-process race means `existing == nil` at read time but a material row exists at transaction time, a duplicate blob with IDENTICAL bytes can remain. Harmless — newest-complete-wins picks the same bytes. Within a process the `workInitialMaterialClaims` claim on the owner id makes it unreachable.

**Known cost, stated plainly:** a replay of a `.syncedPayload` card that still carries its bytes always re-stages them (reads ≤30 MiB and hashes it) in order to compare the hash. I chose fidelity to the plan's "mismatching hash/size" over a size-only short-circuit; the callers all skip material ids they already see, so a replay is a crash/redelivery event, not a hot path.

## 3. GC sites

- **`deleteWorkMaterial(id:workItemID:expectedOwnerRevision:)`** — the ONLY material-deletion path in the app (verified: `grep deleteWorkMaterial` → one declaration, one production caller in `WorkboardLiveRepository:499`). `Self.deleteBlobRows(materialID:in:)` runs inside the existing `context.perform`, in the same `try context.save()` as the material rows. Cross-store paired delete in one save is what the spike proved.
- **`replaceWorkMaterialPayloadFile`** — the same paired delete when a card leaves the synced lane.
- **The no-sweep constraint comment lives at `deleteBlobRows(materialID:in:)`** (the reason: CloudKit can import blob-before-material, so a sweep would export the deletion of a payload that is merely early; crash-orphans are accepted residue, bounded by the ceiling) and is cross-referenced from the delete site and from the rollback in `publishWorkMaterial`.
- The **early return** in `deleteWorkMaterial` when no material row matched is now load-bearing and commented: a blob whose material has not arrived is early, not orphaned. `WorkboardBlobGCTests.testABlobWhoseCardHasNotArrivedIsNeverSweptAway` runs every reclamation path in the store against exactly that state and asserts the blob survives, then that the arriving card finds its bytes.
- **Delete-all needed no extension and the invariant holds.** `ConversationStore.deleteAll()` deletes `Conversation` rows (cascading to messages) plus attempt rows; it deletes NO `WorkMaterial` row, so no blob is implicated. `WorkboardBlobGCTests.testDeletingEveryConversationLeavesSyncedWorkPayloadsStanding` extends the existing `WorkboardPersistenceTests` invariant to the payload store. **I did not edit `ConversationStore.swift`.**
- `reconcileWorkAssetVault` is untouched and touches no blob (asserted).

## 4. What the availability agent may rely on (next wave)

1. **`func workMaterialBlobCompleteness(materialIDs: Set<UUID>) async throws -> [UUID: WorkMaterialBlobRecord]`** is the primitive, already in production use. It is `internal` (not a `#if CONDUCK_TESTING` seam) exactly so the projection can consume it. ONE `.dictionaryResultType` fetch over `materialID/byteSize/contentHash/createdAt/updatedAt`, `materialID IN %@`, **never projects `payload`**. Returns only the newest COMPLETE row per material, using `WorkMaterialBlobRecord.isComplete` — do not restate that rule anywhere else.
2. **A material is available iff its id has an entry in that dictionary.** Absent → `.syncedPending`.
3. **The projection seam is still exactly where foundation.md pinned it**: `StoredWorkMaterial.record(availableLocalKeys:)`, `case .syncedPayload: availability = .synced`. **I did not touch it** — a `.syncedPayload` card with no blob still reports `.synced` today, which is the one thing my tests deliberately do NOT assert (they assert the data layer instead, and say so in a comment). You will want a second parameter alongside `availableLocalKeys` carrying the complete-blob id set, fed from ONE `workMaterialBlobCompleteness` call in `fetchWorkItems(itemID:captureEnvelopeID:)` and one in `fetchWorkMaterial(id:)`.
4. `hasPayload` at the bottom of `record(...)` keys off `availability`, so it follows for free.
5. Reuse `workboard.material.syncPending` (foundation.md); mint no second key.
6. While you are in `fetchWorkItems`, the per-key `await workAssetVault.contains` loop (plan §C, deadlock-precedent shape) is still there and still unbatched — my change neither fixed nor worsened it. `WorkAssetVault.urls(for:)` is the unused batch resolver.

## 5. Other things I added in `ConversationStore+Workboard.swift`

- `import CryptoKit`; file header rewritten to state the two-lane truth.
- `StagedWorkMaterialBytes` gained `blobPayload` + `contentHash` (memberwise init with defaults, so nothing else changed shape). **Exactly one lane is ever populated.**
- `private nonisolated enum WorkMaterialBlobPublication { case none, alreadyPresent, inserted(contentHash:byteSize:) }` — what step 1 did, which is what licenses the rollback.
- `publishWorkMaterialBlob(materialID:payload:byteSize:contentHash:)`, `newestCompleteBlobPayload(materialID:)`, `deleteBlobRows(materialID:contentHash:byteSize:)` (async rollback).
- statics: `measuredByteSize`, `contentHash(of:)`, `blobRows(materialID:in:)`, `deleteSupersededBlobRows(materialID:keepingContentHash:byteSize:in:)`, `deleteBlobRows(materialID:in:)`, `pointAtSyncedPayload(row:byteSize:at:)`, two `blobRecord` builders.
- `stageWorkMaterialBytes` gained `kind:`, `vaultKeyID:` (defaults to the material id; reattach passes a fresh UUID so the bytes a card still names stay authoritative until its CAS commits) and `forcedStorageMode:`.
- `loadWorkMaterialPayload` no longer reads the `payload` column at all; `.syncedPayload` answers from the newest complete blob.
- FIVE test seams, all `#if CONDUCK_TESTING` + gated on `Self.isInMemory(context)` (the convention already in this file — `isIsolatedTestStore` is `private` in `ConversationStore.swift` and therefore unreachable from here), each with a "WHY IT HAS TO EXIST" header: `_workMaterialBlobRowsForTesting(materialID:)` (+ the `WorkMaterialBlobRowProbe` snapshot, payload as a byte COUNT), `_workMaterialPayloadColumnForTesting(id:)`, `_insertWorkMaterialBlobRowForTesting(...)`, `_deleteWorkMaterialBlobRowsForTesting(materialID:)`, `_publishDeskMaterialBlobOnlyForTesting(_:)` (runs the REAL staging + step 1 and stops where a crash would — a refusal path cannot stand in, because a crash runs no rollback).
  - Note the overlap with store-descriptions' `_materialAndBlobForTesting` in `ConversationStore.swift`: that one reports a row COUNT and the first row's fields, unordered, and no material payload column — not enough for newest-wins or paired deletion. I left it alone and did not route anything through `_writeMaterialAndBlobForTesting`, per store-descriptions §6.7.

## 6. Deviations from the brief, with reasons

1. **`addWorkMaterial`/`addWorkMaterialFile` are NOT wired to the policy** (§1). They are not ingest lanes; wiring them would flip ~20 fixtures in six files I do not own and would delete `WorkAssetVaultTests`' subject matter.
2. **No orphan-blob rollback on a crash, only on a refusal this call made** (§2). The plan forbids a *sweep*, whose reason is that a sweep cannot tell an early import from an orphan. Inside the failing call that distinction is known, so the rollback is scoped to the exact bytes this call wrote and is skipped whenever it merely replaced someone else's blob.
3. **I did not land the `.syncedPending` projection** — explicitly next wave's (§4.3). The consequence is that a card with no blob currently still reads `.synced` in `WorkMaterialRecord.availability`. My tests assert the data layer, never that enum, so nothing has to be rewritten when the projection lands.
4. **No incremental `onProgress` on the synced file lane.** `Data(contentsOf:)` reports 0→1 rather than streaming progress, and it is not cancellable mid-read. Bounded by the 30 MiB ceiling; `storeFileStreaming` still drives real progress for everything above it. Flagged as §Requests 3 rather than solved.
5. **No Codex consult.** Nothing in this slice was a genuinely hard call once spike.md, desk-upsert.md §3 and store-descriptions.md §6 were read; the one real judgement (what to do about the pre-policy assertions in files I do not own) is a process question, not a technical one.

## 7. Tests + counts (exact lines)

Slug `desk-blob-io`, derivedData `~/Library/Caches/gigaduck-builds/desk-blob-io/{DerivedData,DerivedDataMac}`, every log written there and grepped. No `-configuration` passed anywhere.

- iOS `build-for-testing`, sim `6C3FB33E-D89F-4D1E-9F0D-3FAC0C089228` → `bft-2.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`. No new warnings in either of my files.
- macOS `xcodebuild build -destination 'platform=macOS'` → `mac-1.log`: 0 `error:` lines, `** BUILD SUCCEEDED **`. Signed through the identity override; **no `CODE_SIGNING_ALLOWED=NO` fallback needed**. (Insurance — this file compiles for macOS.)
- **The VERIFY set** (`test-3.log`, `** TEST EXECUTE FAILED **`, `Executed 48 tests, with 2 failures (0 unexpected) in 2.363 (2.375) seconds`):

| Class | Result |
|---|---|
| `WorkboardBlobGCTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.071 (0.073) seconds` |
| `WorkboardBlobPublicationTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.317 (0.320) seconds` |
| `WorkboardDeskUpsertTests` | `Executed 10 tests, with 2 failures (0 unexpected) in 1.147 (1.150) seconds` ← §Requests 1 |
| `WorkboardModelMigrationTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.539 (0.540) seconds` |
| `WorkboardPersistenceTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.040 (0.041) seconds` |
| `WorkboardTwoStoreLoadTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.249 (0.250) seconds` |

- **FULL iOS suite** (`ios-full-1.log`, `** TEST EXECUTE FAILED **`) — run because I changed the store every capture uses:
```
Executed 4747 tests, with 1 test skipped and 4 failures (0 unexpected) in 64.352 (65.782) seconds
```
  **All four failures, verbatim and deduplicated:**
```
ConversationStoreAtomicWorkCaptureTests.swift:41: error: -[ConduckTests.ConversationStoreAtomicWorkCaptureTests testInitialMaterialPublishesOwnerAndPayloadTogether] : XCTAssertEqual failed: ("Optional(Conduck.WorkMaterialAvailability.synced)") is not equal to ("Optional(Conduck.WorkMaterialAvailability.availableLocally)")
WorkCaptureDrainerTests.swift:119: error: -[ConduckTests.WorkCaptureDrainerTests testTheNoteAndEveryAttachmentLandOnTheDeskTogether] : XCTAssertEqual failed: ("synced") is not equal to ("availableLocally")
WorkboardDeskUpsertTests.swift:228: error: -[ConduckTests.WorkboardDeskUpsertTests testReplayRepairsACardWhoseVaultBytesAreGone] : XCTAssertEqual failed: ("synced") is not equal to ("availableLocally")
WorkboardDeskUpsertTests.swift:229: error: -[ConduckTests.WorkboardDeskUpsertTests testReplayRepairsACardWhoseVaultBytesAreGone] : XCTUnwrap failed: expected non-nil value of type "String"
```
  4747 = the tree's current baseline + my 18 (store-descriptions reported 4730 before the share-extension slice landed its own test edits; I did not reconcile that ±1 and it is not mine).
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 770 Swift files scanned…`, exit 0.
- `git diff --check` → clean, exit 0.
- **Watch suite: NOT RUN.** `ConversationStore+Workboard.swift` is not in the `ConduckWatch Watch App` membership-exception list (`project.pbxproj:210-250` names `ConversationStore.swift` and `ConversationStore+GatewayAttempts.swift`, not this file), so the wrist compiles none of my code and no blob touch needs an `#if !os(watchOS)`. No watch sim was assigned to me.
- Build caches removed: `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-blob-io` → `removed: desk-blob-io`. **The logs no longer exist**; re-run if you need them.
- No new file needed a pbxproj edit (both test files are in the synchronized `ConduckTests` group and compiled + ran).

### The 18 new cases

`WorkboardBlobPublicationTests` (12): under-ceiling → blob the card names but does not hold (payload column proven nil, hash proven, vault untouched) · over-ceiling → vault + no blob, and its replay repairs the vault · a blob left by a crash is adopted, not duplicated · a lost payload store reads incomplete and a replay restages it · a card may claim synced bytes that have not arrived · duplicate blobs resolve to the newest complete row without deleting one · an incomplete row never wins and is never deleted · a replay with other bytes replaces the blob paired with the card · an identical replay writes nothing at all · a refused publication takes back only the bytes it wrote (both the fresh-card and the replacement case) · reattach moves a card off the vault onto the synced lane · reattach moves a card off the synced lane with its blob (plus a refused reattach leaving the old payload standing).

`WorkboardBlobGCTests` (6): paired delete · every physical blob leaves with the card (merged duplicate + incomplete row) · deleting one card leaves other payloads standing · a delete scoped to another owner touches neither · **a blob whose card has not arrived is never swept away** · delete-all leaves synced Work payloads standing.

Two coverage notes: the over-ceiling case allocates `Constants.workboardSyncCeilingBytes + 1` (31,457,281 B) once — the same shape store-descriptions used for its memory measurement, and the whole class still runs in 0.32 s. And `testAPayloadAboveTheCeilingTakesTheVaultAndAReplayRestoresIt` **is** the vault-lane crash-repair coverage that `WorkboardDeskUpsertTests.testReplayRepairsACardWhoseVaultBytesAreGone` used to carry, so that case is now redundant rather than merely stale (§Requests 1).

---

## Call-site touches

**NONE.** No file outside the three I own was opened for editing.

---

## Catalog

**Keys I ADDED in source: NONE.** The write path is headless; it produces no user-facing copy, and no `.xcstrings` file was opened.

**Keys I found DEAD: NONE.** I deleted no code that referenced a key.

---

## Requests

1. **Serial integrator / phase-5 test surgery — FOUR pre-policy assertions in three files I do not own now state the pre-byte-sync truth.** All four are the plan's intended flip (a small payload used to be device-local and now syncs), not regressions; I changed none of them, per the parallel-phase ownership rule.
   - `ConduckTests/ConversationStoreAtomicWorkCaptureTests.swift:41` — `XCTAssertEqual(created.materials.first?.availability, .availableLocally)` → `.synced`. (This whole class is on integrate-a §Requests 4a's deletion list anyway; if `createWorkItemWithInitialMaterial` goes, so does this.)
   - `ConduckTests/WorkCaptureDrainerTests.swift:119` — `XCTAssertEqual(image.availability, .availableLocally)` → `.synced`. The line below it (`storedBytes == payload`) already passes through the blob. Its doc line "the file's bytes are readable from the desk once the queue copy is gone" stays true; consider "and they ride private CloudKit" so the case names the lane it is now proving.
   - `ConduckTests/WorkboardDeskUpsertTests.swift:228-240`, `testReplayRepairsACardWhoseVaultBytesAreGone` — a 19-byte payload can no longer produce a `.localVault` desk card, so `.availableLocally` and `XCTUnwrap(published.localVaultKey)` both fail. **Cheapest correct fix: delete the case** — `WorkboardBlobPublicationTests.testAPayloadAboveTheCeilingTakesTheVaultAndAReplayRestoresIt` is the same test on a payload that still takes that lane, including the "still ONE physical row" assertion. If you would rather keep it where it is, change its payload to `Data(repeating:, count: Int(Constants.workboardSyncCeilingBytes) + 1)` and it passes unchanged otherwise.
2. **Availability agent — read §4 before writing the projection.** In particular: `workMaterialBlobCompleteness` already exists and is already load-bearing in production, so consume it rather than writing a second blob fetch; and do not restate `isComplete`.
3. **Whoever owns capture progress UI (`WorkboardLiveRepository`/`WorkboardCaptureCanvas`)** — a file capture that takes the synced lane reports progress 0→1 with nothing in between and cannot be cancelled mid-read, because the blob attribute needs a whole `Data`. Bounded by the 30 MiB ceiling. If that reads badly on a slow import, the fix is a chunked read that accumulates into `Data` while reporting progress, in `stageWorkMaterialBytes`'s synced-file branch — I left the simple form because 30 MiB costs ~1× peak memory (store-descriptions §4 measured it) and completes in well under a second locally.
4. **`WorkboardLiveRepository.swift:535-537`** carries a comment that is now half false: *"Reattachment replaces local bytes and metadata only. Persisting an extract or a preview here would copy user file content into private CloudKit; the board renders previews from the vault."* Reattached bytes under the ceiling now DO ride private CloudKit, and the board renders such a card from the blob, not the vault. The extract/preview half is still true and still enforced (`replaceWorkMaterialPayloadFile` nils `textContent` and `thumbnailData`). It is not my file and its signature did not change, so I left it — please rewrite it present-tense when you next open that file.
5. **Docs agent — three spec lines are now settled by code, not just by the plan.** Plan §E already names `spec.md:430` (Work file bytes device-local) and `:503`; add the third fact: a material's bytes live in the payload store when they are within `Constants.workboardSyncCeilingBytes` (30 MiB) and in the device-local vault otherwise, the two are never both written, and `WorkMaterial.payload` is never written at all. `WorkAssetVault.swift`'s header (plan §C / Codex #12, lines 6-14, still says device-local-only) is still owed by someone — **I did not touch it.**
6. **Orchestrator — the iOS baseline is 4747 executed, 1 skip**, of which 18 are mine. Gate 2's founder checklist (spike §(c)) needs no change from this slice; steps 8 and 17 are exactly what `WorkboardBlobGCTests` and `WorkboardBlobPublicationTests` assert headlessly, so a failure there would be a CloudKit-transport finding rather than a logic one.
7. **Nobody add an orphan-blob sweep, a `reconcileWorkMaterialBlobs`, or a "blobs with no material" cleanup**, however tempting the residue looks. The reason is at `deleteBlobRows(materialID:in:)` and `WorkboardBlobGCTests.testABlobWhoseCardHasNotArrivedIsNeverSweptAway` fails if one is added.
