# fix-inbox — Codex finding #1 (WorkCaptureInbox.swift:365, major). CONFIRMED and FIXED.

Files I own and touched, and nothing else:

- `Conduck/Conduck/Services/WorkCaptureInbox.swift`
- `Conduck/ConduckTests/WorkCaptureInboxLeaseTests.swift` (9 → 14 cases)
- `Conduck/ConduckTests/WorkCaptureInboxTests.swift` (30 cases, unchanged count)

No git ops. No `.xcstrings` opened. No mirror triplet touched. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. No file outside the three above was edited.

---

## 1. The finding, verified against current code

Both halves held at the moment I read the file:

- `claimNext` renamed `<base>/<id>` → `processing/<id>` and only afterwards called `writeLease(in: claimed, now:)`. The directory was therefore visible in `processing/` with **no owner** for the length of that gap.
- `isAbandonedClaim(at:now:)` returned `true` immediately for `case .absent`, so any other process's `reconcile()` inside that gap requeued the directory.

The destructive consequence the finding names also held: `processing/<id>` is a **reusable path**. After a foreign requeue + reclaim, the first claimant's `preserveClaimedDirectory(id:at:)` — which checked only that `<base>/<id>` was free — would `removeLease` and then `moveItem` **the second claimant's directory**, stripping its marker and requeueing bytes another drainer was reading.

## 2. The fix: the claiming rename IS the acquisition

Option (b) from the task, because it removes the race by construction rather than narrowing it.

**A claimed directory is now named for its acquisition, not for the capture:**

```
processing/<envelopeID>_<claimEpochSeconds>_<generationUUID>
```

`generation` is a fresh UUID per claim attempt, so **only the process that minted it can name that path**. No other process can create it, and a requeue+reclaim by anyone else produces a *different* path — which is what makes every later operation (preserve / rollback / release / acknowledge / heartbeat) unable to touch a claim it did not take, verified or not. The rename is atomic, so ownership is acquired atomically with the move.

`claimedAt` is in the name because it is **the only freshness clock atomic with the rename**: `rename(2)` preserves the directory's own timestamps, so its mtime still dates the *publication*, not the claim, and an mtime-based grace would already be expired for any capture that sat in the queue. With the instant in the name, a markerless-but-fresh acquisition is legible as live.

| Symbol | Change |
|---|---|
| file header | states that the rename carries ownership and that every later operation verifies the generation |
| `Claim.generation: UUID` | new; the value spelled into the directory name (no external constructor exists — grep: nothing outside this file builds a `Claim`) |
| `ClaimLease.generation: UUID` | new; the marker names the acquisition as well as the owner |
| `ClaimDirectory` (private) | parsed identity of a processing child: `envelopeID` + optional `generation`/`claimedAt` |
| `claimNameSeparator = "_"` | UUID strings never contain it, so the name parses even with a negative epoch |
| `claimDirectoryName(envelopeID:claimedAt:generation:)` | **internal, not private** — it IS the ownership boundary, and a test that stages a mid-acquisition state must spell exactly what production creates |
| `epochSeconds(_:)` | finite-checked + clamped so no caller-supplied date can trap the `Int64` conversion |
| `claimNext(now:)` | renames into the generation path, then leases it. Signature unchanged |
| `isAbandonedClaim(_:at:now:)` | takes the parsed directory. **Bare-`<id>` name → abandoned at once** (no acquisition in this build can create one). Generation-named: `.absent` lease → aged from `claimedAt`; `.held` → aged from `max(claimedAt, refreshedAt)`. Same-owner short-circuit kept (see §3) |
| `requireLeaseOwnership` | verifies owner **and** generation; `.absent` now always throws `.staleClaim` (see §3) |
| `isOwnedForRollback(_:generation:)` | new; `preserveClaimedDirectory` refuses to move a directory a readable foreign lease covers |
| `preserveClaimedDirectory(id:at:generation:)` | gained the generation + the ownership guard |
| `activeClaims` | keyed by **generation**, not envelope id — a requeued-and-retaken capture is a different acquisition |
| `requireActive` | also requires the directory's name to carry the claim's generation |
| `isClaimed(_:)` | new; `publishAppCapture`'s "already in processing" check reads the id out of claim names instead of spelling `processing/<id>` |
| `reconcile(now:)` | iterates processing *children* and parses each name (`childEnvelopeIDs` would drop every generation-named directory) |
| `respectedLeaseCount` doc | now covers "a rename whose lease has not landed yet" as well as a live lease |

**`refreshLease(_:now:)`, `claimNext(now:)`, `reconcile(now:)`, `acknowledge(_:)`, `release(_:)` all kept their exact signatures** — fix-drainer's heartbeat needs no edit (see §5).

## 3. Decisions (and why)

- **Grace = the existing `staleClaimHorizon`, not a new constant.** A process suspended between its rename and its lease write is indistinguishable from one suspended just after, so a second tunable would only be a second thing to get wrong. A markerless generation-named claim is therefore respected until `claimedAt + horizon`, then requeued — never leaked (test: `testAnAcquisitionThatNeverLeasesIsRecoveredAtTheHorizon`).
- **A bare-`<id>` processing directory is still requeued immediately.** It cannot be produced by this build, so nothing is racing it — the same reasoning the existing markerless test always carried, now anchored on the *name* rather than on the missing marker. This is what keeps `testReconcileReleasesCrashStrandedClaimAndSweepsOnlyOldTmp` (whose fixture builds exactly that shape) green **unedited**; had I aged such a directory by mtime instead, that test's `now: 1_000` fixture would have made a 2026 mtime look future-dated.
- **Same-owner short-circuit kept, and now provably sound.** Under a unique path, a lease naming this instance can only have been written by this instance for that exact acquisition; if the generation is not in `activeClaims`, the claim is this instance's own dead one. (Under the "write the lease before the move" alternative it would *not* have been sound: the loser of a claim race can leave its own fresh lease inside the winner's directory, and its own reconcile would then steal a live claim. That is the main reason I did not take that option.)
- **`requireLeaseOwnership`'s `.absent` case now throws `.staleClaim` even when the directory is gone** (it previously returned silently for a vanished directory). With generation-scoped paths a theft leaves the original claimant's path *absent* rather than foreign-leased, so the old rule would have turned a stolen claim's `acknowledge` into a silent no-op — and `testTheOriginalOwnerCanNeitherAcknowledgeNorReleaseAStolenClaim` would have failed. The new rule is strictly stronger and fail-closed: for a claim this instance still holds, the marker is written before the claim is handed out, so a missing marker means the claim was taken. Behavioural consequence for the drainer: a claim whose directory vanished for a non-theft reason (App Group wiped) now surfaces `.staleClaim` from `acknowledge` instead of succeeding. The bytes are gone either way; the difference is that it is reported.
- **`isSafeLeaf`, exact-containment validation, the reserved lease name, the bounded validator, best-effort reconcile, the atomic-move claim boundary and the acknowledgement seam are all untouched.** Nothing was widened to make this pass.
- **No new user-facing copy**, so no catalog work.

## 4. Tests

Slug `fix-inbox`, derivedData `~/Library/Caches/gigaduck-builds/fix-inbox/DerivedData`, sim `D4046F86-A150-4168-AADD-91EF925731E9`, no `-configuration` passed anywhere, every log written to the slug dir and grepped.

**Build** (`bft-1.log`): `grep -c ': error: '` = **0** · `** TEST BUILD SUCCEEDED **`.

**`test-without-building`, my two classes** (`test-1.log`, `** TEST EXECUTE SUCCEEDED **`):

| Class | Result |
|---|---|
| `WorkCaptureInboxLeaseTests` | `Executed 14 tests, with 0 failures (0 unexpected) in 0.096 (0.099) seconds` |
| `WorkCaptureInboxTests` | `Executed 30 tests, with 0 failures (0 unexpected) in 0.179 (0.186) seconds` |
| total | `Executed 44 tests, with 0 failures (0 unexpected) in 0.275 (0.286) seconds` |

**Insurance run, not my files** (`test-2.log`, `** TEST EXECUTE SUCCEEDED **`): `WorkCaptureDrainerTests` `Executed 9 tests, with 0 failures (0 unexpected) in 0.141 (0.144) seconds` · `WorkCaptureRefreshCoordinatorTests` `Executed 6 tests, with 0 failures (0 unexpected) in 0.993 (0.994) seconds` · `WorkboardDeskViewModelTests` `Executed 5 tests, with 0 failures (0 unexpected) in 0.093 (0.094) seconds`.

`git diff --check` clean. Build cache removed with `.claude/scripts/clean-build-cache.sh fix-inbox`.

**NOT run** (outside my VERIFY): macOS build, full iOS suite, watch suite, `check-storage-seam.sh`. My file is pure Foundation with no platform-conditional code, but I did not prove the macOS build myself.

### The 5 new cases (`WorkCaptureInboxLeaseTests`, +5 on the iOS executed count)

| Case | Holds |
|---|---|
| `testAnAcquisitionIsNotRequeuedBeforeItsLeaseLands` | **the finding's interleaving**: capture moved into processing under an acquisition name, lease not yet written, a second instance reconciles → `releasedClaimCount 0`, `respectedLeaseCount 1`, its `claimNext` returns nil, the directory is left byte-for-byte where the rename put it |
| `testAnAcquisitionThatNeverLeasesIsRecoveredAtTheHorizon` | the grace is bounded: at `claimedAt + horizon` the same state is requeued to the publisher's exact shape and re-claimable |
| `testARollbackCannotTouchACaptureAnotherAcquisitionTookOver` | **the destructive half**: a thief requeues + retakes the capture under its own acquisition *while the first claimant is inside validation*; the claimant's rollback fires and the thief's directory, marker and payload survive, and nothing is requeued |
| `testARollbackRefusesADirectoryAForeignLeaseCovers` | rollback verifies owner+generation: a foreign marker planted at the claimant's own path makes `preserveClaimedDirectory` refuse to move anything, and the horizon still recovers the capture |
| `testAClaimWhoseLeaseCannotLandIsRefusedWithoutClobberingTheRequeuedCapture` | a claim requeued underneath the claimant the instant its rename lands: the lease write fails, the claim is refused, the requeued copy keeps the publisher's exact shape, and the retry claims and leases it |

Adapted, not weakened: `testAMarkerlessStrandedClaimIsRequeuedImmediately` → `testABareIdStrandedDirectoryIsRequeuedImmediately` (identical assertions; the name and comment now say *why* — the directory's name, not its missing marker). Every helper that spelled `processing/<id>` (both files) now *finds* the claimed directory instead, which is strictly stronger: `claimedURL(for:)` asserts exactly one acquisition holds a capture, and the three absence assertions in `WorkCaptureInboxTests` now fail on a directory under **any** generation.

**Honesty about "fails on the old code":** `testARollbackCannotTouchACaptureAnotherAcquisitionTookOver` encodes exactly the interleaving that destroyed the second claimant's directory before this fix (old rollback names `processing/<id>` unconditionally, which is the path the thief occupies) — but it, and the two staged-acquisition cases, reference `claimDirectoryName`, which the old code does not have, so they would not *compile* against it rather than failing an assertion. That is inherent to a fix whose whole content is a new on-disk identity. I did not run them against the pre-fix code.

## 5. What the next agent must know

- **fix-drainer's heartbeat needs no change.** `refreshLease(_:now:)` kept its signature and semantics; `withLeaseHeartbeat`'s `try? await inbox.refreshLease(claim, now: now())` works unchanged. Proven directly by `testARefreshedLeaseSurvivesAHorizonThatWouldHaveExpiredIt` (green), which drives `refreshLease` on a real claim through the new `requireActive` generation check and the new owner+generation lease check.
- **`WorkCaptureDrainerDurabilityTests` (fix-drainer's new, untracked file) had 2 failures when I ran it as insurance** — reported here as an observation, not touched:
  - `WorkCaptureDrainerDurabilityTests.swift:297: error: -[…testTheHeartbeatKeepsALongImportOwnedPastTheStaleHorizon] : failed - The claim's lease was never renewed while its import was still running`
  - `WorkCaptureDrainerDurabilityTests.swift:233: error: -[…testTheHeartbeatKeepsALongImportOwnedPastTheStaleHorizon] : XCTAssertTrue failed - the claimed directory is never requeued underneath the drainer reading it`
  - `Executed 5 tests, with 2 failures (0 unexpected) in 11.050 (11.052) seconds`, `** TEST EXECUTE FAILED **`. The second failure is downstream of the first (a lease that never renews ages past the horizon and is correctly requeued). **I ran this against a binary built at 01:15 while that test file's mtime is 01:17:52**, i.e. a stale binary for a file that was being edited, so I could not tell an in-flight state from a real defect — and my re-build to settle it failed outside my files (§6). fix-drainer should re-run it once the tree compiles.
- Anything that enumerates `processing/` must parse the name (`<id>_<epoch>_<generation>`), never assume `<id>`. Inside the actor use `claimDirectory(named:)`; from outside, match on the `<id>` prefix or use `claimDirectoryName`.
- The share extensions still need no mirror: they publish only, and `directoryName` / `manifest.json` / the Darwin name are all unchanged. Do **not** add a fourth mirror.

## 6. Parallel-phase blocker (not mine, recorded per protocol)

After my green build and test runs, a re-build to re-check fix-drainer's durability test failed **only in files I do not own** — the audio workflow's surface. Waited 120 s, retried once (`bft-3.log`), identical:

```
Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1170:21: error: cannot convert value of type 'WorkboardMaterialKind' to expected argument type 'UTType'
Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1632:30: error: type 'WorkboardMaterialKind' has no member 'audio'
```

Cause is upstream of the canvas: `Conduck/Conduck/ViewModels/WorkboardViewModel.swift` (mtime 01:15:57, i.e. changed right after my successful build) declares `enum WorkboardMaterialKind { case image, file, link, note }` — no `.audio`. Mid-edit state of the audio/strings workflow; the serial integration step resolves it. **My three files compiled cleanly in `bft-1.log` with zero `error:` lines and are not implicated in either error.**

## Catalog

**Keys I ADDED in source: NONE** — this slice adds no user-facing copy.
**Keys I found DEAD: NONE.**

## Requests

1. **fix-drainer / ByteSync:** nothing required. `refreshLease(_:now:)` is unchanged; `acknowledge` stays the last statement. One behaviour to be aware of: `acknowledge`/`release`/`refreshLease` now throw `.staleClaim` when the claimed directory is **absent** as well as when it is foreign-leased (§3). Your `try?`-wrapped heartbeat already tolerates this; your barrier's `catch → release → rethrow` is unaffected.
2. **Serial integration / audio workflow:** restore `WorkboardMaterialKind.audio` (or finish the migration off it) — `WorkboardCaptureCanvas.swift:1170` and `:1632` do not compile without it (§6). Nothing in my files depends on that enum.
3. **Orchestrator:** expect **+5** on the iOS executed count from this slice (`WorkCaptureInboxLeaseTests` 9 → 14). `WorkCaptureInboxTests` stays at 30. Full iOS, watch and macOS gates unrun by me.

## Call-site touches

**NONE.** No file outside the three I own was edited.
