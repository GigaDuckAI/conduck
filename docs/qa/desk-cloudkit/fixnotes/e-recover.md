# e-recover — `recover` no longer fails for ever on a taken id, and records the verdict it earns. Both findings CONFIRMED and fixed; nothing refuted.

Slug `e-recover`. Sim `C26F4ECE-16AC-40B7-8D6A-BBF82B5BBA5D`. No commits, pushes, stash, checkout,
reset or index operations. `Identity-Override.xcconfig` untouched. Nothing under
`docs/qa/desk-cloudkit/` touched. **No `.xcstrings` opened.** No `.pbxproj` edit. No mirror triplet
touched. No file outside my ownership edited (`git status --short` over the tree lists my three plus
twelve that belong to e-queue, e-drainer, e-surfaces and d-store, and nothing else).

Files changed — three, none new:

| File | Change |
|---|---|
| `Conduck/Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift` | `recover` takes a `PendingRetryClaim` and an optional transcript · `Republication` · `republishRecording(_:under:escapingTo:createdAt:store:)` · the escape-aware attach · `recordPublicationState` after a landed republication |
| `Conduck/ConduckTests/WorkVoiceRecoveryTests.swift` | 20 → **27** cases; every case migrated to the claim API and given its own isolated queue |
| `Conduck/ConduckTests/WorkboardVoiceLaneTests.swift` | 11 cases, **count unchanged**; three source rules re-anchored off type and function NAMES onto the values and sites they are actually about (§Decisions 4) |

`Conduck/ConduckTests/WorkboardAudioCaptureTests.swift` is mine and is **unchanged** — its call-site
guard (`testEveryRetrySurfaceMakesItsDeskDecisionThroughTheOneRecovery`) is written against
`WorkVoiceCaptureCoordinator.recover(` and the two literals it forbids, none of which the claim
migration touches. 19/19 green throughout.

**Net iOS executed from this slice: +7.**

**HEADLINE.** iOS `** TEST BUILD SUCCEEDED **` (0 `: error: `) · targeted 9-class set
`Executed 131 tests, with 0 failures` · signed macOS `** BUILD SUCCEEDED **` ·
**counterfactual: all 7 new cases fail on a tree with only the four mechanisms reverted, each on the
one it names, and all 20 pre-existing cases stay green** (§4).

---

## 1. `recover`'s final signature, VERBATIM

```swift
@discardableResult
static func recover(
    _ claim: PendingRetryClaim,
    transcript: String?,
    store: ConversationStore = .shared,
    queue: PendingRetryStore = .shared
) async throws -> WorkVoiceRecoveryOutcome
```

`WorkVoiceRecoveryOutcome` and `isTerminal` are **byte-identical** to what c-recovery-core shipped —
four cases, two `RetryKept` reasons, the same truth table. Only three doc comments moved, to say what
the escape does to `.republishedAndAttached`, `.fallbackNotePublished` and `.noTranscript`.

The decision, in order:

1. Not a Work record → `.retryKept(.notAWorkCapture)`, nothing read, nothing written.
2. `publicationState == .phaseOneFailed` and the entry parked bytes → republish, escaping ONCE:
   `publishRecording(captureID:)`, and on `invalidMaterialOwner`
   `publishRecording(captureID: WorkMaterialCollisionEscape.materialID(forCapture: captureID))`. A
   second `invalidMaterialOwner` is `.refusedTwice` — **no third id is ever derived**. Every other
   error still propagates unchanged.
3. A republication that LANDED (either id) →
   `queue.recordPublicationState(claim, transcript: nil, publicationState: .published)`,
   immediately, before the transcript is even read.
4. `words = normalizedThought(transcript ?? claim.entry.metadata.transcript ?? "")`; empty → `.retryKept(.noTranscript)`.
5. Attach, to the ids the recording can be standing under, in order:
   - landed → **only** the id it landed under;
   - no republication attempted → `[captureID, escapeID]`;
   - refused twice → `[]`.
   First `.attached` wins (`.republishedAndAttached` if this call republished, else `.attached`).
6. Nothing carried the words → `publishFallbackNote` under `fallbackNoteID(forCapture:)` →
   `.fallbackNotePublished`.

`queue` is the ONE new seam. It is a concrete `PendingRetryStore` rather than a protocol because
`PendingRetryQueueWriting` lives in e-queue's file and adding to it breaks a double I do not own
(e-queue §Requests 2); the `#if CONDUCK_TESTING` initializer e-queue already ships gives every test
an isolated real store, which is a stronger assertion than a fake would be.

---

## 2. Findings

### r5s#3 (major) / r5a#7 (minor) — the republication could throw for ever. CONFIRMED, fixed.

**Verified first, by call path, before any edit.** `recover` (then `WorkVoiceCaptureCoordinator.swift`,
located by symbol) called `try await publishRecording(captureID:…)` inside
`if pending.metadata.publicationState == .phaseOneFailed, !pending.audio.isEmpty`, four lines ABOVE
`guard !words.isEmpty`. `publishRecording` is a straight `store.upsertDeskMaterial(WorkMaterialDraft(id: captureID, kind: .audio, …))`,
and `upsertDeskMaterial` refuses a colliding identity before it stages anything:

```swift
// ConversationStore+Workboard.swift, in upsertDeskMaterial
if let existing, existing.kind != draft.kind {
    throw WorkboardStoreError.invalidMaterialOwner
}
```

plus `requireMatchingKind` inside the transaction and `requireAdoptable`'s unprovable-owner refusal.
Nothing in `recover` caught it, so:

| Clause in the finding | What the code did |
|---|---|
| publishes under `captureID` before examining the transcript | yes — the republication block precedes `guard !words.isEmpty` (r4a#3's fix, and correct) |
| `invalidMaterialOwner` is not caught | yes — `recover` has no `catch` at all; the throw leaves the function |
| `attachTranscript` and the fallback-note branch never run | yes — both are below the throw |
| every retry repeats the same failure | yes — the refusal is a property of the DESK's contents, not of this attempt; a surface catches the throw, keeps the record, and the next tap refuses identically |
| the entry can never leave the queue | yes, and worse than "never": `isExemptFromExpiry` is `resolvedDestination == .work && publicationState != .published`, so a `.phaseOneFailed` capture is exempt for ever — the entry and its bytes stay in the App Group until the person reinstalls |

Both lenses hold exactly as written. One thing the finding does not say that the trace added: the
refusal fires **before** anything is staged (`WorkAssetVault.storeFileStreaming` copies rather than
moves, and the transaction-level refusal rolls back a staged leaf and its blob row), so the parked
bytes the escape republishes are byte-for-byte what the capture recorded. That is what makes a retry
under a second id safe rather than a second chance at half-consumed bytes.

**Fix = K4.** §1 steps 2 and 5. `WorkMaterialCollisionEscape.materialID(forCapture:)` is e-drainer's
file and namespace, used exactly as its §Requests 4 asks — a capture that escaped in the drain lane
and one that escaped here land on the SAME card, which is what makes the two lanes idempotent against
each other.

**Regression tests** — `testACaptureWhoseIdIsTakenLandsUnderItsEscapeAndTakesItsWords` (the finding
itself: `.republishedAndAttached`, the recording under the escape id carrying the parked bytes and the
words, the foreign card's kind, title, `textContent` and PAYLOAD all byte-identical) ·
`testAReplayOfAnEscapedRecoveryRepairsTheSameCard` (two recoveries, one escaped card) ·
`testACaptureRefusedUnderBothIdsPutsItsWordsBesideThemAndFinishes` (`.fallbackNotePublished`, both
foreign payloads intact, and **no `.audio` card anywhere** — the "never a third id" rule as an
assertion) · `testACaptureRefusedUnderBothIdsWithNoWordsKeepsItsRetryAndWritesNothing`.
*How I know they bite:* MEASURED, §4 — the first four all fail with `caught error: "invalidMaterialOwner"`
at the `recover` call on a tree with only the escape reverted.

### r5a#6 (minor) — a wordless republication recorded nothing. CONFIRMED, fixed.

**Verified:** the republication set a local `var republished = false` and nothing else; the very next
statements were `let words = …` and `guard !words.isEmpty else { return .retryKept(.noTranscript) }`.
`.retryKept` is non-terminal, so the caller keeps the entry — and that entry still says
`.phaseOneFailed` over a recording that is now on the desk. Two consequences, both real:
`isExemptFromExpiry` stays true for ever, and the next recovery reads `.phaseOneFailed` as a licence
to republish, so a card the person deleted in the meantime comes back. Both halves hold.

**Fix = K4**, and slightly wider than its letter (§Decisions 1): the verdict is recorded the moment a
republication LANDS, not on the way out of the no-words branch, so the throw path between the
republication and the attachment cannot lose it either.

**Regression test** — `testARepublicationWithNoWordsRecordsThatTheDeskHoldsTheRecording`: a REAL
armed claim from this case's own store, `transcript: nil`, then the assertions are read back through
the store (`load()`), not off the claim: `publicationState == .published`, `transcript == nil`
("a nil transcript keeps what the record already carried"), and `isExemptFromExpiry == false`.
*How I know it bites:* MEASURED — on the counterfactual the same case fails twice, at the verdict
(`("…phaseOneFailed") is not equal to ("…published")`) and at the exemption.

---

## 3. What else changed, and why each is not scope creep

1. **The attach looks under the escape id too, when no republication told it where the recording is**
   (`Republication.recordingIDs`). Without it, the state THIS ROUND CREATES is unrecoverable: after an
   escaped republication the entry says `.published`, so the next recovery does not republish, attaches
   at `captureID`, finds the foreign card, answers `.notAudio` and writes the words into a note beside
   a recording that was standing there to carry them. It is the same defect as r5a#6 one step later,
   and it is what makes recording `.published` after an ESCAPED republication safe. Pinned by
   `testALaterRecoveryFindsTheRecordingUnderTheEscapeItAlreadyTook`.
2. **`transcript` is optional and falls back to the entry's own words.** K4 made the parameter
   optional; leaving the parked words unread would mean the coordinator answers "there are no words"
   while holding the entry that carries them — the r5a#6 shape exactly (state that exists and is not
   used), and a wasted provider round trip on the next tap. The caller's words always win. Pinned by
   `testTheWordsAlreadyParkedFinishACaptureWhenTheSurfaceHasNone`.

## 4. Counterfactual — MEASURED, in an isolated copy

Throwaway tree at `~/Library/Caches/gigaduck-builds/e-recover/cf/tree` (rsync, `.git` excluded),
cleaned with the slug at the end. Four mutations, each reverting exactly one mechanism and nothing
else — the claim signature, the tests and every other agent's work left in place:

| Mutation | What it restores |
|---|---|
| M1 | the republication publishes under the capture id only and lets `invalidMaterialOwner` propagate |
| M2 | the escape id is not an id a recovery looks for the recording under |
| M3 | a landed republication records no verdict; only the local flag moves |
| M4 | the caller's transcript is the only transcript |

`** TEST BUILD SUCCEEDED **`, `grep -c ': error: '` = 0, then:

```
	 Executed 27 tests, with 11 failures (4 unexpected) in 1.371 (1.377) seconds
```

**All 7 new cases fail; all 20 pre-existing cases stay green.** First failure per case, quoted:

| Case | First failure on the counterfactual |
|---|---|
| `testACaptureWhoseIdIsTakenLandsUnderItsEscapeAndTakesItsWords` | `:306 failed: caught error: "invalidMaterialOwner"` |
| `testAReplayOfAnEscapedRecoveryRepairsTheSameCard` | `:351 failed: caught error: "invalidMaterialOwner"` |
| `testACaptureRefusedUnderBothIdsPutsItsWordsBesideThemAndFinishes` | `:381 failed: caught error: "invalidMaterialOwner"` |
| `testACaptureRefusedUnderBothIdsWithNoWordsKeepsItsRetryAndWritesNothing` | `:420 failed: caught error: "invalidMaterialOwner"` |
| `testALaterRecoveryFindsTheRecordingUnderTheEscapeItAlreadyTook` | `:460 ("fallbackNotePublished") is not equal to ("attached")`, then `:463` the note id in the desk's id set and `:467` the escaped card still wordless |
| `testARepublicationWithNoWordsRecordsThatTheDeskHoldsTheRecording` | `:501 ("Optional(…phaseOneFailed)") is not equal to ("Optional(…published)")`, then `:510` the entry still exempt from expiry |
| `testTheWordsAlreadyParkedFinishACaptureWhenTheSurfaceHasNone` | `:536 ("retryKept(…noTranscript)") is not equal to ("attached")`, then `:539` the card still wordless |

The four `invalidMaterialOwner` throws are the finding reproduced verbatim: the recovery throws, the
outcome is never reached, and the entry stays armed over a state that never resolves.

*(The CF run's first attempt died before any case started — `Simulator device failed to launch
com.example.Conduck … Busy ("Application failed preflight checks")`, no `Executed` line at all. Retried
once with no change to the tree and it ran. The CF tree does not carry the identity override, which is
why its bundle id is the placeholder.)*

---

## 5. Decisions

1. **The verdict is recorded when the republication LANDS, not when the no-words branch returns.**
   K4 says "after ANY successful republication with no transcript"; this is that plus the case where
   words exist and the attach then throws, which leaves the same lie on disk (`.phaseOneFailed` over a
   recording that is on the desk) for the next recovery to act on. A superset, in the only direction
   that removes a falsehood.
2. **A double refusal with no words answers `.retryKept(.noTranscript)` and mints no error code.**
   K4's "with the error surfaced" is satisfied by the outcome itself: every surface renders a
   non-terminal outcome as "Couldn't add this recording to Work. Try again." (`ContentView`'s
   `guard outcome.isTerminal else { presentRetryError(…) }`, `DictationService`'s matching arm). I did
   NOT write `AppError.workDeskWriteFailed` into the entry through `updateAttempt`: its copy says
   "just now", which is a claim of transience about a refusal that is permanent, and `AppError.swift`
   is not mine to add a truthful case to. §Requests 3 says what a future round could do instead.
   The capture is not stranded: the moment recognition produces words the fallback note publishes and
   the outcome is terminal, and O-16's discard affordance is the other exit.
3. **`queue` is a concrete `PendingRetryStore`, not a new protocol.** Reasoned in §1. The cases that
   assert what `recover` records drive the REAL actor — its cross-process lock, its sidecar write
   order, its lease — over an isolated directory, which is what makes "the verdict is durable" an
   assertion rather than a claim about a double.
4. **Three source rules in `WorkboardVoiceLaneTests` were re-anchored, not weakened.** e-surfaces'
   migration landed under me and moved what the rules were pinned to; each rule now reads the thing it
   was always about:
   - `.theRecoveryCarriesTheCapturesRecord` read the arguments of `PendingRetryRecord(`. The intent now
     builds its claim in a helper (`Self.heldCapture(…)`), so the type name is gone. It now reads
     `recover`'s OWN first argument — inline, or through the `let` that binds it — and requires
     `pendingMetadata` and `uploadData` in it. Same claim, one indirection later, and no type name.
   - `.onePayloadForEveryUse` counted `audio: ` labels. A queue entry's label is `audioData:`, so the
     count fell from 3 to 2 under a lane that had not changed a byte of its payload discipline. Both
     labels are now counted, and every one of them must still be `uploadData`.
   - `testBothRetrySurfacesStageTheRecoveredBytesUnderTheirOwnContainer` was scoped to
     `runPendingRetry` / `retryLast`; both surfaces now split the work into a claim step and an attempt
     step, and the staging moved to the second. It is now anchored on **every** `conduck_retry_` site
     in the file — at least one must exist, and each must name its file from the bytes — which is
     STRICTER than the single-function form it replaces (it binds every staging site, not one), and the
     hard-coded `.m4a` absence check now covers the whole file rather than one function.
   No assertion was deleted, no rule dropped, and the twelve-rule control fixtures still break exactly
   one rule each (`testTheIntentLaneValidatorRefusesEveryShapeItExistsToRefuse`, 11/11 green).
5. **No Codex consult.** The one genuinely hard call — what a double refusal with no words may answer
   — is a product trade with a stated cost (§Decisions 2), not a technical unknown.

## 6. Deviations

1. **K4 says the second `invalidMaterialOwner` is "terminal → fallbackNotePublished … (or retryKept if
   there is no transcript, with the error surfaced)".** Implemented as written, with "the error
   surfaced" read as the non-terminal outcome every surface already renders rather than as a new error
   code (§Decisions 2). Stated here because "terminal" and "retryKept" cannot both be literally true.
2. **`recover`'s escape-aware attach and its transcript fallback are additions K4 does not name**
   (§3). Both close states this round's own fix would otherwise create.
3. **`PendingRetryRecord` now has no production caller** — it was `recover`'s parameter type and
   nothing else used it; `ConverseIntent` builds a `PendingRetryClaim` instead. It is declared in
   e-queue's file, so I left it. §Requests 2.

---

## 7. Gates — WHAT I ACTUALLY RAN

DerivedData under `~/Library/Caches/gigaduck-builds/e-recover/{DerivedData,DerivedDataMac,DerivedDataCF}`,
every log written there and grepped for `': error: '` and the verdict strings — never judged from a
tail or an exit code. **No `-configuration` passed anywhere.** No `/tmp`, no bare `rm -rf`. The one
throwaway tree copy lived under the slug dir and went with it.

- **Simulator TCC checked BEFORE trusting any run**, per the standing rule:
  `sqlite3 …/C26F4ECE…/data/Library/TCC/TCC.db "select service, client, auth_value from access where
  client='ai.gigaduck.AgentRelay';"` → one row, `kTCCServiceUbiquity|ai.gigaduck.AgentRelay|2`
  (allowed). **No `0` row, so no stale denial**; nothing reset.
- **iOS `build-for-testing`** → `ios-bft-6.log` (final): `grep -c ': error: '` = **0**, and
  `** TEST BUILD SUCCEEDED **`.
- **iOS `test-without-building`**, nine quoted `-only-testing:` flags → `test-5.log`:
  ```
  ** TEST EXECUTE SUCCEEDED **
	 Executed 131 tests, with 0 failures (0 unexpected) in 2.611 (2.650) seconds
  ```
  `grep -cE '\.swift:[0-9]+: error: '` = **0**.

  | Class | Result line |
  |---|---|
  | `WorkVoiceRecoveryTests` (mine) | `Executed 27 tests, with 0 failures (0 unexpected) in 0.364 (0.371) seconds` (was 20) |
  | `WorkboardVoiceLaneTests` (mine) | `Executed 11 tests, with 0 failures (0 unexpected) in 0.097 (0.100) seconds` (unchanged) |
  | `WorkboardAudioCaptureTests` (mine, unedited) | `Executed 19 tests, with 0 failures (0 unexpected) in 0.191 (0.196) seconds` |
  | `PendingRetryQueueTests` | `Executed 17 tests, with 0 failures (0 unexpected) in 0.008 (0.017) seconds` |
  | `HeadlessRetryGuardSpanTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.052 (0.055) seconds` |
  | `PendingRetryDurabilityTests` | `Executed 21 tests, with 0 failures (0 unexpected) in 0.079 (0.083) seconds` |
  | `PendingRetryDestinationTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.013 (0.016) seconds` |
  | `PendingRetrySurfaceHandoffTests` (e-surfaces') | `Executed 9 tests, with 0 failures (0 unexpected) in 1.806 (1.808) seconds` |
  | `WorkMaterialCollisionEscapeTests` (e-drainer's) | `Executed 4 tests, with 0 failures (0 unexpected) in 0.002 (0.003) seconds` |

  An earlier run over a wider neighbourhood (`test-4.log`) was also green:
  `Executed 50 tests, with 0 failures` over `WorkMaterialCollisionEscapeTests`,
  `WorkCaptureDrainerCollisionTests` (3), `WorkboardDeskUpsertTests` (16), `ErrorSurfaceDriftGuardTests`
  (7), `AudioExclusivityCrossSurfaceTests` (7), `PendingRetrySurfaceHandoffTests` (9),
  `DiagnosticsFocusTests` (4) — the classes that could scope the escape id, the desk refusal and the
  voice sheet's error surface.
- **macOS `build -destination 'platform=macOS'`** → `mac-1.log`: `grep -c ': error: '` = **0**, and:
  ```
  ** BUILD SUCCEEDED **
      Signing Identity:     "Apple Development: Peter Krueck (Z4PNDLZK98)"
  ```
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed or used.**
- **The build failed three times before green, and every failure was FOREIGN.** `ios-bft-1.log`: 2
  errors, both `DictationService.swift:788 Extraneous '}' at top level` (e-surfaces mid-edit).
  `ios-bft-2.log`: 1 error, `ConverseIntent.swift:596 cannot convert value of type
  'PendingRetryRecord' to expected argument type 'PendingRetryClaim'` — the parallel migration
  half-landed. `ios-bft-4.log`: 12 errors, all `PendingRetrySurfaceHandoffTests.swift` (e-surfaces'
  new file, mid-edit). **Zero errors in my files in any of them.** Each time I waited ~130 s and
  retried, per the parallel rule; `ios-bft-3.log` and `ios-bft-5.log` were green on the first retry.
- **One test run died before any case started** (`test-2.log`): `Simulator device failed to launch
  ai.gigaduck.AgentRelay … Busy ("Application failed preflight checks")`, `Executed` line absent
  entirely. Retried ONCE with no change to the tree → `test-3.log` green
  (`Executed 118 tests, with 0 failures`). Reported rather than hidden; other agents share this
  simulator, so I did **not** run `simctl shutdown all`.
- **`bash scripts/check-storage-seam.sh`** → `✓ storage seam intact — 803 Swift files scanned…`,
  exit 0. `scripts/check-folder-map.sh`, `check-legal-copies.sh`, `check-spec-cites.sh` → all exit 0.
- **`git diff --check`** → no output, exit 0. `git status --short` for `*.xcstrings`, `*.pbxproj`,
  `Conduck/Configs` and `docs/qa` → **empty**; all three mirror triplets untouched.
- **Warnings: I added NONE.** `grep ': warning: '` over both the iOS and macOS logs, filtered to
  `WorkVoiceCaptureCoordinator.swift`, `WorkVoiceRecoveryTests.swift` and `WorkboardVoiceLaneTests.swift`:
  **zero lines in all six combinations.**
- **The watch target compiles none of my files** — checked, not assumed: `grep -c` for
  `WorkVoiceCaptureCoordinator.swift`, `WorkVoiceRecoveryTests.swift` and `WorkboardVoiceLaneTests.swift`
  in `Conduck.xcodeproj/project.pbxproj` is **0**, so none is in the `ConduckWatch Watch App`
  `membershipExceptions` inclusion list; the coordinator is `#if !os(watchOS)` besides. **No `.pbxproj`
  edit was needed or made.**
- Build cache removed at end of task with `.claude/scripts/clean-build-cache.sh e-recover`; every log
  quoted above went with it, and so did the counterfactual tree. Re-run to reproduce.

### NOT run, plainly

- **The full iOS suite and the watch suite.** Neither is in my brief, no watch sim is assigned, and
  three other agents were editing this tree throughout — a full-suite number from this tree would
  describe a moment nobody will ship. **Suite delta from this slice: +7**
  (`WorkVoiceRecoveryTests` 20 → 27; every other class unchanged in count).
- **Any device QA.** §Founder QA.
- **A genuine id collision on a device.** It cannot be staged without a debug build that mints one;
  everything here is measured against a real `ConversationStore` in memory.

---

## Catalog

**Keys I ADDED in source: NONE.**

**Keys I made DEAD: NONE.** No string-bearing branch was added, deleted or moved.
`workboard.voice.recording.untitled` = `Voice note` is reached by MORE paths now (an escaped
republication titles its card with it until words arrive), which is a use, not a change;
`workboard.error.contentTooLong` and the fallback note's title logic are untouched.

**No `.xcstrings` file was opened.** Nothing for the serial copy agent to splice from this slice.

---

## Requests

1. **e-surfaces / whoever owns `Conduck/Conduck/Intents/ConverseIntent.swift` — the intent's claim
   carries a token no store issued, so any verdict `recover` records there is dropped.**
   `heldCapture(_:audio:)` (`:775-789`) builds `PendingRetryClaim(entry:…, token: UUID())`, and
   `recordPublicationState` refuses a token that does not match the sidecar's live lease. Today that
   costs nothing — the intent only reaches `recover` with a transcript in hand, and it records
   `.published`/`.phaseOneFailed` itself through `recordRecoveryState` at phase one — so this is a
   note, not a defect. But if the Shortcuts lane ever calls `recover` **without** words (a terminal STT
   verdict putting the recording back), it must hold a real reservation from `claimNext` or the
   `.published` verdict my fix writes will silently not be written. The plain fix when that day comes:
   claim through `PendingRetryStore.shared.claimNext(surface: .work)` rather than fabricating one.
2. **Owner of `Conduck/Conduck/Services/PendingRetryStore.swift` (e-queue's file) —
   `PendingRetryRecord` now has ZERO production callers.** It existed as `recover`'s parameter type;
   `recover` takes a `PendingRetryClaim` now and `ConverseIntent` builds one directly. `grep -rn
   'PendingRetryRecord' Conduck --include='*.swift'` should be checked before the next wave deletes
   the superseded `load()` / `clear(ifCurrentID:)` block — the two retirements belong together.
3. **Owner of `Conduck/Conduck/Models/AppError.swift` — there is no error code for a permanent
   identity refusal, and that is why a double-refused wordless capture records none.**
   `.workDeskWriteFailed` (78) reads "Work couldn't save this recording just now", which is a claim of
   transience. If a future round wants Diagnostics to be able to say WHY a capture keeps not
   finishing, the honest shape is a new non-retryable case ("this recording's place on the desk is
   taken") plus one `updateAttempt(claim, lastErrorCode:)` call in `recover`'s `.refusedTwice`
   branch — one line in my file, one case in yours. §Decisions 2 says why I did not do it unilaterally.
4. **e-surfaces — three source rules of mine now read your files by SHAPE, not by name** (§Decisions 4).
   What they still require, so a later tidy-up does not break them silently:
   (a) the value handed to `WorkVoiceCaptureCoordinator.recover(` in `ConverseIntent.perform()` must be
   built — inline or in the `let` that binds it — from something containing `pendingMetadata` and
   `uploadData`;
   (b) every `audio:` / `audioData:` label in that body must carry `uploadData`, at least three of them;
   (c) every `conduck_retry_` staging in `ContentView.swift` and `MenuBar/DictationService.swift` must
   name its file with `PendingRetryAudioFile.extension(for: <something>audioData)`, and neither file may
   contain the literal `conduck_retry_\(UUID().uuidString).m4a`.
5. **Nobody undo these** — each is pinned by a case measured red on the counterfactual:
   - `invalidMaterialOwner` is caught in `republishRecording` and **nowhere else**; every other error
     still propagates. Rethrowing it is r5s#3 exactly, and the entry it strands never expires.
   - There is **one** escape. `.refusedTwice` must never derive a third id.
   - The verdict is recorded the moment a republication lands, before the transcript is read. Moving it
     into the no-words branch loses it on the throw path; removing it is r5a#6.
   - `Republication.recordingIDs` returns `[captureID, escapeID]` when nothing was republished. Cutting
     it to `[captureID]` sends the words to a note beside an escaped recording that was there to carry
     them.
   - The caller's transcript wins and the entry's is the fallback. Reversing that order attaches stale
     words over fresh ones.
   - c-recovery-core's and d-retry's "nobody undo" clauses all still hold: `recover` is still the only
     place the attach-or-fallback decision is made, it still throws rather than answering when the store
     refuses a write, `nil` publication state still means UNKNOWN, and the republication still happens
     BEFORE the transcript is examined.

---

## Refuted

**None.** Both findings were traced against the current tree by call path before any code changed, and
both hold exactly at the anchors quoted in §2 — re-located by symbol, since the wave-E edits had moved
every line number the brief cites. The decided design direction (K4) was implementable as specified;
the two places I went beyond it are recorded in §3 and §6, and the one place its letter is
self-contradictory ("terminal → … or retryKept") is recorded in §6.1 with the reading I took.

One qualification, stated as such rather than as a refusal: r5a#7 rates the same defect "minor" where
r5s#3 rates it "major". The trace supports the major reading — the entry is not merely retried
uselessly, it is `isExemptFromExpiry` and therefore keeps its bytes in the App Group for the life of
the install — so I fixed it as a major and did not scale the answer to the smaller rating.

---

## Founder QA — device-only checks this change needs

These ADD to d-retry's seven and e-queue's six, which all still apply. **A genuine id collision cannot
be staged on a device without a debug build that mints one**, so items 1 and 2 are observables rather
than steps you can force.

1. **The non-event that matters.** Make Work voice notes in airplane mode until several are parked,
   then come back online and finish them. Every one must end as a playable card with its words, and the
   retry card must eventually go away. Before this change, ONE capture whose id collided would have
   stayed on that card for ever — Retry failing silently every time, its recording never reclaimable —
   and the only way out was reinstalling the app.
2. **If a recovered voice note ever appears TWICE** — one playable card with no words and one note
   carrying the words, both from the same recording — that is a collision that escaped and then lost
   track of where it escaped to. It should be unreachable now; worth telling me if you ever see it.
3. **The ten-minute window after a repaired recording.** Record a Work voice note with the desk write
   failing, so it parks; come back online and tap Retry while STT is still failing (airplane mode ON
   for the transcription only, if you can stage that). The card must appear on the desk immediately,
   wordless and playable. Then leave the app for **over ten minutes** and reopen it: the retry entry
   for that capture may now be gone, and that is CORRECT — its recording is on the desk, so only a
   transcription was still owed and the ten-minute transcription budget governs it again. What must
   never happen is the CARD disappearing.
4. **A recording repaired, then deleted.** After item 3's card is on the desk, delete it from the desk
   and tap Retry once more if the entry is still there. The recording must NOT come back: the entry now
   knows the desk took it, so its absence is a deletion.

---

## Settled facts — one sentence each, for whoever writes the docs

- A recording whose place on the desk is already taken by a card of another kind is put back under a
  second, derived name instead of failing on every retry for ever.
- That second name is worked out from the first, so the app, a Shortcut and any later retry all repair
  the same card rather than adding another one.
- There is exactly one second name: if that is taken too, the words are written beside both cards and
  the capture finishes, and neither card is touched.
- The words of a recovered voice note look for their recording under both of its names, so a recording
  that had to take the second one still gets its transcript rather than a note beside it.
- The moment a recovery puts a recording back on the desk, the waiting capture is told so — which is
  what stops that recording being put back a second time after the person deletes it, and what lets the
  capture be cleaned up once its words arrive.
- A retry surface that has no words of its own uses the words already kept with the capture, so the
  same recording is never sent to a speech provider twice for an answer it already gave.
- A capture waiting for words keeps its recording; only a capture whose recording is on the desk is
  governed by the ten-minute limit on retrying a transcription.
