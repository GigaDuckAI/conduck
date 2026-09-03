# integrate-g — wave E coheres. FULL GATE GREEN: iOS 5002 / 1 skip / 0 fail · watch 232 / 0 · signed macOS BUILD SUCCEEDED. One REAL failure found and fixed; one superseded operation deleted.

Six wave-E fixnotes read in full (`e-queue`, `e-drainer`, `e-recover`, `e-store`, `e-surfaces`,
`e-copy-docs`) plus `integrate-f.md` for the 4948 baseline and O-1…O-20. **I changed two files** —
one deletion the brief asked for, and one guard the gate caught broken. Test-count reconciliation is
EXACT with zero drift: 4948 + 54 = **5002**.

**The gate caught something no wave-E agent ran.** The first full run was `Executed 5002 tests, with
1 test skipped and 1 failure` — `STTKeyBlackoutLaneTests` measured red on production code
e-surfaces changed. Details in §3. It is fixed, and two lanes of that guard were blind, not one.

---

## 1. The superseded-method sweep — one deleted, three kept with reasons

Grepped every `.swift` under the project container, production and tests, for each of the four
operations e-queue marked `// Superseded by …; delete when no caller remains`.

| Operation | Production callers | Test callers | Verdict |
|---|---|---|---|
| `updateAttemptIfCurrent(id:lastErrorCode:)` | **none** | **none** | **DELETED** |
| `load()` | **none** | `WorkVoiceRecoveryTests.swift:1066`, `PendingRetryDurabilityTests.swift:242, 355, 372` | **KEPT** — a test still needs it |
| `clear(ifCurrentID:)` | `Conduck/Services/PendingRetryGuard.swift:121`, `Conduck/Services/InAppAudioRecorder.swift:936` | `WorkVoiceRecoveryTests.swift:858, 870` | **KEPT** — production callers remain |
| `recordPublicationState(id:transcript:publicationState:)` | `Conduck/Intents/ConverseIntent.swift:825` | — | **KEPT** — production caller remains |

The `recordPublicationState(id:` caller is broken across lines
(`PendingRetryStore.shared.recordPublicationState(\n id: captureID,`), so a naive one-line grep
misses it; I confirmed it by reading `ConverseIntent.recordRecoveryState` at `:820-830`. That is the
same caller e-surfaces' census allowlist names, and the census passes.

**`load()` is the one worth stating plainly: no PRODUCTION caller remains, and it is kept because
the tests that measure what `claimNext` fixed are what need it.** `PendingRetryDurabilityTests.`
`testClaimingTheNextCaptureReadsExactlyOneRecording` counts `claimNext` at 1 read against `load()`
at 3 — deleting `load()` deletes the control. I widened its doc comment to say so, because
"delete when no caller remains" reads as an invitation to a reader who greps production only.

**Deletion, and why it is safe.** `updateAttemptIfCurrent` is not in `PendingRetryQueueWriting`
(the protocol is `save` + `clear(ifCurrentID:)` only, `PendingRetryStore.swift:528-537`), so the
`RecordingRetryLane` double is untouched. The census needle `"updateAttemptIfCurrent(": []` stays
green because the census skips `Self.storePath`, so the declaration never counted as a call.

**`PendingRetryQueueTests` re-run after the deletion: `Executed 17 tests, with 0 failures
(0 unexpected)`** — unchanged, as expected: the class drives `PendingRetryQueue`'s pure rules, not
the actor.

**`PendingRetryRecord` also has zero real callers** (e-recover §Requests 2). Its only two hits are
its own declaration at `PendingRetryStore.swift:311` and a STRING LITERAL inside
`WorkboardVoiceLaneTests.swift:733`'s `recordChunk` control fixture. **I did NOT delete it** —
e-recover asked for it to go WITH the `load()`/`clear(ifCurrentID:)` block, and that block cannot go
this wave. → **O-2**.

---

## 2. Requests resolved, one by one

Thirty-four request items across six notes. **Six already satisfied inside the wave** (verified by
grep, not on the agent's word), **six are standing "nobody undo" lists** recorded in §7, **two are
integrator duties I discharged**, and the rest collapse into **eleven real design/ownership calls**
→ open items. Several were the same item raised from two sides; I resolved those against each other
rather than carrying them twice.

### Already satisfied inside the wave — verified by me

| Request | Satisfied by | Evidence I checked |
|---|---|---|
| e-queue §1 — `DiagnosticsRunner` needs the one `pendingCount()` line (O-17) | e-surfaces | `DiagnosticsRunner.swift:752` `let pendingRetryCount = await PendingRetryStore.shared.pendingCount()`, consumed at `:1380-1381` in `factPendingRetry` — `parked(code …, …m left, N waiting)` / `orphaned(N waiting)`. **O-17 CLOSED** |
| e-queue §3 — `DictationService.preserveForRetry` builds the now-reserved fixed name | e-surfaces | `DictationService.swift:813` is `PendingRetryFiles.audio(captureID, .chat)`; the fixed literal survives only in the comment at `:795` that explains why it is not used |
| e-queue §4 — the discard must be `clear(_ claim:)`, never `clear()` | e-surfaces | `ContentView.discardPendingRetry` (`:1763-1769`) is `claimNext()` → `finishPendingRetry(claim)`; `grep 'PendingRetryStore.shared.clear()'` over production → **zero hits** |
| e-drainer §4 — e-recover must use the SAME escape namespace | e-recover | Both lanes call the one function: `WorkCaptureDrainer.swift:381` and `WorkVoiceCaptureCoordinator.swift:273` both `WorkMaterialCollisionEscape.materialID(forCapture:)`, whose namespace literal `C0111DE0-0000-4000-A000-000000000001` is declared once at `WorkMaterialCollisionEscape.swift:60`. A drain-lane escape and a recovery-lane escape land on ONE card |
| e-drainer §2 — the inbox must keep two properties or `refused/` becomes claimable | (already true) | `pendingEnvelopeIDs()` → `childEnvelopeIDs(of: baseURL)` → `compactMap { UUID(uuidString: $0.lastPathComponent) }` (`WorkCaptureInbox.swift:1013, 1038-1039`) — `"refused"` is not a UUID. `reconcile` (`:565`) enumerates `processingURL` (`:584`) and `temporaryURL` (`:619`) and nothing else; `baseURL` appears only as a RESTORE destination |
| e-recover §4 — three of its source rules now read e-surfaces' files by SHAPE | (holds) | `WorkboardVoiceLaneTests` **11/0** in the full run, including the twelve-rule validator |

### The two integrator duties

1. **e-copy-docs §5 / integrate-f §1 — record the spec-size guard as PRE-EXISTING.** Done, §4.5:
   exit **1**, **19827 words**, byte-identical to integrate-d's, -e's and -f's number, with the same
   two unrelated over-limit decisions. Not fixed, per plan §E and §F.
2. **e-drainer §5, e-store §"Suite delta", e-surfaces, e-copy-docs §6 — suite arithmetic.** Done and
   EXACT, §5. Every one of the six deltas matches the tree.

### Resolved against each other — the same item raised twice, carried once

- **e-queue §2 + e-surfaces §2 + e-surfaces §3 + e-recover §1** are ONE item: the three lanes that
  ARM a capture (`ConverseIntent`, `PendingRetryGuard`, `InAppAudioRecorder`) address it by the id
  they minted, and the store's only selection primitive answers "the newest capture nobody has
  reserved". Migrating them needs `claim(id:)` (~12 lines, absent — `grep 'func claim(id:'` →
  nothing) AND `PendingRetryQueueWriting` widened AND the `RecordingRetryLane` double updated. → **O-1**.
- **e-drainer §1 + e-copy-docs §3** are ONE item: `invalidCaptureCount` now also counts a terminally
  refused capture, and `workboard.capture.discarded.message.one` is half true for it. Founder copy
  call on a `PersonalWorkbenchView.swift` string. → **O-8**.
- **e-surfaces §4 + e-copy-docs §4** are ONE item: `diagnostics.voice.pendingRetry.waiting` is
  deliberately unminted because `testEveryWorkCatalogRowIsReferencedInSource` now walks
  `pendingRetry.*` too, so the key and its `if` in `DiagnosticsRunner` must land in one edit. → **O-9**.

### Not taken — each with its reason

1. **e-surfaces §1 — `DictationPopoverView.hasSavedRetryAudio` should ask the count, not the
   taxonomy.** VERIFIED exactly as described: `DictationPopoverView.swift:1322-1324` is
   `service.lastError?.shouldPreserveForRetry == true`, it gates the Retry button at `:1356`, and
   `grep -rn 'service\.lastError'` over production returns **that one line and nothing else**.
   `DictationService.swift:103` exposes `private(set) var pendingRetryCount`. So the change is one
   line and e-surfaces' reasoning holds. **I did not make it**: it changes which captures the macOS
   popover offers Retry for (Chat captures included), in a file no wave-E agent owned, and nothing in
   this bundle can verify the result — the popover is macOS UI and there is no UI-test target. A
   behaviour change whose only proof is founder QA is a design call, not an integration tidy-up.
   → **O-3**, with the exact one-line diff recorded so it costs a minute whenever it is wanted.
2. **e-recover §3 — `AppError` has no code for a permanent identity refusal.** `.workDeskWriteFailed`
   (78) says "just now", a claim of transience about a refusal that is permanent. A new enum case
   plus one `updateAttempt(claim:lastErrorCode:)` call. Two files, neither wave-E's. → **O-4**.
3. **e-store §5 — O-19 (`deleteSupersededBlobRows`) is untouched and still open.** e-store's change
   adds a reason to repoint ROWS and does not widen the deletion. → **O-6**.
4. **e-copy-docs §1 and §2 — two founder copy calls** (the backlog count as a fragment; the discard
   confirmation uncontracted). Both are one splice each whenever the founder decides. → **O-8**.
5. **e-copy-docs §8 — whoever next widens the copy guard** adds a prefix to `catalogPrefixes`, and
   `workKeys(in:prefix:)` takes its prefix explicitly because a `Self.keyPrefix` default argument
   does not compile. A note for the next author, not an item.
6. **e-drainer §6 — the pre-existing takeover flake.**
   `WorkCaptureDrainerDurabilityTests.testAProvenTakeoverStopsTheImportBeforeItsNextMaterialWrite`
   did **not** recur: the class is **8/0** in my full run. Recorded as watched-for, not seen.

---

## 3. The failure the gate caught, and the fix

**`ios-full-1.log`: `Executed 5002 tests, with 1 test skipped and 1 failure (0 unexpected)`**, one
case, verbatim:

```
/…/ConduckTests/STTKeyBlackoutLaneTests.swift:277: error:
 -[ConduckTests.STTKeyBlackoutLaneTests testEveryKeyRefusalLaneReadsTypedAndCarriesBothArms] :
 XCTUnwrap failed: expected non-nil value of type "Index" -
 Conduck/MenuBar/DictationService.swift → retryLast (macOS retry of a preserved capture)
 no longer reaches its verdict through `STTKeyReadiness.resolve`.
```

**Why nobody in wave E saw it.** No wave-E fixnote lists `STTKeyBlackoutLaneTests` in its targeted
set. e-surfaces owns both files it guards and ran thirteen classes; this was not among them.

**Verified before touching anything.** The guard's registry names the FUNCTION whose body is scoped,
and `RefusalLaneSource.body(ofFunction:)` brace-matches exactly one function
(`HeadlessRefusalLaneDriftGuardTests.swift:287-302`). e-surfaces split both retry surfaces —
`retryLast` (`DictationService.swift:205`) now reserves a claim and hands it to `attemptRetry`
(`:253`), where `STTKeyReadiness.resolve` sits (`:286`); `runPendingRetry` (`ContentView.swift:1470`)
hands to `attemptPendingRetry` (`:1513`), where the resolve sits (`:1546`). The guard was pinning two
functions that no longer decide anything.

**BOTH lanes were blind, not one.** `try XCTUnwrap` inside the registry loop THROWS, so the run
aborted at the menu bar and the `ContentView` row — later in the array — was never reached. Fixing
only the reported one would have shipped a second dead guard.

**The fix is additive, and strictly stronger than what it replaces.** `Lane` gains
`delegatesTo: String?` (nil for the seven lanes that did not move, via a memberwise init with a
default). When set, the guard now:
- asserts the ENTRY function's body calls `\(helper)(` — **a linkage the old rule never had**; and
- runs **every existing assertion, unchanged**, against the helper's body.

Nothing was deleted, narrowed, or re-aimed: the typed read, both arms, their distinctness, the
ordering assertion and the preservation clause are byte-identical. The lane count assertion
(`XCTAssertEqual(Self.lanes.count, 9)`) and the exhaustiveness rule are untouched.

**How I know the new assertion bites — MEASURED.** Counterfactual on the test file alone: the
mac lane's `function:` changed from `retryLast` to `settleAfterFinishing` (a real function that does
NOT call `attemptRetry`), `delegatesTo` left in place.

```
Executed 11 tests, with 1 failure (0 unexpected) in 2.300 (2.303) seconds
STTKeyBlackoutLaneTests.swift:314: error: … XCTAssertNotNil failed -
 Conduck/MenuBar/DictationService.swift → settleAfterFinishing (macOS retry of a preserved capture)
 no longer calls `attemptRetry(`. The key verdict lives there, so an entry that stopped reaching it
 refuses without ever reading the slot — and this guard would go on asserting about dead code.
```

Restored by file copy, `diff -q` clean, SHA-256
`c023dbb2e080b490142b3508ffc00c95ebaaec80b881fc57d1b6d240a2601b35`. **I label this precisely: it
proves the LINKAGE assertion is live. The evidence that the re-anchored arms bite is the red run
above** — the old registry measured red against this exact production tree, and the arms it could
not find are the ones the new registry finds in the helper.

**Files I changed — two:**

| File | Change |
|---|---|
| `Conduck/Conduck/Services/PendingRetryStore.swift` | `updateAttemptIfCurrent(id:lastErrorCode:)` deleted (zero callers); `load()`'s doc comment widened to say what keeps it |
| `Conduck/ConduckTests/STTKeyBlackoutLaneTests.swift` | `Lane.delegatesTo` + the linkage assertion; the two split lanes pointed at their helpers |
| `Conduck/ConduckTests/PendingRetrySurfaceHandoffTests.swift` | two COMMENTS only — the census header and one needle's note, so neither says a deleted operation still exists. **No assertion, needle or allowlist entry moved** |

---

## 4. The gate — every number, the exact lines

Slug `integrate-g`. DerivedData under
`~/Library/Caches/gigaduck-builds/integrate-g/{DerivedData,DerivedDataMac,DerivedDataWatch}`, every
log written there and grepped for `': error: '` and for
`BUILD SUCCEEDED|BUILD FAILED|TEST SUCCEEDED|TEST FAILED|Executed ` — **never judged from a tail or
an exit code**. **No `-configuration` passed anywhere.** No `/tmp`, no bare `rm -rf`, no throwaway
tree copy. HEAD `f794856f226faaa04c6a028d3c1fa2309adc6bfa`, branch `feature/agent-workboard`.

**Simulator TCC, checked FIRST per the standing rule, before any run:**
```
sqlite3 …/2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF/data/Library/TCC/TCC.db
  "select service, client, auth_value from access where client='ai.gigaduck.AgentRelay';"
→ (no rows), exit 0
```
No row for the bundle = `.notDetermined`. No stale denial, nothing reset.

### (1) iOS `build-for-testing` — sim `2B6E0EAC-…`, `ios-bft-4.log` (final)
`grep -c ': error: '` = **0**, and:
```
** TEST BUILD SUCCEEDED **
```

### (2) macOS signed build, `-destination 'platform=macOS'` — `mac-2.log`
`grep -c ': error: '` = **0**, **3 `CodeSign` steps**, and:
```
** BUILD SUCCEEDED **
    Signing Identity:     "Apple Development: Peter Krueck (Z4PNDLZK98)"
```
**Signed through the identity override. No `CODE_SIGNING_ALLOWED=NO` fallback used or needed.**
*Stated rather than glossed:* `mac-3.log` re-ran the macOS build over the truly final tree and is
`** BUILD SUCCEEDED **`, 0 errors, but **0 `CodeSign` steps and 0 compiles** — a genuine no-op,
because the only change after `mac-2` was a comment in a `ConduckTests` source the macOS Build action
does not compile. `mac-2` is the signed build; `mac-3` is the proof nothing after it needed one.

### (3) FULL iOS suite, `test-without-building` — `ios-full-3.log` (final)
```
** TEST EXECUTE SUCCEEDED **
	 Executed 5002 tests, with 1 test skipped and 0 failures (0 unexpected) in 82.002 (83.443) seconds
```
`grep -cE '\.swift:[0-9]+:[0-9]+: error: '` (a compile error) = **0**.
`grep -cE '\.swift:[0-9]+: error: '` (an XCTest failure) = **0**.
**361 suite lines parsed; summed failures across all of them: 0. Failure list: EMPTY.**

**The one skip is the environment pin, verbatim:**
```
GatewayAdapterBriefTests.swift:263: -[ConduckTests.GatewayAdapterBriefTests
testClipboardBriefRevisionPinMatchesPublishedContract] : Test skipped - No website source at
/Users/peterkruck/repos/GigaDuck/.codex/worktrees/website/src/lib/adapter-contracts.ts — the
clipboard brief's pin (revision 1.10) was NOT verified against the published contract.
```
A missing sibling checkout. **1 skip, as integrate-d, -e and -f all measured** (the plan's "2" is stale).

**Runs before it, reported rather than hidden.** `ios-full-1.log` was the pre-fix run
(**1 failure**, §3). One targeted run (`targeted-1.log`) died before any case started —
`Simulator device failed to launch ai.gigaduck.AgentRelay … Busy ("Application failed preflight
checks")`, `Executed` line absent entirely. I am the only agent on this tree now, so per the standing
rule I ran `xcrun simctl shutdown all` and retried ONCE → green. Not a repeat, so not real.

### (4) FULL watch suite — sim `28AC563B-42C1-4E66-940D-77E63B07918B`, `watch-1.log`
```
** TEST SUCCEEDED **
	 Executed 232 tests, with 0 failures (0 unexpected) in 9.361 (9.438) seconds
```
`grep -c ': error: '` = 0. **232 exactly, as expected.** Wave E added no watch-target source: no
wave-E file appears in the `ConduckWatch Watch App` `membershipExceptions` inclusion list, and the
`.xcdatamodeld` was not touched this wave.

### (5) Guard scripts, from the worktree root
```
✓ storage seam intact — 803 Swift files scanned, no raw store
  or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift   exit 0
✓ folder map current — 36 Swift source directories, all mapped,
  and every path the map names exists                                                 exit 0
✓ spec citations resolve — 803 Swift files scanned, 1 quoted
  section name(s), every one a live heading in docs/ai-context/spec.md                exit 0
```
798 → **803** files is exactly wave E's five new sources (one production, four tests). All five land
in directories the map already names, so **no `project.pbxproj` edit was needed and none happened**
(`git status --short -- '*.pbxproj'` → empty).

**Spec size guard — PRE-EXISTING FAILURE, not fixed** (plan §E and §F both forbid it), exit **1**:
```
✗ docs/ai-context/spec.md is 19827 words; the ceiling is 16900.
✗ decisions over their word limit:
    "Sending files and getting them back are two capabilities of one lane"  687 / 650
    "Forgetting a gateway erases the credentials and keeps the colour tag"  701 / 650
```
`wc -w docs/ai-context/spec.md` = **19827** — **identical to integrate-d's, -e's and -f's number, and
≤ 19827 as the gate requires**, even though e-copy-docs folded five new facts and re-homed one rule
into it. Both over-limit decisions are unrelated to Work and untouched by wave E.

### (6) `git diff --check`
No output, **exit 0**. `git diff --cached --stat` → **empty** (nothing staged; no commit, no push, no
stash, no checkout, no reset, no index operation anywhere in this task). `git status --short` for
`Conduck/Configs`, `Conduck/Conduck.xcodeproj`, `'*.pbxproj'` and `docs/qa` → **empty** on all four.
`git diff --check` cannot see untracked files, so I checked all five by hand: **0 trailing-whitespace
lines and 0 tab lines in every one**, and each opens with `// SPDX-License-Identifier: Apache-2.0`.

### (7) Catalogs — `python3 json.load`, all four parse clean
```
Conduck/Conduck/Localizable.xcstrings                    keys = 2251   PARSE OK
Conduck/ConduckShareExtension/Localizable.xcstrings      keys =   43   PARSE OK
Conduck/ConduckShareExtensionMac/Localizable.xcstrings   keys =   42   PARSE OK
Conduck/ConduckWatch Watch App/Localizable.xcstrings     keys =  299   PARSE OK
```
**Dict diff against `git show HEAD:` for all four**, top-level keys other than `strings` compare
**equal** in every one:

| Catalog | keys | added / removed / changed |
|---|---|---|
| `Conduck/Conduck/Localizable.xcstrings` | 2245 → **2251** | **+6**, −0, ~0 |
| `Conduck/ConduckShareExtension/…` | 43 → 43 | none |
| `Conduck/ConduckShareExtensionMac/…` | 42 → 42 | none |
| `Conduck/ConduckWatch Watch App/…` | 299 → 299 | none |

The six added are exactly e-surfaces' declared set, spliced by e-copy-docs: `pendingRetry.card.busy`
· `…count` · `…discard` · `…discard.confirm.action` · `…discard.confirm.body` ·
`…discard.confirm.title`. **Nothing was changed and nothing was removed** — unlike wave D, this
wave's catalog diff is purely additive.

**Bidirectional audit, mine, over every `.swift` under `Conduck/Conduck`, BOTH prefixes:**
```
workboard.      referenced = 147   catalog rows = 147   MISSING: []   CATALOG-ONLY: []
pendingRetry.   referenced =   8   catalog rows =   8   MISSING: []   CATALOG-ONLY: []
```
`workboard.*` is unchanged at 147/147 across integrate-d, -e, -f and now -g — wave E minted no Work
key and killed none. `pendingRetry.*` went 2 → 8 rows against 8 references, both directions clean.

### (8) Mirror triplets — byte-identical from `import Foundation` onward
| Triplet | bytes below import | app == iOS ext | app == macOS ext | SHA-256 (16) |
|---|---|---|---|---|
| `WorkCaptureEnvelope.swift` | 14801 | **True** | **True** | `45a26a6658c92401` |
| `ShareTargetsSnapshot.swift` | 9728 | **True** | **True** | `a72a7d13d6f1e9ec` |
| `WorkCaptureDirectoryPublisher.swift` | 6198 | **True** | **True** | `777159cc94c1cd9a` |

All three SHAs are **identical to integrate-e's and integrate-f's** — wave E moved no mirror byte.
`git status --short` over all nine paths → **empty**. Paths per integrate-f's correction: the
envelope and snapshot are under `Conduck/Conduck/Models/`, only the publisher under `Services/`.

### (9) Build caches
`ls ~/Library/Caches/gigaduck-builds/` before I created my slug: **only `integrate-g`, i.e. the root
was otherwise EMPTY.** Every wave-E agent had already run its own `clean-build-cache.sh` exactly as
its fixnote records, counterfactual trees included. **No leftover slug existed.** Mine is removed at
end of task (§9) and the root is **empty** afterwards.

### (10) The model — one contents file, and v15 provably untouched
```
git diff --name-only 651a859 -- '*.xcdatamodeld/*'
→ Conduck/Conduck/Models/Conversations.xcdatamodeld/.xccurrentversion
  Conduck/Conduck/Models/Conversations.xcdatamodeld/Conversations 16.xcdatamodel/contents

git diff --name-only 651a859 -- 'Conduck/…/Conversations.xcdatamodeld/*.xcdatamodel/*'
→ Conduck/Conduck/Models/Conversations.xcdatamodeld/Conversations 16.xcdatamodel/contents
```
Among the model CONTENTS files, `Conversations 16.xcdatamodel/contents` is the ONLY one changed on
the branch since `651a859`, working tree included. `.xccurrentversion` also differs and is not a
model: its whole diff is `-<string>Conversations 15.xcdatamodel</string>` /
`+<string>Conversations 16.xcdatamodel</string>` — the required companion, without which model 16 is
not the version the store opens.

**Version 15 is byte-identical to `651a859`, by SHA-256:**
```
git show '651a859:…/Conversations 15.xcdatamodel/contents' | shasum -a 256
  007322f275669bf19967c86484e730cb1cb666b4fa2f53b5b78487d3cec849bc  -
shasum -a 256 '…/Conversations 15.xcdatamodel/contents'
  007322f275669bf19967c86484e730cb1cb666b4fa2f53b5b78487d3cec849bc
```
**Wave E touched neither file** — both differ only against `651a859`, and are already committed at
`f794856`. `WorkboardModelMigrationTests` **6/0** in the full run re-proves model 16 from the
compiled `.momd`.

### (11) Warnings — none added by wave E or by me
`PendingRetryStore.swift` carries **13 on iOS and 13 on macOS**, exactly the number e-queue measured,
all one pre-existing class (main-actor-isolated `DefaultsStore` methods called from this actor's
synchronous locked helpers). Deleting `updateAttemptIfCurrent` did not change it — its warnings were
never in that method. **Zero** in `STTKeyBlackoutLaneTests.swift` on both platforms.

---

## 5. Test-count reconciliation — 4948 → 5002, exact, zero drift

Baseline: integrate-f's full run, **4948 executed / 1 skipped / 0 failures**.

| Slice | Class movement | Δ |
|---|---|---|
| e-queue | `PendingRetryDurabilityTests` NEW 21 · `PendingRetryDestinationTests` 6 → 11 | **+26** |
| e-drainer | `WorkCaptureDrainerCollisionTests` 1 → 3 · `WorkMaterialCollisionEscapeTests` NEW 4 | **+6** |
| e-recover | `WorkVoiceRecoveryTests` 20 → 27 | **+7** |
| e-surfaces | `PendingRetrySurfaceHandoffTests` NEW 9 · `HeadlessRetryGuardSpanTests` 11 → 12 | **+10** |
| e-store | `WorkboardSyncedRowRepairTests` NEW 3 | **+3** |
| e-copy-docs | `WorkboardCopyTruthGuardTests` 6 → 8 | **+2** |
| **integrate-g (me)** | one method deleted, one guard repaired inside existing cases | **0** |
| | **net** | **+54** |

`4948 + 54 = 5002`. **Measured: 5002.** Zero drift — no case was silently lost or silently added
anywhere in the wave. **Every fixnote's arithmetic checks out**, including e-store's independently
measured 4957 mid-wave (4948 + its own 3 + e-drainer's 6 = 4957, which is exactly the in-flight
state its run carried).

**Per-class verification from `ios-full-3.log`, every number against its fixnote, 0 failures each:**
```
PendingRetryDurabilityTests        21/0    PendingRetrySurfaceHandoffTests     9/0
PendingRetryDestinationTests       11/0    HeadlessRetryGuardSpanTests        12/0
PendingRetryQueueTests             17/0    WorkboardSyncedRowRepairTests       3/0
WorkCaptureDrainerCollisionTests    3/0    WorkboardCopyTruthGuardTests        8/0
WorkMaterialCollisionEscapeTests    4/0    STTKeyBlackoutLaneTests            11/0
WorkVoiceRecoveryTests             27/0    WorkCaptureDrainerDurabilityTests   8/0
WorkboardVoiceLaneTests            11/0    WorkboardAudioCaptureTests         19/0
WorkboardBlobPublicationTests      22/0    WorkCaptureInboxTests              29/0
```
`WorkCaptureDrainerDurabilityTests` **8/0** — e-drainer's parallel-load flake did NOT recur.

---

## 6. Files for the orchestrator's commit — 20 modified + 5 untracked, 0 deletions

Production (10): `Conduck/Conduck/ContentView.swift` · `Intents/ConverseIntent.swift` ·
`MenuBar/DictationService.swift` · `Services/ConversationStore+Workboard.swift` ·
`Services/PendingRetryStore.swift` · `Services/Workboard/WorkCaptureDrainer.swift` ·
`Services/Workboard/WorkVoiceCaptureCoordinator.swift` · `ViewModels/DiagnosticsRunner.swift` ·
`Views/Components/PendingRetryCard.swift`
Catalog (1): `Conduck/Conduck/Localizable.xcstrings` (+6 rows)
Docs (2): `docs/ai-context/spec.md` · `docs/ai-context/project-structure.md`
Tests, modified (7): `PendingRetryDestinationTests` · `RemoteAgent/HeadlessRetryGuardSpanTests` ·
`STTKeyBlackoutLaneTests` · `WorkCaptureDrainerCollisionTests` · `WorkVoiceRecoveryTests` ·
`WorkboardBlobPublicationTests` · `WorkboardCopyTruthGuardTests` · `WorkboardVoiceLaneTests`

**Untracked — a `git commit -a` would miss all five:**
```
Conduck/Conduck/Services/Workboard/WorkMaterialCollisionEscape.swift   ← the only untracked PRODUCTION file
Conduck/ConduckTests/PendingRetryDurabilityTests.swift
Conduck/ConduckTests/PendingRetrySurfaceHandoffTests.swift
Conduck/ConduckTests/WorkMaterialCollisionEscapeTests.swift
Conduck/ConduckTests/WorkboardSyncedRowRepairTests.swift
```
No ` D ` row in `git status` this round. `git diff --stat` over the tracked set: **20 files changed,
3179 insertions(+), 688 deletions(-)**. `.xccurrentversion` and `Conversations 16.xcdatamodel/
contents` do NOT appear — they are already committed at `f794856` and are listed under §4.10 only so
the model change reads as complete.

---

## 7. Guard verdicts

### Mine
- **`STTKeyBlackoutLaneTests.testEveryKeyRefusalLaneReadsTypedAndCarriesBothArms` — KEPT,
  RE-ANCHORED and EXTENDED.** Every existing assertion is byte-identical; one new assertion (the
  entry→helper linkage) is added; the lane count stays 9 and the exhaustiveness rule is untouched.
  Measured red against this production tree in its old form, and its new assertion measured red on a
  registry mutation. **Nothing weakened, narrowed, deleted or skipped.**
- **`PendingRetrySurfaceHandoffTests` — comments only.** No needle, allowlist entry or assertion
  moved. The census still asserts EXACT sets in both directions and is 9/0.
- **Test seams: none added, none removed, none widened.** `#if CONDUCK_TESTING` regions are as wave E
  left them.

### Wave E's, verbatim-in-substance, for the record
- **e-queue** — "No `.xcstrings` opened… `hasPending()`, `pendingErrorCode()`,
  `diagnosticSnapshot()`, `cleanupExpired()`, `clear()`, `save(audioData:metadata:workImageData:)`
  and the `PendingRetryQueueWriting` protocol keep their exact signatures — **the recorder's injected
  lane double compiles untouched.**" · `PendingRetryQueueTests` **unchanged, 17/0**. Two
  `#if CONDUCK_TESTING` seams added (the injected directory/defaults initializer and the
  `audioReadsForTesting` counter), both stated at their declarations.
- **e-drainer** — "**No assertion anywhere was weakened, narrowed or deleted.**" The one rewritten
  case (`WorkCaptureDrainerCollisionTests`' original) is rewritten **because its asserted behaviour —
  bytes left queued for ever — is exactly what r5s#2 overturns**, and all three cases are measured
  red on the escape-reverted tree.
- **e-recover** — three `WorkboardVoiceLaneTests` source rules **RE-ANCHORED, not weakened**; the
  staging rule is now bound to EVERY `conduck_retry_` site in the file rather than one function,
  which is stricter. "No assertion was deleted, no rule dropped, and the twelve-rule control fixtures
  still break exactly one rule each." `WorkboardAudioCaptureTests` untouched, 19/0.
- **e-store** — "**None assigned, none converted, none deleted, none weakened.**"
  `WorkboardAvailabilityTests.testTheAvailabilityProjectionNeverNamesThePayloadColumn` and
  `WorkboardBlobSeamPlatformGuardTests` left exactly as they stand and both pass. One existing seam
  (`_duplicateWorkMaterialRowForTesting`) gained two nil-defaulted parameters; **neither can CLEAR a
  column**, and no call site outside e-store's files moved.
- **e-surfaces** — `HeadlessRetryGuardSpanTests` 11 → 12, "nothing existing weakened or re-anchored
  (all 11 pass unchanged)"; the two `.phaseOneFailed` disarm gates are byte-identical to `f794856`
  and the guard still measures exactly three disarms in the documented order.
- **e-copy-docs** — `WorkboardCopyTruthGuardTests` rule (4) **WIDENED** from `workboard.*` to both
  prefixes and rule (5) added; both existing directions kept. Measured red on the pre-splice catalog
  (3 cases) and on a singular-only count row (exactly 1 case).

**Nobody undo these — they interlock, and each is pinned by a case measured red on a
counterfactual.** The six wave-E "nobody undo" lists (e-queue §5 with seven clauses, e-drainer §2,
e-recover §5, e-store §1–4, e-surfaces §5, e-copy-docs §7) all still hold after the merge, and the
5002-case suite is the proof that none contradicts another. Wave A–D's lists also still hold, with
integrate-f's one recorded, argued exception (d-retry §Decisions 2 over c-lanes' `.published` rule).
**Wave E added no reversal of its own.**

---

## 8. Open items — integrate-f's O-1…O-20 reconciled, renumbered

**Closed this wave (four), with the evidence I checked:**

| Was | Item | Closed by |
|---|---|---|
| O-15 | A `recover` republication can throw for ever on `invalidMaterialOwner` | e-recover — `republishRecording` catches `invalidMaterialOwner` and retries ONCE under `WorkMaterialCollisionEscape.materialID(forCapture:)`; a second refusal is `.refusedTwice` and never derives a third id. `WorkVoiceRecoveryTests` **27/0**, with four cases measured red on the escape-reverted tree, each on `caught error: "invalidMaterialOwner"`. **The escape id is shared with the drain lane** (§2), so the two lanes repair one card |
| O-16 | An exempt retry entry has no user-facing discard | e-surfaces + e-copy-docs — `PendingRetryCard` gains a confirmed "Discard recording" reaching `ContentView.discardPendingRetry` → `claimNext()` → `clear(_ claim:)` + `PendingRetryGuard.cancelDeferredNotification(for:)`; five catalog rows spliced. `PendingRetrySurfaceHandoffTests` **9/0**, including `testDiscardingTheOfferedCaptureRemovesExactlyThatOne` measured red when `clear(_ claim:)` becomes `clear()` |
| O-17 | `DiagnosticsRunner`'s parked-retry row describes the newest of several | e-surfaces — `DiagnosticsRunner.swift:752` + the count in `factPendingRetry` (`:1380-1381`). Metadata-only (e-queue measured 0 recording reads). **The on-screen sentence still describes one capture** — that residue is O-9, not this item |
| O-20 | Five wave-D settled facts were in no document | e-copy-docs — five folded into `spec.md` at **zero word cost** (19827 → 19827), and e-store's correction of the "bounded" claim went in with them. The remaining wave-D facts and all of wave E's are in §10 |

**Open, renumbered:**

| # | Item | Why it is open, and who it belongs to |
|---|---|---|
| **O-1** | **The three ARM-side lanes cannot hold a reservation, so three superseded operations cannot be retired.** `ConverseIntent`, `PendingRetryGuard` and `InAppAudioRecorder` each address the capture they minted; the store's only selection primitive is `claimNext`, which answers "the newest capture nobody has reserved" — an arming lane that took it would hold a stranger's recording for ten minutes, and (e-surfaces §Refuted 1b) an intent process killed mid-flight would tell the user at 90 s to retry a recording `claimNext` refuses them for another 510. The fix is `func claim(id: UUID) async -> PendingRetryClaim?` (~12 lines, **absent** — `grep 'func claim(id:'` → nothing) plus `PendingRetryQueueWriting` widened plus the `RecordingRetryLane` double updated: one change, three files. Until then `load()`, `clear(ifCurrentID:)` and `recordPublicationState(id:)` all stay. **It also leaves one residual hazard e-surfaces states rather than hides:** `recover`'s durable `.published` write is refused on the Shortcuts lane, because that lane's claim carries a token no store issued. e-queue §2 + e-surfaces §2, §3 + e-recover §1, resolved into one item |
| **O-2** | **`PendingRetryRecord` has zero real callers** — re-verified: its declaration (`PendingRetryStore.swift:311`) and a STRING LITERAL inside `WorkboardVoiceLaneTests.swift:733`'s control fixture, nothing else. It was `recover`'s parameter type before the claim migration. It retires WITH O-1's block, not before. e-recover §Requests 2 |
| **O-3** | **The macOS backlog Retry button is gated on a proxy the store can now answer directly.** `DictationPopoverView.swift:1322-1324` is `service.lastError?.shouldPreserveForRetry == true`, gating the button at `:1356`; it wants `service.pendingRetryCount > 0` (`DictationService.swift:103`). Verified reachable and safe — `grep -rn 'service\.lastError'` over production returns that ONE line. e-surfaces refused to fake a `lastError` to force the button, which is right. Consequence today: after a terminal finish with a Shortcuts-armed capture still waiting, the popover says one is waiting and draws no Retry. One line, in a file no wave-E agent owned, verifiable only on a Mac. e-surfaces §Requests 1 |
| **O-4** | **No `AppError` code for a permanent identity refusal.** `.workDeskWriteFailed` (78) reads "Work couldn't save this recording just now" — a claim of transience about a refusal that is permanent, which is why a double-refused wordless capture records no code at all. The honest shape is a new non-retryable case plus one `updateAttempt(claim:lastErrorCode:)` in `recover`'s `.refusedTwice` branch. e-recover §Requests 3 |
| **O-5** | **The cross-process publication lock and the retry queue are proven with two instances in ONE process, never two.** e-queue's new cases drive the REAL `flock`, the REAL directory scan and the REAL write orders — a strictly stronger position than wave C's — but from one process, and the App-Group path is exercised only by derivation. → Gate-2 founder QA. *(was O-1)* |
| **O-6** | **`deleteSupersededBlobRows` knowingly accepts r4s#3's hazard class.** It still deletes complete rows carrying OTHER bytes inside the publishing transaction. e-store's repair does not widen it and does not close it, but does make the disagreement it can produce recoverable — a card whose peer republication is deleted is now normalised onto this device's bytes rather than left pending. **Remedy shape written down**: skip rows whose `updatedAt` is newer than this publication's own material read; never a sweep. e-store §Requests 5. *(was O-19)* |
| **O-7** | **`IsolatedWorkStores` adoption** in the classes c-store and c-drainer did not own. Hygiene, not correctness; recipe in c-store §Requests 4. *(was O-2)* |
| **O-8** | **Founder copy calls, consolidated — now seven.** (a) the voice sheet's privacy line, now honest about the AI hop. (b) the three desk-banner sentences. (c) `workboard.workspace.drop.overlay.caption`. (d) the recovered-note title. (e) copy-b §Requests 2's tutorial line and large-file confirm. (f) **NEW** — `workboard.capture.discarded.message.one` is half true for a terminally refused capture (Conduck read it fine and its file still exists in `refused/`); e-copy-docs' recommended wording to react to, not to ship: *"Conduck couldn't add one shared item to your board."* (g) **NEW** — the backlog count is a fragment ("2 recordings waiting") that is a caption on iOS and a whole popover sentence on macOS, and the discard confirmation is deliberately uncontracted ("It cannot be recovered") to match Delete All Conversations rather than the retry card's chattier voice. e-drainer §1 + e-copy-docs §1, §2, §3. *(was O-13)* |
| **O-9** | **`diagnostics.voice.pendingRetry.waiting` is unminted, correctly.** `factPendingRetry` carries the count but the on-screen row's sentence still describes one capture. The copy guard now walks `pendingRetry.*` in BOTH directions, so the key and its `if` in `DiagnosticsRunner` must land in the SAME edit or `testEveryWorkCatalogRowIsReferencedInSource` fails. e-surfaces §Requests 4 + e-copy-docs §Requests 4, resolved into one item. *(was the on-screen half of O-17)* |
| **O-10** | **`WorkCaptureRetryCoordinator.swift` still has ZERO production callers.** Deleting it compiles. The decision is whether the desk keeps a coordinator-shaped fallback now that `recover` is the single answer. *(was O-3)* |
| **O-11** | Collapse the two iCloud banners — `ICloudUnavailableBanner` gains a `message`, `WorkboardSyncBanner` dies. c-guards §Requests 1. *(was O-4)* |
| **O-12** | Should `ReplyVoice.shared` register on iOS? c-session §Requests 2. *(was O-5)* |
| **O-13** | Carry `WorkMaterial.filename` onto `WorkboardMaterialSnapshot` so a voice note's preview copy gets its real `.m4a`. *(was O-6)* |
| **O-14** | Three behaviour-neutral consolidations: the board-tile radius `13` literal into `WorkboardMetrics`; one shared `WorkboardCardActions`; `onCancel` → `onDismiss` on the voice sheet's hand-off. *(was O-7)* |
| **O-15** | The availability glyph/tint/label mapping is still duplicated between `WorkboardSourceCard` and `WorkboardAudioCardView`'s chip. *(was O-8)* |
| **O-16** | `WorkboardViewModel.workspaceStatus` → `transientStatus`/`deskStatus`. Vocabulary only. *(was O-9)* |
| **O-17** | **The external-storage ceiling memory bound is uncovered by DECISION, not oversight.** Accepted debt; reinstating it is its own session. *(was O-10)* |
| **O-18** | **Watch catalog drift, pre-existing since `efa553e`** — `WatchRecordingService.swift:761` declares `"\(name) isn't available…"` while the Watch catalog row reads `"%@ isn't set up…"`. The catalog wins at runtime, so the source lies to the next reader. Not a Work string. copy-b §5. *(was O-11)* |
| **O-19** | **Spec-size debt** — 19827 against a 16900 ceiling, two unrelated decisions over their 650-word limits. Out of scope by plan §"Out of scope". The number has now held at 19827 across FOUR consecutive integrations, with wave D's and wave E's facts each paid for inside the decision that received them; the next cut must come from somewhere else again. *(was O-12)* |
| **O-20** | **Founder QA (Gate 2), consolidated — now 51 items across fifteen fixnotes**, none reachable by a unit test. Wave A–C's 16 + wave D's 15 + wave E's 20 (§9). Plus plan §C's Gate 2 in full: real-CloudKit export/import across both stores, delete/reinstall reimport, actual watch exclusion. **Byte sync does not reach a release build without it.** *(was O-14)* |
| **O-21** | **NEW — one guard registry drifted silently and nothing outside a full-suite run would have caught it.** `STTKeyBlackoutLaneTests` pins nine key-refusal lanes by FUNCTION NAME; e-surfaces split two of them and both rows went blind at once, with the `try XCTUnwrap` loop hiding the second behind the first. Fixed here (§3), and the fix is now a pattern the same class can reuse. The residue worth deciding: **a registry loop whose first failure aborts the pass reports one lane when several are broken.** Converting the six `try XCTUnwrap`s into non-throwing checks that `continue` would report all nine every run. Behaviour-neutral for a green tree; it changes only what a red one tells you |

---

## 9. Founder QA — consolidated from all six wave-E fixnotes (20 items)

All are two-device or device-only and none is reachable by a unit test. These ADD to integrate-f's
31 (now O-20). **Two whole classes of them cannot be forced by hand — a genuine id collision needs a
debug build that mints one — so those are stated as observables, not steps.**

**From e-queue (6) — the container is rewritten on first launch, which is the one-way step:**
1. **The upgrade itself.** BEFORE installing this build, park a Work voice note on the device
   (airplane mode, let STT fail) so a recording exists under the OLD layout. Install, open the app:
   the retry card must still be there and finishing it must produce ONE playable card with the words.
   *Nothing about this is reversible.*
2. **Two surfaces, one recording (macOS).** With a capture waiting, open the menu bar's Retry and the
   main window's retry and press both. Exactly one must do the work.
3. **Force-quit while a retry is in flight.** Reopen: the capture must be offered again — not
   immediately (the reservation is ten minutes), but certainly after that, and never lost.
4. **First unlock.** Reboot the iPhone, do NOT unlock, fire the Action Button with Destination =
   Work. Unlock, open the app: the retry card must be there. Previously a read of the protected file
   could fail and drop the entry.
5. **Two processes, one queue.** While a Shortcut capture is in flight, start an in-app capture that
   also fails. Neither recording may disappear, and Diagnostics afterwards must name both.
6. **Nothing accumulates.** Discard everything from Settings; Diagnostics must report no parked
   recording and a later launch must not resurrect one.

**From e-surfaces (8) — the backlog, the discard, and the busy sentence:**
7. **The backlog, on iPhone.** Park TWO recordings. The card must say **"2 recordings waiting"**. Tap
   Retry ONCE: exactly one goes through, and the card must still be there with the count gone rather
   than disappearing or reading as a failure. Tap again: the second goes, the card disappears.
8. **The backlog, on Mac.** After the first Retry succeeds the popover must NOT go quiet — it must
   say how many are left and still offer Retry. *If the Retry button is missing while the sentence
   says one is waiting, that is **O-3**, not a new bug.*
9. **Discard takes exactly one.** With two waiting, tap **Discard recording**. After confirming: the
   count drops by one, the OTHER recording is still retryable and still produces the right words, and
   no "Recording Saved" notification arrives later for the discarded one. **Cancel must change
   nothing at all.**
10. **Discard the last one.** The card must disappear and Diagnostics must report no parked recording.
11. **Two surfaces, one recording (Mac).** Press both retries: one does the work, the other must say
    **"This recording is already being finished. Try again in a moment."**
12. **The exempt Work capture, end to end.** Airplane mode, Action Button with Destination = Work.
    The desk write fails and the recording parks and never expires. Confirm it is still there after
    ten minutes, then discard it and confirm it is gone for good.
13. **Diagnostics counts them.** With two waiting, Settings → Diagnostics → **Copy report**: the line
    must read `parked(code …, …m left, 2 waiting)`. The row's own sentence still speaks about one —
    that is **O-9**.
14. **VoiceOver over the card.** The Discard button must announce as "Discard recording", and the
    count line must be read. The card is the one place a destructive action sits beside a Retry.

**From e-copy-docs (2) — read the words:**
15. **The count at exactly one, on the Mac.** "**1 recording waiting**" — singular. "1 recordings
    waiting" means the plural row did not ship, and it is the one thing about this change a person
    would actually notice.
16. **Read the discard dialog aloud.** Title "Discard this recording?", body "This deletes the
    recording from this device. It cannot be recovered.", buttons "Discard" and "Cancel". The
    question is register: this is the second-most consequential dialog in the app after Delete All
    Conversations. Check "Discard" and "Cancel" are both reachable at the largest accessibility sizes.

**From e-recover + e-drainer (3) — observables, not steps:**
17. **The non-event that matters (voice).** Make Work voice notes in airplane mode until several are
    parked, then come back online and finish them. Every one must end as a playable card with its
    words. Before this change, ONE capture whose id collided would have stayed on that card for ever,
    Retry failing silently, the only way out being a reinstall.
18. **The non-event that matters (share).** Share several files in a row from another app while Work
    already holds cards. Every share must appear. Before this change ONE capture that could not
    publish stopped every share queued behind it — silently, no card, no message.
19. **If a recovered voice note ever appears TWICE** — one playable card with no words and one note
    carrying the words, both from the same recording — that is a collision that escaped and lost
    track of where. It should be unreachable; report it.
20. **If you ever see "Conduck couldn't read one shared item…" after a share that plainly was
    readable**, that is a terminal refusal rather than a malformed envelope. The file still exists in
    the App Group under `WorkCaptureInbox/refused/<envelope-uuid>/` with a `refusal.txt` naming both
    ids. There is no UI for it by design. In a working build it should never fire.

**Plus two from e-recover about the ten-minute window, which are easy to misread as bugs:**
- After a repaired recording lands on the desk wordlessly, the retry ENTRY may disappear after ten
  minutes and **that is correct** — only a transcription was still owed. What must never happen is
  the CARD disappearing.
- After that card is on the desk, delete it and tap Retry once more: the recording must NOT come
  back. The entry now knows the desk took it, so its absence is a deletion.

**From e-store (2) — two-device and crash-shaped:**
- **A card that was waiting for iCloud, on the device that HAS the bytes.** Two devices, byte sync
  on. Capture a small file into Work on A; with A offline, REATTACH a different small file onto that
  card on B, then put B offline before its payload syncs. Bring both online: within a minute or two
  neither device may show a card stuck on "Waiting for iCloud…".
- **The repeated pre-material crash.** Force-quit immediately after the capture progress bar
  completes, three or four times, capturing the SAME small file each time; then let one finish.
  Expected: one card, it opens, and storage grows by roughly N copies of the file. That growth is
  accepted residue — reattaching a DIFFERENT file or deleting the card must bring it back down.

---

## 10. Settled facts — consolidated, one sentence each

**Already written into a document by e-copy-docs (five, at zero word cost) — no further action:**
- A capture whose identifier already names a card of another kind is republished under one escape
  identifier derived from it, so every process and every replay repairs the same card; a second
  refusal is terminal and retires the capture with its files intact. *(spec.md, Work decision)*
- A publication that dies between saving a card's bytes and saving the card strands one payload row,
  which persists until the card's bytes are replaced or the card is deleted; no sweep may remove it,
  because a stranded attempt is indistinguishable from a peer's upload that arrived ahead of the card
  naming it. *(spec.md, Work decision — this CORRECTS the count-bounded claim integrate-f carried)*
- Each waiting capture writes its record before its bytes and commits the queue last, and a removal
  writes a tombstone before it takes anything away, so an interrupted arm or discard finishes on the
  next launch rather than half-existing. *(spec.md, Audio bullet)*
- A surface reserves the capture it is finishing for ten minutes, so two open surfaces never take the
  same recording; a reservation nobody completes lapses. *(spec.md, Audio bullet)*
- Nothing reclaims a Work recording the desk never accepted, which is why the retry card carries a
  confirmed discard — it is the only way to be rid of one. *(spec.md, Audio bullet)*
- The rule that the Work/Chats shell keeps both drafts alive across a switch lives in
  `project-structure.md`'s `Views/Workboard/` row, not in `spec.md`. *(re-homed, not deleted)*
- The retry queue's claim, lease and per-entry durability are in `project-structure.md`'s `Services/`
  row; the escape derivation is in its `Services/Workboard/` row and in the "Where to start" table.

**True of the code and in NO document — the O-19 trade, preserved verbatim:**
- A replay that carries a card's bytes brings EVERY physical row of that card back onto them — lane,
  content hash and byte size together — whenever any row disagrees, so a merge that left one row
  naming a blob this device never received cannot keep the card waiting for iCloud; a replay onto
  rows that already name its bytes writes nothing at all.
- There is exactly one escape identifier: a refusal of the escape id too is terminal, and neither the
  drain lane nor the recovery lane ever derives a third.
- A capture that can never become cards is retired rather than requeued — its whole claimed directory
  is copied to `refused/` beside the queue, with a one-line reason, before the queue entry is
  acknowledged — so no shared file is destroyed by a refusal, and nothing sweeps or claims `refused/`
  because it is not a UUID-named child of the inbox root.
- A terminal refusal never blocks the queue: the drain counts it as a capture that did not arrive and
  goes straight on to the captures behind it in the same pass; a capture that had already published
  some of its cards keeps them.
- The words of a recovered voice note look for their recording under BOTH of its names, and the
  moment a recovery puts a recording back on the desk the waiting capture is told so — which is what
  stops that recording being put back a second time after the person deletes it.
- A retry surface that has no words of its own uses the words already kept with the capture, so the
  same recording is never sent to a speech provider twice for an answer it already gave.
- A recording that is present but unreadable — the device has not been unlocked since it restarted —
  is left waiting; only a recording that is genuinely gone ends its capture.
- Asking how many recordings are waiting reads no recording at all, and offering one reads exactly one.
- A capture's recording, its record and its screenshot are all named with the capture's own
  identifier, so no operation on one capture can name a file belonging to another; the recording a
  build before capture identifiers parked is copied under an identifier on first launch, and nothing
  reads or deletes the old fixed name afterwards.
- The Shortcuts lane finishes the recording it made rather than picking one out of the queue, because
  a hold taken by a background capture would outlive the kill it is protecting against.
- The Work copy guard walks both `workboard.*` and `pendingRetry.*` in both directions, and
  `pendingRetry.*` is deliberately exempt from its vocabulary rule because the queue behind those
  strings holds Chat captures, where a failed *send* is exactly what happened.
- A source `defaultValue:` cannot express a plural; the catalog row can, it wins at runtime, and the
  two stay byte-identical because the source form is the row's `other` category.
- Wave D's uncarried facts still stand and are still in no document: the colliding-capture refusal,
  model 16's added `contentHash` column, the legacy-key fold, and "a verdict never deletes a
  recording".

**Measured facts about the tree itself, for whoever commits it:**
- The wave-E tree is 20 modified files plus 5 untracked (one production, four tests) and 0 deletions;
  the only `.xcstrings` change is +6 rows in the main catalog, and no model file was touched this wave.
- `updateAttemptIfCurrent(id:lastErrorCode:)` no longer exists; `load()`, `clear(ifCurrentID:)` and
  `recordPublicationState(id:)` do, and each is kept by a named caller (§1).
- A source drift guard that names a function is only as good as the split that function survives:
  `STTKeyBlackoutLaneTests` now pins the entry→helper linkage as well as the arms.
- `git diff --name-only … -- '*.xcdatamodeld'` matches nothing in this repo; the working pathspec is
  `'*.xcdatamodeld/*'`.
- The app-side mirror sources are `Conduck/Conduck/Models/WorkCaptureEnvelope.swift`,
  `…/Models/ShareTargetsSnapshot.swift` and `…/Services/WorkCaptureDirectoryPublisher.swift` — the
  first two are NOT under `Services/`.

---

## Catalog

**Keys I ADDED in source: NONE.** **Keys I made DEAD: NONE.** No `.xcstrings` file was opened by me.

**The wave's whole string story, verified end to end (§4.7).** e-drainer, e-queue, e-recover and
e-store each report ADDED: none / DEAD: none and none opened a catalog — confirmed independently:
`git status --short -- '*.xcstrings'` lists **only** `Conduck/Conduck/Localizable.xcstrings`, and its
dict diff against `HEAD` is **+6 / −0 / ~0**. The six are e-surfaces' declared keys, spliced by
e-copy-docs, and every source `defaultValue:` matches its catalog `en` (the count row's `other`
category being the form the source carries). **Nothing was changed and nothing was retired.**

---

## Requests

1. **Orchestrator — the gate is CLOSED on the merged tree.** Every item plan §F names is quoted in
   §4: iOS `build-for-testing`, signed macOS build, full iOS suite (**5002 / 1 skip / 0 fail**), full
   watch suite (**232 / 0**), the three guard scripts, `git diff --check`, all four catalogs parsing
   with a before/after dict diff, the three mirror triplets byte-identical, and the bidirectional
   string audit on BOTH prefixes (147/147 and 8/8). Plus the model diff since `651a859` with v15
   SHA-proven identical (§4.10) and the empty build-cache root (§4.9). **The spec-size guard exits 1
   and must be recorded as PRE-EXISTING** — 19827 words, unchanged across four integrations.
2. **The commit must include the five untracked files**, one of which is PRODUCTION
   (`WorkMaterialCollisionEscape.swift`). A `git commit -a` would miss all five, and missing that one
   breaks the build.
3. **`STTKeyBlackoutLaneTests` was broken by wave E and is fixed here — do not treat it as noise in
   the diff.** Two of its nine lanes had gone blind. If a later round splits another registered
   refusal lane, the fix is `delegatesTo:`, not deleting the row.
4. **Nobody undo the wave's interlocking constraints** — §7 lists all six lists. Wave E added no
   reversal of an earlier wave's rule.
5. **Whoever runs the next full suite on `2B6E0EAC` — check the TCC row first anyway.** It was clean
   for me; the check costs one command and a `0` row costs a confusing hour.
6. **Whoever picks up O-1 — the three retirements go together.** `claim(id:)`,
   `PendingRetryQueueWriting`, the `RecordingRetryLane` double, and then `load()`,
   `clear(ifCurrentID:)`, `recordPublicationState(id:)` and `PendingRetryRecord` all come out in one
   change. The census in `PendingRetrySurfaceHandoffTests` FAILS until its allowlist is emptied in
   the same edit, which is the point.

---

## Deviations

1. **I changed three files where integrate-f changed none.** Two were the brief's own instruction
   (delete the superseded method with no caller remaining). The third was not optional: the full
   suite went red on a guard wave E broke, and a gate that reports a failure without fixing a
   wave-E file would be handing back a red tree.
2. **I fixed BOTH blind lanes, not only the one the run reported.** The registry loop's
   `try XCTUnwrap` aborts the pass, so `ContentView → runPendingRetry` was never reached and would
   have gone red on the very next run after the menu bar was fixed. Carried the residue as **O-21**.
3. **I edited two comments in `PendingRetrySurfaceHandoffTests`** — a file e-surfaces owns — so that
   neither the class header nor the needle's note claims `updateAttemptIfCurrent` still exists after
   I deleted it. **No assertion, needle or allowlist entry moved**, and the class is 9/0.
4. **I widened `load()`'s doc comment.** "Delete when no caller remains" reads as an invitation to
   anyone who greps production only; the comment now says which tests keep it and why.
5. **My counterfactual mutated the TEST registry, not production**, and I label exactly what it
   proves: the LINKAGE assertion is live. The evidence the re-anchored arms bite is the pre-fix full
   run, which measured the old registry red against this exact production tree.
6. **I ran no other agent's counterfactual and re-ran none of theirs.** Each fixnote records its own
   measured red run; I verified the resulting tree.

## What I did NOT verify, plainly

- **No two-process harness** for the publication lock or the retry queue (O-5), and **no signed
  device** — Gate 2. e-queue's cases drive the real `flock`, the real directory scan and the real
  write orders, but from one process.
- **No migration was run against a real device's App Group.** Both legacy fold-ins are proven against
  a real directory, but a synthetic one, and the container is rewritten on first launch — the one
  irreversible step in this wave (Founder QA 1).
- **`.completeFileProtection` before first unlock is reasoned, not measured** — a simulator has no
  lock state.
- **No UI, no screen.** There is no UI-test target by decision. The 20-item list above is the hand-back.
- **No network, no CloudKit.** The synced-row repair and the escape are proven against in-memory
  stores; the merge they repair is a CloudKit ordering no headless test can produce.
- **The single skip's subject is unverified by construction** — the website checkout it pins against
  does not exist here, which is what the skip says.
- **I ran the full iOS suite three times** (once red before the fix, twice green after), so I have
  some evidence of ordering-independence but not of behaviour under repeated load.

---

## Refuted

**Mine: EMPTY.** Every request I resolved was verified against the current code first (§2 names the
`file:line` I traced for each), and every one held. The one finding I raised myself — the broken
guard — was traced through `RefusalLaneSource.body(ofFunction:)` before any edit, and it held for two
lanes rather than the one the run reported.

**The wave's own `## Refuted` sections, verbatim, so the next round needs no other file:**

- **e-queue** — "**None.** All four findings were traced against the current tree by call path before
  any code changed, and all four hold exactly at the anchors quoted in §Findings. The decided design
  directions (K2 and K3) were implementable as specified; the two places the letter of K3 moved are
  recorded as deviations — the one-time adoption of a recording the previous layout could not
  describe (§Deviations 1), which the standing 'legacy on-disk data is READ and migrated, never
  deleted' rule requires, and the namespacing of two filenames in a shared container (§Deviations 2).
  One qualification, stated as such rather than as a refusal: r5a#5's finding names
  `WorkboardVoiceCaptureView.swift:209` as one of the two racing surfaces. That surface does not read
  this store — it finishes `InAppAudioRecorder.pendingWorkCapture` and releases the queue entry
  through `clear(ifCurrentID:)` — so the lease cannot cover it until a caller migrates it to
  `claimNext` (§Requests 2). The two surfaces that DO select from the queue, the menu bar and the iOS
  retry card, are covered as decided."
- **e-drainer** — "**Empty.** r5s#2 held in full, including the clause about the existing test
  verifying only refusal and preservation. The design directions in the brief — K1's shape, the
  escape-once rule, the terminal second refusal, and the `refused/` sibling — were all implementable
  as written; the only judgement the brief left open ('find that path; if none exists…') resolved to
  *none exists that preserves bytes*, so the `refused/` fallback it names is what I built."
- **e-recover** — "**None.** Both findings were traced against the current tree by call path before
  any code changed, and both hold exactly at the anchors quoted in §2 — re-located by symbol, since
  the wave-E edits had moved every line number the brief cites. The decided design direction (K4) was
  implementable as specified; the two places I went beyond it are recorded in §3 and §6, and the one
  place its letter is self-contradictory ('terminal → … or retryKept') is recorded in §6.1 with the
  reading I took.
  One qualification, stated as such rather than as a refusal: r5a#7 rates the same defect 'minor'
  where r5s#3 rates it 'major'. The trace supports the major reading — the entry is not merely
  retried uselessly, it is `isExemptFromExpiry` and therefore keeps its bytes in the App Group for
  the life of the install — so I fixed it as a major and did not scale the answer to the smaller
  rating."
- **e-store** — "**Nothing.** r5s#1 and r5s#4 both held against the current tree when traced by call
  path before any edit, and r5s#1's mechanism is shown red on the reverted tree (§3). The DESIGN
  DIRECTIONS were implementable as written: r5s#1's comparison fits inside the transaction that
  already holds every physical row, and r5s#4's instruction (state the accurate bound, add no sweep)
  needed no code at all.
  One clause of r5s#4 is worth sharpening rather than disputing: the finding says 'without a
  committed material row every retry inserts another blob', which is true of a CRASH but not of a
  refusal — a refused publication takes its own row back by object id (`deleteBlobRow`). The
  corrected comment says so, because a reader who thinks every failure strands a row will eventually
  add the sweep the same comment forbids."
- **e-surfaces** — **the only agent this wave to refute a decided design direction, in two parts:**
  "**1. 'ConverseIntent: move the disarms to the claim API.' REFUTED — the code makes it impossible,
  and it would be wrong if it were possible.** … **(a) There is no operation that reserves a KNOWN
  capture.** The store offers exactly one selection primitive, `claimNext(surface:)`, and it answers
  'the newest capture nobody has reserved'. `ConverseIntent` does not select a capture: it mints
  `captureID`, writes the entry through `PendingRetryGuard.arm`, and addresses that entry by that id
  for the rest of `perform()`. Whenever anything armed after it … `claimNext` returns somebody ELSE's
  capture, and an intent that took it would put a ten-minute hold on a recording it is never going to
  finish, and read that recording's bytes into the most memory-constrained process in the app to do
  it. … **(b) A reservation held by an intent process outlives the OS kill this guard exists for.**
  The lease is ten minutes … `PendingRetryGuard.arm` schedules the … notification at 90 seconds. So
  an intent killed mid-flight while holding a reservation would tell the user at 90 s to open the app
  and retry, and `claimNext` would refuse them their own recording for another 510 s — the card up,
  the button doing nothing. That is strictly worse than today, on the exact failure this whole lane
  was built for."
  "**2. 'WorkboardVoiceCaptureView selects via claimNext.' REFUTED — that surface does not read the
  queue.** Traced: the sheet's Try Again calls `recorder.retryWorkCapture()` …, which finishes
  `InAppAudioRecorder.pendingWorkCapture` — an IN-MEMORY value this recorder is holding — and
  releases the entry through `InAppAudioRecorder.releaseDurableRetry` …, gated on
  `armedDurableRetryID == id`. There is no queue read anywhere on that path, so there is nothing for
  `claimNext` to replace … **3. Nothing else.**"
  **My verdict on both: SOUND, and both are the reason O-1 exists rather than a gap.** I re-verified
  (a) independently — `grep 'func claim(id:'` returns nothing, so the primitive genuinely does not
  exist — and (b) is arithmetic on two constants both present in the tree.
- **e-copy-docs** — "**Nothing.** Every fact the e-* notes carry held when traced against the code
  before I wrote it down, and every design direction in my brief was implementable as written. Two
  clarifications rather than refutations: **1. 'Replace any "bounded" claim that is inaccurate' had
  no referent in spec.md.** The inaccurate sentence lives in `integrate-f.md`'s O-20 list; `grep -n
  'bound' docs/ai-context/spec.md` shows eleven matches and none is about blob rows. … e-store's
  corrected statement therefore went in as a new claim rather than as a replacement. **2.
  e-surfaces' six keys were declared correctly, but one of them was under-specified**, and the defect
  is real rather than stylistic: the count key's second call site
  (`MenuBar/DictationService.swift:491-511`) has no `> 1` gate, so a single-value row ships
  '1 recordings waiting'. Fixed in the catalog, which is where a plural rule belongs, with no source
  change — and measured red as counterfactual 2. This is a correction to a sibling's declaration, not
  a refutation of a finding."

---

## Cleanup

`/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh integrate-g` — run at end of
task, output `removed: integrate-g`; `ls ~/Library/Caches/gigaduck-builds/` is **empty** afterwards.
**Every log quoted above goes with it** (`ios-bft-1…4`, `ios-full-1…3`, `mac-1…3`, `watch-1`,
`targeted-1/2`, `cf-1`, and the restore backup); re-run to reproduce. No bare `rm -rf`, no `/tmp`, no
throwaway tree copy — the counterfactual was a file swap on the shared tree, restored and SHA-verified.
No commit, no push, no stash, no checkout, no reset, no index operation;
`Identity-Override.xcconfig` untouched; nothing under `docs/qa/desk-cloudkit/` touched.
