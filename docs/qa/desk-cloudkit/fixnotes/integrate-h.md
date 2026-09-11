# integrate-h — wave F integration, L5, and the full gate

Worktree `/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard`, branch
`feature/agent-workboard`, HEAD `1e9a004` (the wave-E commit). Sole editor of the tree for this pass.
Slug `integrate-h`, sim `2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF`, watch sim
`28AC563B-42C1-4E66-940D-77E63B07918B`.

**Headline: the gate is CLOSED.** iOS `build-for-testing` green, signed macOS build green, full iOS
suite **5050 executed / 1 skipped / 0 failures**, full watch suite **232 / 0**, three guard scripts
green, `git diff --check` clean, four catalogs parse, both string audits bidirectionally complete,
three mirror triplets byte-identical, model 15 untouched, no leftover build slugs. The only red
anywhere is `check-spec-size.sh`, unchanged at **19827 words** and pre-existing by plan §E/§F.

---

## 1. L5 — the superseded queue API is GONE, and the census is empty

**The census that was RED in three wave-F fixnotes is now green, and it is green because the migration
finished, not because the expectation was relaxed.**

### What I measured before deleting anything

```
grep -rn "clear(ifCurrentID:\|recordPublicationState(id:\|updateAttemptIfCurrent\|PendingRetryRecord" Conduck/Conduck/
→ Conduck/Conduck/Services/PendingRetryStore.swift:359:nonisolated struct PendingRetryRecord: Sendable {
```
One hit, and it is the declaration. The two `.load()` hits in production
(`PersonalWorkbenchView.swift:812`, `WorkboardView.swift:264`) are
`workboardViewModel.load()` — the board view model, not this store.

### What I deleted, and from where

| Symbol | Where it lived | Why it could go |
|---|---|---|
| `PendingRetryStore.clear(ifCurrentID:)` | `PendingRetryStore.swift`, and the `PendingRetryQueueWriting` requirement | Zero production callers: `PendingRetryGuard.disarm` and `InAppAudioRecorder.releaseDurableRetry` both finish through `clear(_ claim:)` now |
| `PendingRetryStore.recordPublicationState(id:transcript:publicationState:)` | `PendingRetryStore.swift` | Zero callers: `ConverseIntent` writes its verdict token-checked, through the claim it holds |
| `struct PendingRetryRecord` | `PendingRetryStore.swift:359` | Zero callers. It was `recover`'s parameter type before the claim migration (**O-2 closes**) |
| `RecordingRetryLane.clear(ifCurrentID:)` | `WorkVoiceRecoveryTests.swift`, the protocol's only other conformer | Follows the requirement it implemented |

**`load()` is KEPT, deliberately, and it is the only survivor.** Nine test call sites need it as the
CONTROL that `claimNext` is measured against — `ArmSideReservationTests` ×4,
`PendingRetryDurabilityTests` ×4, `WorkVoiceRecoveryTests:1219` — and it is exactly the difference
those cases assert: `load()` reads every queued recording into memory and reserves none of them, which
is both halves of what `claimNext` exists to fix. Deleting it deletes the control. Its doc comment
already says so. **K2 permits this explicitly** ("tests may keep using load()"), and the census still
forbids any production caller of it: `"PendingRetryStore.shared.load()": []` and `"retryLane.load()": []`.

### The protocol — a DEVIATION from the letter of the brief, stated

My brief says "widen `PendingRetryQueueWriting`". **That widening already exists and I did not repeat
it.** f-arm delivered it as a REFINEMENT rather than a widening —
`InAppAudioRecorder.swift:75`, `nonisolated protocol PendingRetryLaneReserving: PendingRetryQueueWriting`,
carrying all five claim operations (`claim(id:duration:)`, `renew`, `confirmOwnership`, `release`,
`clear(_ claim:)`), with `extension PendingRetryStore: PendingRetryLaneReserving {}` and
`RecordingRetryLane` conforming to the refinement. Widening the base as well would give every conformer
two paths to the same five operations for no gain.

What the base protocol needed was the opposite: `clear(ifCurrentID:)` REMOVED from it, which is what I
did. Its doc comment was rewritten, because it had become false — it claimed to name "which capture it
arms and which it releases", and it now names only the arm:

> The durable write a capture surface makes when it parks a recording, named as one seam. … It carries
> the arm and NOTHING that ends a capture: every operation that finishes, restates or releases one is
> token-gated and lives on `PendingRetryLaneReserving`, which refines this. A seam that let a surface
> end a capture by id is what let two surfaces finish one recording.

### The census edit, exactly

`PendingRetrySurfaceHandoffTests.swift`:
- `"clear(ifCurrentID:"` → `[]` (was `["Conduck/Services/PendingRetryGuard.swift", "Conduck/Services/InAppAudioRecorder.swift"]`)
- `"recordPublicationState(id:"` → `[]` (was `["Conduck/Intents/ConverseIntent.swift"]`)
- the three allowlist comments explaining why the arming lanes could not migrate are DELETED — their
  reasons are gone.
- **The needles all stay.** An empty expectation is what a returning caller fails against; deleting the
  rows would retire the guard. This is `updateAttemptIfCurrent(`'s existing treatment, now applied to
  all four.
- The file header was rewritten to the new truth (three operations gone, `load()` surviving as a
  test-only control that production still may not call).
- **One strengthening, in the same edit**: the scan no longer exempts `PendingRetryStore.swift`. The
  exemption existed because the store DECLARED the superseded operations; it declares none of them now,
  so a call to one from inside the store would be as lease-blind as a call from anywhere else. (A
  *declaration* cannot match a needle in any case: `callText` collapses whitespace but keeps it, so
  `func clear(ifCurrentID id: UUID)` reads as `clear(ifCurrentID id:` and the needle is
  `clear(ifCurrentID:`.)

### How I know the census still bites — MEASURED, not argued

Counterfactual on the live tree (the census is a source scan, so no rebuild is involved): one line
appended to `Conduck/Conduck/ContentView.swift` —

```swift
private let censusCounterfactualNeedle = "await store.clear(ifCurrentID: id) and recordPublicationState(id: id)"
```

`test-without-building`, that one case → `** TEST EXECUTE FAILED **`,
`Executed 1 test, with 2 failures (0 unexpected) in 2.180 (2.180) seconds`, verbatim:

```
PendingRetrySurfaceHandoffTests.swift:277: error: -[…testNoProductionCallerRemainsOnTheSupersededQueueOperations] :
  XCTAssertEqual failed: ("["Conduck/ContentView.swift"]") is not equal to ("[]") — `recordPublicationState(id:` …
PendingRetrySurfaceHandoffTests.swift:277: error: -[…testNoProductionCallerRemainsOnTheSupersededQueueOperations] :
  XCTAssertEqual failed: ("["Conduck/ContentView.swift"]") is not equal to ("[]") — `clear(ifCurrentID:` …
```

Restored from a copy taken before the insertion; `diff -q` clean and SHA-256 identical on both sides
(`d99926ec0ce18494400f7a969ed9d3babeddb28cd21a9c616b552007b8abff07` before and after).

### The two consequential edits the deletion forced

1. **`WorkVoiceRecoveryTests.testTwoQueuedCapturesEachFinishOntoTheirOwnCard`** called
   `lane.clear(ifCurrentID:)` twice, because its `first`/`second` are FABRICATED claims whose token no
   lane ever issued. Rewritten to reserve through the lane and clear with the lane's own claim:
   ```swift
   let firstReservation = await lane.claim(id: first.id, duration: 600)
   let firstHold = try XCTUnwrap(firstReservation)
   let firstCleared = await lane.clear(firstHold)
   XCTAssertTrue(firstCleared)
   ```
   Strictly stronger than what it replaced: the old form could not have told a clear from a
   lease-blind delete, and this one asserts the clear was ACCEPTED. Nothing the case proved was
   dropped — the `stillQueued == [second.id]` and `emptied.isEmpty` assertions are untouched.
   (Bound to a local first: `try XCTUnwrap(await …)` is an `async` call in an autoclosure and does not
   compile — measured, `ios-bft-1.log`, four `error: 'async' call in an autoclosure that does not
   support concurrency`.)
2. **`WorkboardVoiceLaneTests`' control fixture named the deleted type.** `recordChunk` built a
   `PendingRetryRecord(metadata:audio:)`; the shipped intent builds `Self.heldCapture(_:audio:reservation:)`.
   Repointed at the shipped shape, and its paired BREAK fixture repointed with it (the needle had to
   move from `"metadata: Self.stamped(…)"` to `"Self.stamped(…),"`, because the shipped form is
   positional). Measured: the intermediate state was RED on exactly the control that exists to catch it
   — `WorkboardVoiceLaneTests.swift:276: XCTAssertEqual failed: ("[]") is not equal to
   ("["theRecoveryCarriesTheCapturesRecord"]") — Control: the fixture written to break
   theRecoveryCarriesTheCapturesRecord must break that rule and only that rule.` — and green after.
   The validator itself was NOT touched: it reads the recovery's first argument for `pendingMetadata`
   and `uploadData` and is deliberately type-name-agnostic, which is why the shipped rename never
   broke it.

**`STTKeyBlackoutLaneTests` needed nothing.** 11/0 in both targeted runs and in the full suite; no lane
was split again, so no `delegatesTo` row was owed and none was added.

---

## 2. Requests resolved, one by one

### Satisfied inside the wave — verified by me, no edit needed

| Request | Verdict |
|---|---|
| f-arm 3 / e-surfaces 1 / **O-3** — macOS Retry gated on `service.lastError?.shouldPreserveForRetry` | **CLOSED, already fixed.** `DictationPopoverView.swift:1326-1327` now reads `service.pendingRetryCount > 0`. `grep -rn 'service\.lastError' Conduck/Conduck/` returns nothing |
| f-queue 3 / **L4** — headless lane must hold for 90 s, not 600 | **SATISFIED.** `PendingRetryGuard.leaseDuration = deferredNotificationDelay` = **90** (`PendingRetryGuard.swift:57,66`), passed at `:164` as `duration: leaseDuration` |
| f-queue 4 — `DictationService.preserveForRetry` still spells the pre-id-scoped `pending_retry_audio.m4a` | **CLOSED, already fixed.** `grep -n 'pending_retry_audio' DictationService.swift` → one hit, and it is a COMMENT at `:847` saying the bookkeeping path is built from `PendingRetryFiles` precisely so it never names the legacy file |
| f-queue 2 / **L2** — every surface that transcribes must renew | **SATISFIED, all four lanes.** `ContentView.swift:1654` and `DictationService.swift:343` wrap the provider hop in `PendingRetryLeaseRenewal.whileRenewing(claim)`; `ConverseIntent.swift:533` calls `PendingRetryGuard.renew(guardToken)`; `InAppAudioRecorder.swift:1088-1108` runs its own loop, started at `:1071` and stopped at `:1079`/`:1121` |
| f-finish 4 / f-copy-docs — the new copy key had no catalog row | **CLOSED.** `pendingRetry.card.discard.confirm.body.published` is spliced; dict diff vs `HEAD` is **+1 / −0 / ~0** and the source `defaultValue:` (a `"""` literal with `\` continuations, `PendingRetryCard.swift:206-212`) collapses byte-for-byte to the catalog `en` |
| f-store 6 — one settled fact REPLACES the one integrate-g carried | **DONE by f-copy-docs**, and carried in §6 below in its narrowed form only. The superseded wording is not reinstated here |
| f-copy-docs 5 — spec-size guard must be recorded as pre-existing | **RECORDED**, §3(5). 19827, the fifth consecutive integration at that number |

### Resolved against each other — the same item raised twice, carried once

- **f-arm 1 + f-finish 3 + f-queue 1** are one request: empty the census, delete the superseded members,
  do both halves in one edit. Done as §1. Each of the three fixnotes says explicitly it left the file
  alone because it was another agent's; none of them was wrong to.
- **f-copy-docs 1a + f-finish 2** are one founder copy call about the SAME dialog: whether the shared
  title "Discard this recording?" should become state-aware for a published Work capture, and whether
  the verb should change with it. Carried once, into **O-8(h)**.
- **f-copy-docs 3 + e-drainer 1** are one item (`workboard.capture.discarded.message.one` is half true
  for a terminal refusal), already **O-8(f)**, and f-drainer's verified retirement makes it *more*
  wrong rather than less — the copy claims Conduck could not read the file, and the file is now
  provably a complete copy in `refused/`.
- **f-copy-docs 4 + e-surfaces 4** are one item, already **O-9**.

### Not taken — real design, each promoted to an open item with its reason

1. **f-arm 4 — the two renewal policies disagree.** `PendingRetryLeaseRenewal.whileRenewing` ENDS its
   loop on a false `renew`; `InAppAudioRecorder.startRenewingRetryLease` deliberately does not
   (`:1100`, "Only `stopRenewingRetryLease` ends the loop"). `PendingRetryStore.renew` answers false for
   five different reasons — no container, a lock throw, an unreadable sidecar, a token mismatch, a
   sidecar write failure — and only ONE of them means the reservation was lost. So a transient lock
   failure retires a renewal that is still the caller's, and a transcription that then runs past the
   horizon is back inside r6a#2. **Not fixed here**: separating "you lost it" from "ask again" needs
   `renew` to answer something richer than `Bool`, which is a store API change with three call sites and
   no counterfactual measured for it, in the last wave before the gate. → **O-1**.
2. **f-finish 1 — `pendingSummary()`.** The retry card renders WHICH recording is waiting from
   `pendingErrorCode()` (newest, held or not) and ACTS through `claimNext()` (newest unreserved); the
   two can name different captures. Real, cosmetic, twelve lines, and a store API addition. → **O-2**.
3. **f-store 1 — the O-6 remedy.** Four lines, and f-store MEASURED them working. It is still a design
   call on three call sites (`:828` repair, `:912` insert, `:1998` reattach) of which f-store touched
   one. → **O-6**, now carrying the measured recipe.
4. **f-drainer 5 — the POSIX-permission case.** Recorded, not changed:
   `testARetirementWhoseCopyCannotLandLeavesTheQueueHoldingTheBytes` chmods its own temp root to `0o555`
   and restores it in a `defer`, asserting `isWritableFile == false` first so a run as root fails
   legibly. It passed in both full-suite runs.

### "Nobody undo these" — carried forward, not re-litigated

f-arm's seven, f-finish's five, f-queue's seven, f-store's five, f-drainer's three and f-copy-docs' two
are each pinned by a case one of those agents measured red on a counterfactual. I undid none of them and
I re-ran none of their counterfactuals. They are the standing list for the next reviewer.

---

## 3. The gate — every number, the exact lines

Slug `integrate-h`; derivedData and every log under
`~/Library/Caches/gigaduck-builds/integrate-h/{DerivedData,DerivedDataMac,DerivedDataWatch,logs}`, every
log grepped for `': error: '` and for `BUILD SUCCEEDED|BUILD FAILED|TEST SUCCEEDED|TEST FAILED|Executed ` —
never judged from a tail or an exit code. **No `-configuration` passed anywhere.** No `/tmp`, no bare
`rm -rf`.

**Simulator TCC checked FIRST**, before trusting any run:
```
sqlite3 ~/Library/Developer/CoreSimulator/Devices/2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF/data/Library/TCC/TCC.db \
  "select service, client, auth_value from access where client='ai.gigaduck.AgentRelay';"
→ (no rows), exit 0
```
No row at all means `.notDetermined` — no stale denial, nothing to reset.

Everything below is the FINAL tree (after the comment-only protocol-doc rewrite; I rebuilt and re-ran
all four rather than reuse the earlier green runs).

### (1) iOS `build-for-testing` — `ios-bft-4.log`
```
** TEST BUILD SUCCEEDED **
```
`grep -c ': error: '` = **0**. `PendingRetryStore.swift` warnings = **13**, the same count and the same
single pre-existing class (main-actor-isolated `DefaultsStore` calls from synchronous locked helpers)
that e-queue and f-queue both measured. **Zero warnings added**, in any file I touched, on either
platform.

### (2) Signed macOS build — `mac-2.log`, `-destination 'platform=macOS'`
```
** BUILD SUCCEEDED **
    Signing Identity:     "Apple Development: Peter Krueck (Z4PNDLZK98)"
```
`grep -c ': error: '` = **0**. Signed through the identity override; **no `CODE_SIGNING_ALLOWED=NO`
fallback needed or used.**

### (3) FULL iOS suite — `test-without-building`, `ios-full-2.log`
```
** TEST EXECUTE SUCCEEDED **
	 Executed 5050 tests, with 1 test skipped and 0 failures (0 unexpected) in 81.509 (82.905) seconds
```
`grep -cE "error: -\["` = **0**. `grep -cE "XCTAssert.* failed"` = **0**. **No failure to list.**
The one skip is the expected environment skip:
`Test Case '-[ConduckTests.GatewayAdapterBriefTests testClipboardBriefRevisionPinMatchesPublishedContract]' skipped`.

(An identical earlier run on the same tree minus the comment edit, `ios-full-1.log`, reported the same
`Executed 5050 tests, with 1 test skipped and 0 failures (0 unexpected) in 82.339 (83.777) seconds`.
Two full runs, same number, so the count is not ordering-dependent on this machine.)

### (4) FULL watch suite — `-scheme ConduckWatchTests`, sim `28AC563B-…`, `watch-2.log`
```
** TEST SUCCEEDED **
	 Executed 232 tests, with 0 failures (0 unexpected) in 9.517 (9.595) seconds
```
`grep -c ': error: '` = **0**. **232 / 0 — exactly the expected baseline.**

### (5) Guard scripts, from the worktree root
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 808 Swift files scanned, no raw store or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift`, exit **0**
- `bash scripts/check-folder-map.sh` → `✓ folder map current — 36 Swift source directories, all mapped, and every path the map names exists`, exit **0**
- `bash scripts/check-spec-cites.sh` → `✓ spec citations resolve — 808 Swift files scanned, 1 quoted section name(s), every one a live heading in docs/ai-context/spec.md`, exit **0**
- `bash scripts/check-spec-size.sh` → exit **1**, **PRE-EXISTING**:
  ```
  ✗ docs/ai-context/spec.md is 19827 words; the ceiling is 16900.
  ✗ decisions over their word limit:
      "Sending files and getting them back are two capabilities of one lane"  687 words, against a ceiling of 650.
      "Forgetting a gateway erases the credentials and keeps the colour tag"  701 words, against a ceiling of 650.
  ```
  `wc -w docs/ai-context/spec.md` = **19827**, the ceiling my brief names and the same number
  integrate-d, -e, -f and -g each recorded. Plan §E and §F both forbid fixing it. **Not mine, not fixed.**

### (6) `git diff --check`
No output, exit **0**. `git status --porcelain` for `*.pbxproj`, `Conduck/Configs`,
`Conduck/Conduck/Configs` and `docs/qa` → **empty on all four**. The symlink
`Conduck/Configs/Identity-Override.xcconfig` was never touched.

### (7) Catalogs — all four `json.load` clean, both audits bidirectional
```
Conduck/Conduck/Localizable.xcstrings              2252 rows
Conduck/ConduckShareExtension/Localizable.xcstrings  43 rows
Conduck/ConduckShareExtensionMac/Localizable.xcstrings 42 rows
Conduck/ConduckWatch Watch App/Localizable.xcstrings  299 rows
```
Bidirectional audit over the app target's comment-bearing sources against the main catalog:
```
workboard.:    catalog=147 source=147  SOURCE-ONLY(no row)=[]  CATALOG-ONLY(no ref)=[]
pendingRetry.: catalog=9   source=9    SOURCE-ONLY(no row)=[]  CATALOG-ONLY(no ref)=[]
```
Dict diff of `Conduck/Conduck/Localizable.xcstrings` against `HEAD`: **added 1, removed 0, changed 0** —
`pendingRetry.card.discard.confirm.body.published`, `en` / `state: new` /
`"This removes only the copy kept for another try at transcribing it. The recording is already in Work
and stays there."`, byte-identical to its source `defaultValue:`. `git status --porcelain -- '*.xcstrings'`
lists only that one file.

### (8) Mirror triplets — byte-identical from `import Foundation` onward
| Triplet | SHA-256 (first 16) |
|---|---|
| `WorkCaptureEnvelope.swift` ×3 | `45a26a6658c92401` — IDENTICAL |
| `ShareTargetsSnapshot.swift` ×3 | `a72a7d13d6f1e9ec` — IDENTICAL |
| `WorkCaptureDirectoryPublisher.swift` ×3 | `777159cc94c1cd9a` — IDENTICAL |

(The app-side sources are `Conduck/Conduck/Models/WorkCaptureEnvelope.swift`,
`Conduck/Conduck/Models/ShareTargetsSnapshot.swift` and
`Conduck/Conduck/Services/WorkCaptureDirectoryPublisher.swift` — the first two are NOT under `Services/`.)

### (9) Build caches
`/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh integrate-h` → `removed: integrate-h`.
`ls ~/Library/Caches/gigaduck-builds/` → **empty**. No leftover slug from any wave-F agent; every log
quoted above went with it, and every run is reproducible from the commands recorded here.

### (10) The model
```
git diff --name-only 651a859 -- '*.xcdatamodeld/*' '*.xccurrentversion'
→ Conduck/Conduck/Models/Conversations.xcdatamodeld/.xccurrentversion
  Conduck/Conduck/Models/Conversations.xcdatamodeld/Conversations 16.xcdatamodel/contents
git diff --stat 651a859 -- '*Conversations 15.xcdatamodel*'   →  (no output)
```
Exactly the two expected files, and **version 15 is byte-identical to `651a859`.** (Note the pathspec:
`'*.xcdatamodeld'` matches nothing in this repo; `'*.xcdatamodeld/*'` is the working one.)

### (11) The files the commit must include — 20 modified + 5 untracked, 0 deletions

Modified (20):
```
Conduck/Conduck/ContentView.swift
Conduck/Conduck/Intents/ConverseIntent.swift
Conduck/Conduck/Localizable.xcstrings
Conduck/Conduck/MenuBar/DictationService.swift
Conduck/Conduck/Services/ConversationStore+Workboard.swift
Conduck/Conduck/Services/InAppAudioRecorder.swift
Conduck/Conduck/Services/PendingRetryGuard.swift
Conduck/Conduck/Services/PendingRetryStore.swift
Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift
Conduck/Conduck/Views/Components/PendingRetryCard.swift
Conduck/Conduck/Views/Workboard/WorkboardVoiceCaptureView.swift
Conduck/ConduckTests/PendingRetryDurabilityTests.swift
Conduck/ConduckTests/PendingRetrySurfaceHandoffTests.swift
Conduck/ConduckTests/RemoteAgent/HeadlessRetryGuardSpanTests.swift
Conduck/ConduckTests/WorkVoiceRecoveryTests.swift
Conduck/ConduckTests/WorkboardCopyTruthGuardTests.swift
Conduck/ConduckTests/WorkboardSyncedRowRepairTests.swift
Conduck/ConduckTests/WorkboardVoiceLaneTests.swift
docs/ai-context/project-structure.md
docs/ai-context/spec.md
```

**UNTRACKED — the commit is incomplete without these five (1 production, 4 tests):**
```
Conduck/Conduck/Services/PendingRetryLeaseRenewal.swift
Conduck/ConduckTests/ArmSideReservationTests.swift
Conduck/ConduckTests/PendingRetryLeaseTests.swift
Conduck/ConduckTests/PendingRetryOwnershipHandoffTests.swift
Conduck/ConduckTests/WorkCaptureDrainerRetirementTests.swift
```
All five verified: first line `// SPDX-License-Identifier: Apache-2.0`, 0 tab lines, 0
trailing-whitespace lines. **No `.pbxproj` edit was needed or made** — every new file is in a
synchronized group and none is in `ConduckWatchTests`.

---

## 4. Test-count reconciliation — 5002 → 5050, exact, zero drift

| Source | Delta | What moved |
|---|---|---|
| integrate-g's gate | — | **5002** executed, 1 skip, 0 fail |
| f-arm | **+15** | `ArmSideReservationTests` NEW **11**; `HeadlessRetryGuardSpanTests` 12 → **13** (+1); `WorkVoiceRecoveryTests` 27 → **30** (+3) |
| f-queue | **+18** | `PendingRetryLeaseTests` NEW **13**; `PendingRetryDurabilityTests` 21 → **26** (+5) |
| f-finish | **+9** | `PendingRetryOwnershipHandoffTests` NEW **9** |
| f-drainer | **+4** | `WorkCaptureDrainerRetirementTests` NEW **4** |
| f-store | **+1** | `WorkboardSyncedRowRepairTests` 3 → **4** (one case became two) |
| f-copy-docs | **+1** | `WorkboardCopyTruthGuardTests` 8 → **9** |
| **integrate-h (me)** | **0** | Three cases REWRITTEN in place, none added, none removed, none deleted |
| **Total** | **+48** | 5002 + 48 = **5050** — the measured number, twice |

**Every delta the six wave-F fixnotes declare is accounted for and none is unexplained.** My own slice
adds no case: L5 is a deletion of production API plus three in-place rewrites
(`WorkVoiceRecoveryTests.testTwoQueuedCapturesEachFinishOntoTheirOwnCard`, the census expectations, and
the `WorkboardVoiceLaneTests` fixture pair), and its regression proof is the counterfactual in §1 rather
than a new case — the guard that proves it already exists and was already red for exactly this reason
in three wave-F runs.

Skips: **1**, unchanged, `GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`.
Watch: **232 / 0**, unchanged.

---

## 5. Open items — integrate-g's O-1…O-21 reconciled, renumbered

**Closed this wave (four), with the evidence I checked:**

| Was | Item | Closed by |
|---|---|---|
| **O-1** | The three ARM-side lanes cannot hold a reservation, so three superseded operations cannot be retired | f-arm minted `claim(id:duration:)` (`PendingRetryStore.swift:796`) and moved `PendingRetryGuard`, `InAppAudioRecorder` and `ConverseIntent` onto it; I deleted the three operations (§1). `grep` over `Conduck/Conduck/` for all four superseded names → **NONE**. **Its residual hazard closes with it**: `ConverseIntent.heldCapture` pairs the record with `reservation.claim?.token` — the store's real token, never a `UUID()` — so `recover`'s durable `.published` write on the Shortcuts lane now LANDS |
| **O-2** | `PendingRetryRecord` has zero real callers | Deleted (§1). The one remaining mention was a string literal in `WorkboardVoiceLaneTests`' control fixture, repointed at the shipped `Self.heldCapture(_:audio:reservation:)` shape in the same edit, with its break fixture, and both measured |
| **O-3** | The macOS backlog Retry button is gated on a proxy the store can answer directly | f-finish. `DictationPopoverView.swift:1327` is `service.pendingRetryCount > 0`; `grep -rn 'service\.lastError' Conduck/Conduck/` → nothing. Verified on a signed macOS build |
| **O-21's remedy half** | `DictationService.preserveForRetry` naming the pre-id-scoped recording (f-queue §Requests 4) | Already fixed: the only `pending_retry_audio` in the file is a comment at `:847` explaining that the bookkeeping path is built from `PendingRetryFiles` so it can never name the legacy file |

**Open, renumbered:**

| # | Item | Why it is open, and who it belongs to |
|---|---|---|
| **O-1** | **NEW — two renewal policies disagree, and the store cannot tell a lost hold from a busy lock.** `PendingRetryLeaseRenewal.whileRenewing` ends its loop on the first false `renew`; `InAppAudioRecorder.startRenewingRetryLease` (`:1100`) deliberately never does. `PendingRetryStore.renew` returns false for five reasons and only a token mismatch means the reservation is gone — so a transient `flock` contention or an unreadable sidecar silently retires a renewal that is still the caller's, and a transcription past the horizon is back inside r6a#2. **Remedy shape**: `renew` answers an enum (`held` / `lost` / `unavailable`), the shared helper retries on `unavailable` and ends only on `lost`, and the recorder's hand-rolled loop folds into the helper. One store change, three call sites. f-arm §Requests 4 |
| **O-2** | **NEW — `pendingSummary()`: the retry card names one capture and acts on another.** Everything the card RENDERS about which recording is waiting comes from `pendingErrorCode()` (the newest, held or not); everything it DOES goes through `claimNext()` (the newest UNRESERVED). No accessor returns an id, so the host cannot bind the card to a capture without reserving it. `func pendingSummary() async -> (id: UUID, lastErrorCode: Int?)?` supersedes `pendingErrorCode()` (two callers, both one line) and lets the discard address its capture with `claim(id:)`. Cosmetic today; twelve lines. f-finish §Requests 1 |
| **O-3** | **No `AppError` code for a permanent identity refusal.** `.workDeskWriteFailed` (78) claims transience about a permanent refusal, which is why a double-refused wordless capture records no code at all. A new non-retryable case plus one `updateAttempt(claim:lastErrorCode:)` in `recover`'s `.refusedTwice` branch. e-recover §Requests 3. *(was O-4)* |
| **O-4** | **The cross-process lock and the retry queue are proven with two instances in ONE process, never two.** Every wave-E and wave-F case drives the REAL `flock`, the REAL directory scan and the REAL write orders — but from one process, and the App-Group path only by derivation. Four separate fixnotes say so in the same words. → Gate-2 founder QA. *(was O-5)* |
| **O-5** | **`deleteSupersededBlobRows` knowingly accepts r4s#3's hazard class — and the remedy is now MEASURED.** f-store: give it `notNewerThan horizon: Date?`, skip any complete row whose `record.updatedAt > horizon`, pass `publicationDate` (already in scope) at the `:828` call site. In f-store's isolated copy that turned the probe from `availability=syncedPending, payloadBytes=nil` into `availability=synced` with the card reading the PEER's bytes and both blob rows present, all nine VERIFY classes green. **The other two call sites (`:912` insert, `:1998` reattach) each need their own decision and were not touched.** Never a sweep. f-store §2, §Requests 1. *(was O-6)* |
| **O-6** | **`IsolatedWorkStores` adoption** in the classes c-store and c-drainer did not own. Hygiene, not correctness. *(was O-7)* |
| **O-7** | **Founder copy calls, consolidated — now NINE.** (a) the voice sheet's privacy line, honest about the AI hop. (b) the three desk-banner sentences. (c) `workboard.workspace.drop.overlay.caption`. (d) the recovered-note title. (e) copy-b's tutorial line and large-file confirm. (f) `workboard.capture.discarded.message.one` is half true for a terminal refusal — and f-drainer's verified retirement makes it MORE wrong, because the copy is now provably complete; recommended wording to react to, not to ship: *"Conduck couldn't add one shared item to your board."* (g) the backlog count is a fragment ("2 recordings waiting") that is a caption on iOS and a whole popover sentence on macOS. (h) **NEW, raised twice** — the discard dialog's TITLE is shared between its two bodies and still reads "Discard this recording?", which the published body's first sentence has to correct; the alternative reads the whole dialog as "Stop retrying this recording?" / "Stop retrying" and costs three more keys, and f-finish declined to take it unilaterally because the card's BUTTON is drawn before any capture is reserved and can never be state-aware. f-copy-docs §Requests 1 + f-finish §Requests 2. *(was O-8)* |
| **O-8** | **`diagnostics.voice.pendingRetry.waiting` is unminted, correctly.** `factPendingRetry` carries the count; the on-screen row's sentence still describes one capture. The copy guard walks `pendingRetry.*` in BOTH directions, so the key and its `if` in `DiagnosticsRunner` must land in the SAME edit or `testEveryWorkCatalogRowIsReferencedInSource` fails. *(was O-9)* |
| **O-9** | **`WorkCaptureRetryCoordinator.swift` still has ZERO production callers.** Deleting it compiles. The decision is whether the desk keeps a coordinator-shaped fallback now that `recover` is the single answer. *(was O-10)* |
| **O-10** | Collapse the two iCloud banners — `ICloudUnavailableBanner` gains a `message`, `WorkboardSyncBanner` dies. *(was O-11)* |
| **O-11** | Should `ReplyVoice.shared` register on iOS? *(was O-12)* |
| **O-12** | Carry `WorkMaterial.filename` onto `WorkboardMaterialSnapshot` so a voice note's preview copy gets its real `.m4a`. *(was O-13)* |
| **O-13** | Three behaviour-neutral consolidations: the board-tile radius `13` literal into `WorkboardMetrics`; one shared `WorkboardCardActions`; `onCancel` → `onDismiss` on the voice sheet's hand-off. *(was O-14)* |
| **O-14** | The availability glyph/tint/label mapping is still duplicated between `WorkboardSourceCard` and `WorkboardAudioCardView`'s chip. *(was O-15)* |
| **O-15** | `WorkboardViewModel.workspaceStatus` → `transientStatus`/`deskStatus`. Vocabulary only. *(was O-16)* |
| **O-16** | **The external-storage ceiling memory bound is uncovered by DECISION, not oversight.** Accepted debt. *(was O-17)* |
| **O-17** | **Watch catalog drift, pre-existing since `efa553e`** — `WatchRecordingService.swift:761` declares `"\(name) isn't available…"` while the Watch catalog row reads `"%@ isn't set up…"`. The catalog wins at runtime, so the source lies to the next reader. Not a Work string. *(was O-18)* |
| **O-18** | **Spec-size debt** — 19827 against a 16900 ceiling, two unrelated decisions over their 650-word limits. Out of scope by plan §"Out of scope". The number has now held at 19827 across **five** consecutive integrations, with wave D's, E's and F's facts each paid for inside the decision that received them. *(was O-19)* |
| **O-19** | **Founder QA (Gate 2), consolidated — now 81 items across twenty-one fixnotes**, none reachable by a unit test. Waves A–C's 16 + D's 15 + E's 20 + F's 30 (§6). Plus plan §C's Gate 2 in full: real-CloudKit export/import across both stores, delete/reinstall reimport, actual watch exclusion. **Byte sync does not reach a release build without it.** *(was O-20)* |
| **O-20** | **A registry loop whose first failure aborts the pass reports one lane when several are broken.** `STTKeyBlackoutLaneTests` pins nine key-refusal lanes; its six `try XCTUnwrap`s hide every failure after the first. Converting them to non-throwing checks that `continue` would report all nine every run. Behaviour-neutral for a green tree; it changes only what a red one tells you. *(was the residue half of O-21)* |
| **O-21** | **NEW — a control fixture can name a type that no longer exists and stay green.** `WorkboardVoiceLaneTests`' `recordChunk` named `PendingRetryRecord` for a whole wave after the shipped lane stopped building one, and nothing failed: the validator reads the recovery's first argument for `pendingMetadata` and `uploadData` and is deliberately type-name-agnostic (which is right). The fixture is repointed now, but nothing stops it drifting again. The honest guard is a rule-0 assertion that the compliant fixture's identifiers all still resolve in the shipped source — or an explicit comment saying the fixture is a SHAPE, not a quotation. Decide which; do not tighten the validator itself, whose type-agnosticism is load-bearing |

---

## 6. Founder QA — consolidated from the six wave-F fixnotes (30 items)

All are device-only or two-device and none is reachable by a unit test. These **ADD** to the 51 already
carried (waves A–C's 16, D's 15, E's 20), all of which still apply. Total **81** (O-19).

**From f-arm (7) — a Shortcut and the app, racing:**
1. **A Shortcut and the app, racing for one recording.** Airplane mode. Run the Action-Button capture so it parks a recording, then — before the "Recording Saved" notice — open the app and tap Retry. Exactly one may finish it; the other must say **"This recording is already being finished. Try again in a moment."** and change nothing. Never two cards, two chat turns, or two replies.
2. **The Shortcut killed mid-flight, then retried at once.** Start a Shortcut capture on a terrible connection and force-quit the Shortcuts host while it is thinking. When the notice arrives at 90 seconds, tap it and press Retry immediately: it must offer the recording **now**, not refuse it. (This is the whole reason the headless hold is 90 seconds rather than ten minutes.)
3. **The desk voice sheet and the retry card, at once.** Park a Work voice capture. With the sheet still open showing its error, retry from the home-screen card, and while that runs press **Try Again** on the sheet. The sheet must show the busy sentence and do nothing else — no second spinner, no second provider charge — and when the card's retry finishes, exactly one audio card carries the words.
4. **Record Again while the card is retrying.** Same setup, but press **Record Again** on the sheet mid-retry. The new recording must start and the FIRST must still be there and still finish correctly. Nothing may vanish.
5. **A long Work retry does not lose its hold.** With a deliberately slow custom STT endpoint, start the sheet's Try Again and let it run past ten minutes. It must still finish onto the same card, and the retry card must not have taken the recording away meanwhile.
6. **VoiceOver on the voice sheet's refusal.** With the sheet in its error state, trigger the busy refusal (step 3). VoiceOver must read the busy sentence — the visible state does not otherwise change, so it is the only signal a non-sighted person gets.
7. **The Shortcut whose save failed still works.** Fill the device storage (or otherwise make the parked write fail) and run a Shortcut capture: it must still transcribe and still deliver its answer. The one thing that must NOT happen is a refusal — with nothing parked, this process holds the only copy.

**From f-finish (7) — the renewal, the busy line, the discard:**
8. **A transcription longer than ten minutes, on the surface doing it.** Point Settings → Voice at a stalling custom STT endpoint, park a recording, press Retry, let it run past ten minutes. The words must land; nothing may appear twice; the card must not have quietly emptied while the spinner was up.
9. **Two surfaces, one recording, on the Mac — the losing one must SAY so.** Start the menu-bar Retry, let it run, then press the main window's retry. The second must show the busy sentence **and must still draw a Retry button** (it is a retryable state). Never two cards, never two messages in the thread.
10. **Discard while another surface holds the only waiting recording.** With the menu bar mid-retry, tap **Discard recording** in the main window. **No confirmation dialog may appear at all** — the busy line shows instead and nothing is deleted. This is the half that used to fail silently.
11. **Discard a published Work recording, and read the dialog.** Record a Work voice note that reaches the desk but whose transcription fails (turn the network off *after* the card appears). Tap Discard: the confirmation must say the retry copy is removed and **the recording stays in Work** — it must NOT say it cannot be recovered. Confirm, then check the desk: the audio card is still there and still plays.
12. **Cancel the confirmation, then retry immediately.** Tap Discard, tap **Cancel**, then tap **Retry** at once. Retry must start straight away — "already being finished" here is a bug in this change.
13. **Discard, then leave the dialog by a side door.** Tap Discard and, while it is up, open a reply notification (or switch apps and come back). Then tap Discard again: the confirmation must appear normally, not report the recording as busy.
14. **The backlog after a refused hand-off.** With two recordings waiting, retry one on each surface at roughly the same time. Exactly one message per recording may reach the thread, and the count must end at zero with no card left standing.

**From f-queue (5) — the reservation and the upgrade:**
15. **A transcription longer than ten minutes.** On a terrible connection, start a Work retry and let it run past ten minutes. The recording must still be there afterwards — before this change the launch sweep could delete it mid-transcription.
16. **Force-quit mid-retry, then retry immediately.** Reopen and press retry at once. It is EXPECTED to say nothing is waiting for up to ten minutes (the reservation is honoured), then to offer the capture again. What must NEVER happen is two cards or two transcripts for one recording.
17. **The upgrade, from a container the fold half-finished.** Anything left of `pending_retry_audio.m4a` is now reclaimed on first launch only if its bytes are already parked under a capture id. After the first launch of this build, Settings → Diagnostics must report the same number of waiting recordings as before it, and no recording may have vanished.
18. **Two surfaces, one recording (macOS), while one is slow.** Start the menu-bar retry, let it run, then press the main window's retry. The second must refuse or wait — never start a second transcription of the same recording — and when the first finishes, exactly one card appears.
19. **A Shortcut capture and an in-app capture failing at once.** Both must still be listed in Diagnostics afterwards, and finishing either must not disturb the other.

**From f-store (2) — two devices, byte sync on (Gate 2):**
20. **A reattach that must survive somebody else's retry.** On device A, capture a file into Work and let it sync so B shows and opens the card. Put B in airplane mode. On A, reattach a DIFFERENT file onto that card. Bring B online only briefly — long enough for the card to update and start saying "Waiting for iCloud…", not long enough to download — then, on B, use the Work retry (or re-share the ORIGINAL file into Work on B, which replays the same capture). Expected: B's card keeps naming A's NEW file and finishes downloading it; the old file must not come back on either device. **The specific failure this round fixes is A's newer file silently reverting to the older one on both devices.**
21. **The same thing once the new file has fully arrived.** Repeat 20 but let B download A's new file completely first, then run the retry/re-share. Expected (and NOT guaranteed today — this is **O-5**): the card still opens A's new file. **If instead it sticks on "Waiting for iCloud…" permanently on both devices, that is the measured O-5 residue, not a regression of this fix.**

**From f-drainer (4) — observables, not steps (a genuine double id collision cannot be staged by hand):**
22. **The observable is still a non-event.** Share several files in a row from another app. Every one must appear on the desk. This change alters nothing a working device does; it alters what a device interrupted mid-retirement does next.
23. **If you ever see "Conduck couldn't read one shared item, so it wasn't added to your board"** (see **O-7(f)** — the sentence is half wrong), the file is in the App Group under `WorkCaptureInbox/refused/<envelope-uuid>/` with a `refusal.txt` beside it. What is new is that this directory is now guaranteed complete: the queue's copy is deleted only after every file was verified present at the right size under a temporary name and renamed into place.
24. **If you ever find a directory in `refused/` whose name ends `.incomplete`**, that is a retirement an earlier crash interrupted, kept deliberately rather than deleted. The complete copy is the plain-UUID directory beside it. Nothing needs doing; it is evidence, not a fault.
25. **Force-quitting the app during a share import is safe to try** (open a large share → kill the app mid-import). Repeat it a few times and confirm every shared file still reaches the desk. This is the interruption class the whole barrier exists for.

**From f-copy-docs (5) — read the words:**
26. **The state that shows the new sentence, which is the only one that matters.** Record a Work voice note from the desk's voice sheet with recognition guaranteed to fail (airplane mode, cloud provider). It must appear as a playable card AND leave a retry card. Tap **Discard recording**: the body must read *"This removes only the copy kept for another try at transcribing it. The recording is already in Work and stays there."* — and after confirming, **the card must still be on the desk and still play**. A body that says "cannot be recovered" here, or a card that disappears, is the bug this row exists to prevent.
27. **The other state, unchanged, for contrast.** A Chat voice capture that fails to transcribe has no desk card. Its discard must still read *"This deletes the recording from this device. It cannot be recovered."* Seeing both dialogs back to back is the fastest way to judge whether the two registers sit together.
28. **Read the published body aloud and decide on the title.** The dialog is titled "Discard this recording?" in both states; for the published one, that title is answered rather than matched by the body. **O-7(h)** is the decision.
29. **Dynamic Type on the longer body.** 21 words against the sibling's 11, on a system confirmation dialog. At the largest accessibility sizes, "Discard" and "Cancel" must both still be reachable.
30. **VoiceOver over the confirmation.** Both sentences should be read as one message; confirm the second is not truncated, since it carries the reassurance.

**Plus, carried from wave E and easy to misread as bugs** — after a repaired recording lands on the desk
wordlessly, the retry ENTRY may disappear after ten minutes and **that is correct** (only a
transcription was still owed); what must never happen is the CARD disappearing. And after that card is
on the desk, delete it and tap Retry once more: the recording must NOT come back.

---

## 7. Settled facts — consolidated, one sentence each

**Already written into a document by f-copy-docs — no further action.** (`spec.md` holds at 19827 words;
`project-structure.md` carries the claim/lease/renewal/sidecar row under `Services/` and the verified
retirement under `Services/Workboard/`.)
- A replay may bring a card's rows back onto its bytes only when those rows are not newer than the capture being replayed; a newer row is another device's file still on its way and is left to arrive on its own. **This REPLACES integrate-g's "brings EVERY physical row back onto them whenever any row disagrees" — the narrowing is the point, and a later doc pass reading integrate-g rather than f-store must not reinstate the wider wording.**
- A capture refused under both its own identifier and its escape identifier is retired by copying its whole directory aside and verifying the copy byte for byte before the queue lets the original go, so "files intact" is a property of the write order rather than of an intention.
- A surface reserves the capture it is finishing by name where it made the recording, renews the reservation while it works, and confirms it still holds before handing the words on, so two surfaces open at once never finish the same recording.
- The record kept beside a waiting recording outranks the queue's index when the two disagree, and a record that cannot yet be read defers its capture rather than being replaced by a guess.
- Discarding a waiting recording the desk has already accepted removes only the queue's second copy and leaves the playable card on the desk, so its confirmation is a separate catalog row that carries neither of the other row's claims.
- The copy guard pins that row on what it asserts — that the recording stays in Work, and what is actually removed — and on it differing from its sibling, never on its wording, so a founder copy pass can rewrite the sentence without failing the build.
- The ten-minute figure is out of `spec.md` and lives in `PendingRetryStore` alone, because `spec.md`'s own rule is that a constant's name is written down and its value is not.

**True of the code and in NO document — the O-18 trade, for whoever next has spec words to spend:**
- A lane that makes a recording reserves that exact recording the moment it parks it, so a Shortcut, the app's retry card and the desk's voice sheet can all be live at once without two of them finishing one recording.
- A Shortcut holds its recording for ninety seconds — the same ninety after which it tells you to open the app and retry — so a Shortcut the system shuts down hands the recording back exactly when the notice invites you to pick it up.
- A lane that is still working extends its hold as it goes, so a slow transcription cannot have its recording taken or deleted underneath it, and a lane that dies stops extending simply by being gone.
- Before a surface sends the words it recognised, cancels the "Recording Saved" notice, or shows success, it checks that the recording is still its own; if another surface took over, it says so and does nothing else — which is why the same words can never be sent twice, and why nothing is written to Work on behalf of a recording the surface no longer holds.
- Finishing a recording deletes it only for the surface that is holding it; a Shortcut completing can no longer delete the recording the app is in the middle of transcribing.
- Starting a new recording lets go of the previous capture without deleting a recording somebody else is finishing.
- A recording whose parking failed is still transcribed and still delivered: with nothing saved there is nothing for another surface to hold, and the copy in hand is the only one there is.
- A lane that recorded the audio keeps only its claim on the recording, never a second copy of the audio itself, so a background capture never carries two copies of one recording through the work.
- Tapping Discard reserves the recording first and asks the question second, so the recording deleted is the one the person was looking at, even if another arrives while the confirmation is up; and when every waiting recording is being finished elsewhere, Discard shows the busy line and asks no question at all.
- Cancelling the Discard confirmation gives the recording straight back, so the next attempt — here or in another window — can start immediately.
- The Discard confirmation says what is actually lost: for a recording the desk has already accepted it removes only the copy kept for another transcription attempt, and only for a recording that exists nowhere else does it say it cannot be recovered.
- The ten-minute limit on how long a recording waits for its words applies only when nobody is working on it; a recording somebody is finishing is never retired on the clock.
- The recording a build before capture identifiers parked is deleted only once its bytes are provably parked under an identifier, and it is deleted before the last thing that names it — so an interrupted upgrade can never leave it stranded in the container for ever.
- A refused capture's bytes are copied into `refused/` under a temporary name and renamed into place only after every file the queue holds is verified present in the copy at the same byte count, and the queue entry is acknowledged strictly after that rename — the only acknowledgement in the drainer proven by a copy on disk rather than by a card on the desk.
- A retirement directory already on disk is verified the same way rather than trusted for existing; an incomplete one is moved aside under a unique name and kept, and nothing in `refused/` is ever claimed, requeued or swept.
- A row naming a payload this device does not have is preserved rather than repaired whenever it is newer than the replay that met it: it is another device's file still on its way, and the card goes back to normal on its own when those bytes land.
- **NEW, mine:** the retry queue has exactly one way to end, restate or release a capture — a token the store issued — and the seam a capture surface writes through carries the arm and nothing else, so an id-keyed finish is not something a surface can reach for even by mistake.
- **NEW, mine:** the one operation that reads every parked recording at once survives only as the control its replacement is measured against, and a source census forbids any production caller of it.

**Measured facts about the tree itself, for whoever commits it:**
- The wave-F tree is **20 modified files plus 5 untracked** (one production, four tests) and **0 deletions**; the only `.xcstrings` change is **+1 row** in the main catalog, and **no model file was touched this wave** — the only model diff against `651a859` is wave C's `Conversations 16.xcdatamodel/contents` + `.xccurrentversion`, with version 15 byte-identical.
- `clear(ifCurrentID:)`, `recordPublicationState(id:)`, `updateAttemptIfCurrent(id:)` and `PendingRetryRecord` no longer exist. `load()` does, and its only callers are tests.
- `PendingRetryQueueWriting` now declares exactly one operation (`save`); every token-gated operation lives on `PendingRetryLaneReserving`, which refines it.
- The census in `PendingRetrySurfaceHandoffTests` no longer exempts `PendingRetryStore.swift` from its own scan, because the store no longer declares anything the census forbids.
- The full iOS suite is **5050 / 1 skip / 0 fail**, twice, and the watch suite **232 / 0**; `check-spec-size.sh` is the only red guard and has read **19827** for five consecutive integrations.
- `git diff --name-only … -- '*.xcdatamodeld'` matches nothing in this repo; the working pathspec is `'*.xcdatamodeld/*'`.

---

## Catalog

**Keys I ADDED in source: NONE. Keys I made DEAD: NONE. No `.xcstrings` file was opened by me.**

`git status --porcelain -- '*.xcstrings'` lists only `Conduck/Conduck/Localizable.xcstrings`, whose dict
diff against `HEAD` is **+1 / −0 / ~0** — f-finish's declared key, spliced by f-copy-docs, with its
source `defaultValue:` byte-identical to the catalog `en`. The bidirectional audit is **147/147** on
`workboard.*` and **9/9** on `pendingRetry.*`, with an empty CATALOG-ONLY list on both. **Nothing was
changed and nothing was retired.**

Deleting three store operations retired no string: none of them carried user-facing copy, and no
string-bearing branch was removed.

---

## Requests

1. **Orchestrator — the gate is CLOSED on the merged tree.** Every item plan §F names is quoted in §3
   with its exact line. The commit needs the 20 modified files **and the 5 untracked ones** in §3(11);
   without the untracked five it does not build.
2. **Orchestrator — `check-spec-size.sh` exits 1 and that is PRE-EXISTING**, at the identical 19827 for
   the fifth integration running. Plan §E and §F both forbid fixing it. Do not read that exit code as
   this wave's.
3. **Nobody re-add a lease-blind operation to `PendingRetryStore`.** The census is now an EXACT set with
   every expectation EMPTY, which is what makes a returning caller fail; the needles must stay for that
   to work. Measured red in §1.
4. **Nobody exempt a file from the census again.** The store's exemption existed because it declared the
   operations; it declares none now. Re-adding the exemption would hide a lease-blind call written
   inside the store itself.
5. **Nobody delete `load()`.** Nine test call sites use it as the control that `claimNext` is measured
   against — the whole point being that one reads every recording and the other reads one. Its
   production callers are forbidden by the census, which is the right place for that rule.
6. **`O-1` (renewal policy) is the one open item I would fix first.** It is the only open item that can
   still lose a recording, it has a written remedy, and it is three call sites.
7. **The `## Refuted` sections of all six wave-F fixnotes are empty** — every finding held. They are
   quoted verbatim below rather than summarised, because "nothing was refuted" is a claim a later reader
   should be able to check.

---

## Deviations

1. **I did not widen `PendingRetryQueueWriting`, and my brief says to.** The widening exists as f-arm's
   refinement `PendingRetryLaneReserving: PendingRetryQueueWriting`, which carries all five claim
   operations and is conformed to by both the store and the test double. Repeating them on the base
   would give every conformer two paths to one operation. What the base needed — and got — was the dead
   `clear(ifCurrentID:)` requirement removed and its doc comment corrected. §1.
2. **I rewrote three existing cases rather than adding beside them**, because all three asserted through
   an API that no longer exists. Each is strictly stronger afterwards (the lane clear is now token-gated;
   the census expectations are now empty sets; the intent fixture now quotes the shipped shape), and
   no assertion was dropped from any of them.
3. **My regression proof is a counterfactual on an existing guard, not a new case.** The guard that
   proves L5 already exists and was already red for exactly this reason in three wave-F runs; adding a
   second case asserting the same source scan would measure nothing new. The counterfactual is in §1,
   with its verbatim failure lines and its SHA-verified restore.
4. **I re-ran all four gate runs after a comment-only edit** (the protocol doc rewrite), rather than
   quoting the earlier green ones. The numbers in §3 describe the tree exactly as it stands.

---

## Refuted

**Nothing, by me.** Both halves of my brief's L5 held against the current tree when traced by call path
before anything was deleted: the four superseded names had zero production callers, and the census
allowlist was stale in exactly the two rows three wave-F fixnotes said it was. The only place the letter
moved is §Deviations 1, recorded as a deviation rather than a refusal.

**The six wave-F fixnotes' own `## Refuted` sections, verbatim:**

> **f-arm.** Nothing. r6a#1 holds in every clause at the anchors quoted, and every design direction in
> the brief (L1, L2, L3, L4) was implementable as specified. The two places the letter moved are recorded
> as decisions rather than refusals: the protocol refinement instead of widening `PendingRetryQueueWriting`
> (§Decisions 1, which avoids every foreign edit), and the recorder's finish relying on the token-gated
> `clear(claim)` rather than a further `confirmOwnership` (§Decisions 7, which L3 explicitly permits).
> The two REFUTATIONS this wave was told to reverse are reversed, and both for the exact reason each gave.

> **f-finish.** None. All three findings were traced against the current tree by call path before any code
> changed, and all three hold exactly at the anchors quoted. The decided design directions (L2, L3, and
> r6a#4's state-aware confirmation) were implementable as specified. The one place the letter moved is
> recorded as §Deviations 1 rather than a refusal — `claimNext()` at tap instead of `claim(id:)`, forced
> by the store having no metadata-only id accessor and by that file not being mine — and it delivers
> r6a#7's substance in full. One qualification, stated as such: L2 says "every surface that transcribes
> renews", and two do. The Work voice sheet transcribes too, and whether it holds a renewable reservation
> at all is the arm-side agent's slice, not mine.

> **f-queue.** None. All three findings were traced against the current tree by call path before any code
> changed, and all three hold exactly at the anchors quoted. The decided design directions (L1, L2, L3, L6)
> were implementable as specified; the two places the letter moved are recorded as decisions rather than
> refusals — the reservation's duration living in the lease instead of the claim (§Decisions 1, forced by
> K2's claim shape and by two foreign construction sites), and the expiry exemption that L1–L3 do not
> mention but without which a renewable reservation still loses its recording at 600 s (§Decisions 2).
> One qualification, stated as such: r6a#2's fix is only HALF landed after this wave. The store can now be
> renewed and addressed by id; no surface does either yet.

> **f-store.** Nothing. r6s#1 held against the current tree when traced by call path before any edit, the
> `:102-145` case did construct a 60-second-newer peer row and did assert it was replaced, and the
> mechanism is shown red on the reverted tree. The DESIGN DIRECTION was implementable as written. One
> clause is worth SHARPENING rather than disputing. The finding says a preserved newer pairing "will then
> be `.synced` on its own" when its blob arrives — true in the common case. But if that blob has ALREADY
> arrived here, the same transaction's `deleteSupersededBlobRows` deletes it, and the preserved row is then
> left naming bytes this device just destroyed. That is O-6 [now **O-5**], not this fix — but the SYMPTOM
> it produces is different now (a card that will not open, rather than a silent revert to the older file),
> and a reader who assumes "preserved ⇒ eventually fine" would be wrong in that sub-case.

> **f-drainer.** Empty. r6s#2 held in full: the copy went to the final destination, existence was the only
> completion test, and the acknowledgement behind it deletes the queue's only copy. The design directions
> in the brief — the uniquely named temporary sibling on the inbox's conventions, manifest-plus-payload
> byte-count verification, the atomic rename, the pre-existing directory validated and displaced rather
> than deleted, and acknowledgement only after the rename — were all implementable exactly as written.

> **f-copy-docs.** Nothing. Every fact the f-* notes carry held when traced against the code before I wrote
> it down, and every design direction in my brief was implementable as written. Two clarifications rather
> than refutations: (1) "Fix any sentence in spec.md that the round-6 findings proved false" had almost no
> referent — `grep -n 'unrecoverable\|lease\|sidecar' docs/ai-context/spec.md` returns nothing, and every
> instance of `deleted` is still true. What round 6 changed was not a false claim but two INCOMPLETE ones,
> both rewritten rather than patched. (2) f-store's fact explicitly REPLACES a fact integrate-g carries
> under "the O-19 trade", and the replaced version was never in spec.md — so what landed is f-store's
> corrected statement as a NEW claim, not an edit to a wrong sentence. The superseded wording must not be
> reinstated by a later doc pass reading integrate-g rather than f-store.

---

## What I did NOT verify, plainly

- **Two PROCESSES on one container are still untested** (O-4 / Gate 2). Every case in this wave drives
  the real store, the real `flock` and the real write orders — from one process.
- **No UI, no screen, no device.** Every surface behaviour in §6 is a founder-QA item; the source guards
  prove where a statement sits, never that a dialog appears or that VoiceOver reads it sensibly.
- **I ran no wave-F agent's counterfactual and did not re-run any of theirs.** I ran my own (§1), and I
  take their measured red/green at their word.
- **The renewal has never been observed firing on a real interval.** The production intervals are 45 s,
  90 s and 120 s; the cases assert the timer's SHAPE in source and the store's `renew` behaviour
  directly. O-1 is about what happens when one of those ticks answers false for the wrong reason, and
  nothing here measures that either.
- **I did not read every line of the wave-F diff.** I read the six fixnotes in full, traced the claims
  my own edit depends on by call path, and ran the whole suite twice.
