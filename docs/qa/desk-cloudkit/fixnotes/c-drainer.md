# c-drainer — r3s#5 CONFIRMED + fixed · O-18 regression landed · O-2 adopted · the provenance one-liner taken

Parallel phase. No commits/pushes/stash/checkout, no index operations. `Conduck/Configs/Identity-Override.xcconfig`
untouched. **No `.xcstrings` file opened.** Nothing under `docs/qa/desk-cloudkit/` touched. No mirror triplet
touched. No pbxproj edit. No file outside my ownership list edited.

Files I changed — six, all mine, plus my ONE new file:

| File | Change |
|---|---|
| `Conduck/Conduck/Services/WorkCaptureInbox.swift` | **release semantics only**: `release` abandons the local claim token on both of its failure paths (`abandonLocalClaim`) |
| `Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift` | provenance one-liner (`Self.legacyProvenance(of:)` at three call sites) + two comment corrections |
| `Conduck/ConduckTests/WorkCaptureInboxLeaseTests.swift` | 15 → **17** cases (r3s#5's two) + one injected-fault `FileManager` |
| `Conduck/ConduckTests/WorkCaptureDrainerTests.swift` | 9 → **10** cases (the targeted-replay regression) + `IsolatedWorkStores` |
| `Conduck/ConduckTests/WorkCaptureDrainerDurabilityTests.swift` | `IsolatedWorkStores` + async teardown (8 cases, unchanged) |
| `Conduck/ConduckTests/WorkAssetVaultTests.swift` | `IsolatedWorkStores` + async teardown (19 cases, unchanged) |
| `Conduck/ConduckTests/WorkCaptureDrainerTakeoverTests.swift` | **NEW** — O-18, 1 case |

**Net iOS executed: +4** (`WorkCaptureInboxLeaseTests` +2, `WorkCaptureDrainerTests` +1, the new class +1).
**No assertion anywhere was weakened, narrowed or deleted.**

---

## 1. r3s#5 — verified against the current code, then fixed

**VERDICT: CONFIRMED.** Re-located by symbol, not by the cited line, and every clause of the evidence held
when traced:

| Claim in the finding | What the code did |
|---|---|
| the drainer's error path ends the import and then discards a failing release with `try?` | yes — `persistAndAcknowledge`'s `catch`: `if await ownership.endImport() { try? await inbox.release(claim) }` |
| `release` removes `activeClaims` only after a successful move | yes — the removal sits INSIDE the `do` block, after `moveItem`; both failure paths (`destination exists`, and the move itself) threw `.filesystemFailure` with the token still present |
| every later `reconcile` then skips that directory | yes — `reconcile` opens each stranded child with `if let generation = claimed.generation, activeClaims[generation] != nil { continue }`, BEFORE it computes a destination or asks `isAbandonedClaim` |
| until process termination or another process intervenes | yes — and the move-failure path had already run `removeLease`, so the directory is markerless: another process recovers it at the horizon, this one never does |

The consequence is real and not merely theoretical: the app is a long-lived process, so one transient fault
at the moment of release strands a share capture — the queue's only copy of the person's file — invisibly, for
as long as the app stays open, with every foreground drain walking straight past it.

Nothing refuted. `## Refuted` is empty.

### 1.1 The fix, and why it is in the inbox rather than in the drainer

The finding's wording is drainer-shaped ("when an owned release fails after the import has ended, explicitly
abandon the local token"). I put the abandonment **inside `release`**, which is squarely the "release
semantics only" half of `WorkCaptureInbox.swift` I own:

```swift
guard !fileManager.fileExists(atPath: destination.path) else {
    abandonLocalClaim(claim)
    throw InboxError.filesystemFailure
}
removeLease(in: claim.directoryURL)
do { … } catch {
    abandonLocalClaim(claim)
    throw InboxError.filesystemFailure
}
```

`private func abandonLocalClaim(_:)` removes the token and touches nothing on disk, with a declaration
comment stating the constraint: reconciliation skips every directory `activeClaims` names because a live
import must never have its bytes requeued underneath it, and a token held past the end of that import inverts
that protection.

Why here and not at the call site:

1. **It is not conditional on the caller's discipline.** `release` is reached only when a claim is being given
   up; there is no path on which the caller keeps reading the directory afterwards. The drainer is the only
   production caller (`WorkCaptureDrainer.swift`), and the two test callers use the success path.
2. **A failed `acknowledge` is funnelled into the same place.** `persistAndAcknowledge`'s `catch` runs
   `endImport()` — which returns true, the claim not being lost — and calls `release`, so an
   acknowledgement that could not remove its directory now also ends with a token that cannot hide it.
   Fixing only the drainer's `try?` would have left that path.
3. **The refusals stay refusals.** Both paths still throw `.filesystemFailure`; the error type, the message
   and the on-disk state are unchanged. The collision path still refuses to overwrite either directory, and
   the move path still leaves the capture in `processing/`.

The drainer needed **no code change** for this (its `try?` is now correct rather than lossy); its comment at
the `catch` was corrected to say what actually recovers the directory.

**What recovers it, exactly.** The move-failure path leaves a markerless claim, so `isAbandonedClaim` falls to
`now - claimedAt >= staleClaimHorizon` — the same process recovers it on its next reconcile past the horizon,
without a relaunch. The collision path leaves this instance's own lease on its own generation, which
`isAbandonedClaim` already treats as a dead claim, so the directory is *looked at* every pass and reported as
a `collisionCount` until the colliding publication drains — visible instead of invisible. I deliberately did
NOT re-write a lease on the failure path to shorten the first case: writing on the path a write just failed
on is the wrong place to be clever, and the horizon is the queue's own liveness rule.

### 1.2 The two regression tests (`WorkCaptureInboxLeaseTests`, 15 → 17)

| Case | Asserts |
|---|---|
| `testAReleaseRefusedByACollisionStopsHidingTheClaimFromReconciliation` | the same capture id is pending again while this one is claimed → `release` throws `.filesystemFailure`, the claimed directory keeps `manifest.json` + payload + its lease (nothing moved, nothing stripped); `reconcile` past the horizon now reports `collisionCount == 1` and still refuses to overwrite; once the colliding publication is removed the SAME instance's next `reconcile` returns `releasedClaimCount == 1`, `pendingCount == 1`, and `claimNext` hands the capture back under a different generation |
| `testAReleaseWhoseMoveFailsLeavesTheBytesRecoverableByReconciliation` | an injected one-shot `moveItem` fault on the release → `.filesystemFailure`; the claimed directory holds `["manifest.json", "payload-000.pdf"]` and the payload still reads back byte-for-byte; `pendingCount == 0` (the release really did not land); then the SAME instance reconciles past the horizon → `releasedClaimCount == 1`, no filesystem failure, `pendingCount == 1`, and `claimNext` recovers it under a different generation |

The fault is injected through `ReleaseMoveFaultFileManager`, a one-shot `FileManager` subclass in the same
shape as the two the file already carries (`ClaimInterferenceFileManager`, `RequeueDuringClaimFileManager`).
One-shot on purpose: the reconciliation that has to recover the capture afterwards must run against a working
filesystem, or the case would prove nothing about recovery.

### 1.3 MEASURED counterfactual (CF1)

Isolated copy at `~/Library/Caches/gigaduck-builds/c-drainer/tree2` — `git archive HEAD | tar -x` plus my six
files, with the copy's `Identity-Override.xcconfig` symlink re-pointed at the same real file. **Nothing in the
worktree was touched for this.** Baseline in that copy: `** TEST BUILD SUCCEEDED **`, 0 `error:`, and the
VERIFY set `Executed 82 tests, with 0 failures`.

CF1 = the two `abandonLocalClaim(claim)` call sites removed (the helper kept, so nothing but the two lines
differs). `** TEST BUILD SUCCEEDED **`, 0 `error:`; then:

```
WorkCaptureInboxLeaseTests   Executed 17 tests, with 7 failures (0 unexpected)
WorkAssetVaultTests          Executed 19 tests, with 0 failures
WorkCaptureDrainerDurabilityTests  Executed 8 tests, with 0 failures
WorkCaptureDrainerTests      Executed  9 tests, with 0 failures
WorkCaptureInboxTests        Executed 29 tests, with 0 failures
```

All seven failure lines belong to my two new cases and to nothing else:

```
WorkCaptureInboxLeaseTests.swift:749: XCTAssertEqual failed: ("0") is not equal to ("1") - a directory this instance still counted as its own would never be looked at
WorkCaptureInboxLeaseTests.swift:761: XCTAssertEqual failed: ("0") is not equal to ("1")
WorkCaptureInboxLeaseTests.swift:763: XCTAssertEqual failed: ("0") is not equal to ("1")
WorkCaptureInboxLeaseTests.swift:765: XCTUnwrap failed: expected non-nil value of type "Claim"
WorkCaptureInboxLeaseTests.swift:806: XCTAssertEqual failed: ("0") is not equal to ("1")
WorkCaptureInboxLeaseTests.swift:809: XCTAssertEqual failed: ("0") is not equal to ("1")
WorkCaptureInboxLeaseTests.swift:811: XCTUnwrap failed: expected non-nil value of type "Claim"
```

The other 15 lease cases stayed green, so neither new case fails merely because a seam is absent, and neither
disturbs an existing invariant.

## 2. Adjudication O-18 — the stale-drainer takeover regression. LANDED.

New file `Conduck/ConduckTests/WorkCaptureDrainerTakeoverTests.swift`, one case:
`testASuccessorNeverAcknowledgesBytesItsPredecessorCanStillTakeBack`.

**The topology.** Two `WorkCaptureInbox` instances over one App Group queue directory, and two
`ConversationStore` instances over one **on-disk** sqlite (`isolated.make(storeURL:)` twice with the same
URL). On disk is not optional: `ConversationStore.workMaterialPublicationLock` is nil for an in-memory store
by design, so an in-memory pair would exclude nothing. Two instances contend exactly as two processes do
because `flock(2)` is scoped to the open file description, which is the property C8's own header names.

**The interleaving, staged step by step:**

1. The stale drainer claims the capture and is parked by `_setWorkMaterialPublicationLockHoldForTesting`
   (c-store's C8 seam) **inside the publication lock**, after the payload row is durable and before any card
   names it. Asserted at that moment: `workMaterialBlobCompleteness([entryID])` reports the payload's exact
   byte size — the bytes a successor could adopt — and the desk holds no card for it.
2. The claim ages past `staleClaimHorizon`; the successor's inbox reconciles it back to pending
   (`releasedClaimCount == 1`). The stale drainer's own heartbeat is the production 60 s interval and never
   fires inside the case, which is what keeps it parked rather than cancelled — it is a process that has not
   yet noticed anything.
3. The successor drainer drains. It claims, writes past the note, and reaches the same deterministic material
   id — where the lock stops it.
4. For a 400 ms window the case asserts, repeatedly: the successor has NOT returned, and the queue directory
   still holds `payload-000.bin` byte-for-byte. Acknowledgement is the only thing that deletes it, so the
   surviving file IS the proof that no acknowledgement happened.
5. The predecessor's bytes are then taken back — every `WorkMaterialBlob` row for that material deleted
   through a THIRD opener of the shared payload store.
6. The hold is released. The stale drain throws and consumes nothing (`WorkboardStoreError` or
   `WorkCaptureInbox.InboxError`; which one is a benign race — its barrier refuses the card whose payload is
   gone, unless the successor repaired one first, in which case its `acknowledge` is refused by the lease it
   no longer holds. It cannot delete the successor's directory either way: `requireLeaseOwnership` reads its
   OWN, now-vanished claim path and answers `.absent`).
7. Final state asserted: the successor reports one capture; `loadWorkMaterialPayload(entryID)` equals the
   payload; the card is `hasPayload`; the desk holds exactly the note and the entry; `processing/` is empty
   and `pendingCount == 0`.

**Deviation, stated plainly.** The brief says "forces rollback after the successor's barrier but before
acknowledgement". With the lock in place the successor cannot reach its barrier at all while the predecessor
holds — that impossibility IS the fix — so the rollback is staged at the equivalent point instead: the moment
the successor would have sampled. And it is staged as a direct deletion through a third opener of the payload
store rather than by forcing the predecessor's own rollback, because on the synced lane that rollback is
reachable only from a failure inside the store's write transaction, and the store's blob-deletion seams
(`_deleteWorkMaterialBlobRowsForTesting`) answer for in-memory stores only — while this case needs the real
sqlite the two instances share. A third opener is a faithful model: a rollback in another process is exactly
a third-party write to that file. (One trap for the next agent, recorded because it cost a run: a store
previously opened WITH `NSPersistentHistoryTrackingKey` and reopened without it is forced **read-only**
silently. The helper sets both history-tracking options.)

### 2.1 MEASURED counterfactual (CF2)

Copy of the SHARED tree at `~/Library/Caches/gigaduck-builds/c-drainer/tree3` (taken at a moment it built
clean), with `ConversationStore.publicationLockDirectory(besideCore:)` forced to nil — i.e. exactly C8
absent, everything else identical. `** TEST BUILD SUCCEEDED **`, 0 `error:`. Result:

```
Executed 1 test, with 4 failures (1 unexpected)
:183 XCTAssertFalse failed - no publication of this material may complete while its lock is held
:187 XCTAssertEqual failed: threw error "…payload-000.bin couldn't be opened because there is no such file" - the queue keeps the only copy until the desk provably holds one
:219 XCTAssertEqual failed: ("nil") is not equal to ("Optional(51 bytes)") - the desk holds the shared file, not a card waiting for bytes nobody has
:224 XCTAssertTrue failed
```

That is the O-18 sequence happening, in order, on demand: the successor adopted the predecessor's blob,
passed its barrier, **acknowledged and deleted the queue's only copy of the shared file**, and was then left
with a card whose payload nobody has. With C8 in place the same case is green.

## 3. Adjudication O-2 — `IsolatedWorkStores` adopted in my classes

Converted, every `ConversationStore(inMemory: true)` → `isolated.make()`, plus a fixture and an async
teardown that awaits `cleanUp()`:

| Class | Direct store constructions removed | Teardown |
|---|---|---|
| `WorkAssetVaultTests` | 6 | new `tearDown() async throws` (the class had none) |
| `WorkCaptureDrainerDurabilityTests` | 7 | `tearDownWithError` → `tearDown() async throws`, cleanup first, then the inbox root |
| `WorkCaptureDrainerTests` | 9 | same conversion |
| `WorkCaptureDrainerTakeoverTests` (new) | uses `isolated.make(storeURL:)` | cancels and **awaits** both drains, then cleans up, then removes the sqlite/`-Blobs`/`-Locks` files |

`WorkCaptureDrainerTests` is not named in the adjudication but is mine, builds real vault leaves from its
attachment cases, and is the same defect class — converting it now is what the adjudication's "then
mechanically adopt it elsewhere as those classes are touched" asks for.

**On the "cancel and await every spawned task first" clause.** In the two existing drainer classes every case
already awaits its own drain before returning (`async let … ; try await drained`, or `Task { … }` + `await
drain.result`), and an `async let` skipped by a thrown assertion is cancelled and awaited at scope exit — so
teardown cannot race a store operation, and I added no machinery there. The new takeover class DOES need it,
because an early assertion can leave a drain parked on a lock: it tracks its drains and `tearDown` cancels
and awaits each one **before** `isolated.cleanUp()` and before the sqlite files are removed.

`WorkCaptureDrainerDurabilityTests`' >30 MB case — the one the adjudication singles out as the active
reliability problem — now has its vault removed at teardown.

## 4. The provenance one-liner (r3s#2's drainer half) — TAKEN

c-store's extended type had already landed when I finished
(`case captureEnvelope(UUID, legacyTargetWorkItemID: UUID?)` plus a one-argument overload, and
`requireAdoptable` matching on `envelopeID == id || owner == legacyTargetWorkItemID`). The drainer's three
`.captureEnvelope(envelope.id)` sites now go through one private static:

```swift
private static func legacyProvenance(of envelope: WorkCaptureEnvelope) -> WorkMaterialLegacyProvenance {
    .captureEnvelope(envelope.id, legacyTargetWorkItemID: envelope.targetWorkItemID)
}
```

A named helper rather than three copies of the same two-argument literal: the *reason* the drainer carries a
target it never honours as a destination is not obvious at a call site, and stating it once is what stops the
next reader "simplifying" it back. The file header's sentence about `targetWorkItemID` was corrected to match
(never honoured **as a destination**; carried as evidence).

**Regression** — `WorkCaptureDrainerTests.testAPartiallyDrainedTargetedCaptureReplaysOntoTheDesk` (9 → 10):
a pre-desk targeted drain is staged for real (a work item the person picked, holding a material under the
ENTRY's own id, with the owner row left untouched), then the same envelope — carrying that
`targetWorkItemID` — is drained. It must complete, re-home the stranded card onto the desk beside the note,
leave the chosen item empty (re-homed, not copied), and consume the queue.

**MEASURED counterfactual (CF3):** in `tree3`, with only the drainer's provenance reverted to
`.captureEnvelope(envelope.id)` and c-store's type left in place —
`WorkCaptureDrainerTests Executed 10 tests, with 1 failure`,
`testAPartiallyDrainedTargetedCaptureReplaysOntoTheDesk] : failed: caught error: "invalidMaterialOwner"`,
and the takeover case in the same run stayed green. That is r3s#2's "refused on every replay for ever",
reproduced and then closed.

## 5. Gates — WHAT I ACTUALLY RAN

Slug `c-drainer`. Everything under `~/Library/Caches/gigaduck-builds/c-drainer/`
(`DerivedData`, `DerivedDataCF`, `DerivedDataCF2`, `tree2`, `tree3`, every log). Each log grepped for
`': error: '` and for `BUILD SUCCEEDED|BUILD FAILED|TEST SUCCEEDED|TEST FAILED|Executed ` — never judged from
a tail or an exit code. **No `-configuration` passed anywhere.** Sim
`E953B6D8-44F3-4595-9C24-29F3991C13FE`.

- **iOS `build-for-testing`** on the shared worktree → `bft-8.log` (final): `grep -c ': error: '` = **0**,
  `** TEST BUILD SUCCEEDED **`.
- **Warnings in files I own: zero.** The two in `WorkCaptureInboxLeaseTests.swift:33,60` ("converting
  non-Sendable function value…") are **pre-existing** — both lines are byte-identical to `HEAD`, verified
  with `git show HEAD:… | sed -n 33p` / `60p`, and fix2-inbox recorded them.
- **VERIFY set** (`test-11.log`, `test-without-building`, one quoted `-only-testing` per class),
  `** TEST EXECUTE SUCCEEDED **`:

| Class | Result | Was |
|---|---|---|
| `WorkAssetVaultTests` | `Executed 19 tests, with 0 failures (0 unexpected) in 0.117 (0.122) seconds` | 19 |
| `WorkCaptureDrainerDurabilityTests` | `Executed 8 tests, with 0 failures (0 unexpected) in 0.714 (0.716) seconds` | 8 |
| `WorkCaptureDrainerTakeoverTests` | `Executed 1 test, with 0 failures (0 unexpected) in 0.529 (0.529) seconds` | new |
| `WorkCaptureDrainerTests` | `Executed 10 tests, with 0 failures (0 unexpected) in 0.101 (0.103) seconds` | 9 |
| `WorkCaptureInboxLeaseTests` | `Executed 17 tests, with 0 failures (0 unexpected) in 0.081 (0.084) seconds` | 15 |
| `WorkCaptureInboxTests` | `Executed 29 tests, with 0 failures (0 unexpected) in 0.144 (0.150) seconds` | 29 |
| total | `Executed 84 tests, with 0 failures (0 unexpected) in 1.685 (1.706) seconds` | |

- **Neighbours, one run earlier** (`test-10.log`, same tree plus the store-adjacent classes),
  `** TEST EXECUTE SUCCEEDED **`, `Executed 136 tests, with 0 failures (0 unexpected)`:
  `WorkboardAvailabilityTests` 10/0 · `WorkboardBlobGCTests` 6/0 · `WorkboardBlobPublicationTests` 21/0 ·
  `WorkboardDeskUpsertTests` 15/0. That is the measurement that matters for a change to `release`: nothing
  storage-adjacent moved.
- `git diff --check` → clean, exit **0**.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 794 Swift files scanned…`, exit 0.
- `bash scripts/check-folder-map.sh` → `✓ folder map current — 36 Swift source directories, all mapped…`,
  exit 0. The new test file lands in a directory the map already names; **no pbxproj edit was needed** and
  `git status --short -- Conduck/Conduck.xcodeproj` is empty (the group is a
  `PBXFileSystemSynchronizedRootGroup`, and the file compiled and ran in the same bundle).
- `git status --short -- '*.xcstrings' '*WorkCaptureEnvelope.swift' '*ShareTargetsSnapshot.swift' '*WorkCaptureDirectoryPublisher.swift' 'Conduck/Configs' 'Conduck/Conduck.xcodeproj' 'docs/qa'` → **empty**.
- Build caches, both isolated copies and every log removed at end of task with
  `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh c-drainer`. **The logs go with
  them** — re-run if the integrator needs them.

### NOT run, stated plainly

- **macOS build — not run.** My brief says it is not required for this slice, and I did not run it. Neither
  file I changed in the app target contains platform-conditional code beyond the `#if !os(watchOS)` fences
  they already had, and `WorkCaptureInbox.swift` and `WorkCaptureDrainer.swift` are not in the watch target;
  but I did not prove either the macOS or the watch build myself.
- **Full iOS suite and watch suite — not run.** Neither is in my VERIFY, and several agents were editing the
  tree throughout, so a full-suite number from me would have been mostly theirs.
- **Nothing on a real device, and no UI.** The takeover case proves the lock's ORDERING with two store
  instances in one process; it does not prove two real processes. That remains Gate-2 founder QA (§Requests 6).
- **One honest weakness in the takeover case, named.** "The successor has not finished" is observed by
  polling a flag the successor's own task sets, over a 400 ms window — a bound, not a proof of blocking. The
  assertion that carries the weight beside it is the queue file still being present (acknowledgement is the
  only thing that deletes it), and CF2 shows both go red together when the lock is removed in 1.65 s.

### Parallel-phase blockage (not mine, recorded per protocol)

`bft-2` and `bft-3` failed **only in `Conduck/ConduckTests/WorkVoiceRecoveryTests.swift`** (33 errors:
`'async' call in an autoclosure that does not support concurrency`, `actor-isolated property 'armed' can not
be referenced from the main actor`) — c-recovery-core's in-flight file. I waited ~2 minutes, retried, and it
cleared on its own; I edited nothing to work around it. An earlier copy of the tree also caught
`ContentView.swift:554: the compiler is unable to type-check this expression in reasonable time` mid-edit,
which is why the r3s#5 counterfactual copy was rebuilt from `git archive HEAD` plus my own files rather than
from a live rsync. Two test runs died on `Simulator device failed to launch … Busy` / `Mach error -308`;
`xcrun simctl shutdown all` plus a retry cleared each, per the standing rule.

---

## Guard verdicts

**None assigned, none touched.** My brief names no `t#N` guard item, and no file I own contains a source-text
drift guard. I converted nothing, kept nothing on that basis, and deleted nothing.

## Catalog

**Keys I ADDED in source: NONE.** Every change in this slice is headless — a claim token, a provenance
argument, and tests. `WorkCaptureInbox.InboxError.filesystemFailure` and `.staleClaim` are pre-existing cases
with no user-facing copy of their own.

**Keys I made DEAD: NONE.** I deleted no code that carried a string. The five keys the drainer owns are all
still live: `workboard.capture.note` · `workboard.capture.sharedText` · `workboard.capture.image` ·
`workboard.capture.webPage` · `workboard.capture.file`.

**No `.xcstrings` file was opened.**

## Requests

1. **Nobody move `abandonLocalClaim` back inside the `do` block, or drop it from the collision path.**
   `reconcile`'s `activeClaims` skip is a protection for a LIVE import only; a token that outlives its import
   is what makes a stranded capture unreachable for the life of the process. Both call sites are pinned
   (`testAReleaseRefusedByACollisionStopsHidingTheClaimFromReconciliation`,
   `testAReleaseWhoseMoveFailsLeavesTheBytesRecoverableByReconciliation`) and both were measured red without
   them.
2. **c-store — nothing owed, two facts are now load-bearing for me.** (a) `WorkMaterialPublicationLock` must
   stay acquired BEFORE any blob lookup and released only after every rollback path; my takeover case asserts
   the ordering it buys and CF2 measured what its absence costs. (b) The `#if CONDUCK_TESTING`
   `workMaterialPublicationLockHoldForTesting` seam, awaited between the blob save and the material save, is
   the only way that window is reachable — if it moves, tell me where it moved to, because a hold on the
   wrong side of the blob save stages nothing.
3. **c-store — your r3s#2 half and mine now meet.** The drainer passes
   `.captureEnvelope(envelope.id, legacyTargetWorkItemID: envelope.targetWorkItemID)` at all three sites, and
   `WorkCaptureDrainerTests.testAPartiallyDrainedTargetedCaptureReplaysOntoTheDesk` is the drainer-level
   fixture for it (measured red on `invalidMaterialOwner` with the one-argument form). Your store-level
   fixture and this one are complementary, not duplicates; neither replaces the other.
4. **fix2-drainer's standing requests still hold and I preserved all of them.** The structured task group,
   the checkpoint before every material write, the `endImport()` gate on `acknowledge`/`release`,
   `confirmDurablyImported`'s one-fetch shape, `acknowledge` as the last statement of the import, and the two
   defaulted `init` parameters are all untouched. `Report`'s four fields and `drainAvailableCaptures()`'s
   signature are unchanged, so `WorkboardLiveRepository.drainCaptures()` and
   `WorkCaptureRetryCoordinator.publish` needed no edit — neither file was opened.
5. **Orchestrator — suite arithmetic.** `WorkCaptureInboxLeaseTests` 15 → **17** (+2) ·
   `WorkCaptureDrainerTests` 9 → **10** (+1) · `WorkCaptureDrainerTakeoverTests` **+1** (new class).
   **Net +4 iOS executed.** `WorkCaptureDrainerDurabilityTests` stays at 8, `WorkAssetVaultTests` at 19,
   `WorkCaptureInboxTests` at 29. Full iOS, watch and macOS unrun by me.
   **One scheduling note:** the takeover case runs two real sqlite stores and holds a 400 ms observation
   window, so it costs ~0.5 s. It is the only case in the suite that mounts two live stores over one file; if
   a future run shows it flaky under load, the honest fix is a longer window, not a weaker assertion.
6. **Founder QA (Gate 2) — one item.** Share a large file from another app while the app is backgrounded long
   enough (>5 min) for the capture to be reclaimed by the other process, then reopen. The card must appear
   **exactly once**, with its bytes playable/openable — not twice, not once with a permanent "Waiting for
   iCloud…" chip. That is the user-visible shape of the publication lock; the headless case proves the
   ordering between two store instances, not between two real processes.
7. **Docs agent — one fact is now settled by code.** A capture the app fails to give back to the queue is not
   lost and is not stranded: the process stops counting it as its own, and the queue's ordinary recovery pass
   picks it up — no relaunch, no manual step. Nothing is deleted on that path; the person's file stays where
   its publisher left it until a drain proves the desk holds it.

## Refuted

**Empty.** r3s#5 held in full, and both adjudications (O-2, O-18) held with it.

## Call-site touches

**NONE outside my ownership.** `release(_:)`, `acknowledge(_:)`, `claimNext(now:)`, `refreshLease(_:now:)`,
`reconcile(now:)` and `ReconciliationReport` all kept their exact signatures, error types and semantics —
only what `release` does to its OWN bookkeeping on a failure changed. The drainer's public surface is
unchanged.
