# f-drainer — r6s#2 CONFIRMED and fixed. Retirement is now stage → verify → rename. Two counterfactuals MEASURED.

Parallel phase. No commits/pushes/stash/checkout, no index operations. `Conduck/Configs/Identity-Override.xcconfig`
untouched. **No `.xcstrings` opened**, no `.pbxproj` edit, no mirror triplet touched, nothing under
`docs/qa/desk-cloudkit/` touched. No file outside my ownership list edited.

**Files changed — 1 production, 1 test (new):**

| File | Change |
|---|---|
| `Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift` | terminal retirement only: staged copy → byte-count verification → atomic rename; a pre-existing destination verified rather than trusted, and displaced instead of overwritten; one new `#if CONDUCK_TESTING` seam |
| `Conduck/ConduckTests/WorkCaptureDrainerRetirementTests.swift` | **NEW** — 4 cases |

`WorkCaptureDrainerCollisionTests` (3) and `WorkCaptureDrainerDurabilityTests` (8) are mine and were **not
edited**: nothing in them needed changing and both stay green, including the collision suite's assertion that
a finished retirement is the ONLY child of `refused/`. **Net iOS executed: +4.**

**HEADLINE.** iOS `** TEST BUILD SUCCEEDED **` (0 `: error: `) · VERIFY set of 7 classes
`Executed 72 tests, with 0 failures` · wider 8-class Work set `Executed 85 tests, with 0 failures` ·
signed macOS `** BUILD SUCCEEDED **` (6 `CodeSign` steps, 0 errors) · **two counterfactuals measured, each
turning exactly one case red and leaving the other three green** (§4).

---

## 1. r6s#2 — verified against the current code, then fixed

**VERDICT: CONFIRMED.** Re-located by symbol (`retireRefusedCapture`), not by the cited line. Every clause held
against the tree as it stands:

| Claim in the finding | What the code did |
|---|---|
| the copy goes straight to the final destination | `try fileManager.copyItem(at: claim.directoryURL, to: destination)` where `destination = refused/<envelopeID>` — the name a later drain reads as "already retired" |
| mere existence is treated as completion | the copy sat inside `if !fileManager.fileExists(atPath: destination.path) { … }`; nothing looked inside |
| a crash or a copy failure can leave that directory partial | `copyItem` on a directory is per-file (APFS clones each leaf); a kill, a full disk or an I/O fault between two files leaves the destination present and short, and Foundation does not unwind it |
| the next refusal then skips copying and writes `refusal.txt` | it did exactly that: the `if` is skipped, the reason is written into the partial directory |
| and `acknowledge` deletes the source | `persistAndAcknowledge`'s terminal branch is `try retireRefusedCapture(…); try await inbox.acknowledge(claim)`, and `acknowledge` deletes the claimed directory — the queue's only copy of what the person shared |

The consequence is the sharpest one in this whole subsystem, and it is worth stating plainly: **the retirement
is the one path where the acknowledgement barrier is not the desk.** Everywhere else `confirmDurablyImported`
reads the cards back out of the store before the bytes are consumed. Here nothing is on the desk by
definition — that is what "refused twice" means — so the copy in `refused/` IS the barrier, and an
unverified barrier is no barrier. The old code could destroy a shared file and leave seven bytes of it plus a
note explaining why.

Nothing refuted. `## Refuted` is empty.

## 2. The fix — stage, verify, rename

`retireRefusedCapture` is now four steps, in this order, and `acknowledge` is reached only after the last one:

1. **Snapshot what "complete" means** — `retirementContents(of:fileManager:)` walks the claimed directory and
   records every regular file's name and byte count, minus the lease (which names an acquisition of a queue
   the copy has left). Claim directories are flat by validation (`WorkCaptureInbox.isSafeLeaf` refuses a path
   separator), so nothing recurses.
2. **A destination already in place is verified, not believed** — `holdsRetirement(_:at:fileManager:)` demands
   every one of those names present, a regular file, at the same byte count. Complete → the reason is
   rewritten and the retirement stands (this is e-drainer §3.3's idempotence, preserved). Incomplete → it is
   **moved aside** under a unique `…​.incomplete` name. Never deleted: it holds bytes nobody else has.
3. **The copy is staged** into a uniquely named sibling `<envelopeID>_<epoch>_<generation>.staging`, built with
   `WorkCaptureInbox.claimDirectoryName(envelopeID:claimedAt:generation:)` — the queue's own naming for
   "these bytes, this attempt" — with a role suffix so a person reading the container can tell a copy in
   flight from a displaced partial and both from the retirement. The lease is stripped from the copy, the
   copy is verified against the step-1 snapshot, and `refusal.txt` is written INTO the staging directory.
4. **Rename** `staging → <envelopeID>`. `rename(2)` is the only atomic step available, so after this change the
   envelope-named directory can only ever be one something finished — which is what makes step 2's fast path
   safe rather than merely convenient.

Any failure between 3 and 4 removes the staged copy and rethrows, so the claim is released and the entry
returns to the queue. That removal is the only deletion in the function, and it is provably safe: nothing has
been acknowledged, so the queue still holds every byte the staged copy holds.

**Test seam.** One new `#if CONDUCK_TESTING` property, `retirementStagingHoldForTesting: (@Sendable (URL) -> Void)?`,
called between the copy and the verification with the staging URL. Its header states why it must exist:
`copyItem` either completes or throws, so nothing inside this type can produce the state the finding is about —
a copy that landed SHORT — and handing the staging directory to a test is the only way to stage it. Nil on
every production path, and it is not reachable in release (the flag is test-only).

**What I did NOT change.** `persistAndAcknowledge`'s ordering and its three catch arms, `ImportOutcome`,
`TerminalCollision`, the escape, `confirmDurablyImported`, `persist`, the heartbeat task group, `ImportOwnership`,
`Report`'s fields, `drainAvailableCaptures`'s signature and its `.refused → continue`, and every
`WorkCaptureInbox` API. No assertion anywhere was weakened, narrowed or deleted.

## 3. Decisions

### 3.1 The partial destination is replaced in the SAME pass, not deferred

The finding's test sketch reads "must NOT lead to acknowledgement of the complete source — the source
survives and the next drain completes the retirement", while its FIX paragraph says the pre-existing directory
"is validated the same way and replaced … before the source is acknowledged". I implemented the FIX paragraph:
a partial destination is displaced and a fresh verified copy is renamed into place in that same drain, and only
then is the source acknowledged. The invariant the sketch protects — *the complete source is never acknowledged
while only a partial copy exists* — is what my case asserts, and it holds either way; deferring would only
mean the queue carries the entry one drain longer for no gain. Nothing about the sketch's shape is lost: if the
replacement itself fails at any point, the source is not acknowledged and the next drain finishes it (case 2
and case 3 both stage exactly that and then measure the recovery).

### 3.2 Byte counts, not hashes

The finding names byte counts and that is what I verify. The failure mode being closed is an interrupted copy —
a file missing or short — not a corrupting one; `copyItem` clones leaves through the kernel, so a
same-size-different-content copy is not a state this path can produce. Hashing a 30 MB payload on the
retirement path would buy nothing and cost a full read.

### 3.3 A displaced partial is kept for ever; a failed staging copy is not

Two different things, deliberately treated differently. A displaced destination may hold bytes that exist
nowhere else — that is the whole premise of the finding — so it is renamed aside and never removed, and
`refused/` may accumulate at most one `.incomplete` per interrupted retirement. A staged copy that did not
become the retirement is redundant by construction, because acknowledgement is strictly after the rename and
the queue therefore still holds the original; leaving those would make a repeatedly failing device fill its own
container with partial copies of a file it already has.

### 3.4 The scratch names borrow the inbox's claim-directory shape

`<envelopeID>_<epochSeconds>_<UUID>` plus `.staging` / `.incomplete`. Nothing parses them — that is the point —
but they sort beside the retirement, name the envelope they belong to, and cannot be mistaken for the finished
directory, whose name is the bare UUID. e-drainer's Request 2 still holds and I depend on it identically:
`pendingEnvelopeIDs()` counts only UUID-named children of the inbox ROOT and `reconcile` walks only
`processing/` and `tmp/`, so nothing in `refused/` — retirement, staging or displaced — is ever claimed or swept.

## 4. Counterfactuals — MEASURED, in an isolated copy

Throwaway tree at `~/Library/Caches/gigaduck-builds/f-drainer/cf/tree`, built from `git archive HEAD` plus my
two files (HEAD `1e9a004` already carries wave E), with the copy's `Identity-Override.xcconfig` symlink
re-pointed at the same real file. **Nothing in the worktree was touched for either run.**

**CF-A — the pre-existing-destination validation reverted** (`if Self.holdsRetirement(expected, at: destination…)`
→ `if true`, i.e. exactly the old "existence means done"). `** TEST BUILD SUCCEEDED **`, 0 `: error: `; then:

```
Test Suite 'WorkCaptureDrainerRetirementTests' failed
	 Executed 4 tests, with 3 failures (0 unexpected) in 1.172 (1.174) seconds
…testAShortRetirementOnDiskIsReplacedInsteadOfTrusted] : XCTAssertEqual failed: ("7 bytes") is not equal to
  ("43 bytes") - a retirement the queue was acknowledged against must carry every byte it had
…testAShortRetirementOnDiskIsReplacedInsteadOfTrusted] : XCTAssertEqual failed: ("0") is not equal to ("1")
  - an incomplete retirement is displaced, not destroyed
…testAShortRetirementOnDiskIsReplacedInsteadOfTrusted] : XCTUnwrap failed: expected non-nil value of type "URL"
Test Suite 'WorkCaptureDrainerCollisionTests' passed — Executed 3 tests, with 0 failures
```

That first line IS the finding: 43 bytes went into the queue, the drain acknowledged the source away, and 7
bytes are what is left of the person's file. Exactly one of my four cases is red, so the other three do not
fail merely because a mechanism is absent.

**CF-B — the staging verification reverted** (`guard Self.holdsRetirement(expected, at: staged…)` → `guard true`,
destination validation restored). `** TEST BUILD SUCCEEDED **`, 0 `: error: `; then:

```
Test Suite 'WorkCaptureDrainerRetirementTests' failed
	 Executed 4 tests, with 7 failures (2 unexpected) in 0.496 (0.498) seconds
…testAStagedRetirementThatLandedShortIsNeverRenamedIntoPlace] : failed - an incomplete copy may not be acknowledged against
…] : XCTAssertFalse failed - the retirement's name may only ever appear on a complete copy
…] : XCTAssertEqual failed: ("1") is not equal to ("0") - and the copy that did not become one is cleaned up…
…] : XCTAssertEqual failed: threw error "…payload-000.bin couldn't be opened because there is no such file…
   /conduck-work-drainer-retirement-…/143CEE87-…/payload-000.bin" - the queue's copy is untouched by a retirement that failed
…] : XCTAssertEqual failed: threw error "…/refused/143CEE87-…/payload-000.bin … no such file"
Test Suite 'WorkCaptureDrainerCollisionTests' passed — Executed 3 tests, with 0 failures
```

Read those last two lines together: the payload is in neither place. The drain did not throw, the short copy
took the retirement's name, the queue was acknowledged, and the file the person shared no longer exists on the
device. Again exactly one case red, the other three green.

## 5. The four regression tests, and how each proves the old code wrong

New file `Conduck/ConduckTests/WorkCaptureDrainerRetirementTests.swift`. All four stage a genuine double
collision (image cards seeded at both the capture's id and its `WorkMaterialCollisionEscape` id), so the
retirement is reached through production code, never called directly.

1. **`testAShortRetirementOnDiskIsReplacedInsteadOfTrusted`** — a previous retirement of the same envelope
   left on disk with its manifest whole and its payload 7 of 43 bytes. One drain: `invalidCaptureCount == 1`;
   `refused/<envelopeID>/payload-000.bin` equals the full payload; the manifest is there and the lease is not;
   `refusal.txt` names the colliding id; the short directory is still on disk under a second name carrying its
   7 bytes; and only then is `pendingCount() == 0`. *Old code:* 7 bytes at the retirement's name, nothing
   displaced, and the queue's 43 acknowledged away (CF-A).
2. **`testARetirementWhoseCopyCannotLandLeavesTheQueueHoldingTheBytes`** — `refused/` is `chmod 0o555`, so the
   copy cannot start. The drain throws, `refused/` has no children, the capture is back in the queue
   (`pendingCount() == 1`) with its payload byte-for-byte; permissions restored, the next drain completes the
   retirement and the queue empties. This is the finding's "a copy that throws mid-way leaves the source intact
   and no final directory", staged with a real filesystem refusal rather than an injected one.
3. **`testAStagedRetirementThatLandedShortIsNeverRenamedIntoPlace`** — the new seam deletes the payload from
   the staged copy, which is what a crash between two files leaves. The drain throws, the envelope-named
   directory does not exist, `refused/` is empty (the failed staging copy is cleaned up), the queue still holds
   the whole payload; with the seam cleared the next drain retires it completely, `refusal.txt` included.
   *Old code:* not expressible — the old path had no staging directory at all; the equivalent state was the
   destination itself, which is case 1. CF-B measures this case against the verification's absence.
4. **`testARetirementIsByteCompleteAndIdempotentAcrossTwoDrains`** — a 4096-byte payload, drained twice. The
   retirement is byte-for-byte (payload AND manifest compared against `envelope.encoded()`), `refused/` holds
   exactly one child both times, and the second drain writes no second copy. The happy path and e-drainer's
   idempotence rule in one case.

## 6. Gates — WHAT I ACTUALLY RAN

Slug `f-drainer`, everything under `~/Library/Caches/gigaduck-builds/f-drainer/`, every log written to a file
and grepped for `': error: '` and for `BUILD SUCCEEDED|BUILD FAILED|TEST SUCCEEDED|TEST FAILED|Executed ` —
never judged from a tail or an exit code. **No `-configuration` passed anywhere.** Sim
`5C851D88-959C-445E-ACC8-A4C6ADB2876C`. `.claude/scripts/clean-build-cache.sh f-drainer` run at the end.

| Gate | Command | Result line |
|---|---|---|
| iOS build-for-testing (final, after other agents' edits landed) | `build-for-testing … -destination 'platform=iOS Simulator,id=5C851D88-…'` | `** TEST BUILD SUCCEEDED **`, `grep -c ': error: '` → **0** |
| VERIFY set (7 classes) | `test-without-building`, one quoted `-only-testing` per class: Retirement, Collision, Durability, Drainer, Takeover, Inbox, InboxLease | `Executed 72 tests, with 0 failures (0 unexpected)`, `** TEST EXECUTE SUCCEEDED **` |
| wider Work set (8 classes) | + CollisionEscape, DeskUpsert, AssetVault, BlobPublication, Availability, BlobGC | `Executed 85 tests, with 0 failures (0 unexpected)` |
| signed macOS | `build … -destination 'platform=macOS'` | `** BUILD SUCCEEDED **`, 6 `CodeSign` steps, 0 `: error: ` |
| guards | `check-storage-seam.sh` · `check-folder-map.sh` | `✓ 805 Swift files scanned` · `✓ 36 Swift source directories, all mapped`, both exit 0 |
| whitespace | `git diff --check` | exit 0, no output |
| forbidden paths | `git status --short -- '*.xcstrings' '*WorkCaptureEnvelope.swift' '*ShareTargetsSnapshot.swift' '*WorkCaptureDirectoryPublisher.swift' 'Conduck/Configs' 'Conduck/Conduck.xcodeproj' 'docs/qa'` | **empty** |

Per-class counts in the VERIFY run: Retirement **4** · Collision 3 · Durability 8 · Drainer 10 · Takeover 1 ·
InboxLease 17 · Inbox 29.

### NOT run, stated plainly

- **Full iOS suite.** Not run by me — `ConversationStore+Workboard.swift`, `PendingRetryStore.swift` and two
  test files changed under me mid-session; a full-suite number from this tree would describe a moment nobody
  ships. The orchestrator's gate run is the one that counts.
- **watchOS.** Not built. `WorkCaptureDrainer.swift` is `#if !os(watchOS)` and not in the watch target, and I
  added no watch-facing code — but I did not prove the watch build myself.
- **Simulator TCC check.** Not needed: nothing in my slice records audio and no audio class was run.
- **Any device QA.** See §Founder QA.
- **One warning, not mine.** `WorkCaptureDrainer.swift:417:45 warning: call to main actor-isolated static
  method 'materialID(forCapture:)' in a synchronous nonisolated context` sits in e-drainer's `escaping(_:)`,
  which I did not touch. Recorded, not fixed — it is not in my slice.

## Catalog

**Keys I ADDED in source: NONE.** The only new string this slice writes is `refusal.txt`'s body, which is
forensic text inside the App Group that no person is ever shown; the scratch directory names are filesystem
identifiers, not copy.

**Keys I made DEAD: NONE.** I deleted no code carrying a string.

**No `.xcstrings` file was opened.**

## Requests

1. **Nobody replace the rename with a copy-in-place, or the verification with an existence check.** The
   retirement is the only acknowledgement in this actor that is NOT backed by a desk read, so
   `holdsRetirement` is the barrier itself. Both call sites are pinned and both were measured red without them
   (§4). If a future round wants the verification cheaper, the honest cheap version is still per-file byte
   counts — not "the directory is there".
2. **Nobody delete a `.incomplete` directory in `refused/`.** It exists precisely because its bytes may exist
   nowhere else. If the container is ever swept, sweep `.staging` (redundant by construction) and leave
   `.incomplete` alone, or ask the founder first.
3. **e-drainer's Request 2 is now doubly load-bearing.** My scratch directories live inside `refused/`, so the
   two inbox properties it names — `pendingEnvelopeIDs()` filtering on `UUID(uuidString:)`, and `reconcile`
   walking only `processing/` and `tmp/` — protect three kinds of directory rather than one. If either ever
   widens, the whole retirement needs a home outside the inbox root.
4. **Orchestrator — suite arithmetic.** `WorkCaptureDrainerRetirementTests` **+4** (new class). **Net +4 iOS
   executed.** `WorkCaptureDrainerCollisionTests` stays at 3, `WorkCaptureDrainerDurabilityTests` at 8,
   `WorkCaptureDrainerTests` at 10, `WorkCaptureDrainerTakeoverTests` at 1, `WorkCaptureInboxTests` at 29,
   `WorkCaptureInboxLeaseTests` at 17.
5. **Orchestrator — one case uses POSIX permissions.** `testARetirementWhoseCopyCannotLandLeavesTheQueueHoldingTheBytes`
   chmods its own temp directory to `0o555` to make the copy fail for real, restores it in a `defer`, and
   asserts `isWritableFile == false` first so that a run as root would fail with a legible reason rather than
   mysteriously. It touches nothing outside the case's own temporary root.

## Refuted

**Empty.** r6s#2 held in full: the copy went to the final destination, existence was the only completion test,
and the acknowledgement behind it deletes the queue's only copy. The design directions in the brief — the
uniquely named temporary sibling on the inbox's conventions, manifest-plus-payload byte-count verification, the
atomic rename, the pre-existing directory validated and displaced rather than deleted, and acknowledgement only
after the rename — were all implementable exactly as written.

## Founder QA

Device-only, none reachable by a unit test. All of it needs a genuine double id collision, which cannot be
staged on a device without a debug build that mints one — so treat these as confirmations of a non-event, not
as steps to perform.

1. **The observable is still a non-event.** Share several files in a row from another app. Every one must
   appear on the desk. Nothing about this change alters what a working device does; it alters what a device
   that was interrupted mid-retirement does next.
2. **If you ever see "Conduck couldn't read one shared item, so it wasn't added to your board"** (e-drainer's
   note: that sentence now also covers a double refusal — open item O-8), the file is in the App Group
   container under `WorkCaptureInbox/refused/<envelope-uuid>/` with a `refusal.txt` beside it. What is new is
   that this directory is now guaranteed complete: the queue's copy is deleted only after every file in it
   was verified present at the right size under a temporary name and renamed into place.
3. **If you ever find a directory in `refused/` whose name ends `.incomplete`**, that is a retirement an
   earlier crash interrupted, kept deliberately rather than deleted. The complete copy is the plain-UUID
   directory beside it. Nothing needs doing; it is evidence, not a fault.
4. **Force-quitting the app during a share import is safe to try** (Settings → open a large share → kill the
   app mid-import). Repeat it a few times and confirm every shared file still reaches the desk. This is the
   interruption class the whole barrier exists for.

## Settled facts

One sentence each; true of the code as it now stands.

- A refused capture's bytes are copied into `refused/` under a temporary name and renamed into place only after
  every file the queue holds is verified present in the copy at the same byte count, so the envelope-named
  directory can only ever be a retirement something finished.
- The queue entry is acknowledged — and its bytes deleted — strictly after that rename succeeds, which is the
  only acknowledgement in the drainer that is proven by a copy on disk rather than by a card on the desk.
- A retirement directory already on disk is verified the same way rather than trusted for existing, so a copy
  an earlier crash left short can never stand in for the queue's complete original.
- An incomplete retirement is moved aside under a unique name and kept: this drainer deletes no bytes except
  those of a staged copy that never became a retirement, which the queue is by then still holding anyway.
- Nothing in `refused/` — the retirement, a staged copy or a displaced partial — is ever claimed, requeued or
  swept, because the inbox counts only UUID-named children of its root and reconciles only `processing/` and
  `tmp/`.
