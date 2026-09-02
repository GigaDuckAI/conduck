# c-store — r3s#1/#2/#3/#4/#6 + adjudications O-1, O-2, O-18. Four CONFIRMED and fixed, one accepted as debt. Counterfactual MEASURED.

Parallel phase. No commits/pushes/stash/checkout, no index operations. `Identity-Override.xcconfig`
untouched. **No `.xcstrings` opened**, no `.pbxproj` edit, no mirror triplet touched, nothing under
`docs/qa/desk-cloudkit/` touched. No file outside my ownership list edited.

Files changed (9) — 3 production edited, 1 production new, 4 owned tests edited, 1 new test file:

- `Conduck/Conduck/Services/Workboard/WorkMaterialPublicationLock.swift` — **NEW** (contract C8)
- `Conduck/Conduck/Services/ConversationStore.swift` (+110/−0; lock region + CONDUCK_TESTING seams only)
- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (+262/−75)
- `Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift` (+18; `importMaterial`'s catch only)
- tests: `WorkboardBlobPublicationTests` 21→21 (one case rewritten) · `WorkboardDeskUpsertTests` 14→15 ·
  `WorkboardLiveRepositorySupportTests` 5→6 · `WorkboardTwoStoreLoadTests` 7→7 (one case narrowed) ·
  **NEW** `Conduck/ConduckTests/WorkboardPublicationLockTests.swift` (2)

**HEADLINE.** iOS `** TEST BUILD SUCCEEDED **` (0 `: error: `) · my 9-class VERIFY set
`Executed 79 tests, with 0 failures` · **full iOS suite `Executed 4906 tests, with 1 test skipped and
3 failures`, and all 3 are c-guards' un-spliced `workboard.sync.banner.*` catalog rows** · signed
macOS `** BUILD SUCCEEDED **` · watchOS `** TEST BUILD SUCCEEDED **` · **counterfactual: every one of
the four mechanisms fails red on a tree with it reverted — 4 cases, 9 assertions — and NO pre-existing
case failed** (§6).

---

## 1. r3s#1 + O-1 + O-18 — the cross-process publication race. CONFIRMED, fixed (contract C8).

**Verified by call path before writing anything.** `publishWorkMaterialBlob`
(`ConversationStore+Workboard.swift`) returns `.alreadyPresent` for a complete matching row, so an
adopter inserts nothing and commits a card naming a row it did not write; the refusal path deletes
that row through `deleteBlobRow(_:)`; `workMaterialPublicationClaims` is a `Set<UUID>` on the actor
instance, so it says nothing about a second process (or, equivalently, a second store instance). The
drainer's ownership gate is checked before it awaits `upsertDeskMaterial` and cannot cancel a store
call already in flight, and `confirmDurablyImported` samples `hasPayload` before `acknowledge`
without revalidating. Every clause held. **Measured, not argued** — §6 reproduces the whole sequence:
the successor's card ends `syncedPending`, `loadWorkMaterialPayload` returns nil, 0 blob rows.

### The mechanism: an App Group advisory file lock, keyed by material id

**`WorkMaterialPublicationLock.swift`, final API — verbatim:**

```swift
#if !os(watchOS)

nonisolated struct WorkMaterialPublicationLock: Sendable {

    final class Hold: @unchecked Sendable {
        init(descriptor: Int32)
        func release()          // idempotent; `deinit` releases whatever is left
    }

    enum LockError: Error {
        case unavailable        // the directory or its file could not be opened
    }

    let directoryURL: URL

    init(directoryURL: URL, pollInterval: Duration = .milliseconds(20))

    func acquire(materialID: UUID) async throws -> Hold
}

#endif
```

**`ConversationStore.swift`, the lock region — verbatim:**

```swift
private var workMaterialPublicationLockStorage: WorkMaterialPublicationLock?

/// Nil for an in-memory store — no other process can open one.
var workMaterialPublicationLock: WorkMaterialPublicationLock? { ... }

private static func publicationLockDirectory(besideCore coreURL: URL?) -> URL?
```

Held from BEFORE staging/blob lookup through the material save, the confirmation and every rollback,
by `defer { publicationHold?.release() }` at the top of both `publishWorkMaterial` and
`replaceWorkMaterialPayloadFile` — so `upsertDeskMaterial`'s whole publication is covered.

**Why `flock`, and why not the alternatives.** `flock(2)` is released by the kernel when the
descriptor closes, including on process death — no staleness horizon to tune, no lock file to reap,
and a jetsam mid-publication cannot wedge a material for ever. It is scoped to the OPEN FILE
DESCRIPTION rather than the process, which is what lets two `ConversationStore` instances in one test
process contend exactly as two processes do; `fcntl` byte-range locks are per-process and would have
made the takeover untestable. Blocking `flock` cannot be cancelled, so waiting is a poll of
`LOCK_EX | LOCK_NB` with `try await Task.sleep` between attempts — that sleep IS the cancellation
awareness the contract asks for, and `Task.checkCancellation()` guards the first attempt.
Lock files are **never unlinked**: unlinking races a concurrent opener onto a different inode, and
two holders of two inodes are not holding one lock. A zero-byte file per material ever published is
the price, bounded by the cards the desk has held. All of this is written at the file header.

**Where the directory comes from, and why it is not a second App Group query.** It is
`<coreStoreURL directory>/<coreStoreStem>-Locks/` — in production `<AppGroup>/Conversations-Locks/`,
derived from the Core store description the one existing App Group lookup already set.
`scripts/check-storage-seam.sh` counts a second `containerURL(forSecurityApplicationGroupIdentifier:)`
as a seam change; there is none (`✓ storage seam intact — 794 Swift files scanned`, exit 0).

**Adjudication O-1 implemented as decided: a lock, NOT a schema column.** No column was added; the
model-16 shape is untouched, so nothing new is owed to CloudKit Production.

**Test seam (verbatim), reachable to c-drainer:**

```swift
var workMaterialPublicationLockHoldForTesting: (@Sendable (UUID) async -> Void)?
func _setWorkMaterialPublicationLockHoldForTesting(_ hold: (@Sendable (UUID) async -> Void)?)
```

`#if CONDUCK_TESTING` inside `#if !os(watchOS)`, gated on `isIsolatedTestStore`, with a
WHY-IT-HAS-TO-EXIST header. Awaited in `publishWorkMaterial` at exactly ONE point — inside the lock,
after STEP 1 (the blob is durable) and before STEP 2 (the material transaction). That placement is
load-bearing rather than convenient: a hold taken before staging would leave the predecessor with no
blob to adopt, and the defect would not reproduce at all. Not added to the reattach: nothing needs it.

**Regression test.** `WorkboardPublicationLockTests.testASuccessorNeverAdoptsABlobThePredecessorCanStillRollBack`
— two `ConversationStore(storeURL:)` instances over ONE sqlite file (`IsolatedWorkStores.make(storeURL:)`),
one deterministic material id, the same bytes. The predecessor is stopped inside its lock by the seam,
then refused by a stale `expectedOwnerRevision` so its rollback deletes the blob it inserted; the
successor is launched only once an actor gate proves the predecessor is inside. Asserted: the ORDER
(`["predecessor-inside", "predecessor-leaving", "successor-inside"]` — the successor's own hold cannot
fire until the predecessor has left), and the OUTCOME (`loadWorkMaterialPayload` returns the payload,
one blob row with the right hash and size, the card reads `.synced`).
`adopted.hasPayload` is asserted with a comment saying it is NOT discriminating — it is true in both
worlds, because it is what the drainer's barrier samples and the deletion has not happened yet. That
is the whole of O-18 stated as data. Plus a unit case,
`testOneMaterialIsHeldExclusivelyWhileOthersAreFreeAndAWaiterCanBeCancelled`: exclusive per material,
free between materials, released by the holder, and a cancelled waiter throws `CancellationError`.

## 2. r3s#2 — a targeted pre-rewrite envelope can never be adopted. CONFIRMED, fixed.

**Verified against the pre-rewrite code, as instructed.** `git show
651a859:Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift`: `destination(for:)` checks
`fetchWorkItem(captureEnvelopeID: envelope.id)` FIRST, so when it falls through to the
`envelope.targetWorkItemID` branch the chosen item provably does NOT carry this envelope's id; that
branch then wrote materials with `addWorkMaterial(draft, to: item.id)` /
`addWorkMaterialFile(…, to: item.id)` and touched no column on the owner row. `requireAdoptable`
accepted `.captureEnvelope(id)` only when `ownerRow.captureEnvelopeID == id`, so the replay throws
`invalidMaterialOwner` on every attempt for ever. Confirmed.

### The provenance type extension — VERBATIM

```swift
nonisolated enum WorkMaterialLegacyProvenance: Sendable, Equatable {
    case captureEnvelope(UUID, legacyTargetWorkItemID: UUID?)
    case chatMessage(UUID)

    /// A replay of an envelope that named no target.
    static func captureEnvelope(_ id: UUID) -> Self {
        .captureEnvelope(id, legacyTargetWorkItemID: nil)
    }
}
```

Additive by construction: the static overload keeps every existing one-argument call site compiling,
which is what made this safe to land mid-phase. `requireAdoptable`'s one changed line:

```swift
case .captureEnvelope(let id, let legacyTargetWorkItemID):
    matches = envelopeID == id || owner == legacyTargetWorkItemID
```

**The kind check and the absent-owner refusal are untouched** — a missing owner row still refuses,
because CloudKit can import a material ahead of its item.

**Regression test.** `WorkboardDeskUpsertTests.testAPartiallyDrainedTargetedPreRewriteEnvelopeReplaysCleanOntoTheDesk`
— the REAL fixture: an item the person made (`captureEnvelopeID` asserted nil), two of the envelope's
deterministic ids already parked under it, one entry never drained. The refusal half is asserted from
the SAME fixture before the fix's path is taken: a replay carrying only the envelope id, and one
carrying a foreign target, both throw `invalidMaterialOwner` and leave the card where it was — so the
case pins the mechanism, not a loosened gate. Then the real provenance adopts both, publishes the
third, and the person's item survives, empty, still titled.

**c-drainer's side is already done and verified green.** `WorkCaptureDrainer.legacyProvenance(of:)`
now returns `.captureEnvelope(envelope.id, legacyTargetWorkItemID: envelope.targetWorkItemID)` and all
three call sites (`:222`, `:249`, `:255`) route through it. The Request stands recorded in §Requests 1
in case that file is rebased.

## 3. r3s#3 — a committed-but-unreadable card counted as a failed import. CONFIRMED, fixed.

**Verified:** `importMaterial` caught only `WorkboardStoreError.staleRevision` and rethrew everything
else; `WorkMaterialCommittedUnavailableError` therefore reached `WorkboardViewModel`, which counts
`failed += 1` and adopts no desk, while `WorkboardMaterialImport.init` defaults `id` to a fresh UUID —
so the person's repeat drop publishes a second card beside the unreadable one.

**Fix, at the repository level and standing on its own:** a `catch let committed as
WorkMaterialCommittedUnavailableError` clause that fetches the desk, requires `error.record.id` to
actually be on it, and returns that snapshot. The card's own `.unavailableOnThisDevice` availability
is what tells the person the bytes are not here. If the record is somehow not on the desk the error is
rethrown — an import that really did fail is still a failure.

**No view-model change is needed, and none is requested.** `WorkboardViewModel.importMaterialsUnlocked`
already `adopt(refreshed)`s whatever the dependency returns and counts it as added; the fix is
complete at the boundary the finding names.

**Regression test.** `WorkboardLiveRepositorySupportTests.testACommittedCaptureWhoseBytesCannotBeProvedComesBackAsTheCardItPublished`
— a real `WorkboardLiveRepository` over an isolated store, driven through `makeDependencies()`. A
zero-length file takes the vault lane (the only lane whose publication can refuse), the confirmation
seam removes the leaf between the commit and the proof, and the import must RETURN a desk holding
exactly that card, reading `.unavailableOnThisDevice`. The case then drives the repair route
(`replaceMaterial` on the same id) to `.available`, so "adopt the committed card" is shown to be a
route forward and not a dead end.

## 4. r3s#4 — a refused reattach destroyed the synced payload it was replacing. CONFIRMED, fixed.

**Verified:** the swap's `.localVault`/`.metadataOnly` branch called
`deleteBlobRows(materialID:in:)` inside the transaction, at which point the new leaf had been proved
readable but not CONFIRMED; `restoreReplacedPayload` then refused any prior row that was not
`.localVault`, so the card was left naming an unreadable leaf with its old bytes already gone
account-wide, on a reattach reported as failed.

### The fix, in the order the finding asks for

1. **The old blob rows stay through the swap.** The transaction points every physical row at the
   vault and deletes no blob.
2. **They are retired only after the leaf is proved**, in a follow-up logical operation — new
   `private func retireReplacedBlobRows(materialID:)`, called after `guard publicationIsDurable` and
   only when the new lane is not `.syncedPayload` (the synced→synced case retires superseded rows
   inside its own transaction, which is correct and untouched).
3. **The restore is now lane-aware.** `restoreReplacedPayload` judges each prior physical row against
   the lane it claimed: `.localVault` needs its leaf readable, `.syncedPayload` needs a complete blob
   (`workMaterialBlobCompleteness`), `.metadataOnly` and a row with no lane column claim nothing and
   pass, and a lane this build does not know refuses. That generalisation is the same rule the old
   guard stated — restore only when it is lossless — applied per row instead of to the vault lane
   alone; it is stated at the declaration.

**The invariant and its residue are stated at the deletion sites**, as required: `deleteBlobRow(_:)`
now names BOTH mechanisms that make object-scoped rollback safe (the in-process claim, the
cross-process lock) and the one thing neither reaches (a peer's import of an identical row, which is
why identity is the object id); `deleteBlobRows(materialID:in:)` states the widened crash window — a
process that dies between the confirmation and the retirement leaves blobs for a card that no longer
claims the synced lane, nothing reads them, and the alternative costs the person their payload every
time a confirmation refuses.

**Regression test.** `WorkboardBlobPublicationTests.testAReattachOffTheSyncedLaneKeepsTheBlobItWasReplacing`
(the rewrite of `testAReattachOffTheSyncedLaneReportsTheCommittedCardItCannotRestore`, whose asserted
behaviour this finding overturns — the old case asserted the loss as correct). It now pins: the rows
go back to `syncedPayload` with no vault key and the original `byteSize`, one blob row survives with
the original hash, `loadWorkMaterialPayload` returns the original bytes, the card reads `.synced` with
its original filename, and the failure is the ordinary `materialPayloadUnavailable` (nothing committed
for a caller to adopt) rather than a committed-unavailable one. The success direction is already
pinned by the two existing cases that assert the blobs ARE gone after a proved reattach
(`testReattachingAnUnsyncableFileMovesACardOffTheSyncedLaneWithItsBlob`,
`testReattachWritesEveryDuplicateRowSoNoneResurrectsTheOldLane`) — both still pass, so the pair fixes
the ORDERING and not merely the presence.

## 5. r3s#6 — the ceiling-memory test. Bound DELETED, recorded as accepted debt.

**The escape hatch the finding allows does not exist here.** `grep -rn 'XCTMetric|XCTMemoryMetric|
measure(metrics'` over `ConduckTests/` returns nothing, and there is no helper-process facility in
either bundle (`Process()` appears nowhere in the test target). So the instructed fallback applies:
the memory bound is **deleted**, along with the now-dead `FootprintSampler`.

`testACeilingSizedPayloadStaysBoundedInPeakMemory` becomes
`testACeilingSizedPayloadIsWrittenWholeAndReadBackWhole`, keeping only the honest half — the
ceiling-sized payload routes to the payload store, its row records the full length, and the bytes come
back byte-for-byte through the external-storage attribute. Its doc comment states plainly WHAT IS NO
LONGER COVERED and why an assertion that can pass while the defect is present is worse than none.
Recorded under §Decisions 4 as accepted debt.

## 6. The counterfactual — MEASURED, in an isolated copy

`~/Library/Caches/gigaduck-builds/c-store/cf-tree`, an rsync snapshot with its `Identity-Override`
symlink re-pointed at the same real file. **Nothing in the worktree was touched for this.** One
variant, reverting all four mechanisms in the copy's PRODUCTION files only (tests untouched): both
`workMaterialPublicationLock?.acquire` sites and their `defer`s removed; `matches` back to
`envelopeID == id`; the repository's committed-unavailable catch removed; `deleteBlobRows` back inside
the swap, `retireReplacedBlobRows` dropped, and the old localVault-only restore guard restored.

`cf-bft-1.log` → `** TEST BUILD SUCCEEDED **`, 0 errors. `cf-test-1.log` → `** TEST EXECUTE FAILED **`:

| Class | Result on the reverted code |
|---|---|
| `WorkboardPublicationLockTests` | `Executed 2 tests, with 6 failures (0 unexpected)` |
| `WorkboardBlobPublicationTests` | `Executed 21 tests, with 1 failure (1 unexpected)` |
| `WorkboardDeskUpsertTests` | `Executed 15 tests, with 1 failure (1 unexpected)` |
| `WorkboardLiveRepositorySupportTests` | `Executed 6 tests, with 1 failure (1 unexpected)` |
| `WorkboardChatCaptureTests` | `Executed 8 tests, with 0 failures` |
| `WorkboardAvailabilityTests` | `Executed 10 tests, with 0 failures` |
| `WorkboardBlobGCTests` | `Executed 6 tests, with 0 failures` |
| `WorkboardTwoStoreLoadTests` | `Executed 7 tests, with 0 failures` |
| `ConversationStoreAtomicWorkCaptureTests` | `Executed 4 tests, with 0 failures` |

**Exactly 4 distinct cases fail, every one of them a case I added or rewrote, and NO pre-existing case
failed.** Verbatim lines (elided where the record dump is long):

```
testASuccessorNeverAdoptsABlobThePredecessorCanStillRollBack : XCTAssertEqual failed: ("["predecessor-inside", "successor-inside", "predecessor-leaving"]") is not equal to ("["predecessor-inside", "predecessor-leaving", "successor-inside"]")
testASuccessorNeverAdoptsABlobThePredecessorCanStillRollBack : XCTAssertEqual failed: ("nil") is not equal to ("Optional(37 bytes)")
testASuccessorNeverAdoptsABlobThePredecessorCanStillRollBack : XCTAssertEqual failed: ("0") is not equal to ("1") - one publication survived, and it is the one that committed
testASuccessorNeverAdoptsABlobThePredecessorCanStillRollBack : XCTAssertEqual failed: ("nil") is not equal to ("Optional("4348377366463fe940d4393b9d3300b087d545bf4af05b573ab558c9dee7a57f")")
testASuccessorNeverAdoptsABlobThePredecessorCanStillRollBack : XCTAssertEqual failed: ("nil") is not equal to ("Optional(37)")
testASuccessorNeverAdoptsABlobThePredecessorCanStillRollBack : XCTAssertEqual failed: ("syncedPending") is not equal to ("synced")
testAReattachOffTheSyncedLaneKeepsTheBlobItWasReplacing : failed: caught error: "WorkMaterialCommittedUnavailableError(record: … storageMode: …localVault, availability: …unavailableOnThisDevice …)"
testAPartiallyDrainedTargetedPreRewriteEnvelopeReplaysCleanOntoTheDesk : failed: caught error: "invalidMaterialOwner"
testACommittedCaptureWhoseBytesCannotBeProvedComesBackAsTheCardItPublished : failed: caught error: "WorkMaterialCommittedUnavailableError(record: … availability: …unavailableOnThisDevice …)"
```

The first block is O-18 reproduced end to end: the successor adopts inside the predecessor's window,
its card ends `syncedPending`, and the payload is gone.

**One case is argued rather than reverted, and I say which.**
`WorkboardPublicationLockTests.testOneMaterialIsHeldExclusivelyWhileOthersAreFreeAndAWaiterCanBeCancelled`
passes on the reverted tree, because I reverted the lock's USE and not the lock file itself — it is a
unit test of a type that did not exist before, so there is no old code for it to fail against. Its
value is that the four properties the takeover depends on are each pinned separately.

## Guard verdicts

**None.** No `t#N` guard item was assigned to me this wave, and I converted, kept or deleted no
source-text guard. `WorkboardBlobSeamPlatformGuardTests.testThePayloadSeamsAreCompiledOutOfTheWatchBuild`
was left exactly as it stands and passes (`Executed 1 test, with 0 failures`) — its `payloadSeams`
list is a subset check, so my new seam is simply unlisted; see §Requests 3.

## Catalog

**Keys I ADDED in source: NONE.** Nothing in this slice is user-facing: the lock is headless, the
provenance change is a store-side gate, the repository change turns a thrown error into a returned
snapshot the existing card copy already describes, and `WorkMaterialPublicationLock.LockError`
deliberately does not conform to `LocalizedError` — matching `WorkMaterialCommittedUnavailableError`
and `WorkboardStoreError.materialPayloadUnavailable`, whose `errorDescription` is nil on purpose: an
internal invariant failure has no user action, and inventing copy for one dresses a bug up as a
decision.

**Keys I made DEAD: NONE.** I deleted no code carrying a key.

**No `.xcstrings` file was opened** (`git status --short -- '*.xcstrings'` empty).

## Decisions

1. **`flock` on a per-material lock file, not a publication-identity column** (§1) — O-1 decided this,
   and the reasons hold up in code: the column is a schema change to a model headed for CloudKit
   Production that could never be withdrawn, while a file lock is withdrawable at any time and is
   released by the kernel on process death. `fcntl` byte-range locks were rejected because they are
   per-process and would have made the takeover untestable in one process.
2. **The lock is nil for an in-memory store** (§1) — nothing else can open one, so there is nothing to
   exclude and the in-process claim is the whole answer; the alternative (a shared temp lock
   directory) would couple unrelated test stores to each other for no invariant.
3. **Lane-aware restore rather than synced-only** (§4) — `.metadataOnly` prior rows are restored too.
   The finding names the synced lane, but the rule it states is "restore whenever that is lossless",
   and putting a row back to claiming no payload is trivially lossless. Narrowing it to the two lanes
   the finding happened to mention would have left a reattach onto a chat "Reattach in Work"
   placeholder failing into a permanently unreadable card for no reason.
4. **The ceiling memory bound is deleted, not weakened** (§5) — accepted debt, with the gap stated in
   the test's own doc comment. Reinstating it needs a helper process with a high-water mark or an
   allocator instrument; neither exists in this bundle, and this is not the wave to build one.
5. **No hold seam on the reattach path** (§1) — the takeover the findings describe is a desk
   publication racing a desk publication. A second seam would be wider than any test needs.
6. **No Codex consult.** The one genuinely hard call — whether `flock`'s per-descriptor scope is
   real on Darwin, since the whole two-store test rests on it — is settled by measurement rather than
   by opinion: §6 shows the successor blocking with the lock and interleaving without it, in one
   process.

## Deviations

- **`ConversationStore.swift` gains one production stored property and one static function**
  (`workMaterialPublicationLockStorage`, `publicationLockDirectory(besideCore:)`), beyond the literal
  "publication-claim/lock region and CONDUCK_TESTING seams". Swift extensions cannot add stored
  properties, `ConversationStore` is an actor, and the directory has to come from the Core store
  description that only this file holds — a file-scope global would be shared across store instances,
  which is wrong for isolated test stores. Both sit in the same region as the two existing claim sets,
  in the same style. Declared here rather than done quietly.
- **`_removeIsolatedVaultDirectoryForTesting()` now also removes the lock directory.** It is the only
  place that can: the path is derived from a store description a test does not read. The name is
  unchanged (`WorkboardBlobSeamPlatformGuardTests` matches on it) and the doc comment says what it
  now takes. Measured: **0 leftover `*-Locks` directories** in the simulator after the full run.
- **`WorkboardChatCaptureTests.swift` and `WorkboardIsolatedStoreFixture.swift` are untouched.** Both
  are mine and neither needed a change: the fixture already offers `make(storeURL:)`, which is exactly
  what the two-store topology needs.
- **O-2 in my classes: `WorkboardLiveRepositorySupportTests` converted** (it built a bare
  `ConversationStore(inMemory: true)`), and the new `WorkboardPublicationLockTests` uses the fixture
  from the start. Every one of my classes now makes stores through `IsolatedWorkStores` and calls
  `await isolated.cleanUp()` from an async `tearDown`; **none of my classes leaves a spawned task
  running at teardown** — the lock test awaits both of its tasks inside the case before asserting, and
  its cancelled waiter is awaited too. The 88 vault directories still in the simulator belong to
  classes I do not own (§Requests 4).

## Gates — WHAT I ACTUALLY RAN

Slug `c-store`. DerivedData under `~/Library/Caches/gigaduck-builds/c-store/{DerivedData,
DerivedDataMac,DerivedDataWatch,DerivedDataCF,cf-tree}`, every log written there and grepped for
`': error: '` and the verdict strings — never judged from tail or exit code. **No `-configuration`
passed anywhere.** Sim `C26F4ECE-16AC-40B7-8D6A-BBF82B5BBA5D`.

- **iOS `build-for-testing`** → `bft-6.log` (final): `grep -c ': error: '` = **0**,
  `** TEST BUILD SUCCEEDED **`.
- **FULL iOS suite**, `test-without-building` → `ios-full-1.log`, `** TEST EXECUTE FAILED **`,
  `Executed 4906 tests, with 1 test skipped and 3 failures (0 unexpected) in 90.842 (97.117) seconds`.
  **All 3 failures are foreign and expected in this phase** — one case,
  `WorkboardCopyTruthGuardTests.testEveryWorkKeyInSourceHasACatalogRow`, failing three times for
  `workboard.sync.banner.noAccount` / `.restricted` / `.quotaExceeded`: c-guards' C7 keys, declared in
  source, catalog rows spliced by c-copy-docs in C3. The single skip is the environment-conditional
  `GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`. I ran the full
  suite because my files are on every capture path.
- **My 9-class VERIFY set**, from that same full run:

| Class | Result |
|---|---|
| `WorkboardPublicationLockTests` | `Executed 2 tests, with 0 failures` (new) |
| `WorkboardBlobPublicationTests` | `Executed 21 tests, with 0 failures` |
| `WorkboardDeskUpsertTests` | `Executed 15 tests, with 0 failures` (was 14) |
| `WorkboardChatCaptureTests` | `Executed 8 tests, with 0 failures` |
| `WorkboardTwoStoreLoadTests` | `Executed 7 tests, with 0 failures` |
| `WorkboardLiveRepositorySupportTests` | `Executed 6 tests, with 0 failures` (was 5) |
| `WorkboardAvailabilityTests` | `Executed 10 tests, with 0 failures` |
| `WorkboardBlobGCTests` | `Executed 6 tests, with 0 failures` |
| `ConversationStoreAtomicWorkCaptureTests` | `Executed 4 tests, with 0 failures` |

  (An earlier targeted run of the same nine, `test-3.log`, reported
  `** TEST EXECUTE SUCCEEDED **` / `Executed 79 tests, with 0 failures (0 unexpected)`.)
- **macOS `build -destination 'platform=macOS'`** → `mac-1.log`: 0 `: error: `,
  `** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`.
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed.**
- **watchOS `build-for-testing`** (`-scheme ConduckWatchTests`, sim
  `28AC563B-42C1-4E66-940D-77E63B07918B`) → `watch-bft-1.log`: 0 `: error: `,
  `** TEST BUILD SUCCEEDED **`. Run because `ConversationStore.swift` is a Watch target member and I
  added a conditional region to it. **I did not RUN the watch suite** — no watch sim is assigned to me
  and it is not in my VERIFY.
- **Counterfactual** → `cf-bft-1.log` (`** TEST BUILD SUCCEEDED **`, 0 errors), `cf-test-1.log`
  (`** TEST EXECUTE FAILED **`); table and verbatim lines in §6.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 794 Swift files scanned…`, exit 0.
- `git diff --check` → clean, exit 0. `git status --short` for `*.xcstrings`, `*.pbxproj`,
  `Conduck/Configs`, `docs/qa` → **empty**.
- **Build caches, the isolated copy and every log removed at end of task** with
  `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh c-store`. Re-run if the
  integrator needs the logs.

### Suite delta for the orchestrator

**+3 iOS executed** from this slice: `WorkboardPublicationLockTests` 0→2, `WorkboardDeskUpsertTests`
14→15, `WorkboardLiveRepositorySupportTests` 5→6, `WorkboardTwoStoreLoadTests` 7→7 (a case renamed and
narrowed, not removed), `WorkboardBlobPublicationTests` 21→21 (a case rewritten). Measured full-suite
total with the whole wave's in-flight work in the tree: **4906 executed, 1 skipped**.

### What I did NOT verify, plainly

- **The watch SUITE** (built, not run) and the drift-guard / folder-map scripts outside my VERIFY.
- **A genuinely multi-PROCESS run.** The takeover test uses two store instances in one process, which
  `flock`'s per-descriptor scope makes a faithful stand-in — but I did not build a two-executable
  harness, and the App Group path itself (`<AppGroup>/Conversations-Locks/`) is exercised only by
  derivation, never on a signed device. §Requests 5 puts it on Gate 2.
- **The ceiling's PEAK MEMORY** is now uncovered by decision (§5), not by oversight.
- **Whether the lock behaves under a sandboxed macOS App Group container at runtime.** The macOS build
  is green and the lock uses no privileged API, but no macOS run exercised it.

## Call-site touches

**None.** Every symbol I changed kept a compiling call shape: `legacyProvenance:` gained an additive
case with a same-name overload, `upsertDeskMaterial`'s signature is unchanged, and
`WorkboardLiveRepository.importMaterial`'s change is internal to its own `do`/`catch`.

## Requests

1. **c-drainer — already satisfied, recorded in case of a rebase.** The one-line change is, verbatim,
   at each of the three desk writes in `WorkCaptureDrainer.persist`:
   `legacyProvenance: .captureEnvelope(envelope.id, legacyTargetWorkItemID: envelope.targetWorkItemID)`
   (they have factored it into `private static func legacyProvenance(of:)`, which is better; all three
   sites route through it and the tree is green). **Do not drop the target argument** — without it a
   partially drained targeted envelope is refused for ever, which is r3s#2.
2. **Nobody take the publication lock later than staging, or release it before the confirmation.**
   Acquiring after the blob lookup reopens O-18 exactly: the successor's adoption decision happens
   inside `publishWorkMaterialBlob`, so the lock must already be held when that runs. The
   `defer { publicationHold?.release() }` placement is what covers every rollback path.
3. **Whoever owns `WorkboardBlobSeamPlatformGuardTests.swift`** may want one row added to
   `payloadSeams`: `var workMaterialPublicationLockHoldForTesting`. It is already inside
   `#if CONDUCK_TESTING` + `#if !os(watchOS)` (the guard passes as it stands); this is drift
   insurance, not a defect.
4. **O-2's remainder is still open outside my classes.** Measured after my full run: **88**
   `conduck-workasset-tests-*` directories in the assigned simulator, and **0** `*-Locks` directories.
   The producers are the classes fix2-store named (`WorkAssetVaultTests`,
   `WorkboardMaterialBoardActionsTests`, `WorkboardDeskViewModelTests`, `WorkboardAudioCaptureTests`)
   plus whatever this wave added; each needs `private let isolated = IsolatedWorkStores()`,
   `isolated.make()` in place of the initializer, and `await isolated.cleanUp()` in an async
   `tearDown` **after cancelling and awaiting any spawned task**.
5. **Founder QA (Gate 2) — two items this slice adds.** (a) With the app in the foreground, run a
   Shortcut/App Intent capture of the same shared item at the same moment as an in-app drop of it: one
   card, and it must open. (b) Reattach a smaller file onto a Work card whose payload SYNCS, then pull
   the device off Wi-Fi and confirm the card still opens on the device that reattached — and if the
   reattach reports an error, the ORIGINAL file must still open from that card, on this device and on
   another one.
6. **Docs agent — three facts are now settled by code.** (a) One publication of a material's payload
   is in flight at a time across the whole device, app and headless intent process included, through
   an App Group advisory lock beside the store. (b) A reattach that moves a card between the storage
   lanes releases the lane it leaves only after the new one is proved readable, so a refused reattach
   gives the card its previous payload back — synced bytes included. (c) A material a pre-desk build
   parked under an item the person explicitly chose is re-homed by a replay that names both the
   envelope and that item.

## Refuted

**Nothing.** r3s#1, #2, #3 and #4 and adjudications O-1, O-2 and O-18 all held against the current
tree when traced by call path, and all four mechanisms are shown red on the reverted tree (§6).

r3s#6 is not refuted either — its evidence holds — but the fix it proposes (a helper process with a
peak-memory metric) is unavailable in this bundle, so the instructed fallback was taken: the bound is
deleted and the gap is recorded as accepted debt in §5 and §Decisions 4, with the reason written into
the test that remains.
