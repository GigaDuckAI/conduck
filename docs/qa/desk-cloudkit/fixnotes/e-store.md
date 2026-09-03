# e-store — r5s#1 CONFIRMED and fixed, r5s#4 CONFIRMED as a doc defect and corrected. Nothing refuted. Counterfactual MEASURED.

Parallel phase. No commits/pushes/stash/checkout, no index operations.
`Identity-Override.xcconfig` untouched (only re-pointed inside my own throwaway copy).
**No `.xcstrings` opened**, no `.pbxproj` edit, no mirror triplet touched, nothing under
`docs/qa/desk-cloudkit/` touched. No file outside my ownership list edited.

Files changed (3) — 1 production edited, 1 owned test edited, 1 new test file:

- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (+86/−8)
- `Conduck/ConduckTests/WorkboardBlobPublicationTests.swift` (22→22; two doc comments corrected,
  no assertion moved)
- **NEW** `Conduck/ConduckTests/WorkboardSyncedRowRepairTests.swift` (3 cases)
- `Conduck/Conduck/Models/WorkboardRecords.swift`: **NOT TOUCHED.** The record shape forced nothing —
  `WorkMaterialRecord.contentHash` and `WorkMaterialBlobPairing` already carry everything this fix
  needed, and the repair reads raw COLUMNS rather than records because it works inside the write
  transaction.

**HEADLINE.** iOS `** TEST BUILD SUCCEEDED **` (0 `: error: `) · my 10-class VERIFY set
`Executed 94 tests, with 0 failures` · **full iOS suite `Executed 4957 tests, with 1 test skipped and
0 failures`** · signed macOS `** BUILD SUCCEEDED **` · **counterfactual: the new case fails with 7
assertions on a tree with the mechanism reverted, and NO other case in the 10-class set failed** (§3).

---

## 1. r5s#1 — a replay with complete matching bytes could leave a physical row permanently `syncedPending`. CONFIRMED, fixed.

**Verified by call path before writing anything**, in the order the finding states it:

1. `publishWorkMaterialBlob` (now `:1139`) short-circuits to `.alreadyPresent` when
   `workMaterialRowNames(pairing, materialID:)` is true AND a complete matching blob exists.
   `workMaterialRowNames` (`:1189`) returns true when **ANY** physical row names the staged pairing —
   `for row in try context.fetch(request) { … return true }`. So one agreeing row is enough.
2. In the transaction's repair branch, `repaired` became true only for `case .inserted = publishedBlob`
   or `superseded > 0` (HEAD `f794856:804-807`), and `pointAtSyncedPayload` ran only
   `if repaired` (`:809-817`).
3. `deleteSupersededBlobRows` (`:1359`) deletes only rows that are **complete** and carry OTHER bytes
   (`guard let record = blobRecord(of: row), record.isComplete` … `record.contentHash != contentHash
   || record.byteSize != byteSize`). A blob that never ARRIVED is not a row, so it can never be counted
   as superseded.

The reachable state, end to end: device A publishes bytes B (row names `H(B)`, blob `H(B)` lands here);
device B publishes different bytes under the same material id; CloudKit merges its material row here
but its blob does not arrive. Two physical rows, one naming `H(B)`, one naming a hash with no blob.
`workMaterialRow(id:)` and `deduplicatedWorkMaterials` are both newest-`updatedAt`-wins (`:2670`,
`:2522`), so the merged row is the canonical one; `workMaterialRecords(for:)` builds the pairing off
that row (`:2410`, `uniquingKeysWith`), the completeness fetch finds no blob it names, and the card
reads `.syncedPending`. A replay carrying exactly the bytes that ARE here then repairs nothing: its
blob is present so nothing is inserted, and the absent blob cannot be retired so nothing is superseded.
`repaired` stays false, `context.save()` is skipped, and the disagreement survives every replay for
ever. **Measured, not argued** — §3.

### The fix, as the design direction specifies it

`ConversationStore+Workboard.swift`, in `publishWorkMaterial`'s `.syncedPayload` repair branch:

```swift
let rowsDisagree = materialRows.contains { row in
    !Self.namesSyncedPayload(row: row, contentHash: contentHash, byteSize: staged.byteSize)
}
if case .inserted = publishedBlob { repaired = true }
else if superseded > 0 { repaired = true }
if rowsDisagree { repaired = true }
if repaired { for row in materialRows { Self.pointAtSyncedPayload(…) } }
```

plus a new `private static func namesSyncedPayload(row:contentHash:byteSize:)`, sited immediately
beside `pointAtSyncedPayload` because it is that writer's question read back: **lane, contentHash and
byteSize together**, which is exactly the comparison the finding asks for and exactly the pairing
`WorkMaterialBlobPairing.names` states from the blob side.

**It is ADDITIVE, deliberately.** The two existing triggers are kept rather than replaced by the row
comparison alone. A publication that inserted a blob or retired a superseded one has changed what the
card's bytes ARE, and repointing every row in that same save is the behaviour four existing cases
pin (`testAPayloadUnderTheCeilingBecomesABlobTheCardNamesButDoesNotHold`,
`testAReplayCarryingOtherBytesReplacesTheBlobPairedWithTheCard`,
`testACardWhosePayloadStoreWasLostIsIncompleteUntilAReplayRestagesIt`,
`testABlobNoCardNamesIsNotAdoptedByTheReplayThatFindsIt`). Narrowing to "disagreement only" would have
changed those and bought nothing.

**Regression tests** — `WorkboardSyncedRowRepairTests` (new file):

- `testAReplayRepairsARowNamingABlobThatNeverArrived` — the finding's exact scenario. A synced card;
  then a merged second row stamped 60 s newer, naming a hash whose blob is not here and a byteSize of
  its own. The BROKEN state is asserted first (one card, `.syncedPending`, `loadWorkMaterialPayload`
  nil) so the case pins the defect rather than assuming it. Then the replay with the SAME bytes, and:
  every physical row's `contentHash` is `hex(bytes)`, every row's `byteSize` is the payload's, every
  row's `storageMode` is `syncedPayload`, the card reads `.synced`,
  `WorkboardLiveRepository.presentationAvailability` reads `.available`, the payload loads back
  byte-for-byte, both rows survive (normalised, never deleted), and **exactly one blob row** exists —
  which is what proves the replay adopted rather than duplicating, i.e. that the repair really did
  happen with `.alreadyPresent` and nothing superseded. *Measured red on the reverted tree with 7
  assertions* (§3).
- `testAnIdenticalReplayOntoAgreeingRowsWritesNothing` — the control that keeps the new trigger from
  turning every replay into a write. Two AGREEING rows, an identical replay: both rows' `updatedAt`
  are unchanged and the blob store is untouched. Without it a wrong comparison (an `NSNumber`/`Int64`
  mismatch, say) would stamp both rows and export a CloudKit change on every drainer replay, and every
  other case would still pass. It passes on the reverted tree by construction and I say so.

## 2. r5s#4 (O-20) — the "duplicate blob rows are count-bounded" claim. CONFIRMED inaccurate, corrected in the doc comment. No sweep added.

**Verified.** `publishWorkMaterialBlob` inserts whenever it cannot prove a committed row names the
bytes, and no card exists to prove it until the material save commits — so a process dying between the
two saves strands a row, and the next attempt strands another (`:1146-1179` at HEAD). A refusal is
different: it takes its own row back by object id (`deleteBlobRow(rowID)`), which is why only a crash
or a jetsam accumulates. `deleteSupersededBlobRows` retains every row carrying the eventual matching
hash+size (`:1366-1370` at HEAD; `guard record.contentHash != contentHash || record.byteSize !=
byteSize else { continue }`). So the count is bounded by nothing arithmetic.

**What changed — a doc comment, no code.** The sentence at `publishWorkMaterialBlob` said "two rows
carrying identical bytes … are an accepted state … and paired deletion takes both". It now says the
accurate thing, in the finding's own terms: the bound is **persistence, not arithmetic** — one row per
attempt that died between the blob save and the material save, each at most the sync ceiling, retired
by the next publication or reattach putting DIFFERENT bytes on the card and by paired deletion when
the card goes — followed by a paragraph saying why no sweep may close it (a stranded attempt is
indistinguishable from a peer's blob imported ahead of its material).

The same inaccurate generalisation appeared twice in a test I own and is corrected there too, with no
assertion moved: `WorkboardBlobPublicationTests.testABlobNoCardNamesIsNotAdoptedByTheReplayThatFindsIt`
(its doc comment, and the inline "the duplication is bounded at one" — true of REPLAY, which is what
that case measures, and false of the state).

**A characterisation test, not a counterfactual, and I label it as such.**
`WorkboardSyncedRowRepairTests.testStrandedBlobsAccumulatePerAttemptUntilDifferentBytesRetireThem`
runs `_publishDeskMaterialBlobOnlyForTesting` three times (three crashes at the same step), then the
real publication, and pins **3 → 4 rows**, all carrying one hash; a replay adds none and retires none;
a publication of DIFFERENT bytes leaves **exactly 1**. It cannot fail on the old code — nothing about
this behaviour changed — and that is the point: it makes the corrected sentence checkable, so the
comment cannot drift back. It fails if anyone adds a sweep, loosens adoption, or widens the
retirement.

## 3. The counterfactual — MEASURED, in an isolated copy

`~/Library/Caches/gigaduck-builds/e-store/cf-tree`, an `rsync -a --delete` snapshot with its
`Identity-Override` symlink re-pointed at the same real file. **Nothing in the worktree was touched for
this.** One variant, reverting the mechanism in the copy's PRODUCTION file only (tests untouched): the
`rowsDisagree` computation and the `if rowsDisagree { repaired = true }` line removed, leaving the two
original triggers exactly as they were. `namesSyncedPayload` was left in place unused — the MECHANISM
is the trigger, and deleting a private helper would have been reverting the diff rather than the
behaviour.

`cf-bft-1.log` → `** TEST BUILD SUCCEEDED **`, 0 errors. `cf-test-1.log` → `** TEST EXECUTE FAILED **`:

| Class | Result on the reverted code |
|---|---|
| `WorkboardSyncedRowRepairTests` | `Executed 3 tests, with 7 failures (0 unexpected)` |
| `WorkboardBlobPublicationTests` | `Executed 22 tests, with 0 failures` |
| `WorkboardDeskUpsertTests` | `Executed 16 tests, with 0 failures` |
| `WorkboardAvailabilityTests` | `Executed 11 tests, with 0 failures` |
| `WorkboardBlobGCTests` | `Executed 6 tests, with 0 failures` |
| `WorkboardTwoStoreLoadTests` | `Executed 7 tests, with 0 failures` |
| `WorkCaptureDrainerCollisionTests` | `Executed 3 tests, with 0 failures` |
| `WorkCaptureDrainerTests` | `Executed 10 tests, with 0 failures` |
| `WorkCaptureDrainerDurabilityTests` | `Executed 8 tests, with 0 failures` |
| `WorkboardChatCaptureTests` | `Executed 8 tests, with 0 failures` |

**ONE case fails, it is the case I added for this finding, and NO pre-existing case failed.** Verbatim
lines:

```
testAReplayRepairsARowNamingABlobThatNeverArrived : XCTAssertEqual failed: ("syncedPending") is not equal to ("synced") - a replay carrying the bytes that are here must end the wait
testAReplayRepairsARowNamingABlobThatNeverArrived : XCTAssertEqual failed: ("Optional("e133494de32ba7d31efc0bae53c3ee1642c8affeed78a641ca491347620ac86c")") is not equal to ("Optional("4749ed6d7e8dfb4895c74c2f7f80b27b7eaabfab14b817fdec06afdfd76e03a2")")
testAReplayRepairsARowNamingABlobThatNeverArrived : XCTAssertEqual failed: ("["4749ed6d…", "e133494d…"]") is not equal to ("["4749ed6d…"]") - EVERY physical row names the bytes the card holds, or the next merge picks one that points at nothing
testAReplayRepairsARowNamingABlobThatNeverArrived : XCTAssertEqual failed: ("[34, 4096]") is not equal to ("[34]") - the pairing is both halves; a row keeping the other size names the blob no better
testAReplayRepairsARowNamingABlobThatNeverArrived : XCTAssertEqual failed: ("nil") is not equal to ("Optional(34 bytes)")
testAReplayRepairsARowNamingABlobThatNeverArrived : XCTAssertEqual failed: ("Optional(Conduck.WorkMaterialAvailability.syncedPending)") is not equal to ("Optional(Conduck.WorkMaterialAvailability.synced)")
testAReplayRepairsARowNamingABlobThatNeverArrived : XCTAssertEqual failed: ("syncPending") is not equal to ("available") - the card opens again, which is the whole point of repairing it
```

The second line is the card's own record still naming the stranded hash after the replay; the third
and fourth are the two physical rows still disagreeing about both halves of the pairing; the last
three are what the person sees — a card that will not open, with its payload sitting in the store.

**Two of my three cases pass on the reverted tree, and I say which and why.**
`testAnIdenticalReplayOntoAgreeingRowsWritesNothing` is a control on the NEW trigger (it fails if the
comparison is wrong, not if it is absent) and
`testStrandedBlobsAccumulatePerAttemptUntilDifferentBytesRetireThem` is a characterisation of
behaviour r5s#4 did not change.

## Guard verdicts

**None assigned, none converted, none deleted, none weakened.**
`WorkboardAvailabilityTests.testTheAvailabilityProjectionNeverNamesThePayloadColumn` and
`WorkboardBlobSeamPlatformGuardTests.testThePayloadSeamsAreCompiledOutOfTheWatchBuild` were both left
exactly as they stand and both pass — I added no seam and moved no `propertiesToFetch` block; the one
seam whose SIGNATURE I widened (`_duplicateWorkMaterialRowForTesting`) keeps its name, which is the
needle those guards read.

## Catalog

**Keys I ADDED in source: NONE.** Everything in this slice is headless — a repair that repoints rows,
and two corrected doc comments. The pending chip keeps reusing `workboard.material.syncPending`, and
a card that stops being pending simply stops rendering it.

**Keys I made DEAD: NONE.** I deleted no code carrying a key.

**No `.xcstrings` file was opened** (`git status --short -- '*.xcstrings'` empty).

## Decisions

1. **The comparison is lane + hash + size, not hash alone.** `WorkMaterialBlobPairing` is both halves,
   and a row that kept the vault lane while the card is synced is naming the blob no better than a row
   naming the wrong hash. The lane half is the one I could not construct a case for (see §Deviations 2),
   so it is argued rather than measured, and stated as such.
2. **Additive triggers, not a replacement.** See §1. The two existing ones describe a change to the
   payload STORE and are what four standing cases pin; disagreement describes a change to the ROWS.
   Collapsing them into one predicate would have moved behaviour the findings did not ask about.
3. **The helper lives beside `pointAtSyncedPayload`, not inside `WorkMaterialBlobPairing`.** The
   pairing type answers about a `WorkMaterialBlobRecord`; this answers about an `NSManagedObject`
   inside a write transaction, where no record has been projected yet. Putting a Core Data question on
   a `nonisolated struct` in `WorkboardRecords.swift` would have dragged CoreData into a file that is
   deliberately value-only and a Watch target member.
4. **No sweep, per the finding.** r5s#4 is answered with an accurate sentence and a case that pins it.
   A sweep is the one remedy the plan (§C, "Blob GC = paired deletion ONLY") forbids outright.
5. **No Codex consult.** The only genuinely hard call — whether normalising on disagreement could
   itself export a wrong state — is settled by the code: `pointAtSyncedPayload` writes exactly what
   this device just proved it holds, and the alternative is a card that never opens.

## Deviations

1. **I widened a test seam I did not strictly own the region of.** My ownership reads
   "`ConversationStore+Workboard.swift` (synced repair / replay path only)", and
   `_duplicateWorkMaterialRowForTesting` is in the `#if CONDUCK_TESTING` region. It gained two optional
   parameters (`contentHash:`, `byteSize:`), both defaulting to nil = copy the source's, so **no call
   site outside my files moved** and the full suite is the proof. It was unavoidable: the state r5s#1
   describes is two physical rows naming DIFFERENT blobs, no public API can produce it (every repair
   writes every row together, and the insert paths refuse a colliding id), and the seam's own doc
   comment already names "two offline devices import one logical material as several rows" as the
   thing it exists to stage. Neither parameter can CLEAR a column — the seam can only make a row name
   some other blob, never no blob.
2. **The LANE half of the comparison is argued, not measured**, and I dropped the case that would have
   measured it rather than widen the seam further. Producing a lane-divergent duplicate needs a
   `storageMode`/`localVaultKey` override on the same seam, which is a materially wider surface than
   the pairing columns, and d-store §Decisions 5 already set the house rule that a seam wider than the
   test needs is not worth it. The lane comparison costs one clause and is the honest statement of
   "names these bytes"; if a later round wants it measured, the shape is a `storageMode:` parameter on
   the same seam and a case staging a vault-lane duplicate under a synced card.
3. **`WorkboardBlobGCTests` and `WorkboardTwoStoreLoadTests` are untouched.** Both are mine and neither
   needed a change; they are in the VERIFY set and green.

## Gates — WHAT I ACTUALLY RAN

Slug `e-store`. DerivedData under `~/Library/Caches/gigaduck-builds/e-store/{DerivedData,
DerivedDataMac,DerivedDataCF,cf-tree}`, every log written there and grepped for `': error: '` and the
verdict strings — never judged from a tail or an exit code. **No `-configuration` passed anywhere.**
Sim `C26F4ECE-16AC-40B7-8D6A-BBF82B5BBA5D`; its TCC table was checked first
(`kTCCServiceUbiquity|ai.gigaduck.AgentRelay|2` — allowed, no `0` row, nothing to reset).

- **iOS `build-for-testing`** → `bft-4.log` (final): `grep -c ': error: '` = **0**,
  `** TEST BUILD SUCCEEDED **`.
- **My 10-class VERIFY set**, `test-without-building`, one quoted `-only-testing:` per class →
  `test-2.log`: `** TEST EXECUTE SUCCEEDED **`, `Executed 94 tests, with 0 failures (0 unexpected)`.

| Class | Result |
|---|---|
| `WorkboardSyncedRowRepairTests` | `Executed 3 tests, with 0 failures` (new) |
| `WorkboardBlobPublicationTests` | `Executed 22 tests, with 0 failures` |
| `WorkboardDeskUpsertTests` | `Executed 16 tests, with 0 failures` |
| `WorkboardAvailabilityTests` | `Executed 11 tests, with 0 failures` |
| `WorkboardBlobGCTests` | `Executed 6 tests, with 0 failures` |
| `WorkboardTwoStoreLoadTests` | `Executed 7 tests, with 0 failures` |
| `WorkCaptureDrainerCollisionTests` | `Executed 3 tests, with 0 failures` (e-drainer's, 1 → 3) |
| `WorkCaptureDrainerTests` | `Executed 10 tests, with 0 failures` |
| `WorkCaptureDrainerDurabilityTests` | `Executed 8 tests, with 0 failures` |
| `WorkboardChatCaptureTests` | `Executed 8 tests, with 0 failures` |

- **FULL iOS suite** → `ios-full-1.log`: `** TEST EXECUTE SUCCEEDED **`,
  `Executed 4957 tests, with 1 test skipped and 0 failures (0 unexpected) in 95.739 (102.058) seconds`.
  0 compile-error anchors, 0 XCTest-failure anchors. The single skip is the environment-conditional
  `GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`. I ran it because my
  file is on every capture path; it carries the whole wave's in-flight work.
  Spot-checked green beyond my VERIFY: `WorkboardPersistenceTests` 7/0 ·
  `WorkboardMaterialBoardActionsTests` 12/0 · `WorkboardVoiceLaneTests` 11/0 ·
  `WorkboardAudioCaptureTests` 19/0 · `WorkboardModelMigrationTests` 6/0 ·
  `WorkboardPublicationLockTests` 2/0 · `WorkboardLiveRepositorySupportTests` 6/0 ·
  `ConversationStoreAtomicWorkCaptureTests` 4/0.
- **macOS `build -destination 'platform=macOS'`** → `mac-1.log`: 0 `: error: `,
  `** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`.
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed.**
- **Counterfactual** → `cf-bft-1.log` (`** TEST BUILD SUCCEEDED **`, 0 errors), `cf-test-1.log`
  (`** TEST EXECUTE FAILED **`); table and verbatim lines in §3.
- **watchOS: NOT run, and it is not owed.** `Services/ConversationStore+Workboard.swift` is absent from
  the Watch target's membership-exception list in `project.pbxproj` (which names
  `Services/ConversationStore.swift` and `Services/ConversationStore+GatewayAttempts.swift` but not the
  Workboard extension), and I touched neither `WorkboardRecords.swift` nor the `.xcdatamodeld`.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 802 Swift files scanned…`, exit 0 ·
  `check-folder-map.sh` → `✓ folder map current — 36 Swift source directories`, exit 0 ·
  `check-spec-cites.sh` → `✓ spec citations resolve — 802 Swift files scanned`, exit 0.
- `git diff --check` → clean, exit 0. `git status --short` for `*.xcstrings`, `*.pbxproj`,
  `Conduck/Configs`, `docs/qa` → **empty** on all four. My untracked file checked by hand
  (`git diff --check` cannot see it): opens with `// SPDX-License-Identifier: Apache-2.0`, **0
  trailing-whitespace lines, 0 tab lines**.
- **Build caches, the isolated copy and every log removed at end of task** with
  `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh e-store` → `removed: e-store`.
  Re-run to reproduce. The `e-drainer` and `e-queue` slugs were still present afterwards and are not
  mine to remove.

### Suite delta for the orchestrator

**+3 iOS executed** from this slice: `WorkboardSyncedRowRepairTests` 0→3. `WorkboardBlobPublicationTests`
stays 22 (two doc comments, no case added or removed). Measured full-suite total with the whole wave's
in-flight work in the tree: **4957 executed, 1 skipped, 0 failures** (integrate-f's baseline was 4948;
the other +6 belong to the wave's other agents, of which `WorkCaptureDrainerCollisionTests` 1→3 is
visible in my VERIFY table).

### What I did NOT verify, plainly

- **The lane half of the row comparison** (§Deviations 2) — argued, not measured.
- **Anything across two real devices.** The merge this fix repairs is a CloudKit ordering no headless
  test can produce; the divergent row is staged through the duplication seam. §Founder QA.
- **A real CloudKit merge of two material rows naming different blobs**, which is the state itself
  rather than a stand-in for it. Only a device produces that.
- **The watch suite** (not built, not run — see §Gates for why it is not owed).
- **I ran the full iOS suite once**, green on the first attempt, so I have no evidence about
  ordering-independence under repeated load.

## Requests

1. **Nobody make the synced repair depend on blob insertion or deletion again.** That is r5s#1
   exactly: a replay whose bytes are already present inserts nothing, and a blob that never arrived
   cannot be superseded, so both signals read "no work to do" on precisely the state that needs
   repairing. The row comparison is the only one that answers it.
2. **Nobody drop the `rowsDisagree` guard and repoint unconditionally.** The rows are CloudKit records:
   stamping `updatedAt` on every replay would export a change for a card nothing happened to, on the
   path the drainer replays whenever a claim is retried.
   `testAnIdenticalReplayOntoAgreeingRowsWritesNothing` fails if anyone does.
3. **Nobody "tidy up" the stranded blob rows.** O-19's neighbour, and the same answer: a sweep cannot
   tell this device's interrupted attempt from a peer's blob imported ahead of its material. The bound
   is now stated accurately at `publishWorkMaterialBlob` and measured by
   `testStrandedBlobsAccumulatePerAttemptUntilDifferentBytesRetireThem`.
4. **Whoever owns `_duplicateWorkMaterialRowForTesting` next** — the two new parameters are
   nil-defaulted and additive; if a later round needs a lane-divergent duplicate, add `storageMode:`
   and `localVaultKey:` the same way rather than minting a second seam.
5. **O-19 is untouched by this slice and still open.** `deleteSupersededBlobRows` still deletes complete
   rows carrying other bytes inside the publishing transaction. My change does not widen it — it only
   adds a reason to repoint ROWS — but it does make the disagreement it can produce visible, because a
   card whose peer republication is deleted now gets normalised onto this device's bytes rather than
   left pending. That is strictly better for the person and does not close O-19.
6. **Docs agent — see §Settled facts.** Two facts, one of which CORRECTS a sentence integrate-f already
   carries under O-20.
7. **Founder QA — see §Founder QA.** Both items are two-device or crash-shaped and neither is reachable
   by a unit test.

## Refuted

**Nothing.** r5s#1 and r5s#4 both held against the current tree when traced by call path before any
edit, and r5s#1's mechanism is shown red on the reverted tree (§3). The DESIGN DIRECTIONS were
implementable as written: r5s#1's comparison fits inside the transaction that already holds every
physical row, and r5s#4's instruction (state the accurate bound, add no sweep) needed no code at all.

One clause of r5s#4 is worth sharpening rather than disputing: the finding says "without a committed
material row every retry inserts another blob", which is true of a CRASH but not of a refusal — a
refused publication takes its own row back by object id (`deleteBlobRow`). The corrected comment says
so, because a reader who thinks every failure strands a row will eventually add the sweep the same
comment forbids.

## Founder QA

Both need a signed device; the first needs two on one iCloud account (Gate 2).

1. **A card that was waiting for iCloud, on the device that has the bytes.** Two devices, byte sync on.
   On device A capture a small file into Work. On device B, with A offline, REATTACH a different small
   file onto that same card, then put B offline before it finishes syncing its payload. Bring both
   online. Expected: within a minute or two neither device shows a card stuck on "Waiting for
   iCloud…" — whichever bytes win, both devices open the card. The specific failure this round fixes
   is a card that says "Waiting for iCloud…" for ever on the device that visibly HAS a copy of the
   file, and that re-capturing the same file does not clear.
2. **The repeated pre-material crash** (the accurate bound in §2). On one device, force-quit the app
   immediately after the capture progress bar completes, three or four times in a row, capturing the
   SAME small file into Work each time; then let one capture finish. Expected: one card, it opens, and
   the app's storage in Settings → General → iPhone Storage grows by roughly N copies of that file
   rather than one. That growth is the accepted residue, not a leak — reattaching a DIFFERENT file
   onto that card, or deleting the card, must bring it back down. If it does not, the retirement is
   broken and the comment at `publishWorkMaterialBlob` is wrong.

## Settled facts

- A replay that carries a card's bytes brings EVERY physical row of that card back onto them — lane,
  content hash and byte size together — whenever any row disagrees, so a merge that left one row
  naming a blob this device never received cannot keep the card waiting for iCloud.
- A replay onto rows that already name its bytes writes nothing at all: the repair is licensed by
  disagreement, never by having run.
- **Corrects the fact integrate-f carries under O-20** ("Two blob rows carrying identical bytes for one
  card are a normal, bounded state"): the bound is persistence rather than a count — one payload row is
  stranded per publication that DIES between the blob save and the material save (a refusal takes its
  own row back), they accumulate until the card's bytes are replaced or the card is deleted, and no
  sweep may remove them because a stranded attempt is indistinguishable from a payload another device
  uploaded ahead of the card that names it.
