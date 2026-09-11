# fix2-store — r2#1/#2/#4/#5/#6 + adjudications (a)(b)(c) + t#5/t#9/t#11/t#13. All CONFIRMED, all fixed; nothing refuted. Every counterfactual MEASURED.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` in the worktree
untouched. **No `.xcstrings` opened** (`git status --short -- '*.xcstrings'` empty). No `.pbxproj`
edit. No mirror triplet touched. Nothing under `docs/qa/desk-cloudkit/` touched. No file outside my
ownership + minimal-touch list edited.

Files changed (13) — 3 production, 9 owned tests, 1 new test file:
- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (+594/−…, the bulk)
- `Conduck/Conduck/Services/ConversationStore.swift` (+118 — one production stored property, the
  isolated-vault URL, three `#if CONDUCK_TESTING` seams; deviation stated in §8)
- `Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift` (call-site only — §Call-site touches)
- tests: `WorkboardBlobPublicationTests` 15→21 · `WorkboardDeskUpsertTests` 11→14 ·
  `WorkboardChatCaptureTests` 7→8 · `ConversationStoreAtomicWorkCaptureTests` 3→4 (class rewritten) ·
  `WorkboardAvailabilityTests` 9→9 (one guard converted) · `WorkboardTwoStoreLoadTests` 7→7 (one case
  de-flaked) · `WorkboardBlobGCTests`, `WorkboardPersistenceTests`, `ConversationStoreWorkCaptureTests`
  (teardown only) · NEW `Conduck/ConduckTests/WorkboardIsolatedStoreFixture.swift`

**HEADLINE.** iOS `** TEST BUILD SUCCEEDED **` (0 `error:`) · my 13-class VERIFY set
`Executed 129 tests, with 0 failures` · **full iOS suite `Executed 4869 tests, with 1 test skipped and
1 failure`, and the one failure is fix2-inbox's in-flight file** · signed macOS `** BUILD SUCCEEDED **`
· watchOS `** TEST BUILD SUCCEEDED **` · **counterfactual: 11 of 11 new/extended cases fail on a tree
with the four mechanisms reverted, and NO pre-existing case fails with them** (§7).

---

## 1. r2#1 — legacy adoption re-homes on a matching UUID alone. CONFIRMED, fixed.

**Verified before changing anything**, by call path rather than line number: `publishWorkMaterial`'s
transaction compared `owners != [ownerID]` and then re-homed every foreign row, checking nothing about
kind, the foreign owner, or content. On the synced lane the same call went on to `deleteSupersededBlobRows`
+ `pointAtSyncedPayload`, so a capture carrying different bytes **replaced the parked card's payload**.
Both clauses held. Measured, not argued — §7 CF row 1 shows the parked card's `contentHash` changing
from the stranger's to the recapturing caller's on the pre-fix code.

### The fix: adoption needs stated provenance, and the owner row has to agree

New `nonisolated enum WorkMaterialLegacyProvenance { case captureEnvelope(UUID); case chatMessage(UUID) }`
and a **defaulted** `legacyProvenance:` parameter on `upsertDeskMaterial` (defaulted, so no caller
outside my minimal-touch list needed an edit). New `static func requireAdoptable(materialRows:deskID:
kind:provenance:in:)` runs before any re-homing and refuses unless EVERY foreign row satisfies both:

| Half | Rule | Why |
|---|---|---|
| Owner agrees | the foreign `WorkItem` must exist AND carry the caller's capture identity — `captureEnvelopeID == id`, plus `owner.id == id` for `.chatMessage` (the pre-desk chat lane wrote both) | a missing owner row is not evidence: CloudKit imports a material ahead of its item, and adopting then moves a card whose history has not arrived |
| Kind agrees | `row.kind == draft.kind.rawValue` | two materials sharing a UUID is what an id collision looks like from here; re-homing across kinds hands this capture's bytes to whatever the other card was |

`provenance == nil` can never satisfy the first half — deliberately: every lane that mints its ids per
attempt (drop, picked file, Shortcut run, voice capture) has no history to adopt.

**Callers that pass it:** `captureMessageToWork` → `.chatMessage(persistedMessage.id)` on the note and
on every attachment; `WorkCaptureDrainer.persist` → `.captureEnvelope(envelope.id)` at all three desk
writes. Nothing else passes provenance, which is the intended posture.

**Regression tests** (all measured red on the pre-fix tree, §7):
`testAMaterialIdParkedUnderAnUnrelatedOwnerIsRefusedRatherThanAdopted` — a card parked on the SYNCED
lane under a stranger's envelope; a nil-provenance capture and a wrong-envelope capture both throw
`invalidMaterialOwner`; the parked row keeps its owner, its blob keeps the stranger's hash, its bytes
read back unchanged, nothing reaches the desk — and the capture that CAN account for it still adopts,
so the refusal is about provenance, not about adoption being switched off ·
`testAdoptionIsRefusedWhileTheLegacyOwnerCannotAccountForTheCard` (owner row with no capture identity)
· `testAdoptionIsRefusedWhenTheParkedRowIsADifferentKindOfCard` ·
`WorkboardChatCaptureTests.testAChatRecaptureNeverAdoptsACardParkedByAnUnrelatedCapture` (the turn's
words land, the attachment reports `failedMaterialCount == 1`, the stranger's payload survives).
The two adoption tests fix-store wrote still pass, now passing provenance.

## 2. r2#2 + adjudication (a) — an adopted in-flight blob can be deleted by its publisher. CONFIRMED, fixed.

Verified: `publishWorkMaterialBlob` returns `.alreadyPresent` for a complete matching row (so the
adopter inserts nothing and commits a card naming a row it did not write), and
`replaceWorkMaterialPayloadFile` held **no claim at all** — `publishWorkMaterial` serialized only on
the OWNER id, which a reattach never takes. Two reattaches of one card, or a reattach against a desk
capture, could therefore interleave across the blob-save→row-save gap.

### The fix: a per-MATERIAL publication claim, held across the whole publication

`ConversationStore.workMaterialPublicationClaims: Set<UUID>` (beside the two existing claim sets),
taken by `publishWorkMaterial` (after the desk claim) and by `replaceWorkMaterialPayloadFile` (its
only claim), each for the whole call. Acquisition order is desk-then-material in one path and
material-only in the other, so there is no cycle.

**Per material, not per owner, deliberately.** Work is one desk, so an owner-keyed claim would queue
every capture behind a several-hundred-megabyte reattach's file copy. Per-material is strictly the
serialization the defect needs and nothing wider.

### THE INVARIANT, stated (adjudication (a) asks for exactly this)

> Within a process, at most one publication of a given material's payload is in flight at a time,
> and it holds that material's claim from staging through the blob save, the row save and the vault
> confirmation. Therefore "the blob row I inserted is the only blob row I may delete" is true by
> construction, and object-scoped rollback needs no publication-identity column.

**Across processes the claim does not reach** (app + headless intent share the store and capture ids
are deterministic). I did **not** add a publication-identity column: it is a schema change to a model
already headed for CloudKit Production, and the residue is bounded and repairable rather than lossy —
the adopter's card reads `.syncedPending`, a replay of either capture restages the bytes, and the
drainer's durability barrier refuses to acknowledge a capture whose cards do not read back. Both the
invariant and its boundary are written at `deleteBlobRow`'s declaration, which is the only place a
blob is ever removed without its material.

**Regression test.** `testOneMaterialsPayloadIsPublishedByOneCallerAtATime` — the confirmation seam
holds a reattach for 400 ms after its save; a desk publication of the SAME material is launched 120 ms
in and does no I/O of its own. The recorded order must be `["reattach-held", "reattach-released",
"replay-done"]`. *Measured counterfactual:* with the claims removed the run reports
`["reattach-held", "replay-done", "reattach-released"]` — the interleaving the finding describes,
produced on demand.

## 3. r2#4 (store half) — availability on the vault lane. CONFIRMED as already-closed-by-C4, adopted properly.

The projection read `Set(await workAssetVault.urls(for:).keys)`, and fix2-vault's `urls(for:)` already
carries the readability predicate — so the store half of the finding no longer holds on the current
tree, and I say so rather than claiming a fix I did not make. What I DID change is the shape: a new
private `readableVaultKeys(among:)` calls contract C4's `readableKeys(among:)` directly (no URL
dictionary built to be thrown away) and is the ONE place availability asks the vault anything. That is
what makes t#13's behavioural guard possible (§6).

## 4. r2#5 — a committed card reported as a bare failure. CONFIRMED, fixed.

Verified: all three sites posted the change notification for a committed mutation and then threw
`WorkboardStoreError.materialPayloadUnavailable`, which carries neither the record nor its identity.

**The outcome shape I chose, and why.** A new
`nonisolated struct WorkMaterialCommittedUnavailableError: Error { let record: WorkMaterialRecord }`,
thrown by `publishWorkMaterial`, `insertWorkMaterial` and `replaceWorkMaterialPayloadFile` when the
post-commit confirmation refuses. **Not** a changed return type: `upsertDeskMaterial` has callers in
four files outside my minimal-touch list (`WorkboardLiveRepository`, the watch intent's own
implementation, two foreign test files), and a signature break in a parallel phase is worse than an
error that carries what a caller needs. **Not** a new `WorkboardStoreError` case either:
`Models/WorkboardRecords.swift` is not mine and the enum is `Equatable`, compared with `==` across the
suite.

It stays a THROW, so every existing caller behaves exactly as before — in particular the drainer still
refuses to acknowledge (any throw releases the claim and leaves the queue copy). What is new is that a
caller minting its material id per attempt can now adopt the committed card instead of retrying under
a fresh id. `WorkboardLiveRepository.importMaterial` is that caller and is NOT mine — §Requests 2.

**Regression tests.** `testAFreshPublicationThatCannotProveItsLeafReportsTheCommittedCard` (error
carries the record, its availability is `.unavailableOnThisDevice`, the card is on the desk, the
change notification fired, and a replay repairs it to one card) and
`testAnArbitraryInsertThatCannotProveItsLeafReportsItsCommittedCard`. Both measured red on the pre-fix
tree — `failed: caught error: "materialPayloadUnavailable"`, i.e. the catch clause does not match.

## 5. r2#6 — a refused reattach confirmation destroyed the bytes it replaced. CONFIRMED, fixed.

Verified: `confirmPublication` could set `publicationIsDurable = false`, and the very next lines removed
every old vault key unconditionally, then posted and threw. The caller was left with a card pointing at
an unreadable leaf and no copy of what it had.

### The fix, in the order the finding asks for

1. **Prove the staged leaf BEFORE the CAS, without releasing its guard.**
   `await workAssetVault.readableKeys(among: [newKey]).isEmpty` → remove the leaf and throw
   `materialPayloadUnavailable` with nothing committed. `readableKeys` is the right primitive here
   precisely because it does not end staging: only `confirmPublication` may do that, and until the
   swap commits a reclamation in another process must not be free to take the leaf.
2. **Old keys are released only after the final confirmation** — the `for oldKey in oldKeys` loop
   moved below the `guard publicationIsDurable`.
3. **Enough prior row state is kept for a compensating restore.** New
   `private nonisolated struct WorkMaterialRowSnapshot` captures every payload-bearing column of every
   physical row inside the transaction; `restoreReplacedPayload(id:to:discardingBlob:)` puts them back
   and reports whether it did.

**The restore is conditional, and the condition is stated at the declaration:** it runs only when
every prior row was `.localVault` with a prior key that is still readable — the one case where putting
the card back is lossless. A card whose payload was a BLOB cannot be restored: retiring its blob rows
is part of the swap's own transaction and their bytes are gone, so pointing it back at the synced lane
would leave it claiming a payload nothing holds — strictly worse than the unreadable leaf it names,
which a reattach can replace. That card keeps the new pointer and the failure is reported as
committed-but-unavailable (§4) instead. When the restore DOES run, the blob this call inserted for the
replacement is taken back too, by the same object-scoped rule.

**Regression tests.** `testAReattachThatCannotProveItsLeafKeepsTheBytesItWasReplacing` and
`testAReattachOffTheSyncedLaneReportsTheCommittedCardItCannotRestore`. The first one's pre-fix failure
lines are the finding stated as data: the card named the NEW key, `byteSize` 0 instead of 29, the old
leaf was gone (`XCTAssertTrue failed - the only surviving copy of the person's bytes stays on disk`),
and `loadWorkMaterialPayload` returned nil.

## 6. Adjudications (b) and (c)

### (b) Measured bytes, persisted and compared — done

- `stageWorkMaterialBytes`' `.localVault` payload path takes `store(bytes:)` and returns
  `byteSize: write.byteCount` (was `declaredByteSize ?? measured`).
- `addWorkMaterial` takes `store(bytes:)` and lets `write.byteCount` replace `draft.byteSize ?? count`.
- All three `confirmPublication` calls now pass `expectedByteCount:` — `staged.byteSize` at the desk
  publication and the reattach, the insert's `byteSize` at `insertWorkMaterial`. They go through one
  new `confirmVaultPublication(site:materialID:key:expectedByteCount:)`, which is also seam (c).

The two halves are ONE change and must stay together: the confirmation compares the leaf against the
persisted column, so a column carrying the caller's claim would refuse a healthy publication.

**Regression tests.** `testAVaultRowRecordsTheBytesTheLeafHoldsRatherThanTheCallersClaim` (declared
9 999, payload 20 bytes → row says 20, and the card confirms) and an added assertion on the existing
`testAPayloadAboveTheCeilingTakesTheVaultAndAReplayRestoresIt` (declared `count + 4096`). Measured red:
`("9999") is not equal to ("20")` and `("31461377") is not equal to ("31457281")`.

### (c) The post-save / pre-confirm seam — done, ONE seam for all three sites

`ConversationStore.publicationConfirmationHookForTesting` (`#if CONDUCK_TESTING`, inside the existing
`#if !os(watchOS)` payload region, gated on `isIsolatedTestStore`), plus
`nonisolated enum WorkPublicationSite { deskPublish, arbitraryInsert, reattach }` declared in
production because it names a real distinction the three sites make. The closure is awaited exactly
between the save and the proof: returning nil runs the REAL confirmation over whatever the closure did
to the leaf (my tests remove it — the reclamation the staging guard cannot cover), returning a Bool
forces the answer. One seam, no wider than the three branches need, with a WHY-IT-HAS-TO-EXIST header.

All three branches are now covered, with the returned error/outcome, the notification, the preserved
old bytes and the replay repair asserted (§4, §5).

## 7. The counterfactual — MEASURED, in an isolated copy

`~/Library/Caches/gigaduck-builds/fix2-store/tree`, an rsync snapshot with its `Identity-Override`
symlink re-pointed at the same real file. **Nothing in the worktree was touched for this.** One
variant, reverting all four mechanisms in the copy's `ConversationStore+Workboard.swift` only: the
adoption gate removed, declared byte sizes restored, `expectedByteCount` dropped, the committed-
unavailable error replaced by the plain one, the reattach's pre-CAS proof / restore / key retention
removed, and both publication claims removed.

`cf-test-1.log`, `** TEST EXECUTE FAILED **`:

| Class | Result on the reverted code |
|---|---|
| `WorkboardBlobPublicationTests` | `Executed 21 tests, with 14 failures (4 unexpected)` |
| `WorkboardDeskUpsertTests` | `Executed 14 tests, with 10 failures` |
| `WorkboardChatCaptureTests` | `Executed 8 tests, with 4 failures` |
| `ConversationStoreAtomicWorkCaptureTests` | `Executed 4 tests, with 0 failures` (its subject is the fixed desk, which the revert did not touch) |

**Exactly 11 distinct cases fail, and every one of them is a case I added or extended. No
pre-existing case failed.** Selected verbatim lines:

```
testAVaultRowRecordsTheBytesTheLeafHoldsRatherThanTheCallersClaim : XCTAssertEqual failed: ("9999") is not equal to ("20")
testAPayloadAboveTheCeilingTakesTheVaultAndAReplayRestoresIt      : XCTAssertEqual failed: ("31461377") is not equal to ("31457281")
testAFreshPublicationThatCannotProveItsLeafReportsTheCommittedCard: failed: caught error: "materialPayloadUnavailable"
testAnArbitraryInsertThatCannotProveItsLeafReportsItsCommittedCard: failed: caught error: "materialPayloadUnavailable"
testAReattachThatCannotProveItsLeafKeepsTheBytesItWasReplacing    : XCTAssertTrue failed - the only surviving copy of the person's bytes stays on disk
testAReattachThatCannotProveItsLeafKeepsTheBytesItWasReplacing    : XCTAssertEqual failed: ("nil") is not equal to ("Optional(29 bytes)")
testAReattachOffTheSyncedLaneReportsTheCommittedCardItCannotRestore: failed: caught error: "materialPayloadUnavailable"
testOneMaterialsPayloadIsPublishedByOneCallerAtATime : XCTAssertEqual failed: ("["reattach-held", "replay-done", "reattach-released"]") is not equal to ("["reattach-held", "reattach-released", "replay-done"]")
testAMaterialIdParkedUnderAnUnrelatedOwnerIsRefusedRatherThanAdopted : failed - a capture that names no provenance has no history to adopt
testAMaterialIdParkedUnderAnUnrelatedOwnerIsRefusedRatherThanAdopted : XCTAssertEqual failed: ("Optional("11173fd2…")") is not equal to ("Optional("47dc3582…")") - a refused adoption must not replace the payload it collided with
testAdoptionIsRefusedWhileTheLegacyOwnerCannotAccountForTheCard   : failed - an owner row that names no capture cannot license an adoption
testAdoptionIsRefusedWhenTheParkedRowIsADifferentKindOfCard       : failed - a note must not adopt the rows of a file that shares its id
testAChatRecaptureNeverAdoptsACardParkedByAnUnrelatedCapture      : XCTAssertEqual failed: ("[DE5C0000-…-000000000001]") is not equal to ("[3EB6912B-…]")
```

Three cases are argued rather than reverted, and I say which: the batch-count conversion (§9) cannot
be reverted meaningfully because the counters do not exist in the old code — a per-card loop reports
8 and 4 where the case demands 1 and 1; the arbitrary-owner guard (§8) fails trivially on the old code
because the declarations sit outside `#if CONDUCK_TESTING`; and the memory lower bound (§9) is an
added assertion whose whole point is that the old case passed without it.

## 8. t#5 — the project-era constructor kept alive by its own tests. CONFIRMED, fixed.

- **`createWorkItemWithInitialMaterial` DELETED from production**, with `WorkMaterialOwnerPolicy` and
  the `.createNew` arm; `publishWorkMaterial` no longer takes an owner policy and names the desk.
- **`createWorkItem`, `addWorkMaterial`, `addWorkMaterialFile`, `insertWorkMaterial` moved behind
  `#if CONDUCK_TESTING`**, each with a header saying why it exists and why it must not ship. That is
  t#5's "gate legacy fixture creation under CONDUCK_TESTING", and it is stronger than a convention:
  in a shipping build the arbitrary-owner constructors do not exist, so the COMPILER forbids a future
  capture lane from minting a second board. All callers were already tests (verified by grep across
  every target before moving them).
- **`ConversationStoreAtomicWorkCaptureTests` rewritten around the fixed desk** — the first capture
  commits the desk row and its card together and the desk carries no brief; a staging failure commits
  neither and leaves the next capture on the same lazy-creation path; a refused transaction takes back
  its staged vault bytes.
- **The guard**: `testNoArbitraryOwnerConstructorSurvivesIntoAShippedBuild` walks
  `ConversationStore+Workboard.swift`'s conditional-compilation regions (the same shape
  `WorkboardBlobSeamPlatformGuardTests` uses) and requires each of the four declarations to sit under
  `CONDUCK_TESTING`, plus that `createWorkItemWithInitialMaterial` is gone. **A source guard with its
  reason stated in the test:** what it asserts is the absence of declarations from a build this suite
  is not — the test bundle compiles WITH the flag, so the compiler cannot be asked the question. Its
  behavioural half is the first case in the same file.

## 9. t#9, t#11, t#13

**t#9 — the ceiling-memory test was flaky by construction.** Fixed rather than deleted: the payload is
now a named local held across `sampler.finish()` (`withExtendedLifetime`), so its own pages are
guaranteed to be in the measurement, and a new `XCTAssertGreaterThanOrEqual(growth, ceiling)` runs
BEFORE the upper bound with a message saying the bound is vacuous without it. That converts the failure
mode the reviewer named — a transient allocation released before sampling, giving a pass that proves
nothing — into a red run. The contamination half needs no change: XCTest runs this bundle's classes
serially in one process, and the upper bound is a growth delta, not an absolute footprint. Measured
green (`0.044 s`).

**t#11 — isolated stores leaked their vault directories.** New
`ConversationStore._removeIsolatedVaultDirectoryForTesting()` (the store remembers the path its
`init(inMemory:storeURL:)` minted, under `#if CONDUCK_TESTING && !os(watchOS)`, and refuses anything
but an isolated store), driven from the new `IsolatedWorkStores` fixture: every one of my nine classes
now makes its stores through it and empties them in `tearDown`.
*Measured, not argued:* the simulator held **82 leftover `conduck-workasset-tests-*` directories,
155 736 KB**, before; running my nine owned classes (62 stores) left the count at **82 — zero new**.
The remaining 82 are earlier runs and classes I do not own (§Requests 4).

**t#13 — `testAvailabilityIsResolvedOncePerFetchRatherThanOncePerCard` CONVERTED.** Two counting
collaborators were the honest small seam: `readableVaultKeys(among:)` and `workMaterialBlobCompleteness`
are each the single entry point for their question, and each increments a `#if CONDUCK_TESTING`
counter. The case builds a nine-card board (4 synced, 4 device-local, 1 note), resets, fetches, and
asserts **exactly 1 vault resolution and 1 completeness fetch**, then that a second pass reports 2 and
2 (so the counters are counting real calls, not a cache). The three source-text assertions it replaces
are gone. A per-card loop would report 8 and 4.

## Guard verdicts

| Test | Verdict acted on | What I did |
|---|---|---|
| `WorkboardAvailabilityTests.testAvailabilityIsResolvedOncePerFetchRatherThanOncePerCard` | convert | **CONVERTED** to counting collaborators (§9). Source-text assertions deleted. |
| `WorkboardAvailabilityTests.testTheDeskBannerReadsAccountStateRatherThanTheLastSyncEvent` | convert | **KEPT as a source guard, with the reason now in its doc comment.** The desk has no presentation model to inject monitor states into — the banner is read inside `WorkboardCaptureCanvas`'s body from the shared monitor. Converting means mounting SwiftUI (no UI test target, by decision) or extracting a desk presentation layer that would exist for this test alone; the canvas is also not my file this wave. `CloudSyncMonitorTests` plus the case below it (the three actionable reasons read differently) carry the behaviour. |
| `WorkboardAvailabilityTests.testTheAvailabilityProjectionNeverNamesThePayloadColumn` | keep | Left exactly as it was. |

## Catalog

**Keys I ADDED in source: NONE.** Every change here is headless. The one new error type
(`WorkMaterialCommittedUnavailableError`) deliberately does NOT conform to `LocalizedError`, matching
`WorkboardStoreError.materialPayloadUnavailable`, whose `errorDescription` is `nil` on purpose: an
internal invariant failure has no user action, and inventing copy for one dresses a bug up as a
decision. No `.xcstrings` file was opened.

**Keys I made DEAD: NONE.** I deleted no code carrying a key. `createWorkItemWithInitialMaterial` and
the four gated constructors carry none.

## Decisions

1. **Per-material claim rather than per-owner** (§2) — an owner claim would work (Work is one desk, so
   it subsumes the material claim) but would queue every capture behind a 256 MB reattach's copy.
2. **An error carrying the record rather than a changed return type** (§4) — four call sites outside
   my ownership, in a parallel phase.
3. **The compensating restore is conditional** (§5) — restoring a card off the synced lane would leave
   it claiming a payload nothing holds.
4. **No publication-identity column** (§2) — a schema change to a deployed model, for a residue that
   is bounded and repairable. The boundary is written at `deleteBlobRow`.
5. **`#if CONDUCK_TESTING` on the arbitrary-owner constructors rather than deletion** (§8) — the
   pre-desk owner rows those fixtures build are the state the adoption path exists for; deleting them
   would delete the only way to test r2#1.
6. **No Codex consult.** The one genuinely hard call (whether the claim makes a publication-identity
   column unnecessary) is an argument about reachability I could settle by tracing the two callers.

## Deviations

- **`ConversationStore.swift`: one PRODUCTION stored property** (`workMaterialPublicationClaims`),
  outside my stated "inMemory initialiser + CONDUCK_TESTING seams" scope. Swift extensions cannot add
  stored properties and `ConversationStore` is an actor, so a claim set has nowhere else to live; a
  file-scope global would be shared across store instances, which is wrong for isolated test stores.
  It sits beside the two existing claim sets, in the same region, in the same style. Declared here
  rather than done quietly.
- **`store(_ data:)` (the key-only vault form) is NOT deleted.** `WorkAssetVault.swift` is not mine
  and two callers remain in `WorkboardLiveRepositorySupportTests.swift`, which is not mine either.
  My two call sites now take `store(bytes:)`, which is the half fix2-vault's Request 1 assigned me —
  §Requests 1 carries the rest.
- **`WorkboardBlobSeamPlatformGuardTests`' `payloadSeams` list does not name my three new seams.** That
  file is not mine (§Requests 5). Two of the three are inert on the wrist and the third
  (`_removeIsolatedVaultDirectoryForTesting`) is compiler-enforced into `!os(watchOS)` by the property
  it reads, so the gap is real but low-value.
- **`WorkboardLiveRepository` does not adopt the committed-unavailable outcome** (§Requests 2): not in
  my minimal-touch list. Behaviour there is unchanged, not regressed.

## Gates — WHAT I ACTUALLY RAN

Slug `fix2-store`. DerivedData under `~/Library/Caches/gigaduck-builds/fix2-store/{DerivedData,
DerivedDataMac,DerivedDataWatch,DerivedDataCF,tree}`, every log written there and grepped for
`': error: '` and the verdict strings — never judged from tail or exit code. **No `-configuration`
passed anywhere.** Sim `C26F4ECE-16AC-40B7-8D6A-BBF82B5BBA5D`.

- **iOS `build-for-testing`** → `bft-4.log` (final): `grep -c ': error: '` = **0**,
  `** TEST BUILD SUCCEEDED **`. The only two `warning:` lines naming my files are pre-existing, in the
  screenshot-mode block of `ConversationStore.init()` (`:1341` main-actor property, `:1381` will never
  be executed) — lines my diff does not touch.
- **VERIFY set**, `test-without-building`, one quoted `-only-testing:` per class → `test-4.log`,
  `** TEST EXECUTE SUCCEEDED **`, `Executed 129 tests, with 0 failures (0 unexpected)`:

| Class | Result |
|---|---|
| `WorkboardBlobPublicationTests` | `Executed 21 tests, with 0 failures` (was 15) |
| `WorkboardDeskUpsertTests` | `Executed 14 tests, with 0 failures` (was 11) |
| `WorkboardChatCaptureTests` | `Executed 8 tests, with 0 failures` (was 7) |
| `ConversationStoreAtomicWorkCaptureTests` | `Executed 4 tests, with 0 failures` (was 3) |
| `WorkboardAvailabilityTests` | `Executed 9 tests, with 0 failures` |
| `WorkboardTwoStoreLoadTests` | `Executed 7 tests, with 0 failures` |
| `WorkboardBlobGCTests` | `Executed 6 tests, with 0 failures` |
| `WorkboardPersistenceTests` | `Executed 7 tests, with 0 failures` |
| `ConversationStoreWorkCaptureTests` | `Executed 5 tests, with 0 failures` |
| `WorkCaptureDrainerTests` | `Executed 9 tests, with 0 failures` |
| `WorkCaptureDrainerDurabilityTests` | `Executed 8 tests, with 0 failures` |
| `WorkboardAudioCaptureTests` | `Executed 19 tests, with 0 failures` |
| `WorkboardVoiceLaneTests` | `Executed 12 tests, with 0 failures` |

- **FULL iOS suite** → `ios-full-2.log`, `** TEST EXECUTE FAILED **`,
  `Executed 4869 tests, with 1 test skipped and 1 failure (0 unexpected) in 62.905 (64.284) seconds`.
  **The one failure is not mine** — `WorkCaptureInboxTests.swift:308:
  testShareWritersValidateAndRollbackBeforeAtomicPublication : XCTUnwrap failed`, the share-writer
  source drift guard over fix2-inbox's in-flight files (the test lens rated it "convert" and assigned
  it to them). The single skip is the environment-conditional
  `GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`, as fix-verify §4
  recorded. I ran the full suite because my file is on every capture path.
- **macOS `build -destination 'platform=macOS'`** → `mac-1.log`: 0 `error:`, `** BUILD SUCCEEDED **`,
  `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`. **Signed through the identity
  override; no `CODE_SIGNING_ALLOWED=NO` fallback needed.**
- **watchOS `build-for-testing`** (`-scheme ConduckWatchTests`, sim
  `28AC563B-42C1-4E66-940D-77E63B07918B`) → `watch-bft-1.log`: 0 `error:`,
  `** TEST BUILD SUCCEEDED **`. Beyond my VERIFY, run because `ConversationStore.swift` is a member of
  the Watch target and I added conditional-compilation regions to it. **I did not RUN the watch
  suite** — no watch sim is assigned to me and it is not in my VERIFY.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 785 Swift files scanned…`, exit 0.
- `git diff --check` → clean, exit 0. `git status --short` for `*.xcstrings`, `*.pbxproj`,
  `Conduck/Configs`, `docs/qa` → **empty**.
- **Build caches, the isolated copy and every log removed at end of task** with
  `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh fix2-store` (`removed:
  fix2-store`). Re-run if the integrator needs the logs.

### Suite delta for the orchestrator

**+11 iOS executed** from this slice: `WorkboardBlobPublicationTests` 15→21, `WorkboardDeskUpsertTests`
11→14, `WorkboardChatCaptureTests` 7→8, `ConversationStoreAtomicWorkCaptureTests` 3→4. Measured
full-suite total with the whole wave's in-flight work in the tree: **4869 executed, 1 skipped**.

### What I did NOT verify, plainly

- The watch SUITE (built, not run) and the drift-guard / folder-map scripts (outside my VERIFY).
- **The cross-process half of r2#2** (§2). The claim is process-local by construction; I did not build
  a two-process harness, and I state the residue rather than claiming it closed.
- **`WorkboardLiveRepository`'s adoption of the new outcome** — not my file, not attempted, §Requests 2.

## Call-site touches

**One file, three lines of argument** — `Services/Workboard/WorkCaptureDrainer.swift`, `persist(_:ownership:)`:
the share-note write and both entry writes now pass `legacyProvenance: .captureEnvelope(envelope.id)`.
Nothing else in that file changed; no signature moved. `WorkboardViewModel.swift`,
`WorkVoiceCaptureCoordinator.swift` and `Intents/*.swift` needed **no** edit — `legacyProvenance` is
defaulted to nil, which is the correct posture for every lane that mints its own ids.

`Services/ConversationStore.swift` is listed under Files changed rather than here: the stored property
is a declaration, not a call-site adoption (deviation stated above).

## Requests

1. **fix2-vault's Request 1, second half — whoever owns `WorkAssetVault.swift` + the two remaining
   callers.** My two call sites now take `store(bytes:)` and persist `byteCount`, and all three
   `confirmPublication` sites pass `expectedByteCount:`. The key-only `func store(_ data: Data, …) ->
   String` now has exactly TWO callers left, both in
   `ConduckTests/WorkboardLiveRepositorySupportTests.swift:22-23`; change them to
   `store(bytes: …).key` and the vault method can go.
2. **Whoever owns `Services/Workboard/WorkboardLiveRepository.swift` — adopt
   `WorkMaterialCommittedUnavailableError`.** `importMaterial` mints a fresh material id per drop, so
   it is the caller r2#5 is actually about: on that error it should present/refresh the card the error
   carries (`error.record`, reading `.unavailableOnThisDevice`) rather than surfacing a bare failure
   the person may retry into a second card. `catch WorkboardStoreError.staleRevision` stays as it is.
   Behaviour is unchanged until someone does this; nothing is broken by leaving it.
3. **Nobody re-open the adoption gate.** `requireAdoptable` is r2#1: a matching UUID licenses nothing.
   In particular do not "fix" the missing-owner refusal — a material that arrives before its item is
   exactly the case where adopting would move somebody else's card — and do not drop the kind check.
   Four cases fail if either is removed.
4. **Every OTHER test class that builds a `ConversationStore(inMemory:)` should take
   `IsolatedWorkStores`** (`ConduckTests/WorkboardIsolatedStoreFixture.swift`): a `private let isolated
   = IsolatedWorkStores()`, `isolated.make()` in place of the initializer, and a `tearDown` calling
   `await isolated.cleanUp()`. I adopted it in my nine classes only. The measured residue is 82
   directories / 155 MB in one simulator, and the biggest remaining producers are
   `WorkAssetVaultTests`, `WorkboardMaterialBoardActionsTests`, `WorkboardDeskViewModelTests` and
   `WorkboardAudioCaptureTests`.
5. **Whoever owns `WorkboardBlobSeamPlatformGuardTests.swift`** may want three rows added to
   `payloadSeams`: `var publicationConfirmationHookForTesting`,
   `var projectionVaultReadabilityCallsForTesting`, `func _removeIsolatedVaultDirectoryForTesting(`.
   All three are already inside `#if CONDUCK_TESTING` + `#if !os(watchOS)` (the guard passes as it
   stands); this is drift insurance, not a defect.
6. **Nobody move the reattach's readability proof after the CAS, or release the old vault keys before
   the confirmation.** That ordering IS r2#6, and
   `testAReattachThatCannotProveItsLeafKeepsTheBytesItWasReplacing` is measured red against the old
   order — it loses the person's only copy.
7. **Nobody remove the two publication claims** (`workInitialMaterialClaims` on the desk,
   `workMaterialPublicationClaims` on the material). The second is the whole of adjudication (a), and
   the object-scoped rollback's safety argument (written at `deleteBlobRow`) depends on it.
8. **Docs agent — four facts are now settled by code.** (a) A material a pre-desk build parked under a
   per-capture owner is re-homed onto the desk only by a re-capture that names the capture it belongs
   to AND matches its kind; anything else is refused and the parked card keeps its owner and its bytes.
   (b) A device-local row records the length the vault measured off the leaf, and a publication is
   reported durable only when the leaf reads back at that length. (c) A reattach proves its new bytes
   before the swap, and a swap it cannot prove afterwards gives the card its previous payload back
   whenever that is lossless. (d) One process publishes one material's payload at a time.
9. **Founder QA (Gate 2) — two items this slice adds.** (a) Reattach a file onto a Work card, then
   check the card still opens; if the reattach reports an error, the ORIGINAL file must still open
   from that card — never an empty or broken one. (b) On a device upgrading from a build with the old
   per-capture Work items, re-capture a chat turn that was already captured: its cards must move onto
   the desk exactly once, and the old Work item must still exist and be empty.

## Refuted

**Nothing.** All five findings and all three adjudications held against the current tree when traced by
call path. The one qualification is r2#4's store half (§3): its consequence no longer holds because
fix2-vault's `urls(for:)` already carries the readability predicate — I adopted contract C4's
`readableKeys(among:)` there anyway and say so rather than claiming a fix I did not have to make.
