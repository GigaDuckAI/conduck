# d-store — r4s#1/#2/#3. All three CONFIRMED and fixed; nothing refuted. Counterfactual MEASURED.

Parallel phase. No commits/pushes/stash/checkout, no index operations.
`Identity-Override.xcconfig` untouched. **No `.xcstrings` opened**, no `.pbxproj` edit, no mirror
triplet touched, nothing under `docs/qa/desk-cloudkit/` touched. No file outside my ownership list
edited.

Files changed (9) — 3 production edited, 1 model version edited, 5 owned tests edited, 1 new test file:

- `Conduck/Conduck/Models/Conversations.xcdatamodeld/Conversations 16.xcdatamodel/contents`
  (+1 line: `WorkMaterial.contentHash`, optional String, no default — model 16 has never shipped)
- `Conduck/Conduck/Models/WorkboardRecords.swift` (+`WorkMaterialBlobPairing`,
  +`WorkMaterialRecord.contentHash`)
- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (the bulk)
- tests: `WorkboardDeskUpsertTests` 15→16 · `WorkboardBlobPublicationTests` 21→22 ·
  `WorkboardAvailabilityTests` 10→11 · `WorkboardBlobGCTests` 6→6 · `WorkboardModelMigrationTests`
  6→6 (one case renamed + extended) · `WorkCaptureDrainerTakeoverTests` (one call site) ·
  **NEW** `Conduck/ConduckTests/WorkCaptureDrainerCollisionTests.swift` (1)
- `Conduck/Conduck/Services/ConversationStore.swift`: **NOT TOUCHED.** Nothing in this slice needed a
  new seam or a store-description change.

**HEADLINE.** iOS `** TEST BUILD SUCCEEDED **` (0 `: error: `) · my 15-class VERIFY set
`Executed 129 tests, with 0 failures` · **full iOS suite `Executed 4948 tests, with 1 test skipped and
0 failures`** · signed macOS `** BUILD SUCCEEDED **` · watchOS `** TEST BUILD SUCCEEDED **` ·
**counterfactual: 6 distinct cases fail on a tree with the three mechanisms reverted, 22 assertions,
and NO pre-existing case failed** (§4).

---

## 1. r4s#1 — a desk-owned colliding row of another KIND bypassed every gate. CONFIRMED, fixed.

**Verified by call path before writing anything.** In `publishWorkMaterial`'s transaction the only
kind check lived inside `requireAdoptable`, and `requireAdoptable` ran only in the
`owners != [ownerID]` branch — so when the colliding row was already on the DESK the write fell
straight through to the idempotent-replay path. Two consequences, and the finding names the milder one:

1. `upsertDeskMaterial` answers the caller with the OTHER card. The drainer's barrier samples that
   card's `hasPayload`, passes, and `acknowledge` deletes the queue's only copy of the shared file.
2. **Worse, and not in the finding:** with the colliding card on the SYNCED lane, `repairLane`
   resolves to `.syncedPayload` for any bytes inside the ceiling, so the colliding capture STAGES —
   `publishWorkMaterialBlob` writes its bytes, `deleteSupersededBlobRows` retires the standing card's
   blob, and `pointAtSyncedPayload` repoints the card. The person loses the card they had, not merely
   the one they were making. Measured, not argued — §4, CF row 1: the drain reports success, the queue
   payload file is gone (`"[]" is not equal to "[43 bytes]"`), and the screenshot card's payload reads
   back as the arriving file's bytes.
   On the vault lane the same staging overwrites the standing card's leaf on disk, because a vault key
   is derived from the material id — which is why the refusal has to come BEFORE staging.

### The fix

- **`static func requireMatchingKind(materialRows:kind:)`** (new, `ConversationStore+Workboard.swift`)
  — throws `invalidMaterialOwner` unless EVERY physical row's `kind` column equals `draft.kind`,
  whoever owns the row. Called in the transaction immediately after `workMaterialRows(id:)`, before the
  owner branch.
- **A pre-staging refusal in `publishWorkMaterial`**, on `existing.kind != draft.kind`, sited between
  the `fetchWorkMaterial` read and the repair/staging decision. The transaction check is the
  authoritative one (it sees every physical row); this one is what stops a colliding capture from
  writing bytes over the standing card's leaf or blob before the transaction can refuse.
- **The kind check moved OUT of `requireAdoptable`** rather than being duplicated. It is not a property
  of adoption — a colliding id is a collision under any owner — and stating it twice is how a read path
  and a write path start disagreeing. `requireAdoptable`'s doc now says where it lives; behaviour for a
  foreign row is unchanged (same error, from a strictly wider gate), and
  `testAdoptionIsRefusedWhenTheParkedRowIsADifferentKindOfCard` still passes untouched.

**Regression tests.**
`WorkboardDeskUpsertTests.testADeskCardOfAnotherKindSharingAMaterialIdIsRefusedRatherThanAnswered` —
a synced `.image` card on the desk, then a `.file` capture at the same id: the call throws
`invalidMaterialOwner`, the desk still holds exactly one card, it is still the image, still `.synced`,
its payload still reads back as its own bytes, and the blob store still holds exactly its hash.
`WorkCaptureDrainerCollisionTests.testACaptureCollidingWithACardOfAnotherKindLeavesItsBytesQueued`
(new file) — the same collision through the REAL drainer and a real inbox directory: the drain throws,
and the assertion that matters is that `payload-000.bin` is still on disk under the inbox root with
its bytes intact. *Measured on the reverted tree:* the drain succeeds, the queue file is gone, and the
image card's payload is the arriving file (§4).

## 2. r4s#2 — a blob could be adopted that a peer can still roll back. CONFIRMED, fixed as decided.

**Verified:** `publishWorkMaterialBlob` returned `.alreadyPresent` for ANY complete blob whose
`(contentHash, byteSize)` matched, and `newestCompleteBlobPayload` / the availability projection
selected the newest complete row under the material id regardless of what the card said. Blob rows and
material rows mirror through CloudKit independently, so a peer's blob can land here alone; the
publisher's own rollback (`deleteBlobRow`, object-id scoped — correct as it stands) then deletes it and
exports the deletion. The App-Group `flock` is per-filesystem and reaches none of this. Confirmed.

### THE PAIRING INVARIANT — stated once, at `WorkMaterialBlobPairing`, verbatim

> THE PAIRING INVARIANT: a material row records the `contentHash` and `byteSize` of the exact bytes it
> was published with, and a blob answers for that material only when both match — so a blob is adopted,
> read, or counted as present for a card only when some publication of exactly those bytes completed
> against that card.

### What that took

| Where | Change |
|---|---|
| model 16 | `WorkMaterial.contentHash`, optional String, **no default** — additive, lightweight, and 16 has never shipped so no new version was minted |
| `WorkboardRecords.swift` | `WorkMaterialBlobPairing { contentHash: String?; byteSize: Int64; func names(_:) }` — the rule lives in `names`, and adoption, selection and availability all ask it there. `WorkMaterialRecord.contentHash` (defaulted `nil` in the memberwise init, so no foreign call site moved) |
| write | `apply(_ draft:…)` gains `contentHash:` and writes it on the synced lane only; `pointAtSyncedPayload(row:contentHash:byteSize:at:)` writes it; `pointAtLocalVault` CLEARS it |
| adopt | `publishWorkMaterialBlob` returns `.alreadyPresent` only when `workMaterialRowNames(pairing, materialID:)` (new, one `.dictionaryResultType` fetch over `storageMode`/`contentHash`/`byteSize`, never `payload`) AND a complete MATCHING blob both hold; otherwise it inserts its own row |
| select | `newestCompleteBlobPayload(materialID:pairedWith:)`; `loadWorkMaterialPayload` reads the row's pairing and passes it |
| availability | `workMaterialBlobCompleteness(materialIDs:pairedWith:)` — same ONE metadata fetch, now filtered by `pairing.names`; `workMaterialRecords(for:)` builds the pairing map off `StoredWorkMaterial.contentHash` (`uniquingKeysWith`, because one id can appear under two owners mid-adoption) |
| restore | `WorkMaterialRowSnapshot` carries `contentHash` and exposes `pairing`; `restoreReplacedPayload` proves the blob each prior ROW named, not merely that some blob exists |

**Duplicate blob rows are now an accepted state** and are stated as such at
`publishWorkMaterialBlob`. They cost one bounded extra copy until the card is deleted; paired deletion
takes both, `deleteSupersededBlobRows` retires the ones carrying other bytes, and the reads resolve
newest-among-matching.

**A nil `contentHash` falls back to newest-complete**, per the design direction. It is unreachable in
production (nothing has shipped) and is what keeps a row written by the two-store topology seam, or by
any pre-pairing writer, readable rather than permanently pending.

**Regression tests.**
`WorkboardAvailabilityTests.testANewerBlobCarryingOtherBytesIsNotThisCardsPayload` — a peer's newer
complete blob does not become the card's payload, and once the card's OWN blob is gone the card reads
`.syncedPending` rather than quietly serving the peer's bytes ·
`WorkboardBlobPublicationTests.testABlobNoCardNamesIsNotAdoptedByTheReplayThatFindsIt` (the rewrite of
`testABlobLeftByACrashIsAdoptedByTheReplayRatherThanDuplicated`, whose asserted behaviour this
finding overturns) — the replay writes its own row, the stranded row survives, both carry the same
bytes, and a SECOND replay adopts and writes nothing, so the duplication is bounded at one ·
`testDuplicatesOfTheNamedBytesResolveNewestFirstAndOtherBytesNeverWin` (the rewrite of
`testDuplicateBlobsResolveToTheNewestCompleteRow`) — newest-first holds AMONG the rows the card names ·
`testAPayloadUnderTheCeilingBecomesABlobTheCardNamesButDoesNotHold` and
`testReattachingASmallFileMovesACardOffTheVaultOntoTheSyncedLane` gain the write half (every physical
row names the blob; a reattach onto the synced lane names the blob it arrived with) ·
`testARefusedPublicationLeavesAnIdenticalBlobItDidNotWrite` and
`testARefusedReattachTakesBackOnlyTheBlobRowItWrote` were re-staged to carry bytes no row already
holds, so they genuinely exercise the object-id rollback again (under the old adoption rule they
would have adopted and rolled nothing back) · `WorkboardModelMigrationTests`
`testV16AddsTheBlobEntityTheMaterialPairingAndTwoCloudKitConfigurations` pins the added column, its
type/optionality/absent default, that `WorkMaterial`'s versionHash MOVED and every other entity's did
not, and `testV15SQLiteReopensAsCoreInV16BesideAWritableBlobStore` pins that lightweight migration
leaves `contentHash` nil and that the pairing survives close-and-reopen.

## 3. r4s#3 — the post-confirmation cleanup deleted every blob of the material. CONFIRMED, fixed.

**Verified:** `retireReplacedBlobRows(materialID:)` called `deleteBlobRows(materialID:in:)`, a
predicate delete over `materialID ==`. It runs AFTER the vault confirmation, i.e. after a window in
which CloudKit can deliver a peer's republication — which would be deleted here, and the deletion
exported, leaving the peer's card permanently `.syncedPending`.

**Fix.** The swap's transaction now names the rows the card is being taken off:
`blobRows(materialID:in:)` + `context.obtainPermanentIDs(for:)`, carried out in a new
`WorkMaterialReattachSwap` alongside `oldVaultKeys` and `priorRows`.
`retireReplacedBlobRows(_ rowIDs: [NSManagedObjectID])` deletes exactly those by
`existingObject(with:)`. Nothing is ever refetched by material id after the confirmation. The
permanent-id call is load-bearing: a row inserted in the same context would otherwise carry a temporary
id that `existingObject` cannot resolve afterwards.

**Regression test.**
`WorkboardBlobPublicationTests.testABlobImportedDuringTheConfirmationWindowIsNotRetiredWithTheOldOnes`
— a synced card, a reattach of a zero-byte file (the lane change that triggers the retirement), and
the `publicationConfirmationHookForTesting` seam inserting a peer's blob row at exactly the moment
between the swap's commit and the proof of the new leaf, then returning nil so the REAL confirmation
runs. Asserted: the card ends `.localVault` naming no blob, and the payload store holds exactly the
row that arrived inside the window. *Measured on the reverted tree:* `"[]"` — the peer's arrival is
deleted.

## 4. The counterfactual — MEASURED, in an isolated copy

`~/Library/Caches/gigaduck-builds/d-store/cf-tree`, an rsync snapshot with its `Identity-Override`
symlink re-pointed at the same real file. **Nothing in the worktree was touched for this.** One
variant, reverting all three mechanisms in the copy's PRODUCTION files only (tests untouched): the two
kind gates removed and the kind check put back inside `requireAdoptable`; `publishWorkMaterialBlob`
back to blob-only adoption, `WorkMaterialBlobPairing.names` back to `true`, and both writers of
`contentHash` back to nil; the retirement back to a delete by material id. The model version was NOT
reverted — a schema column is not a mechanism, and reverting it would have failed the migration tests
for a reason unrelated to the defects.

`cf-bft-1.log` → `** TEST BUILD SUCCEEDED **`, 0 errors. `cf-test-1.log` → `** TEST EXECUTE FAILED **`:

| Class | Result on the reverted code |
|---|---|
| `WorkCaptureDrainerCollisionTests` | `Executed 1 test, with 3 failures` |
| `WorkboardDeskUpsertTests` | `Executed 16 tests, with 3 failures` |
| `WorkboardAvailabilityTests` | `Executed 11 tests, with 4 failures` |
| `WorkboardBlobPublicationTests` | `Executed 22 tests, with 12 failures` |
| `WorkboardBlobGCTests` · `WorkboardTwoStoreLoadTests` · `WorkboardModelMigrationTests` · `WorkboardChatCaptureTests` · `WorkCaptureDrainerTests` · `WorkCaptureDrainerDurabilityTests` · `WorkboardPersistenceTests` · `ConversationStoreAtomicWorkCaptureTests` · `WorkboardPublicationLockTests` · `WorkCaptureDrainerTakeoverTests` | **0 failures each** |

**Six distinct cases fail, every one of them a case I added or rewrote, and NO pre-existing case
failed.** Verbatim lines (elided where long):

```
testACaptureCollidingWithACardOfAnotherKindLeavesItsBytesQueued : failed - a capture that cannot publish its card must not report an import
testACaptureCollidingWithACardOfAnotherKindLeavesItsBytesQueued : XCTAssertEqual failed: ("[]") is not equal to ("[43 bytes]") - an unpublished capture's bytes may not be deleted from the queue
testACaptureCollidingWithACardOfAnotherKindLeavesItsBytesQueued : XCTAssertEqual failed: ("Optional(43 bytes)") is not equal to ("Optional(37 bytes)") - the arriving capture's bytes must never become the standing card's payload
testADeskCardOfAnotherKindSharingAMaterialIdIsRefusedRatherThanAnswered : failed - a file capture must not be answered with an image that shares its id
testADeskCardOfAnotherKindSharingAMaterialIdIsRefusedRatherThanAnswered : XCTAssertEqual failed: ("Optional(46 bytes)") is not equal to ("Optional(34 bytes)") - the colliding capture's bytes must never become another card's payload
testANewerBlobCarryingOtherBytesIsNotThisCardsPayload : XCTAssertEqual failed: ("Optional(47 bytes)") is not equal to ("Optional(26 bytes)") - the card opens the payload its own row names, not the newest row under its id
testANewerBlobCarryingOtherBytesIsNotThisCardsPayload : XCTAssertEqual failed: ("…synced") is not equal to ("…syncedPending") - a complete blob that is not the one this card names proves nothing about it
testABlobNoCardNamesIsNotAdoptedByTheReplayThatFindsIt : XCTAssertEqual failed: ("1") is not equal to ("2") - no card named those bytes, so the publication wrote a row of its own
testDuplicatesOfTheNamedBytesResolveNewestFirstAndOtherBytesNeverWin : XCTAssertEqual failed: ("Optional(40 bytes)") is not equal to ("Optional(23 bytes)") - the card opens the payload its own row names
testABlobImportedDuringTheConfirmationWindowIsNotRetiredWithTheOldOnes : XCTAssertEqual failed: ("[]") is not equal to ("[…]") - The retirement took the rows the swap found and only those.
testAPayloadUnderTheCeilingBecomesABlobTheCardNamesButDoesNotHold : XCTAssertEqual failed: ("[]") is not equal to ("[…]") - every physical row names the blob
testARefusedPublicationLeavesAnIdenticalBlobItDidNotWrite : XCTAssertEqual failed: ("Optional(49 bytes)") is not equal to ("Optional(30 bytes)") - the refused replay changed nothing, so the card still opens the bytes it named
```

The first block is r4s#1 reproduced end to end THROUGH THE DRAINER: the queue's only copy of the
shared file is deleted and the standing card's payload is replaced.

## Guard verdicts

**None assigned, none converted, none deleted, none weakened.**
`WorkboardAvailabilityTests.testTheAvailabilityProjectionNeverNamesThePayloadColumn` was left exactly
as it stands and passes — the completeness fetch still projects
`materialID`/`byteSize`/`contentHash`/`updatedAt` and never `payload`, and the new parameter did not
move the `propertiesToFetch` block out of the window that guard reads.

## Catalog

**Keys I ADDED in source: NONE.** Every change here is headless: a refused collision throws
`WorkboardStoreError.invalidMaterialOwner`, whose `errorDescription` is deliberately nil (an internal
invariant failure has no user action), and the pairing is a storage fact with no surface. The pending
chip keeps reusing `workboard.material.syncPending`.

**Keys I made DEAD: NONE.** I deleted no code carrying a key.

**No `.xcstrings` file was opened** (`git status --short -- '*.xcstrings'` empty).

## Decisions

1. **The kind gate is stated once, wider, rather than duplicated** (§1). It moved out of
   `requireAdoptable` into `requireMatchingKind`, which every publication runs for every physical row.
   Keeping a copy inside adoption would have meant two places to keep in step for one rule.
2. **Refuse the collision rather than mint a derived id inside the store.** The store cannot invent an
   identity for a caller — the caller's id IS its replay key — so the honest answer is a throw the
   caller can act on. It is also what keeps the drainer's queue copy: any throw leaves the claim
   unacknowledged. The voice lane already derives its own ids for exactly this reason
   (`fallbackNoteID(forCapture:)`, `WorkVoiceScreenshotCoordinator.materialID(forCapture:)`), and those
   lanes are unaffected.
3. **One completeness entry point, with the pairing as a parameter** (§2). `pairedWith: [:]` means "no
   card names these bytes", which is a real question two tests ask (a stranded blob, an emptied store);
   a second function would have been a second place to state completeness, which `availability.md`
   §Requests 5 forbids.
4. **`.alreadyPresent` needs BOTH halves** — a material naming the bytes and a complete matching blob.
   Requiring only the first would re-insert nothing when the payload store was lost; requiring only the
   second is the defect.
5. **No new test seam.** I dropped a planned case that would have needed a
   `_setWorkMaterialKindColumnForTesting` seam to stage a row whose kind this build cannot name. The
   transaction check compares the RAW column, so the tolerance direction is argued rather than
   measured; a seam wider than the rest of the suite needs is not worth the surface.
6. **`WorkMaterialRecord.contentHash` is defaulted `nil` in the init** so no call site outside my
   ownership moved (there is one, in `WorkboardLiveRepositorySupportTests`).
7. **No Codex consult.** The one genuinely hard call — whether adoption could stay legal for a blob
   this device itself wrote — is settled by the code: nothing distinguishes that row from a peer's
   import once it is on disk, which is the finding's whole point.

## Deviations

- **`ConversationStore.swift` is untouched**, though my ownership allowed seams and store
  descriptions there. Nothing needed one.
- **The model file gained a column on `WorkMaterial`**, which the previous
  `testV16AddsOnlyTheBlobEntityAndTwoCloudKitConfigurations` asserted could not happen. That case is
  renamed and extended, not weakened: it now pins the added column by name, type, optionality and
  absent default, and pins that exactly one entity's versionHash moved.
- **Two rewritten cases assert the opposite of what they asserted before** —
  `testABlobLeftByACrashIsAdoptedByTheReplayRatherThanDuplicated` (adoption of a stranded blob) and
  the newest-wins half of `testDuplicateBlobsResolveToTheNewestCompleteRow`. Both encoded the
  behaviour r4s#2 overturns; each is replaced by a case that fails on the old code, and the doc
  comments say what changed and why.
- **`deleteSupersededBlobRows` is unchanged.** It still deletes complete rows carrying OTHER bytes
  inside the publishing transaction, which can in principle delete a peer's republication whose own
  material update has not landed. That is the plan's decided shape ("a replayed material with
  mismatching hash/size — replace blob, paired"), it is inside a transaction the publisher owns rather
  than in a post-hoc cleanup, and narrowing it was not in my brief. Recorded under §Requests 3 as the
  one place the same class of hazard is knowingly accepted.

## Gates — WHAT I ACTUALLY RAN

Slug `d-store`. DerivedData under `~/Library/Caches/gigaduck-builds/d-store/{DerivedData,
DerivedDataMac,DerivedDataWatch,DerivedDataCF,cf-tree}`, every log written there and grepped for
`': error: '` and the verdict strings — never judged from a tail or an exit code. **No
`-configuration` passed anywhere.** Sim `C26F4ECE-16AC-40B7-8D6A-BBF82B5BBA5D`; its TCC table was
checked first (`kTCCServiceUbiquity|ai.gigaduck.AgentRelay|2` — no denial row, nothing to reset).

- **iOS `build-for-testing`** → `bft-3.log` (final, after the wave's other agents landed):
  `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
- **My 15-class VERIFY set**, `test-without-building`, one quoted `-only-testing:` per class →
  `test-1.log`: `** TEST EXECUTE SUCCEEDED **`, `Executed 129 tests, with 0 failures (0 unexpected)`.

| Class | Result |
|---|---|
| `WorkboardBlobPublicationTests` | `Executed 22 tests, with 0 failures` (was 21) |
| `WorkboardDeskUpsertTests` | `Executed 16 tests, with 0 failures` (was 15) |
| `WorkboardAvailabilityTests` | `Executed 11 tests, with 0 failures` (was 10) |
| `WorkCaptureDrainerCollisionTests` | `Executed 1 test, with 0 failures` (new) |
| `WorkboardBlobGCTests` | `Executed 6 tests, with 0 failures` |
| `WorkboardTwoStoreLoadTests` | `Executed 7 tests, with 0 failures` |
| `WorkboardModelMigrationTests` | `Executed 6 tests, with 0 failures` |
| `ConversationsModelMigrationTests` | `Executed 20 tests, with 0 failures` |
| `WorkboardPublicationLockTests` | `Executed 2 tests, with 0 failures` |
| `WorkCaptureDrainerTakeoverTests` | `Executed 1 test, with 0 failures` |
| `WorkboardChatCaptureTests` | `Executed 8 tests, with 0 failures` |
| `WorkCaptureDrainerTests` | `Executed 10 tests, with 0 failures` |
| `WorkCaptureDrainerDurabilityTests` | `Executed 8 tests, with 0 failures` |
| `WorkboardPersistenceTests` | `Executed 7 tests, with 0 failures` |
| `ConversationStoreAtomicWorkCaptureTests` | `Executed 4 tests, with 0 failures` |

- **FULL iOS suite** → `ios-full-2.log`: `** TEST EXECUTE SUCCEEDED **`,
  `Executed 4948 tests, with 1 test skipped and 0 failures (0 unexpected) in 78.380 (79.889) seconds`.
  0 compile-error anchors, 0 XCTest-failure anchors. The single skip is the environment-conditional
  `GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`. I ran the full
  suite because my file is on every capture path.
  **An EARLIER full run (`ios-full-1.log`) had 3 failures, all caused by my change in files I do not
  own** — see §Requests 1. They are gone in `ios-full-2.log`: the agent owning those files adapted
  them to the refusal while I was running.
- **macOS `build -destination 'platform=macOS'`** → `mac-1.log`: 0 `: error: `,
  `** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`.
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed.**
- **watchOS `build-for-testing`** (`-scheme ConduckWatchTests`, sim
  `28AC563B-42C1-4E66-940D-77E63B07918B`) → `watch-bft-1.log`: 0 `: error: `,
  `** TEST BUILD SUCCEEDED **`. Run because `WorkboardRecords.swift` and the `.xcdatamodeld` are Watch
  target members. **I did not RUN the watch suite** — it is not in my VERIFY and no watch sim is
  assigned to me for running.
- **Counterfactual** → `cf-bft-1.log` (`** TEST BUILD SUCCEEDED **`, 0 errors), `cf-test-1.log`
  (`** TEST EXECUTE FAILED **`); table and verbatim lines in §4.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 798 Swift files scanned…`, exit 0.
- `git diff --check` → clean, exit 0. `git status --short` for `*.xcstrings`, `*.pbxproj`,
  `Conduck/Configs`, `docs/qa` → **empty**.
- **Model-16 registration re-proven**: `WorkboardModelMigrationTests` loads `Conversations 16.mom`
  out of the COMPILED `Conversations.momd` and its added-column assertion passes, so the new attribute
  is in the built model. **No `project.pbxproj` edit** (the synchronized group covers the
  `.xcdatamodeld`, as model 16 itself established).
- **Build caches, the isolated copy and every log removed at end of task** with
  `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh d-store`. Re-run if the
  integrator needs the logs.

### Suite delta for the orchestrator

**+4 iOS executed** from this slice: `WorkboardDeskUpsertTests` 15→16, `WorkboardBlobPublicationTests`
21→22, `WorkboardAvailabilityTests` 10→11, `WorkCaptureDrainerCollisionTests` 0→1. Measured full-suite
total with the whole wave's in-flight work in the tree: **4948 executed, 1 skipped, 0 failures.**

### What I did NOT verify, plainly

- **The watch SUITE** (built, not run) — not my VERIFY, no watch sim assigned for running.
- **Anything across two real devices.** The pairing exists for a CloudKit ordering no headless test can
  produce; every cross-device state here is staged through the blob-row seam. §Founder QA.
- **The pairing under a real CloudKit merge of two material rows naming different blobs.** The
  projection handles it (per-row pairing, `uniquingKeysWith`), but only a device can produce it.

## Requests

1. **Whoever owns `WorkboardVoiceLaneTests.swift` and `WorkboardAudioCaptureTests.swift` — ALREADY
   DONE, recorded in case of a rebase.** Three cases asserted the pre-fix collision behaviour and
   failed against my change; they now assert `WorkboardStoreError.invalidMaterialOwner` and are green
   (`WorkboardVoiceLaneTests` 11/0, `WorkboardAudioCaptureTests` 19/0 in `ios-full-2.log`). The cases
   are `testAScreenshotPublishedAtTheCaptureIdIsRefusedRatherThanBecomingTheRecording` (renamed from
   `…WouldReplaceTheRecordingsBytes`), `testTheFallbackNoteLandsBesideTheRecordingRatherThanVanishing
   IntoIt`, and `testTheFallbackNoteIdIsDerivedFromTheCaptureAndCannotCollideWithIt`. **The derived
   ids they justify are still required** — without them the recovery lanes would now FAIL instead of
   silently landing on the wrong card, which is a worse outcome for the person, so nobody should read
   the refusal as making `fallbackNoteID` / `materialID(forCapture:)` redundant.
2. **Nobody weaken the collision gate to "same owner" or "canonical row only".** The desk-owned case
   IS the defect, and the transaction checks every physical row because a CloudKit-merged duplicate
   carrying another kind is the same collision. Two cases fail if either is narrowed.
3. **Nobody make `.alreadyPresent` depend on the blob alone again**, and nobody "tidy up" the
   duplicate rows a publication now writes when no card names the bytes. That duplication IS the fix.
   The one place the same hazard class is knowingly accepted is `deleteSupersededBlobRows` inside the
   publishing transaction (§Deviations); if a later round wants that closed too, the shape is to skip
   rows whose `updatedAt` is newer than this publication's own material read — not a sweep.
4. **Nobody refetch the reattach's cleanup candidates by material id.** `retireReplacedBlobRows` takes
   permanent object ids sampled inside the swap, and `context.obtainPermanentIDs(for:)` is what makes
   them resolvable afterwards.
5. **Docs agent — see §Settled facts.**
6. **Founder QA (Gate 2) — see §Founder QA.** All three items are two-device and none is reachable by
   a unit test.

## Refuted

**Nothing.** r4s#1, r4s#2 and r4s#3 all held against the current tree when traced by call path before
any edit, and all three mechanisms are shown red on the reverted tree (§4). The DESIGN DIRECTION for
r4s#2 was implementable as written: the column is additive, the migration is lightweight, and the
selection rule fits the one completeness fetch that already existed.

One clause of r4s#1 is UNDERSTATED rather than wrong, and I say so in §1: the finding describes the
capture being dropped, but on the synced lane the colliding publication also replaces the standing
card's payload and retires its blob. Both are measured in §4.

## Founder QA

Two signed devices on one iCloud account, byte sync enabled (Gate 2).

1. **Blob-before-material, and the rollback behind it.** On device A, capture a small file into Work
   with the app FORCE-QUIT immediately after the progress bar completes (the window between the two
   saves). On device B, wait for the card to appear. Expected: B either shows no card at all, or shows
   the card and opens it — never a card that says "Waiting for iCloud…" for ever. Then re-capture the
   same file on A and confirm B ends with ONE card that opens.
2. **A reattach while the other device is republishing.** On device A, open a Work card whose payload
   syncs and reattach a LARGE file (over 30 MB, so the card leaves the synced lane). While that runs,
   on device B reattach a small file onto the same card. Expected: both devices settle on one card
   that opens on each of them, and neither ends up showing "Waiting for iCloud…" permanently.
3. **A colliding capture is refused, not silently swallowed.** Not directly reachable by hand (ids are
   deterministic per capture), so the proxy: record a Work voice note, let the transcription FAIL
   (airplane mode), then use the retry from the menu bar. Expected: the recording card is still there
   and still plays, and the recovered words appear either on that card or as a NOTE beside it — never
   a card that lost its audio, and never a silently discarded transcript.

## Settled facts

- A material's row records the content hash and byte size of the exact payload it was published with,
  and a payload blob answers for that card only when both match — so bytes arriving from another
  device are never adopted as a card's payload until that card's own publication of them completed.
- A card that names synced bytes shows as waiting for iCloud until the blob it names is here whole; a
  complete blob that is not the one it names proves nothing about it.
- Two blob rows carrying identical bytes for one card are a normal, bounded state: a publication that
  cannot prove a card already named those bytes writes its own copy rather than trusting one it found.
- A capture whose identifier already names a card of a different kind is refused outright — nothing is
  written, the standing card keeps its bytes, and a share queue keeps its copy for a later retry.
- A reattach that moves a card off the synced lane releases exactly the payload rows the card was on,
  and never one that arrived from another device while the replacement was being proved.
- Model 16 carries one added column on `WorkMaterial` (`contentHash`); it is optional with no default,
  so an existing card migrates naming no blob and is repaired by its next publication.
