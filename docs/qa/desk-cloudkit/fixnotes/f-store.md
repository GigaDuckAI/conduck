# f-store — r6s#1 CONFIRMED and fixed. Nothing refuted. Counterfactual MEASURED (one case, 5 assertions).

Parallel phase. No commits/pushes/stash/checkout, no index operations.
`Identity-Override.xcconfig` untouched (only re-pointed inside my own throwaway copy).
**No `.xcstrings` opened**, no `.pbxproj` edit, no mirror triplet touched, nothing under
`docs/qa/desk-cloudkit/` touched. No file outside my ownership list edited.

Files changed (2) — 1 production, 1 owned test file:

- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (+39/−2)
- `Conduck/ConduckTests/WorkboardSyncedRowRepairTests.swift` (3 cases → 4; one case split into a
  preserved/normalised pair, one control re-timed, one case untouched)
- `Conduck/ConduckTests/WorkboardBlobPublicationTests.swift`: **NOT TOUCHED.** All 22 cases pass
  unchanged, which is the evidence that the new threshold did not narrow the four repair behaviours
  e-store's §1 pinned there.
- **No new test file.** The two new cases are the same physical fixture as the case they replace, and
  splitting them across files would have hidden that they differ in exactly one value.

**HEADLINE.** iOS `** TEST BUILD SUCCEEDED **` (0 `: error: `) · my 9-class VERIFY set green apart
from the known takeover flake, which passes 8/0 alone · **full iOS suite `Executed 5025 tests, with 1
test skipped and 0 failures (0 unexpected)`** · signed macOS `** BUILD SUCCEEDED **` ·
**counterfactual: `testAReplayOlderThanAPeersRepublicationLeavesItAlone` fails with 5 assertions on a
tree with the timestamp guard reverted, and NO other case in the 9-class set failed** (§3).

---

## 1. r6s#1 — a stale replay could overwrite a newer peer republication whose blob is still in flight. CONFIRMED, fixed.

**Verified by call path before writing anything.**

1. `publishWorkMaterial`'s `.syncedPayload` repair branch (HEAD `1e9a004:820`) computed
   `rowsDisagree` over **every** physical row and, at `:833-840`, stamped **every** physical row with
   the staged hash, size and lane through `pointAtSyncedPayload`. Neither the predicate nor the loop
   read `updatedAt`.
2. The staged bytes are the REPLAY's, and a replay is routinely stale. `WorkCaptureDrainer` builds its
   drafts with `createdAt: envelope.createdAt` (`WorkCaptureDrainer.swift:276`, `:292`, `:398`) and
   replays the same envelope whenever a claim was not acknowledged;
   `WorkVoiceCaptureCoordinator.republishRecording` carries the parked recording's own `createdAt`
   through to `publishRecording` (`:375-401`). So both retry lanes publish material that can be
   minutes or hours older than the rows they meet.
3. The loss is therefore reachable exactly as the finding states it: device A reattaches a new file
   onto the card (row names `H2`, blob still uploading), CloudKit delivers A's ROW to device B ahead
   of its payload, and B re-drains the ORIGINAL capture after a crash-before-ack. B's own blob is
   already present so nothing is inserted (`.alreadyPresent`), `H2`'s blob is absent so nothing is
   superseded — and `rowsDisagree` alone fired, repointing A's row onto the older bytes and exporting
   that as a CloudKit change.
4. `WorkboardSyncedRowRepairTests.swift:102-145` at HEAD **constructed that very row** — a duplicate
   stamped `published.updatedAt + 60` — and asserted it was replaced. The suite was pinning the defect.

### The fix, as the design direction specifies it

`ConversationStore+Workboard.swift`, in `publishWorkMaterial`'s single write transaction:

```swift
let publicationDate = draft.createdAt
let rowsNotNewerThanThisPublication = materialRows.filter { row in
    guard let stamp = row.value(forKey: "updatedAt") as? Date else { return true }
    return stamp <= publicationDate
}
```

computed immediately after `requireMatchingKind`, and then used **twice** in the `.syncedPayload`
branch: `rowsDisagree` is asked of those rows only, and the `pointAtSyncedPayload` loop writes those
rows only. Nothing else in the branch moved — the two existing triggers (`.inserted`, `superseded > 0`)
are untouched, so e-store's Request 1 ("never make the synced repair depend on blob insertion or
deletion again") and Request 2 ("never repoint unconditionally") both still hold, and both are still
measured (§3, variant 2).

**Which timestamp, and why that one.** The finding offered "the envelope/capture `createdAt` the
drainer carries, or the staged publication's own timestamp — pick the one that exists". The one that
exists is `WorkMaterialDraft.createdAt` (`WorkboardRecords.swift:233`). `StagedWorkMaterialBytes`
carries no timestamp at all, so the second option is not available without inventing one. Every
production caller already sets `createdAt` to the thing being republished:

| Caller | `draft.createdAt` |
|---|---|
| `WorkCaptureDrainer` | `envelope.createdAt` — the share the person made |
| `WorkVoiceCaptureCoordinator.republishRecording` → `publishRecording` | the parked recording's own |
| `captureMessageToWork` | `persistedMessage.createdAt` / `attachment.createdAt` |
| `WorkboardLiveRepository.importMaterial`, `CaptureWorkboardIntent` | `Date()` — happening now |

So a publication the person is making right now still normalises every row (the last line of the
table), and only a replay of older material holds back. That is the whole rule.

**Read BEFORE adoption, deliberately.** The legacy-owner adoption block below it sets
`row.setValue(now, forKey: "updatedAt")` on every re-homed row. Computing eligibility after adoption
would make a row THIS SAME CALL just touched read as a later publication than itself, and it would
never be repaired. `WorkboardChatCaptureTests.testATurnCapturedByAnOlderBuildIsAdoptedOntoTheDeskRatherThanFailing`
is the case that walks that path; it is green.

**The `.localVault` branch is deliberately NOT guarded** and I say why: a vault key is a device-local
leaf name that means nothing on another device, so a row imported from a peer never names bytes this
device could be about to destroy. The hazard the guard exists for is specific to the synced lane,
which is the only lane whose pairing travels.

### Regression tests — `WorkboardSyncedRowRepairTests` (4 cases; the file is mine)

The HEAD case `testAReplayRepairsARowNamingABlobThatNeverArrived` is **split into a matched pair over
one shared fixture** (`seedCardWhoseNewestRowNamesAnAbsentBlob`), because the two situations are
physically identical — same two rows, same absent blob, same bytes in hand — and differ only in whose
material is more recent. Stating them as one fixture and two replays is the point.

- **`testAReplayOlderThanAPeersRepublicationLeavesItAlone`** (NEW; the counterfactual case). The
  replay carries the ORIGINAL draft, whose `createdAt` predates the peer row — asserted in the case
  itself (`XCTAssertLessThan(seeded.draft.createdAt, seeded.peerStamp)`) so the reader can see what
  makes it stale. Asserted after the replay: the card still names the peer's hash and still reads
  `.syncedPending`; **`Set(after) == Set(before)` over the whole `WorkMaterialRowProbe`** — not one
  column of either row moved; both hashes still present; the blob rows are byte-identical to before;
  and the payload still loads nil. *Measured red on the reverted tree with 5 assertions* (§3).
- **`testAReplayNewerThanAnAbandonedRowEndsTheWaitItLeft`** (NEW; the twin the finding asked for).
  Same fixture, replay built with `createdAt: peerStamp + 60`. Asserted: `.synced`, every row names
  `hex(bytes)` on both halves of the pairing and on the lane, the payload loads back byte-for-byte,
  `presentationAvailability` is `.available`, both rows survive, and **exactly one blob row** — which
  is what proves the repair ran through `.alreadyPresent` with nothing superseded, i.e. that
  `rowsDisagree` is still the only thing that could have licensed it. **This is r5s#1 staying closed**:
  green on the reverted tree by construction, and green here.
- **`testAnIdenticalReplayOntoAgreeingRowsWritesNothing`** (kept, RE-TIMED, no assertion changed).
  Its duplicate row now sits 60 s BEFORE the published row and the replay's material 60 s after it, so
  both rows are eligible. **This strengthens the case rather than weakening it**: with a duplicate
  newer than the replay, the timestamp rule would hold the write back whatever the disagreement
  predicate said, and the case would have passed with `rowsDisagree` deleted — measuring nothing.
  *Measured red (1 failure) on a variant where the disagreement licence is dropped* (§3, variant 2).
- **`testStrandedBlobsAccumulatePerAttemptUntilDifferentBytesRetireThem`** — untouched, green.

## 2. The hazard my fix hands to O-6, MEASURED. No code changed for it.

Preserving a newer row changes what O-6 (`deleteSupersededBlobRows`, which still deletes COMPLETE rows
carrying other bytes inside the publishing transaction) does to the person, in the one sub-case where
the peer's payload has already arrived here. I measured it rather than argued it, with a throwaway
probe in the isolated copy (never committed):

publish bytes A → republish bytes B under the same id (the peer's reattach, fully synced) → stale
replay of A. **Result on my tree:**

```
availability=syncedPending cardHash=a9c7bc42…(B) rowHashes=["a9c7bc42…"(B)]
blobHashes=["4749ed6d…"(A)] payloadBytes=nil
```

The row correctly keeps naming B — that is my fix — but the retirement deleted B's payload in the same
transaction, so the card can never open. **Before my change the same sequence ended `.synced` on A**:
the person's newer file was silently replaced, which is the loss the finding names. **Both outcomes
destroy B's bytes; only the retirement does that, and it did so before this change too.** What my
change removes is the EXPORT of a wrong row pairing to every device; what it leaves is a visibly
stuck card instead of a silent revert. I am not claiming that is an improvement in this sub-case, and
I have not hidden it.

**I did not fix it**, because O-6 is not in my brief, it is a knowingly-parked item, and its three
call sites (`:828` mine, `:912` the insert path, `:1998` the reattach) need one decision each — that
is a design call, not an integration tidy-up. See §Requests 1 for the measured remedy.

## 3. The counterfactual — MEASURED, in an isolated copy

`~/Library/Caches/gigaduck-builds/f-store/cf-tree`, an `rsync -a --delete` snapshot with its
`Identity-Override` symlink re-pointed at the same real file. **Nothing in the worktree was touched
for this.**

**Variant 1 — the mechanism reverted** in the copy's PRODUCTION file only (tests untouched):
`let rowsNotNewerThanThisPublication = materialRows`, i.e. the filter removed and both uses left
pointing at every row — exactly the pre-fix behaviour. `cf-bft-1.log` → `** TEST BUILD SUCCEEDED **`,
0 errors. `cf-test-1.log` → `** TEST EXECUTE FAILED **`:

| Class | Result on the reverted code |
|---|---|
| `WorkboardSyncedRowRepairTests` | `Executed 4 tests, with 5 failures (0 unexpected)` |
| `WorkboardBlobPublicationTests` | `Executed 22 tests, with 0 failures` |
| `WorkboardDeskUpsertTests` | `Executed 16 tests, with 0 failures` |
| `WorkboardAvailabilityTests` | `Executed 11 tests, with 0 failures` |
| `WorkboardBlobGCTests` | `Executed 6 tests, with 0 failures` |
| `WorkCaptureDrainerCollisionTests` | `Executed 3 tests, with 0 failures` |
| `WorkCaptureDrainerTests` | `Executed 10 tests, with 0 failures` |
| `WorkCaptureDrainerDurabilityTests` | `Executed 8 tests, with 0 failures` |
| `WorkboardChatCaptureTests` | `Executed 8 tests, with 0 failures` |

**ONE case fails, it is the case I added for this finding, and NO pre-existing case failed.** Verbatim
(elided where long):

```
testAReplayOlderThanAPeersRepublicationLeavesItAlone : XCTAssertEqual failed: ("Optional("4749ed6d…")") is not equal to ("Optional("e133494d…")") - a stale replay never repoints a card onto the bytes it happens to be holding
testAReplayOlderThanAPeersRepublicationLeavesItAlone : XCTAssertEqual failed: ("synced") is not equal to ("syncedPending") - the card names the newer file, and keeps naming it until that payload arrives
testAReplayOlderThanAPeersRepublicationLeavesItAlone : XCTAssertEqual failed: ("[…contentHash: Optional("4749ed6d…"), byteSize: Optional(34)…]") is not equal to ("[…contentHash: Optional("e133494d…"), byteSize: Optional(4096)…, …contentHash: Optional("4749ed6d…")…]") - not one column of either row moved — the newer pairing survives the replay intact
testAReplayOlderThanAPeersRepublicationLeavesItAlone : XCTAssertEqual failed: ("["4749ed6d…"]") is not equal to ("["4749ed6d…", "e133494d…"]") - the peer's row still names the peer's file
testAReplayOlderThanAPeersRepublicationLeavesItAlone : XCTAssertNil failed: "34 bytes" - the card opens nothing, and that is the truthful answer while its bytes are in flight
```

The third line is the whole loss in one string: on the reverted tree the two probes COLLAPSE into one
— the peer's row and this device's row have become the same row, naming the same older bytes, and the
newer file is gone from every device the deletion reaches.

**Variant 2 — the disagreement licence dropped**, with the timestamp guard restored
(`if rowsDisagree { repaired = true }` → `repaired = true`). `cf-bft-2.log` →
`** TEST BUILD SUCCEEDED **`, 0 errors. `cf-test-2.log`: `WorkboardBlobPublicationTests`
`Executed 22 tests, with 0 failures`; `WorkboardSyncedRowRepairTests`
`Executed 4 tests, with 1 failure`:

```
testAnIdenticalReplayOntoAgreeingRowsWritesNothing : XCTAssertEqual failed: ("[2026-09-03 10:24:18 +0000]") is not equal to ("[2026-09-03 10:24:18 +0000, 2026-09-03 10:23:18 +0000]") - rows that already name these bytes are left exactly as they are
```

That is the measurement behind the re-timing: the control still catches an unconditional repoint.

**Variant 3 — the measured O-6 remedy**, §Requests 1. Same copy, my call site only.

## Guard verdicts

**None assigned, none converted, none deleted, none weakened.**
`WorkboardAvailabilityTests.testTheAvailabilityProjectionNeverNamesThePayloadColumn` and
`WorkboardBlobSeamPlatformGuardTests.testThePayloadSeamsAreCompiledOutOfTheWatchBuild` were left
exactly as they stand and both pass — I added no seam, widened no seam, and moved no
`propertiesToFetch` block. `_duplicateWorkMaterialRowForTesting` keeps the signature e-store gave it;
I needed no new parameter.

## Catalog

**Keys I ADDED in source: NONE.** This slice is entirely headless — a threshold inside one write
transaction. A card that keeps waiting keeps rendering the existing `workboard.material.syncPending`
chip, and one that stops waiting simply stops rendering it.

**Keys I made DEAD: NONE.** I deleted no code carrying a key.

**No `.xcstrings` file was opened** (`git status --short -- '*.xcstrings'` empty).

## Decisions

1. **`draft.createdAt`, not a new field and not `now`.** It is the one timestamp that already exists on
   every path, it already means "the material this call is publishing", and every retry lane already
   carries the original rather than re-stamping (table in §1). `now` would make the comparison vacuous
   — every row is older than the transaction's clock — and a new field would have to be plumbed
   through five callers to say something `createdAt` already says.
2. **Strictly-newer is preserved; equal is normalised** (`stamp <= publicationDate`). A row stamped at
   the same instant as the material being published is this publication's own earlier attempt, not a
   competitor.
3. **A row with a nil `updatedAt` is normalisable.** Nothing can be proven newer than the replay
   without a stamp, and refusing to repair an unstamped row would reintroduce r5s#1 for exactly the
   rows a partial import is most likely to leave behind.
4. **Eligibility read before adoption, not at the repair** (§1). It is the only ordering under which
   an adopted legacy row can still be repaired in the same call.
5. **The `.localVault` branch left unguarded** (§1) — a vault key does not travel, so there is no
   peer pairing to protect there.
6. **`rowsDisagree` asked of the eligible rows only, not of all of them.** Asking it of all rows would
   set `repaired` for a disagreement the loop is then forbidden to act on: a save, a
   `repairedMaterial: true` outcome and a board change notification for a transaction that wrote
   nothing.
7. **The two existing triggers kept.** They describe a change to the payload STORE (a blob inserted, a
   superseded one retired) and `superseded > 0` is what commits the retirement's deletes. Folding them
   into the row comparison would have moved behaviour four standing cases pin.
8. **O-6 measured but not fixed** (§2, §Requests 1). Out of brief, three call sites, one design call
   each, in a parallel phase.
9. **No Codex consult.** The one hard call — which timestamp — is settled by what the callers already
   pass, and it is written down as a table rather than argued.

## Deviations

1. **I rewrote an existing case rather than adding beside it**, as the finding directs
   (`WorkboardSyncedRowRepairTests.swift:102-145`). The case as it stood asserted the defect. Its
   fixture is preserved verbatim inside `seedCardWhoseNewestRowNamesAnAbsentBlob`, including the three
   "the state is broken before the replay" assertions, so nothing it proved has been dropped — the
   pair that replaced it proves strictly more.
2. **I re-timed `testAnIdenticalReplayOntoAgreeingRowsWritesNothing`'s fixture** (§1). No assertion was
   moved, added or removed; the timestamps changed so that the case still measures the thing its own
   doc comment says it measures. Measured, variant 2.
3. **I ran the full iOS suite** although my brief lists nine classes. My file is on every capture path
   and this is the last wave; the nine classes cannot see `WorkboardPersistenceTests`,
   `WorkboardAudioCaptureTests` or the voice lanes, all of which publish through the branch I changed.

## Gates — WHAT I ACTUALLY RAN

Slug `f-store`. DerivedData under `~/Library/Caches/gigaduck-builds/f-store/{DerivedData,
DerivedDataMac,DerivedDataCF,cf-tree}`, every log written there and grepped for `': error: '` and the
verdict strings — never judged from a tail or an exit code. **No `-configuration` passed anywhere.**
Sim `C26F4ECE-16AC-40B7-8D6A-BBF82B5BBA5D`; its TCC table checked first
(`kTCCServiceUbiquity|ai.gigaduck.AgentRelay|2` — allowed, no `0` row, nothing to reset).

- **iOS `build-for-testing`** → `bft-1.log` and `bft-2.log` (after the wave's other edits landed):
  `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **` both times.
- **My 9-class VERIFY set**, `test-without-building`, one quoted `-only-testing:` per class →
  `test-1.log`: `** TEST EXECUTE FAILED **`, one failure, **not mine**:

| Class | Result |
|---|---|
| `WorkboardSyncedRowRepairTests` | `Executed 4 tests, with 0 failures` (3 → 4) |
| `WorkboardBlobPublicationTests` | `Executed 22 tests, with 0 failures` |
| `WorkboardDeskUpsertTests` | `Executed 16 tests, with 0 failures` |
| `WorkboardAvailabilityTests` | `Executed 11 tests, with 0 failures` |
| `WorkboardBlobGCTests` | `Executed 6 tests, with 0 failures` |
| `WorkCaptureDrainerCollisionTests` | `Executed 3 tests, with 0 failures` |
| `WorkCaptureDrainerTests` | `Executed 10 tests, with 0 failures` |
| `WorkCaptureDrainerDurabilityTests` | `Executed 8 tests, with 1 failure (1 unexpected)` |
| `WorkboardChatCaptureTests` | `Executed 8 tests, with 0 failures` |

  The failure, verbatim:
  `WorkCaptureDrainerDurabilityTests.swift:347: error: -[…testAProvenTakeoverStopsTheImportBeforeItsNextMaterialWrite] : failed: caught error: "CancellationError()"`.
  **It is the known takeover flake** integrate-g §"Not taken" 6 records from e-drainer §6, in a file I
  do not own, on a path with no synced payload in it (two `.text` entries, `metadataOnly`, so the
  branch I changed is never entered). Re-run alone → `test-2.log`: `** TEST EXECUTE SUCCEEDED **`,
  `Executed 8 tests, with 0 failures`. It did **not** recur in the full run either.
- **FULL iOS suite** → `ios-full-1.log`: `** TEST EXECUTE SUCCEEDED **`,
  `Executed 5025 tests, with 1 test skipped and 0 failures (0 unexpected) in 81.166 (82.784) seconds`.
  `grep -cE "error: -\["` = **0**, `grep -cE "XCTAssert.* failed"` = **0**. (The `: error: ` hits in
  that log are CoreData's own logging from the deliberate `/nonexistent-…` store description a
  negative-path case installs — not compile or test errors.)
- **macOS `build -destination 'platform=macOS'`** → `mac-1.log`: 0 `: error: `,
  `** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`.
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed.**
- **Counterfactual** → variant 1 `cf-bft-1.log`/`cf-test-1.log`, variant 2 `cf-bft-2.log`/
  `cf-test-2.log`, variant 3 `cf-bft-3.log`,`cf-bft-4.log`/`cf-test-4.log`,`cf-test-5.log`. Tables and
  verbatim lines in §2 and §3. One `Simulator device failed to launch ai.gigaduck.AgentRelay` on
  `cf-test-3.log`; retried once and it ran (`cf-test-4.log`). I did **not** run `simctl shutdown all`
  — other agents are on their own simulators in this phase and a global shutdown could have killed a
  run of theirs.
- **watchOS: NOT run, and it is not owed.** `Services/ConversationStore+Workboard.swift` is absent from
  the Watch target's membership-exception list in `project.pbxproj`, and I touched neither
  `WorkboardRecords.swift` nor the `.xcdatamodeld`.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 805 Swift files scanned…`, exit 0 ·
  `check-folder-map.sh` → `✓ folder map current — 36 Swift source directories`, exit 0 ·
  `check-spec-cites.sh` → `✓ spec citations resolve — 805 Swift files scanned`, exit 0.
- `git diff --check` → clean, exit 0. `git status --short` for `*.xcstrings`, `*.pbxproj`,
  `Conduck/Configs`, `docs/qa` → **empty** on all four. My two files: 0 trailing-whitespace lines, 0
  tab lines; the test file still opens with `// SPDX-License-Identifier: Apache-2.0`.
- **Build caches, the isolated copy and every log removed at end of task** with
  `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh f-store` → `removed: f-store`.
  Re-run to reproduce.

### Suite delta for the orchestrator

**+1 iOS executed** from this slice: `WorkboardSyncedRowRepairTests` 3 → 4 (one case became two).
`WorkboardBlobPublicationTests` stays 22, untouched. Measured full-suite total with the whole wave's
in-flight work in the tree: **5025 executed, 1 skipped, 0 failures** (e-store measured 4957 at the end
of wave E; the other +67 belong to this wave's other agents).

### What I did NOT verify, plainly

- **Anything across two real devices.** The merge this fix protects is a CloudKit ordering no headless
  test can produce; the peer row is staged through the duplication seam. §Founder QA.
- **A row whose `updatedAt` is nil.** The tolerance (decision 3) is argued, not measured: no seam can
  clear that column, and I did not widen one to reach it.
- **Clock skew between devices.** The rule compares two wall-clock stamps written by different
  machines. On a device whose clock is behind, its own fresh publication can look older than a peer
  row and hold back a repair by one skew interval; the next publication with a later stamp still
  repairs it. Nothing here measures that, and no unit test can.
- **The O-6 sub-case in production** — measured only as a probe in the isolated copy (§2), never as a
  committed test.
- **I ran the full iOS suite once**, green on the first attempt, so I have no evidence about
  ordering-independence under repeated load.

## Requests

1. **Whoever closes O-6 — the remedy is four lines and I have MEASURED it.** Give
   `deleteSupersededBlobRows` a `notNewerThan horizon: Date?` parameter, skip any complete row whose
   `record.updatedAt > horizon`, and pass `publicationDate` (already computed, already in scope) at the
   `:828` call site inside my repair branch. In the isolated copy this turns §2's probe from
   `availability=syncedPending, payloadBytes=nil` into **`availability=synced`, the card reading the
   PEER's 34 bytes, both blob rows present** — and all nine VERIFY classes stayed green
   (`cf-test-5.log`: 3/8/10/11/6/22/8/16 + my 4, 0 failures anywhere but the deliberate probe). The
   stale attempt's blob becomes accepted residue of exactly the kind e-store already documented at
   `publishWorkMaterialBlob`. **The other two call sites (`:912` insert path, `:1998` reattach) need
   their own decision and I did not touch them.**
2. **Nobody drop the timestamp filter and repoint every row again.** That is r6s#1 exactly: the
   drainer and the voice retry lane both publish material older than the rows they meet, so an
   unconditional repoint hands a stale replay the power to revert a file the person put there
   afterwards — and to export the reversion.
   `testAReplayOlderThanAPeersRepublicationLeavesItAlone` fails if anyone does.
3. **Nobody move the eligibility read below the adoption block.** Adoption stamps `now` on every
   re-homed row, so a row this same call just touched would read as newer than the call itself and
   never be repaired. `WorkboardChatCaptureTests.testATurnCapturedByAnOlderBuildIsAdoptedOntoTheDeskRatherThanFailing`
   is the case on that path.
4. **Nobody re-time `testAnIdenticalReplayOntoAgreeingRowsWritesNothing`'s duplicate to be NEWER than
   its replay.** The timestamp rule would then hold the write back on its own and the case would pass
   with the disagreement licence deleted — a green test measuring nothing. Variant 2 in §3 is what
   that case is worth today.
5. **e-store's Requests 1 and 2 both still hold and are both still measured.** I added a third
   condition to the repair; I removed neither of the two it already had.
6. **Docs agent — see §Settled facts.** One fact REPLACES the sentence integrate-g carries verbatim
   under "the O-19 trade" (the "brings EVERY physical row back onto them" one); it is now narrower and
   the narrowing is the point.
7. **Founder QA — see §Founder QA.** Both items are two-device and neither is reachable by a unit test.

## Refuted

**Nothing.** r6s#1 held against the current tree when traced by call path before any edit, the
`:102-145` case did construct a 60-second-newer peer row and did assert it was replaced, and the
mechanism is shown red on the reverted tree (§3). The DESIGN DIRECTION was implementable as written:
the comparison fits inside the transaction that already holds every physical row, one of the two
timestamps it names exists on every draft, and the two test shapes it asks for (preserved newer,
normalised older) are one fixture and two replays.

One clause is worth SHARPENING rather than disputing. The finding says a preserved newer pairing "will
then be `.synced` on its own" when its blob arrives — true, and true in the common case the finding
describes. But if that blob has ALREADY arrived here, the same transaction's `deleteSupersededBlobRows`
deletes it, and the preserved row is then left naming bytes this device just destroyed. That is O-6,
not this fix, and it destroyed those same bytes before this change too — but the SYMPTOM it produces
is different now (a card that will not open, rather than a silent revert to the older file), and a
reader who assumes "preserved ⇒ eventually fine" would be wrong in that sub-case. Measured in §2,
remedied in one place in §Requests 1.

## Founder QA

Both need two signed devices on one iCloud account with byte sync on (Gate 2). Neither is reachable by
a unit test: both turn on CloudKit delivering a ROW before its PAYLOAD, which only a real account does.

1. **A reattach that must survive somebody else's retry.** On device A, capture a file into Work and
   let it sync so B shows the card and opens it. Put B in airplane mode. On A, reattach a DIFFERENT
   file onto that same card. Bring B back online but only briefly — long enough for the card to update
   and start saying "Waiting for iCloud…", not long enough for the new file to finish downloading —
   then, on B, use the Work retry (or share the ORIGINAL file into Work again on B, which replays the
   same capture). Expected: B's card keeps naming A's NEW file and finishes downloading it; the old
   file must not come back on either device. **The specific failure this round fixes is A's newer file
   silently reverting to the older one on both devices.**
2. **The same thing once the new file has fully arrived.** Repeat item 1 but let B download A's new
   file completely first, then run the retry/re-share on B. Expected (and NOT guaranteed today — this
   is O-6, §2): the card still opens A's new file. **If instead it sticks on "Waiting for iCloud…"
   permanently on both devices, that is the measured O-6 residue, not a regression of this fix** —
   report it and §Requests 1 is the change.

## Settled facts

- A replay may only bring a card's physical rows back onto its bytes when those rows are NOT newer
  than the material being replayed — the share's own capture time, the parked recording's, the chat
  turn's, or now for something the person is doing — so a retry of an older capture never replaces a
  file another device attached afterwards, and never exports that replacement.
- A row naming a payload this device does not have is preserved rather than repaired whenever it is
  newer than the replay that met it: it is another device's file still on its way, and the card goes
  back to normal on its own when those bytes land.
- **REPLACES the fact integrate-g carries under "the O-19 trade"** ("A replay that carries a card's
  bytes brings EVERY physical row of that card back onto them … whenever any row disagrees"): it
  brings back every row it is ALLOWED to touch — every row not newer than the material it carries —
  and a replay onto rows that already name its bytes still writes nothing at all.
