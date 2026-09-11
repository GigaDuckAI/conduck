# fix-store — 4 Codex findings on `ConversationStore+Workboard.swift` (1 critical + 3 major). ALL FOUR CONFIRMED, all fixed, every new case measured RED on the pre-fix code.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. **No `.xcstrings` file opened** (zero user-facing strings). Nothing under `docs/qa/desk-cloudkit/` touched. No mirror triplet touched. No file outside my ownership list was edited **in the shared worktree**.

Files I changed, exactly four:
- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (+223 / −86)
- `Conduck/ConduckTests/WorkboardBlobPublicationTests.swift` (12 → 15 cases)
- `Conduck/ConduckTests/WorkboardChatCaptureTests.swift` (5 → 7 cases)
- `Conduck/ConduckTests/WorkboardDeskUpsertTests.swift` (10 → 11 cases; one case REWRITTEN, see §2.3)

`WorkboardBlobGCTests.swift` and `WorkboardPersistenceTests.swift` are **unmodified** and still 6/6 and 7/7.

**HEADLINE FOR THE ORCHESTRATOR.** iOS `** TEST BUILD SUCCEEDED **` (0 `error:`), macOS `** BUILD SUCCEEDED **` signed, my seven-class VERIFY set `Executed 62 tests, with 0 failures`. The FULL iOS suite is `Executed 4810 tests, with 1 test skipped and 4 failures` — **all four are the same single case in a file I do not own, and it is broken BY DESIGN by finding #2's fix**: `WorkCaptureDrainerTests.testAPersistenceFailureReleasesTheClaimAndPreservesItsPayload` used `invalidMaterialOwner` purely as a way to force a mid-import failure, and that error is no longer reachable from a desk capture. §Requests 1 carries a **verified drop-in replacement** (built and run green, `WorkCaptureDrainerTests` 9/9).

---

## 1. Verification of the findings (FIX PROTOCOL step 1)

All four re-located by symbol against the current tree, not by the cited line numbers. **Nothing refuted; there is no `## Refuted` section.**

| # | Finding | Verdict | Evidence at the moment I read it |
|---|---|---|---|
| 1 | critical — a refused blob publication deletes a concurrent publication's row | **CONFIRMED** | `publishWorkMaterialBlob` returned `.inserted(contentHash:byteSize:)`; both rollbacks called `deleteBlobRows(materialID:contentHash:byteSize:)`, which **fetched every row matching that tuple and deleted all of them**. The tuple has no uniqueness constraint (CloudKit forbids one), and the presence check + insert are separate operations, so two callers carrying the same bytes for one material insert rows equal in every column. |
| 2 | major — a legacy-owned material id is refused instead of adopted | **CONFIRMED** | `guard owners == [ownerID] else { throw .invalidMaterialOwner }`. `captureMessageToWork` computes `existingIDs` from the DESK's materials only, so a chat card parked under a per-turn item is not skipped, reaches the upsert, throws, and lands in `failed`. The drainer's `persist` propagates the throw → `release(claim)` → the same envelope replays and fails identically for ever. |
| 3 | major — reattach writes one physical row while blob deletion is by logical id | **CONFIRMED** | `guard let row = try Self.workMaterialRow(id: id, in: context)` (singular, `fetchLimit = 1`) vs `Self.deleteBlobRows(materialID: id, in: context)` (every row). A duplicate left on `.syncedPayload` therefore claims a payload the same save deleted. |
| 4 | major — Chat→Work skips byte-bearing attachments by id | **CONFIRMED** | `guard !existingIDs.contains(attachment.id) else { continue }` ran before `payloads` was consulted, so a card whose blob never landed stayed `.syncedPending` while the receipt reported the turn already captured. |

## 2. What changed

### 2.1 Rollback identity (finding 1)

- `WorkMaterialBlobPublication.inserted(contentHash:byteSize:)` → **`.inserted(rowID: NSManagedObjectID)`**. `publishWorkMaterialBlob` calls `context.obtainPermanentIDs(for: [row])` **before** the save and returns `row.objectID`. (`NSManagedObjectID` is `NS_SWIFT_SENDABLE` in the SDK, so the `nonisolated ... : Sendable` enum still conforms — checked in the CoreData header, not assumed.)
- `deleteBlobRows(materialID:contentHash:byteSize:)` is **deleted**; the new `deleteBlobRow(_ rowID:)` resolves `context.existingObject(with:)` and deletes that one object. A row that has already gone is not an error.
- Both rollback sites (`publishWorkMaterial`'s catch, `replaceWorkMaterialPayloadFile`'s catch) now pass the id through. The reason lives at the declaration.

### 2.2 Legacy-owner adoption (finding 2)

New block in `publishWorkMaterial`'s transaction, ahead of the repair branch:

- `owners != [ownerID]` no longer throws for the `.desk` policy. It re-homes **every physical row whose `workItemID` is not the desk**: `workItemID` ← desk, one shared rank, `updatedAt` ← now; then `ownerRow.updatedAt` ← now, because a card genuinely joined the board.
- **The rank is the desk-side twin's if the card already has one there, otherwise `appendRank(desk)`** — one logical card must hold one rank across every physical row, or `reorderWorkMaterials`' invariant breaks on the next drag.
- **The legacy `WorkItem` row is never touched and never deleted** (it is a valid CloudKit record; exporting its deletion removes it everywhere).
- **Only an explicit capture naming that id adopts.** No sweep, no migration pass, nothing on launch.
- `.createNew` still throws `invalidMaterialOwner` — that arm is unreachable (the policy already throws `identifierCollision` on a colliding material id earlier in the same transaction) and is kept so the rule is stated rather than implied.
- New `WorkMaterialWriteOutcome.adoptedMaterial` drives the save and `postDidChange()`.

`invalidMaterialOwner` is still live and still reachable from `addWorkMaterial`, `addWorkMaterialFile`, `insertWorkMaterial`, `deleteWorkMaterial`, `setWorkMaterialCardSize`, and now `replaceWorkMaterialPayloadFile` (§2.3). It is only the DESK capture path that stopped throwing it.

### 2.3 Reattach + duplicate physical rows (finding 3)

`replaceWorkMaterialPayloadFile`'s transaction now:
1. fetches **`workMaterialRows(id:)`** (all physical rows, newest first),
2. validates a single logical owner — `owners.count == 1` else `invalidMaterialOwner` (rows disagreeing about their owner cannot move under one CAS, and picking one would settle the disagreement by accident; same guard `deleteWorkMaterial` already had),
3. runs the owner CAS **once**,
4. applies the lane, size, key, `updatedAt` and the replacement metadata (`sourceDevice`/`filename`/`mimeType`, `textContent`/`thumbnailData` nilled) to **every** row,
5. returns `Set<String>` of old vault keys; the post-commit sweep removes each one that is not the new key.

New static `pointAtLocalVault(row:vaultKey:byteSize:at:)`, the mirror of `pointAtSyncedPayload`. It is used by the reattach's off-the-synced-lane branch **and** by the `.localVault` repair branch in `publishWorkMaterial` — that is the finding's "likewise normalize storageMode during local-vault repair": the repair loop already wrote every row's key and size, but not its `storageMode`, so a duplicate that had drifted onto the synced lane kept claiming it.

**Stated plainly:** the storageMode-drift half of the repair normalization has **no dedicated regression test**. No public API and no existing seam can produce a duplicate row whose `storageMode` differs from its twin's, and I judged a third `#if CONDUCK_TESTING` column-writer not worth its weight for a defensive write. The lane/key/size half is covered by `testReattachWritesEveryDuplicateRowSoNoneResurrectsTheOldLane`, which uses the same helper.

### 2.4 Chat→Work replay repair (finding 4)

`captureMessageToWork`'s attachment loop no longer prefilters on the id alone:

```swift
let localPayload = payloads[attachment.id]
let alreadyOnDesk = existingIDs.contains(attachment.id)
if alreadyOnDesk, localPayload == nil { continue }
```

- An attachment whose bytes this device still holds is **always** republished, so `upsertDeskMaterial` can restage a blob that never landed. A healthy card takes the idempotent no-op path (`.alreadyPresent`, zero superseded, no save, `updatedAt` unchanged).
- A card with no bytes to offer (server reference, unreadable) is still skipped: there is nothing to repair.
- **Counters keep their meaning.** `added` increments only when `!alreadyOnDesk`, so a repair is never reported as a second copy arriving. `referencedOnly` is unchanged (its branches are only reached when the card is not on the desk). `failed` now also counts a repair that threw — deliberate: a failed repair is a real partial outcome and the banner should say so.
- The note card (`message.id`, `.metadataOnly`) is still skipped on a repeat.

### 2.5 Test-seam changes (both in my file)

- `WorkMaterialRowProbe` gained `workItemID`, `storageMode`, `localVaultKey`, `byteSize` (it had `sequence`/`cardSize`/`updatedAt`). **Additive only** — nothing constructs it; the four consumers (`WorkboardAudioCaptureTests`, `WorkboardChatCaptureTests`, `WorkboardPersistenceTests`, `WorkboardBlobPublicationTests`, `WorkboardDeskUpsertTests`) only read fields and all still compile untouched.
- `_duplicateWorkMaterialRowForTesting(id:)` gained a **defaulted** `updatedAt: Date? = nil`. Its two existing callers in `WorkboardPersistenceTests` are unchanged. The reason it has to exist is in the doc comment: with equal stamps the canonical read picks the row a write touched anyway, so a write that skipped the duplicate would still look correct through the projection.

## 3. The residual I did NOT close, stated plainly

Object-scoped rollback fixes the interleaving the finding describes (**both** callers insert; the loser must not take the winner's row). There is a second interleaving it does **not** close, and I decided against closing it:

> A publishes its blob and is then suspended before its material transaction. B runs whole, sees A's row as complete, adopts it (`.alreadyPresent`, inserts nothing) and commits its card. A resumes, loses the CAS, and rolls back **its own row** — which is the row B's card now names. B's card becomes `.syncedPending`.

Why I left it:
- Every simple guard I could write is worse. "Skip the rollback when a `.syncedPayload` material exists for that id" breaks `testARefusedPublicationTakesBackOnlyTheBytesItWrote` and leaves a refused reattach's bytes riding private CloudKit for ever (there is no sweep to reclaim them). "Skip when ours is the newest complete row" lets a refused replacement's bytes become the card's payload — destructive. "Skip when ours is the only complete row" makes a refused reattach silently give a `.syncedPending` card the new file's bytes under the old card's filename.
- It is bounded in practice. In-process it is unreachable through `upsertDeskMaterial` (`workInitialMaterialClaims` serializes on the desk id); it needs two processes, or two concurrent reattaches of one card, which `replaceWorkMaterialPayloadFile` does not serialize.
- It is **recoverable, not lossy**: the card reads `.syncedPending`, and fix-drainer's `confirmDurablyImported` barrier refuses to acknowledge a capture whose cards are not readable, so a share-inbox capture is redelivered and repaired rather than losing its only copy.

A real fix is a different mechanism (an adopting caller must not depend on a row it did not write), and it is bigger than this slice. **Codex: this is the one part of finding #1 that survives, and I am flagging it rather than quietly claiming the whole finding closed.**

## 4. Regression tests — and the measured proof they fail on the old code

Six new/rewritten cases. I did **not** reason about non-vacuity: I measured it, in an **isolated copy of the worktree** (`…/scratchpad/ctree`, 24 MB, no git operation of any kind), with the four behaviours reverted in that copy alone. The shared tree was never in a reverted state for a single second.

Counterfactual run (`cf-test-1.log`, `** TEST EXECUTE FAILED **`), pre-fix behaviour, my test files verbatim:

| Class | Result on the PRE-FIX code |
|---|---|
| `WorkboardBlobPublicationTests` | `Executed 15 tests, with 8 failures (0 unexpected)` |
| `WorkboardChatCaptureTests` | `Executed 7 tests, with 5 failures (0 unexpected)` |
| `WorkboardDeskUpsertTests` | `Executed 11 tests, with 2 failures (2 unexpected)` |

Every failing assertion belongs to a case I added, and each fails for its own finding's reason:

```
WorkboardBlobPublicationTests.swift:446: testARefusedPublicationLeavesAnIdenticalBlobItDidNotWrite : XCTAssertEqual failed: ("1") is not equal to ("2") - the refusal takes back the row it inserted and leaves the identical one standing
WorkboardBlobPublicationTests.swift:504: testARefusedReattachTakesBackOnlyTheBlobRowItWrote : XCTAssertEqual failed: ("1") is not equal to ("2")
WorkboardBlobPublicationTests.swift:669: testReattachWritesEveryDuplicateRowSoNoneResurrectsTheOldLane : XCTAssertEqual failed: ("["localVault", "syncedPayload"]") is not equal to ("["localVault"]") - a row left on the synced lane would claim a payload this same save deleted
WorkboardChatCaptureTests.swift:282: testRecapturingATurnRestagesAnAttachmentWhoseSyncedBytesAreGone : XCTAssertEqual failed: ("syncedPending") is not equal to ("synced")
WorkboardChatCaptureTests.swift:355: testATurnCapturedByAnOlderBuildIsAdoptedOntoTheDeskRatherThanFailing : XCTAssertEqual failed: ("2") is not equal to ("0") - a card an older build parked elsewhere is adopted, never reported as failed
WorkboardDeskUpsertTests.swift:318: testAMaterialUnderALegacyOwnerIsAdoptedByAnExplicitRecapture : failed: caught error: "invalidMaterialOwner"
WorkboardDeskUpsertTests.swift:384: testAPartiallyDrainedPreRewriteEnvelopeReplaysCleanOntoTheDesk : failed: caught error: "invalidMaterialOwner"
```

### The cases

| Case | Finding | Holds |
|---|---|---|
| `testARefusedPublicationLeavesAnIdenticalBlobItDidNotWrite` (`WorkboardBlobPublicationTests`) | 1 | a peer's NEWER blob makes the presence check miss the identical row already there — the same position a concurrent publication is in — so the refused replay inserts a row equal in every column. Afterwards BOTH the peer's row and the identical one it did not write are standing (2 rows, hashes `{mine, peer}`), and the newest complete row still answers for the card |
| `testARefusedReattachTakesBackOnlyTheBlobRowItWrote` | 1 | the same rule on the reattach rollback — the path with **no** in-process claim, i.e. the one two callers can genuinely overlap on |
| `testReattachWritesEveryDuplicateRowSoNoneResurrectsTheOldLane` | 3 | a CloudKit-merged duplicate stamped one hour AHEAD (so it would win the canonical read) is written by the reattach too: every physical row reports `localVault`, one shared vault key, size 0, and no blob survives |
| `testAMaterialUnderALegacyOwnerIsAdoptedByAnExplicitRecapture` (`WorkboardDeskUpsertTests`) | 2 | **rewritten from `testAMaterialIdOwnedByAnotherItemIsRefusedRatherThanMoved`** (§4.1). The card lands on the desk, keeps its own title (adoption re-homes, it never rewrites content), moves as ONE row, the legacy owner row survives with its title and holds no materials, and the next replay is an ordinary no-op |
| `testAPartiallyDrainedPreRewriteEnvelopeReplaysCleanOntoTheDesk` | 2 | the drainer's upgrade case: two entries adopted + one published, ranks `[0, 1, 2]`, the adopted file keeps the bytes it already had, the legacy envelope row survives |
| `testATurnCapturedByAnOlderBuildIsAdoptedOntoTheDeskRatherThanFailing` (`WorkboardChatCaptureTests`) | 2 | Chat recapture of a pre-rewrite turn: `failedMaterialCount == 0`, `addedMaterialCount == 2`, both cards on the desk, ONE physical row each, the attachment's bytes intact, the legacy item row standing and empty |
| `testRecapturingATurnRestagesAnAttachmentWhoseSyncedBytesAreGone` | 4 | capture → blob rows deleted through the seam → card is `.syncedPending` / `hasPayload == false` → recapture → `.synced` with the exact bytes back, `addedMaterialCount == 0`, `failedMaterialCount == 0`, still 2 cards, still ONE physical row |

### 4.1 The one assertion I changed, and why that is not weakening a test

`WorkboardDeskUpsertTests.testAMaterialIdOwnedByAnotherItemIsRefusedRatherThanMoved` asserted `invalidMaterialOwner` and "the other item keeps its card". **That is the contract Codex finding #2 overturns**, so it could not both stand and be fixed. After the purge there is no legitimate second owner in production — `createWorkItem` has no app caller, the projects UI is gone — so "a material id owned by another item" and "a material id a pre-desk build parked" are the same state.

I rewrote it into the adoption case rather than deleting it, and it still holds the property that mattered: **the other item is not disturbed** — its row survives, keeps its title, and is not deleted. What flipped is only the direction of the material, from "refused" to "adopted", which is exactly what the finding asks for. No other assertion anywhere was weakened, narrowed or removed.

### 4.2 One test-authoring trap worth recording

`appendMessage`'s RETURNED `MessageRecord` carries attachment records built by `ConversationStore.attachmentRecords(from:at:)`, which mints a **fresh `UUID()`** per attachment — those are NOT the persisted row ids the capture lane reads. Use `loadLocalAttachmentPayloads(for: message.id)`' keys (or read the id back off the desk card) whenever a test needs the real attachment identity.

## 5. Gates — WHAT I ACTUALLY RAN

Slug `fix-store`. DerivedData under `~/Library/Caches/gigaduck-builds/fix-store/{DerivedData,DerivedDataMac,DerivedDataCounterfactual}`, every log written into the slug dir and grepped. No `-configuration` passed anywhere. Sim `C26F4ECE-16AC-40B7-8D6A-BBF82B5BBA5D`.

- iOS `build-for-testing` → `bft-3.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`. **Zero `warning:` lines mention either of my files** in any build log.
- **VERIFY set** (`test-1.log`, `** TEST EXECUTE SUCCEEDED **`, total `Executed 62 tests, with 0 failures (0 unexpected) in 1.137 (1.152) seconds`):

| Class | Result |
|---|---|
| `WorkboardAvailabilityTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.290 (0.292) seconds` |
| `WorkboardBlobGCTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.201 (0.202) seconds` |
| `WorkboardBlobPublicationTests` | `Executed 15 tests, with 0 failures (0 unexpected) in 0.155 (0.159) seconds` |
| `WorkboardChatCaptureTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.065 (0.066) seconds` |
| `WorkboardDeskUpsertTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.099 (0.101) seconds` |
| `WorkboardPersistenceTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.060 (0.062) seconds` |
| `WorkboardTwoStoreLoadTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.267 (0.268) seconds` |

- **FULL iOS suite** (`ios-full-1.log`, `** TEST EXECUTE FAILED **`) — run because I changed the store every capture goes through:
```
Executed 4810 tests, with 1 test skipped and 4 failures (1 unexpected) in 64.819 (66.265) seconds
```
  **All four failure lines are one method in one file I do not own**, verbatim and deduplicated:
```
WorkCaptureDrainerTests.swift:321: error: -[…testAPersistenceFailureReleasesTheClaimAndPreservesItsPayload] : failed - A material owned by another Work item must fail the import
WorkCaptureDrainerTests.swift:327: error: -[…] : XCTAssertEqual failed: ("0") is not equal to ("1") - a failed import must return the capture to the queue, not consume it
WorkCaptureDrainerTests.swift:329: error: -[…] : XCTAssertEqual failed: ("[047383DA-…, F7DCD807-…]") is not equal to ("[047383DA-…]") - the card written before the failure stays; replay repairs the rest
WorkCaptureDrainerTests.swift:334: error: -[…] : failed: caught error: "…payload-000.png couldn't be opened because there is no such file…"
```
  Cause and verified remedy: §Requests 1. Nothing else in the whole suite moved — in particular the `WorkboardLiveRepositorySupportTests` and `WorkCaptureDrainerDurabilityTests` failures fix-vault and fix-inbox recorded have since cleared.
- macOS `xcodebuild build -destination 'platform=macOS'` → `mac-1.log`: 0 `error:` lines, `** BUILD SUCCEEDED **`. Signed through the identity override; **no `CODE_SIGNING_ALLOWED=NO` fallback needed.**
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 777 Swift files scanned…`, exit **0**.
- `git diff --check` → clean, exit **0**. `git status --short` shows no `.xcstrings`, no `Identity-Override`, nothing under `docs/` from me (the two modified catalogs are the audio/strings workflow's).
- **Watch suite: NOT RUN.** `ConversationStore+Workboard.swift` is not in the `ConduckWatch Watch App` membership-exception list, so the wrist compiles none of my code, and no watch sim was assigned to me.
- **No Codex consult.** Nothing here was a genuinely hard call once plan §A/§C, desk-upsert.md §2–§3 and blob-io.md §2 were read; the one real judgement (§3, the residual interleaving) is recorded for adjudication rather than silently decided.
- **Build caches removed at end of task** with `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh fix-store` (all three DerivedData trees live under that one slug). **The logs are gone with them**; re-run if you need them.

### The isolated copy, so nobody mistakes it for work product

`…/scratchpad/ctree` is a throwaway copy of the worktree used ONLY for the counterfactual and for verifying the drainer-test patch in §Requests 1. It holds the pre-fix production file at one point and a locally patched `WorkCaptureDrainerTests.swift`, and **must never be copied back**. Its `.git` file was renamed to `git-file-detached-do-not-use` so no git command in it can reach the real repository. I could not delete the copy (a bare `rm -rf` is denied and the build-cache script owns only `~/Library/Caches/gigaduck-builds`); it lives in the session scratchpad, not the repo. The two Python patch scripts beside it (`revert.py`, `drainer_test_patch.py`) both hard-code the `ctree` path.

---

## Call-site touches

**NONE.** No signature I own changed: `upsertDeskMaterial`, `captureMessageToWork`, `replaceWorkMaterialPayloadFile`, `createWorkItemWithInitialMaterial`, `deleteWorkMaterial` and every test seam kept their exact signatures (the one new seam parameter is defaulted). `WorkboardLiveRepository.swift` was never opened.

---

## Catalog

**Keys I ADDED in source: NONE.** Every change here is headless; it produces no user-facing copy and no `.xcstrings` file was opened.

**Keys I found DEAD: NONE.** I deleted no code that referenced a key. The chat-capture keys chat-capture.md listed as live are all still live and still reachable.

---

## Requests

1. **BLOCKING for the gate — `ConduckTests/WorkCaptureDrainerTests.swift` (serial integrator / whoever owns it).** `testAPersistenceFailureReleasesTheClaimAndPreservesItsPayload` seeds a material under a foreign owner and drains, using `invalidMaterialOwner` as its way to "make the second write fail through the public API with no store seam" (its own comment). Finding #2's fix removes that error from the desk capture path, so the import now succeeds and the case fails. Its SUBJECT — a failed import releases the claim instead of acknowledging it, and the queue keeps the only copy of the bytes — is still exactly right and must not be dropped.
   **Verified drop-in mechanism: an unreadable payload leaf.** `WorkCaptureInbox`'s validator only STATS a leaf (`attributesOfItem`, size + type); the STORE is what reads the bytes. So a mode-`0` regular file passes validation and fails inside `stageWorkMaterialBytes`, with no store seam and nothing the desk can adopt. Replace the `otherOwner`/`collidingID` fixture with a second `.file` entry (`payload-001.bin`, sequence 1, honest `byteCount`), `chmod 000` its leaf after `publish(...)` and before `drainAvailableCaptures()`, drop the `XCTAssertEqual(error as? WorkboardStoreError, .invalidMaterialOwner)` line (the drainer's behaviour is the subject, not which error the store raised), and restore `0o644` at the end so the read-back assertion and `tearDown` are unaffected. Every other assertion in the case stays byte-for-byte.
   I **built and ran exactly that patch** in the isolated copy: `WorkCaptureDrainerTests` `Executed 9 tests, with 0 failures (0 unexpected) in 0.424 (0.429) seconds` and `WorkCaptureDrainerDurabilityTests` `Executed 5 tests, with 0 failures`. The script that applies it is `…/scratchpad/drainer_test_patch.py` (its `PATH` points at `ctree` — **repoint it before use**). I did not touch the file in the shared tree because it is not mine.
   If you would rather retire the case than rewrite it: `WorkCaptureDrainerDurabilityTests.testAPendingSyncedCardBlocksAcknowledgementAndKeepsTheQueueCopy` already asserts claim-released + `pendingCount == 1` + byte-identical queue copy through the import hold. It does not assert "the card written before the failure stays", which is the half only this case carries.

2. **Codex / adjudicator — read §3.** Finding #1's fix closes the interleaving the finding describes and leaves one adjacent interleaving open (A publishes, is suspended, B adopts A's row and commits, A rolls back its own row and strands B's card). I list the three narrower guards I rejected and why each is worse. If you want it closed, the shape is "an adopting caller must not depend on a row it did not write", which is a mechanism change rather than a rollback-scope change.

3. **Nobody re-narrow the desk capture's owner rule back to a refusal.** `upsertDeskMaterial` adopting a legacy-owned id is what makes an upgrade replay terminate; `testAMaterialUnderALegacyOwnerIsAdoptedByAnExplicitRecapture` and `testAPartiallyDrainedPreRewriteEnvelopeReplaysCleanOntoTheDesk` both fail if it is restored. And nobody turn adoption into a background sweep or a launch migration — the constraint and its reason are at the block.

4. **Nobody drop `replaceWorkMaterialPayloadFile`'s all-rows loop back to `workMaterialRow(id:)`.** Blob deletion there is scoped to the LOGICAL material id, so a single-row write leaves a duplicate claiming a payload the same save deleted. `testReattachWritesEveryDuplicateRowSoNoneResurrectsTheOldLane` fails if it is narrowed. Note it also gained an `invalidMaterialOwner` refusal for rows that disagree about their owner — that is new behaviour on a public method, though unreachable from the desk UI (every card the reattach sheet can reach is desk-owned by then).

5. **`WorkboardLiveRepository.swift:535-537`** still carries the comment blob-io.md §Requests 4 flagged as half false ("Reattachment replaces local bytes and metadata only… the board renders previews from the vault"). Still owed, still not mine — I did not open that file.

6. **Docs agent — two facts are now settled by code.** (a) A material a build before the single desk parked under a per-capture owner row is re-homed onto the desk by an explicit re-capture of that id; the owner row it came from is kept and never deleted. (b) A repeat of a Chat → Work capture republishes every attachment whose bytes the device still holds, so a card whose payload never landed is repaired rather than reported as already captured.

7. **Orchestrator — expect +6 on the iOS executed count** from this slice (`WorkboardBlobPublicationTests` 12→15, `WorkboardChatCaptureTests` 5→7, `WorkboardDeskUpsertTests` 10→11). Measured full-suite total with the wave's other in-flight work in the tree: **4810 executed, 1 skipped**. The only failing case is §Requests 1's.
