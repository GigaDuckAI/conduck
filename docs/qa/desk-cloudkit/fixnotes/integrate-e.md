# integrate-e — wave C coheres. FULL GATE GREEN on the merged tree: iOS 4917/1 skip/0 fail · watch 232/0 · signed macOS BUILD SUCCEEDED.

Six wave-C fixnotes read in full (`c-copy-docs`, `c-drainer`, `c-guards`, `c-lanes`,
`c-recovery-core`, `c-session`, `c-store` — seven files), plus `integrate-d.md` for the O-list and the
4874 baseline. Every request resolved or carried forward with a reason. **Nothing refuted by me**;
every `## Refuted` and `## Guard verdicts` entry the wave produced is reproduced verbatim in §7 and §8
so Codex round 4 needs no other file.

---

## 1. Requests resolved, one by one

Five taken (all mechanical, all inside a test file or a comment), six carried forward as open items
because they need a design or an ownership call, and eight already satisfied by another wave-C agent.

### Taken

**(a) c-recovery-core §Requests 1 — `AppErrorCodeContractTests` code 78 was UNPINNED.**
VERIFIED first: `AppError.swift:376` declares `case workDeskWriteFailed // 78`, `:1443` decodes
`case 78: return .workDeskWriteFailed`, `:1544` emits `case .workDeskWriteFailed: return 78`. The test
computed its expected set as `Set((1...77).filter { $0 != 27 }).union([99])` — **independent of the
enum**, so a new case with no row left both sides equal and 21/21 stayed green. That is the exact
event the test's own comment says it exists for.
Fixed exactly as the request specifies, four literals in
`Conduck/ConduckTests/AppErrorCodeContractTests.swift`:
`("workDeskWriteFailed", .workDeskWriteFailed, 78),` after the `insecureConnectionBlocked` row
(with a two-line reason comment in the file's existing style) · `(1...77)` → `(1...78)` ·
`expectedDistinctCodes.count` `77` → `78` · `forwardTable.count` `77` → `78`.
**How I know it proves the old code wrong — argument from the assertion, and it is airtight.** The
three count literals are computed from the RANGE, never from the table. With the row present and any
one of the three literals still `77`, `XCTAssertEqual(Set(tableCodes), expectedDistinctCodes)` and
`XCTAssertEqual(forwardTable.count, 78)` disagree by exactly the new code and the case fails; with the
row absent (the pre-fix table) `forwardTable.count == 77 != 78` fails. So the guard now moves with the
enum in both directions, which it did not before. `AppErrorCodeContractTests` 21/0 in the full run
(the case count is unchanged — the fix is data inside two existing cases, not a new case).
No `collapseToAPIFailure` entry is needed: 78 carries no associated value and round-trips to itself.

**(b) c-recovery-core §Requests 3 — the `isTroubleshootable` deny-list claimed to be "complete,
exhaustive" and was not.** VERIFIED at `AppError.swift:1318-1338`: production returns `false` for
`.workDeskWriteFailed` AND for `.turnStoppedBeforeSend`, and the test listed neither.
Added both rows to `AppErrorTroubleshootableTests.testDenyListCasesAreNotTroubleshootable` and widened
the doc sentence to name the two categories they belong to.
**Deviation, stated:** the request asked for ONE row. I added two, because `.turnStoppedBeforeSend`
(76) is the same gap in the same list — the doc's word is "exhaustive", and leaving 76 out keeps the
claim false while pretending to repair it. Both are provable from the switch above, and the class went
2 → 2 cases (rows inside an existing loop), 2/0 in the full run.
**How it proves the old code wrong:** the assertion is a loop over the list — a production change that
moved either case off the deny-list now fails it, where before it silently would not have been seen.

**(c) c-store §Requests 3 — one row for `payloadSeams`.** VERIFIED: the new seam is declared at
`ConversationStore.swift:4737` (`var workMaterialPublicationLockHoldForTesting`), inside `#if
CONDUCK_TESTING` (opened `:4450`) and `#if !os(watchOS)` (opened `:4575`, closed `:4803`), so the row
is drift insurance rather than a defect. Added
`"var workMaterialPublicationLockHoldForTesting",` to `WorkboardBlobSeamPlatformGuardTests`.
**How it proves the old code wrong:** the guard walks the conditional-compilation stack line by line;
move that declaration out of the `!os(watchOS)` region and the second `XCTAssertTrue` fails naming the
seam, rename it and `XCTUnwrap` fails with "no longer declares". Neither was reachable before the row.
1/0 in the full run.

**(d) c-session §Requests 3 — two stale doc references to the renamed type.** VERIFIED by grep:
`ChatPlaybackSession` survived only in two comments after the file was deleted
(` D Conduck/Conduck/Services/TTS/ChatPlaybackSession.swift` in `git status`).
`Services/TTS/SpeechPlayer.swift:244` and `Services/TTS/SpeechChunkQueue.swift:49` now read
`SpokenAudioSession`. `grep -rn 'ChatPlaybackSession' Conduck --include='*.swift'` → **no matches**.
Comment-only; no build impact; no changelog narration added.

**(e) c-session §Requests 1 — `ThreadSpeakerExclusivityTests` was under-scoped AND its header was
false.** VERIFIED against `ThreadSpeaker.swift`: the registration is `#if os(macOS) || os(iOS)` at
`:59-70`, the three claims at `:180-184`, `:217-221`, `:356-357`, and the `SpeechExclusivityParty`
conformance at `:492-493` — all now exist on iOS, so the file's "`#if os(macOS)` because the
registration/claim lines inside `ThreadSpeaker` only exist there" was a false statement about the
code.
Widened the gate to `#if os(macOS) || os(iOS)` and rewrote the header clause to state the real
constraint (the gate matches `ThreadSpeaker`'s own; the wrist registers nothing). **No assertion was
added, removed, changed or weakened** — the two cases are byte-identical.
**Measured, not argued:** the class contributed **0** cases to integrate-d's 4874 and contributes
**2/0** to my 4917. The rig compiles on iOS for the same reason `ThreadSpeakerTests` (`#if
!os(watchOS)`, 8 cases on the iOS sim) does — `makeThrowawayOutcomeLog` is `#if !os(watchOS)`
(`TTSTestSupport.swift:12`) and `ReplyVoice` is an iOS/macOS type.
c-session had already replicated the load-bearing case in `AudioExclusivityCrossSurfaceTests`; the
widening restores the ORIGINAL two on the platform that ships, and both are green.

### Already satisfied inside the wave — recorded so nothing is chased twice

| Request | Satisfied by | Evidence I checked |
|---|---|---|
| c-guards §Requests 2 — splice three `workboard.sync.banner.*` rows | c-copy-docs | main catalog 2242 → **2245**; the three `en` values are byte-equal to c-guards' declared `defaultValue`s, curly apostrophes included (§5) |
| c-recovery-core §Requests 2 — re-anchor `HeadlessRetryGuardSpanTests`, then convert the audio-capture guard, in that order | c-lanes | both done in the stated order; `HeadlessRetryGuardSpanTests` 11/0, `WorkboardAudioCaptureTests` 19/0 |
| c-store §Requests 1 — the drainer's `legacyProvenance:` argument | c-drainer | factored into `private static func legacyProvenance(of:)`, all three sites route through it; `WorkCaptureDrainerTests` 10/0 |
| c-drainer §Requests 3 — the two halves of r3s#2 meet | c-store | complementary fixtures, both green |
| copy-b §Requests 1 — the blocking `WorkCaptureInboxTests` failure | fixed before wave C opened | `WorkCaptureInboxTests` **29/0** |
| c-copy-docs §Requests 4 — O-14 closed on the minted-keys side | c-guards + c-copy-docs | O-14 **CLOSED**, §9 |
| c-guards §Requests 3 — O-6 closed | c-guards | `.openPersonalAISettings` and all four observers gone; O-6 **CLOSED**, §9 |
| c-copy-docs §Requests 5 + 6 — run the guard scripts and the macOS build | me | §2.5, §2.2 |

### Not taken — each with its reason

1. **c-lanes §Requests 1 — delete `WorkCaptureRetryCoordinator.swift`.** I VERIFIED the claim: `grep
   -rn WorkCaptureRetryCoordinator Conduck --include='*.swift'` returns five lines and **not one is a
   production call** — a prose reference (`WorkVoiceScreenshotCoordinator.swift:20`), its own two
   lines, an ABSENCE assertion (`WorkboardAudioCaptureTests.swift:748`) and a string literal inside a
   reconstructed fixture (`WorkboardVoiceLaneTests.swift:242`). Deleting it would compile.
   I did not delete it. Removing a production file at the gate re-opens every agent's build
   measurement for zero user-visible gain, and the real question — whether the desk still wants a
   coordinator-shaped fallback at all, or whether `recover` is now the only answer forever — is an
   adjudication, not a tidy-up. **→ O-4 below**, with the grep as evidence so it is a one-line
   decision next round.
2. **c-guards §Requests 1 — collapse the two iCloud banners into one.** Three files, a changed
   initialiser on a shared component (`ICloudUnavailableBanner`) and a Chat call site. Real design in
   a file no wave-C agent owns. **→ O-5.**
3. **c-lanes §Requests 2 + 3 — three more hardcoded `audio/mp4` container claims**
   (`STTClient+Background.swift:267-268` on the Watch lane; `QwenSTTProvider.swift:55`;
   `GeminiSTTProvider.swift:66`). Same defect class as the one c-lanes fixed, on files it does not
   own, and the Watch one is not a defect today (the wrist records AAC M4A natively). **→ O-6.**
4. **c-lanes §Requests 4 — a targeted `recordPublicationState(_:transcript:ifCurrentID:)` on
   `PendingRetryStore`.** Closes a TOCTOU window and drops a whole-slot re-commit to a metadata write.
   A new API on a file c-lanes deliberately did not open. **→ O-7.**
5. **c-session §Requests 2 — whether `ReplyVoice.shared` should register on iOS.** c-session states it
   is harmless today (nothing speaks through `.shared` on iOS) and becomes a hole the day an iOS
   surface does. A product/architecture call. **→ O-8.**
6. **c-store §Requests 4 — `IsolatedWorkStores` adoption outside c-store's and c-drainer's classes.**
   Hygiene. Measured on MY simulator after the full run: **57** `conduck-workasset-tests-*`
   directories and **0** `*-Locks` directories. **→ O-3** (carried from integrate-d's O-2).

Founder/QA-shaped requests (c-copy-docs 1 + 2, c-drainer 6, c-guards 6, c-lanes 6, c-recovery-core 4 +
6, c-session 4, c-store 5) are not integration work; they are consolidated as **O-13** and **O-14**.
The two docs-agent requests (c-drainer 7, c-store 6) are recorded in §Requests — the wave's docs slice
(`c-copy-docs`) is closed and did not carry them.

---

## 2. The gate — every number, the exact lines

Slug `integrate-e`. DerivedData under
`~/Library/Caches/gigaduck-builds/integrate-e/{DerivedData,DerivedDataMac,DerivedDataWatch}`, every
log written there and grepped for `': error: '` and for
`BUILD SUCCEEDED|BUILD FAILED|TEST SUCCEEDED|TEST FAILED|Executed ` — **never judged from a tail or an
exit code**. No `-configuration` passed anywhere. No `/tmp`, no bare `rm -rf`, no throwaway tree copy.

### (1) iOS `build-for-testing` — sim `2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF`, `ios-bft-1.log`
`grep -c ': error: '` = **0**, and:
```
** TEST BUILD SUCCEEDED **
```
**Zero `warning:` lines naming any of my five edited files** (grepped by filename on both platforms).

### (2) macOS signed build, `-destination 'platform=macOS'` — `mac-1.log`
`grep -c ': error: '` = **0**, and:
```
** BUILD SUCCEEDED **
    Signing Identity:     "Apple Development: Peter Krueck (Z4PNDLZK98)"
```
**Signed through the identity override. No `CODE_SIGNING_ALLOWED=NO` fallback used or needed.**

### (3) FULL iOS suite, `test-without-building` — `ios-full-2.log`
```
** TEST EXECUTE SUCCEEDED **
	 Executed 4917 tests, with 1 test skipped and 0 failures (0 unexpected) in 76.988 (78.391) seconds
```
`grep -cE '\.swift:[0-9]+:[0-9]+: error: '` (a compile error) = **0**.
`grep -cE '\.swift:[0-9]+: error: '` (an XCTest failure) = **0**.

**The one skip is the environment pin, verbatim:**
```
GatewayAdapterBriefTests.swift:263: -[ConduckTests.GatewayAdapterBriefTests
testClipboardBriefRevisionPinMatchesPublishedContract] : Test skipped - No website source at
/Users/peterkruck/repos/GigaDuck/.codex/worktrees/website/src/lib/adapter-contracts.ts — the
clipboard brief's pin (revision 1.10) was NOT verified against the published contract.
```
A missing sibling checkout, as fix-verify §4 and integrate-d §3 both characterised it. **1 skip, not
the plan's 2** — unchanged from integrate-d.

**The FIRST full run was NOT green, and the reason was my simulator, not the tree — §3 has the whole
story.** `ios-full-1.log`: `Executed 4917 tests, with 1 test skipped and 5 failures`. All five traced
to one stale TCC row on `2B6E0EAC`; cleared with `xcrun simctl privacy … reset all
ai.gigaduck.AgentRelay`; `ios-full-2.log` is the re-run with **no code change between them**.

### (4) FULL watch suite — sim `28AC563B-42C1-4E66-940D-77E63B07918B`, `watch-1.log`
```
** TEST SUCCEEDED **
	 Executed 232 tests, with 0 failures (0 unexpected) in 9.470 (9.553) seconds
```
0 compile-error anchors, 0 XCTest-failure anchors. **232 exactly, as expected** — c-recovery-core's
new `AppError` case reaches the wrist build (`Models/AppError.swift` is a Watch target member) and it
links; c-store's conditional region in `ConversationStore.swift` (also a Watch member) is compiled out
on the wrist and nothing moved. Neither agent could run this suite; it is proven here.

### (5) Guard scripts, from the worktree root
```
✓ storage seam intact — 795 Swift files scanned, no raw store
  or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift     exit 0
✓ folder map current — 36 Swift source directories, all mapped,
  and every path the map names exists                                                    exit 0
✓ spec citations resolve — 795 Swift files scanned, 1 quoted
  section name(s), every one a live heading in docs/ai-context/spec.md                   exit 0
```
(786 → 795 files is the wave's nine new sources; every one lands in a directory the map already names,
so no `project.pbxproj` edit was needed and none happened.)

**Spec size guard — PRE-EXISTING FAILURE, not fixed** (plan §E and §F both forbid fixing it), exit
**1**:
```
✗ docs/ai-context/spec.md is 19827 words; the ceiling is 16900.
✗ decisions over their word limit:
    "Sending files and getting them back are two capabilities of one lane"  687 / 650
    "Forgetting a gateway erases the credentials and keeps the colour tag"  701 / 650
```
`wc -w docs/ai-context/spec.md` = **19827** — **identical to integrate-d's number, and ≤ 19827 as the
gate requires.** Both over-limit decisions are unrelated to Work and untouched by wave C. The wave's
only spec edit is net-neutral in length (`git diff --stat docs/ai-context/spec.md` = `4 ++--`).

### (6) `git diff --check`
No output, **exit 0**. `git diff --cached --stat` → **empty** (nothing staged; no commit, no stash, no
checkout, no index operation anywhere in this task). `git status --short` for `Conduck/Configs`,
`Conduck/Conduck.xcodeproj` and `docs/qa` → **empty** on all three.

### (7) Catalogs — `python3 json.load`, all four parse clean
```
Conduck/Conduck/Localizable.xcstrings                    keys = 2245
Conduck/ConduckShareExtension/Localizable.xcstrings      keys =   43
Conduck/ConduckShareExtensionMac/Localizable.xcstrings   keys =   42
Conduck/ConduckWatch Watch App/Localizable.xcstrings     keys =  299
```
Main catalog 2242 → **2245** (+3, c-guards' desk-banner keys, spliced by c-copy-docs). The other three
are untouched — `git status --short -- '*.xcstrings'` lists only the main catalog.

**Bidirectional `workboard.*` audit, mine, over every `.swift` under `Conduck/Conduck`:**
```
source-declared workboard.* keys = 147 · source-referenced = 147 · catalog rows = 147
MISSING from catalog: []   CATALOG-ONLY (unreferenced): []
```
144 → 147, exactly the three new rows. **`defaultValue` vs catalog `en`, all 51 parsed pairs:** the
only two differences are the known formatted-literal exemptions —
`workboard.error.contentTooLong` (`\(limit)` vs `%@`) and `workboard.workspace.drop.image`
(`\(index + 1).\(format.ext)` vs `%1$lld.%2$@`) — which copy-b §Requests 7, strings-audit §Requests 5
and integrate-d §4.7 all say must NOT be "fixed". **I did not fix them.** The three new rows match
their source `defaultValue`s byte for byte, curly apostrophes (U+2019) included.

### (8) Mirror triplets — byte-identical from `import Foundation` onward
| Triplet | bytes below import | app == iOS ext | app == macOS ext | SHA-256 (16) |
|---|---|---|---|---|
| `WorkCaptureEnvelope.swift` | 14801 | **True** | **True** | `45a26a6658c92401` |
| `ShareTargetsSnapshot.swift` | 9728 | **True** | **True** | `a72a7d13d6f1e9ec` |
| `WorkCaptureDirectoryPublisher.swift` | 6198 | **True** | **True** | `777159cc94c1cd9a` |

All nine files carry one SHA-256 within their triplet. All three are **unmodified in `git status`**
this wave. Their drift guards are green in the full run: `WorkCaptureSharePublisherTests` 7/0
(carrying `testThreeCrossProcessPublisherCopiesAreIdenticalBelowImport`) and `WorkCaptureInboxTests`
29/0.
**Path note for the next integrator:** the app-side publisher is
`Conduck/Conduck/Services/WorkCaptureDirectoryPublisher.swift`, NOT `…/Services/Workboard/…` —
integrate-d's §4.8 does not say which, and the wrong guess silently compares nothing.

### (9) Build caches
`ls ~/Library/Caches/gigaduck-builds/` at the start of my task: **`integrate-e` only** — every wave-C
agent (`c-copy`, `c-drainer`, `c-guards`, `c-lanes`, `c-recovery`, `c-session`, `c-store`) had already
run its own `clean-build-cache.sh`, exactly as each fixnote records. **No leftover slug existed, so
none needed removing.** Mine is removed at end of task (§11).
Still outstanding and NOT mine to clean: integrate-c §6.6's ~24 MB `…/scratchpad/verify-tree-1`, which
sits in the session scratchpad rather than under the cleanup script's hardcoded root.

---

## 3. The five first-run failures — diagnosed to the simulator, not the tree

`ios-full-1.log`, verbatim, `file:line` each:

```
AudioExclusivityCrossSurfaceTests.swift:145: testTheComposerMicrophoneIsALiveCaptureTheDeskCanSee
    : failed - the capture must actually be recording for the probe to mean anything
AudioExclusivityCrossSurfaceTests.swift:175: testAStartingMicrophoneStopsACardThatIsBringingAudioUp
    : failed - the capture must actually be recording
AudioExclusivityCrossSurfaceTests.swift:196: testAStartingMicrophoneStopsAReplyThatIsBeingReadAloud
    : XCTAssertEqual failed: ("playing") is not equal to ("idle") - a reply must not go on reading into a live capture
WorkVoiceRecoveryTests.swift:418: testRecordAgainKeepsTheCaptureUntilTheReplacementMicrophoneStarts
    : XCTAssertEqual failed: ("error(Conduck.AppError.speechPermissionDenied)") is not equal to ("error(Conduck.AppError.audioMissingData)")
WorkVoiceRecoveryTests.swift:437: (same case) : failed - the replacement capture must actually be recording
```

Both classes are wave-C files (c-session's and c-recovery-core's), and both agents reported them
green — 7/0 and 18/0 — on their own simulators. So I traced it rather than re-running hopefully.

**Root cause, measured.** `InAppAudioRecorder.startRecording()` runs a speech preflight at `:339`
before it reaches the injected `microphoneStartForTesting` stub at `:376`:
```swift
let speechStatus = await VoicePermissions.ensureSpeechRecognitionForActiveProvider()
if speechStatus == .denied || speechStatus == .restricted { state = .error(.speechPermissionDenied); return }
```
`VoicePermissions.ensureSpeechRecognitionForActiveProvider()` never PROMPTS under XCTest — it returns
`AppleSpeechRunner.currentAuthorizationStatus()`, and its own comment states the assumption:
"(`.notDetermined` in tests → callers proceed, never bail)". On my assigned simulator that assumption
was false. Read directly out of the device's TCC store:
```
sqlite3 ~/Library/Developer/CoreSimulator/Devices/2B6E0EAC…/data/Library/TCC/TCC.db
  "select service, client, auth_value from access;"
→ kTCCServiceSpeechRecognition|ai.gigaduck.AgentRelay|0        (0 = DENIED)
```
A stale denial from some earlier session. `xcrun simctl privacy … grant speech-recognition` and
`… reset speech-recognition` both refuse with `Operation not permitted`; `xcrun simctl privacy
2B6E0EAC… reset all ai.gigaduck.AgentRelay` succeeds and leaves **no row for the bundle**, i.e.
`.notDetermined`.

**Verified with no code change between the two runs.** Targeted re-run immediately after the reset
(`ios-targeted-1.log`, `** TEST EXECUTE SUCCEEDED **`):
```
	 Executed  7 tests, with 0 failures (0 unexpected)   AudioExclusivityCrossSurfaceTests
	 Executed  2 tests, with 0 failures (0 unexpected)   ThreadSpeakerExclusivityTests
	 Executed 18 tests, with 0 failures (0 unexpected)   WorkVoiceRecoveryTests
	 Executed 27 tests, with 0 failures (0 unexpected)   (total)
```
then the clean full run in §2.3.

**I did not "fix" this by weakening anything, and I did not add a skip.** But it is a real fragility
the wave introduced and it is not mine to design away: five cases hard-FAIL — they do not skip — on
any machine whose Speech Recognition TCC row is `denied` or `restricted`, which includes a founder
device where someone once tapped Don't Allow and any CI image that pre-seeds TCC. AGENTS.md's rule is
"skips are expected, failures are not", and this is a failure carrying no information about the code.
Recorded as **O-1** with the two candidate remedies.

---

## 4. Test-count reconciliation — 4874 → 4917, exact, zero drift

Baseline: integrate-d's full run, **4874 executed / 1 skipped / 0 failures**.

| Slice | Class movement | Δ |
|---|---|---|
| c-copy-docs | `WorkboardCopyTruthGuardTests` 4 → 6 | **+2** |
| c-drainer | `WorkCaptureInboxLeaseTests` 15 → 17 · `WorkCaptureDrainerTests` 9 → 10 · `WorkCaptureDrainerTakeoverTests` NEW 1 | **+4** |
| c-guards | `WorkboardDeskPresentationTests` NEW 6 · `WorkboardAvailabilityTests` 9 → 10 · `WorkboardDeskSurfaceDriftGuardTests` 4 → 1 | **+4** |
| c-lanes | `WorkboardVoiceLaneTests` 12 → 11 (three retry-surface guards retired, two new source-scoped cases) | **−1** |
| c-recovery-core | `WorkVoiceRecoveryTests` NEW 18 · `PendingRetryDestinationTests` 3 → 6 | **+21** |
| c-session | `AudioExclusivityCrossSurfaceTests` NEW 7 | **+7** |
| c-store | `WorkboardPublicationLockTests` NEW 2 · `WorkboardDeskUpsertTests` 14 → 15 · `WorkboardLiveRepositorySupportTests` 5 → 6 | **+4** |
| **integrate-e (me)** | `ThreadSpeakerExclusivityTests` 0 → 2 (§1e; the gate widened, no case added) | **+2** |
| | **net** | **+43** |

`4874 + 43 = 4917`. **Measured: 4917.** Zero drift — no case was silently lost or silently added
anywhere in the wave.

**One fixnote's own arithmetic is off by one, and the tree is right.** c-store's "Suite delta for the
orchestrator" says **+3** while enumerating three movements that sum to **+4** (2 + 1 + 1); its own
per-class table is correct and matches the tree. Recorded so Codex does not read the discrepancy as a
lost case. c-store's separately-measured in-flight full run (4906) predates c-copy-docs' splice,
c-guards' landing and my two, so it does not contradict this.

**Per-class verification from `ios-full-2.log` — every number matches its fixnote, 0 failures each:**
```
WorkboardCopyTruthGuardTests        6/0    WorkVoiceRecoveryTests             18/0
WorkCaptureInboxLeaseTests         17/0    PendingRetryDestinationTests        6/0
WorkCaptureDrainerTests            10/0    AudioExclusivityCrossSurfaceTests   7/0
WorkCaptureDrainerTakeoverTests     1/0    WorkboardPublicationLockTests       2/0
WorkboardDeskPresentationTests      6/0    WorkboardDeskUpsertTests           15/0
WorkboardAvailabilityTests         10/0    WorkboardLiveRepositorySupportTest  6/0
WorkboardDeskSurfaceDriftGuard      1/0    ThreadSpeakerExclusivityTests       2/0
WorkboardVoiceLaneTests            11/0    AppErrorCodeContractTests          21/0
WorkCaptureInboxTests              29/0    AppErrorTroubleshootableTests       2/0
WorkAssetVaultTests                19/0    WorkboardBlobSeamPlatformGuard      1/0
WorkCaptureDrainerDurabilityTests   8/0    WorkboardBlobPublicationTests      21/0
WorkboardAudioCaptureTests         19/0    WorkboardChatCaptureTests           8/0
WorkboardAudioCardTests            27/0    ConversationStoreAtomicWorkCapture  4/0
WorkboardOpenPathTests              6/0    WorkboardBoardProjectionTests       4/0
WorkboardTwoStoreLoadTests          7/0    WorkboardWorkspaceCaptureTests      5/0
WorkboardBlobGCTests                6/0    WorkCaptureSharePublisherTests      7/0
HeadlessRetryGuardSpanTests        11/0    MacWorkbenchShellDriftGuardTests    4/0
STTKeyBlackoutLaneTests            11/0    WorkboardMaterialBoardActionsTests 12/0
ErrorSurfaceDriftGuardTests         7/0    WorkboardDeskViewModelTests         5/0
                                           WorkboardDeskIdentityDriftTests  ABSENT ✓
```
**Failures summed across every suite in the log: 0.**

---

## 5. Files I changed

| File | Symbol | Why |
|---|---|---|
| `Conduck/ConduckTests/AppErrorCodeContractTests.swift` | `forwardTable`, `testForwardTableIsExhaustiveOverEmittedCodes` | §1a |
| `Conduck/ConduckTests/AppErrorTroubleshootableTests.swift` | `testDenyListCasesAreNotTroubleshootable` | §1b |
| `Conduck/ConduckTests/WorkboardBlobSeamPlatformGuardTests.swift` | `payloadSeams` | §1c |
| `Conduck/ConduckTests/ThreadSpeakerExclusivityTests.swift` | file gate + header | §1e |
| `Conduck/Conduck/Services/TTS/SpeechPlayer.swift` | `pause()` doc comment | §1d |
| `Conduck/Conduck/Services/TTS/SpeechChunkQueue.swift` | file header, AUDIO SESSION bullet | §1d |

No new file, no deleted file, no `.xcstrings`, no `.pbxproj`, no `Identity-Override.xcconfig`, nothing
under `docs/qa/`. Four of six are test files; the other two are comments.

---

## 6. Catalog

**Keys I ADDED in source: NONE.** **Keys I made DEAD: NONE.** No `.xcstrings` file was opened by me.

**The wave's whole string story, verified end to end (§2.7).** c-guards declared three keys in
`Views/Workboard/WorkboardSyncBannerPolicy.swift`; c-copy-docs spliced exactly those three rows and
nothing else; the main catalog went 2242 → 2245 and `workboard.*` 144 → 147:

| Key | `= defaultValue` (source, and catalog `en` — byte-equal) |
|---|---|
| `workboard.sync.banner.noAccount` | `iCloud is signed out — your cards won’t sync across your devices.` |
| `workboard.sync.banner.restricted` | `iCloud is restricted on this device — your cards can’t sync.` |
| `workboard.sync.banner.quotaExceeded` | `Your iCloud storage is full — new cards can’t sync to your other devices.` |

Nothing was retired: `workboard.voice.privacy` kept its key and moved both halves together;
`workboard.voice.error.deskWrite` was RE-HOMED from the deleted `WorkVoiceCaptureError` onto
`AppError.workDeskWriteFailed` with the same key, value and apostrophe; `sync.icloud.banner.*` all
stay live in Chat; `workboard.capture.note` stays live on the drainer's note branch.
c-drainer, c-lanes, c-recovery-core, c-session and c-store each report ADDED: none / DEAD: none, and
my audit confirms it — 147/147/147, no orphan, no missing row.

---

## 7. Refuted

**Mine: EMPTY.** Every request I acted on was verified against the current code first (§1a–e each name
the file:line I traced), and every one held. Nothing in wave C was refuted by me.

**The wave's own `## Refuted` sections, verbatim, so round 4 needs no other file:**

- **c-copy-docs** — "Empty. All four findings held against the current code."
- **c-drainer** — "**Empty.** r3s#5 held in full, and both adjudications (O-2, O-18) held with it."
- **c-guards** — "**Nothing.** The one finding (r3a#8) and both adjudications (GUARD-body, O-6) held
  against the current tree when traced by call path before any edit… The only narrowing is the
  composer clause in §1.1, and it is stated there as a narrowing rather than a refusal."
- **c-lanes** — "**None.** All three findings were traced against the current tree by call path before
  any code changed, and all three hold exactly as written." Two qualifications it states as such:
  *"r3a#6 is CONSERVATIVE"* (the sharper cost is the in-process Apple provider, where the file NAME is
  the only container signal), and *"O-12's proposed mechanism was not implemented literally"* — met by
  deriving MIME and filename inside `STTClient` from the same bytes, "which makes disagreement
  unrepresentable rather than merely avoided"; the adjudication's other two clauses are implemented as
  written.
- **c-recovery-core** — "**None.** All three findings and both adjudications held against the current
  tree when traced by call path before any code changed." One qualification: r3a#4's third clause
  offered "queue, or refuse-with-error" and neither was implemented literally — "the capture surface
  declines to arm rather than the store refusing", meeting the clause's requirement "in the direction
  that destroys something irreplaceable".
- **c-session** — "**None.** The finding and both adjudications held against the current code, traced
  by call path before any edit."
- **c-store** — "**Nothing.** r3s#1, #2, #3 and #4 and adjudications O-1, O-2 and O-18 all held
  against the current tree when traced by call path, and all four mechanisms are shown red on the
  reverted tree (§6). r3s#6 is not refuted either — its evidence holds — but the fix it proposes (a
  helper process with a peak-memory metric) is unavailable in this bundle, so the instructed fallback
  was taken: the bound is deleted and the gap is recorded as accepted debt."

---

## 8. Guard verdicts

### Mine (4 — all KEPT, three EXTENDED, none converted, none deleted, none weakened)

| Test | Verdict | Evidence |
|---|---|---|
| `AppErrorCodeContractTests.testForwardTableIsExhaustiveOverEmittedCodes` | **KEPT, RE-PINNED 77 → 78** | The completeness ceiling now moves with the enum in both directions (§1a). Its own comment instructs exactly this: "the fix is to RECORD the new code here, never to loosen the assertion." 21/0. |
| `AppErrorCodeContractTests.testEveryCaseEmitsItsLockedLiteralCode` / `…RoundTripsBackToItsCase` | **KEPT, WIDENED by one row** | Both loop the table, so `.workDeskWriteFailed` is now pinned forward AND inverse. No `collapseToAPIFailure` entry — 78 carries no associated value. |
| `AppErrorTroubleshootableTests.testDenyListCasesAreNotTroubleshootable` | **KEPT, EXTENDED by two rows** | `.workDeskWriteFailed` and `.turnStoppedBeforeSend`, both provable `false` at `AppError.swift:1318-1338`. The doc's "complete, exhaustive" is now true. 2/0. |
| `WorkboardBlobSeamPlatformGuardTests.testThePayloadSeamsAreCompiledOutOfTheWatchBuild` | **KEPT, EXTENDED by one seam** | `var workMaterialPublicationLockHoldForTesting`, verified at `ConversationStore.swift:4737` inside `CONDUCK_TESTING` (`:4450`) and `!os(watchOS)` (`:4575-4803`). 1/0. |

Not a guard, recorded beside them: **`ThreadSpeakerExclusivityTests`' compile gate widened
`#if os(macOS)` → `#if os(macOS) || os(iOS)`** with the header clause corrected. The two cases are
byte-identical; only the platform they run on changed (0 → 2 on the iOS sim, §1e).

**I deleted no guard, narrowed no guard, and re-aimed no assertion.** No `#if CONDUCK_TESTING` seam
was added, moved or removed by me.

### The wave's, verbatim (every conversion/keep/deletion, for round 4)

**c-copy-docs** — converted one, added two, deleted none.
- `WorkboardCopyTruthGuardTests.testNoWorkStringDescribesSendingDispatchingOrADraft` — **KEPT, but its
  exemption is now scoped.** "The blanket `inertnessPhrases` strip was the mechanism that hid r3a#3,
  so it survives only for keys not in `outboundHopKeys`. Measured: with the pre-fix value in place
  this test now fails (CF-1), where before it passed. No assertion was weakened and no key was removed
  from the scan — the scope narrowed in the direction of catching more."
- `testTheVoiceSheetNamesTheSpeechProviderRatherThanPromisingInertness` — **ADDED.**
- `testTheDeskSyncBannerSpeaksAboutCardsRatherThanConversations` — **ADDED.**
- "Deleted or narrowed: none." `testTheTutorialSyncLineNamesTheDeviceLocalLane`,
  `testEveryWorkKeyInSourceHasACatalogRow`, `testEveryWorkCatalogRowIsReferencedInSource` untouched;
  class 4 → 6.

**c-drainer** — "**None assigned, none touched.** My brief names no `t#N` guard item, and no file I own
contains a source-text drift guard. I converted nothing, kept nothing on that basis, and deleted
nothing."

**c-guards** — three conversions, three keeps, one conversion of an availability guard.
- `WorkboardDeskSurfaceDriftGuardTests.testTheDeskRendersTheFixedIdentityAndResolvesNoItem` —
  **CONVERTED, then DELETED.** Successor
  `WorkboardDeskPresentationTests.testTheDeskBeforeItsFirstCardIsStillTheDeskAtTheFixedIdentity` (+
  `testADeskCarryingCardsDrawsTheBoardRatherThanTheInvitation`); fails on the reverted code, measured;
  deleted only after the successor was green.
- `…testTheEmptyDeskShowsTheEmptyStateAndKeepsTheComposer` — **CONVERTED, then DELETED.** Successor
  `testAnEmptyDeskAndAFailedLoadAreDifferentSurfaces`; "honest limit on the composer's *mounting*
  stated in §1.1".
- `…testEveryWorkDeepLinkResolvesToTheDeskThroughTheRefreshCoordinator` — **CONVERTED, then DELETED.**
  Successors `testAWorkDeepLinkRevealsTheDeskAndAsksForTheReload` and
  `testTheDeepLinksReloadLandsBecauseTheDeskWasRevealedFirst`, the second driving the real
  `WorkCaptureRefreshCoordinator` with no store anywhere. Both measured red on the reverted code.
- `…testTheRefreshCoordinatorIsTheOnlyBoardLoadOwner` — **KEPT** (GUARD-absence, per adjudication).
- `WorkboardAvailabilityTests.testTheDeskBannerReadsAccountStateRatherThanTheLastSyncEvent` —
  **CONVERTED, then DELETED.** Successors `testTheDeskBannerShowsOnlyForAnAccountStateThePersonCanFix`
  and `testTheDeskBannerNamesCardsRatherThanConversations` (measured red pre-fix).
- `WorkboardAvailabilityTests.testTheAvailabilityProjectionNeverNamesThePayloadColumn` — **KEPT**,
  untouched.
- `WorkCaptureSharePublisherTests.testBothShareExtensionsPublishThroughThePublisherRatherThanByHand` ·
  `WorkboardBlobSeamPlatformGuardTests.testThePayloadSeamsAreCompiledOutOfTheWatchBuild` — **KEPT**,
  not opened. *(I later extended the second by one row — §8 mine.)*
- `MacWorkbenchShellDriftGuardTests` (4 cases) — **KEPT**, not opened; all four still pass "checked,
  not assumed".

**c-lanes** — one conversion+rename, one re-anchor, three retirements, four conversions, two additions.
- `WorkboardAudioCaptureTests.testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes` —
  **CONVERTED and RENAMED** to `testEveryRetrySurfaceMakesItsDeskDecisionThroughTheOneRecovery`. "It no
  longer orders two calls; it asserts a CALL-SITE POLICY, comment-stripped, per surface file:
  `WorkVoiceCaptureCoordinator.recover(` appears **exactly once**,
  `WorkCaptureRetryCoordinator.publish(` **not at all**, `WorkVoiceCaptureCoordinator.attachTranscript(`
  **not at all**."
- `HeadlessRetryGuardSpanTests` — **RE-ANCHORED**, exactly as c-recovery-core §Requests 2(a) specifies
  and no further: needle `"WorkCaptureRetryCoordinator.publish"` → `"WorkVoiceCaptureCoordinator.recover("`,
  "**the ordering it asserts is unchanged**… the disarm count still pinned at exactly 3. No assertion
  was weakened, added or removed. 11/11."
- `WorkboardVoiceLaneTests`' three retry-surface guards (cases 10, 11, 12 at `801b937`) — **RETIRED**,
  as r3a#11 directs. "What they asserted… is now either structurally impossible… or asserted
  behaviourally against a real store in `WorkVoiceRecoveryTests`. Nothing they covered is unguarded."
- `WorkboardVoiceLaneTests`' three intent guards (cases 1, 2, 3) and their control (case 9) —
  **CONVERTED, not deleted**, into `WorkVoiceIntentLaneRule` (12 rules) + one predicate, run by two
  cases. "Every rule now has a fixture that fails on it, which is precisely what r3a#11 says the old
  controls did not have."
- Two NEW source-scoped assertions, "both narrow and both paired with behaviour":
  `testBothRetrySurfacesStageTheRecoveredBytesUnderTheirOwnContainer` and
  `testTheUploadBuildsItsAudioPartFromThatAnswer`.
- "**I added no test seam.**"

**c-recovery-core** — one keep, two seams added.
- `WorkboardAudioCaptureTests.testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes` — **KEPT,
  unchanged.** "Its conversion is exactly O-7's step (b) and is unsatisfiable until c-lanes routes the
  two surfaces through `recover`… re-anchoring it now would fail on my own tree while deleting the only
  thing holding `ContentView` and `DictationService` in step." *(c-lanes then did it — the sequencing
  worked.)*
- `HeadlessRetryGuardSpanTests` — not mine, not touched, 11/11 green.
- "**I added no source-text guard.** All 18 new cases are behavioural: 13 drive `recover` against a
  real in-memory store, 5 drive the recorder's own orchestration through the existing injected seams.
  Two carry explicit negative controls."
- **Test seams added (2, both `#if CONDUCK_TESTING`, both on `InAppAudioRecorder`):**
  `retryLaneForTesting` and `microphoneStartForTesting`. "Neither is reachable in a release build."
  The second "stands exactly where `AudioRecorder.startRecording()` does, inside the same `do`, so
  every path around it — the speech preflight, the macOS lease, the error mapping, the release, the
  state — is the production path." *(That preflight is what §3's stale TCC row tripped.)*
- "The macOS `SpeechExclusivity` registration/claim regions are byte-for-byte untouched."

**c-session** — "**None.** I converted, kept and deleted no source-text guard: every case I added is
behavioural, and the five source-text guards that failed in my runs (`WorkboardVoiceLaneTests`) belong
to another agent's files and were left exactly as they are." *(Those five were mid-edit foreign
landings; all green now — `WorkboardVoiceLaneTests` 11/0.)*

**c-store** — "**None.** No `t#N` guard item was assigned to me this wave, and I converted, kept or
deleted no source-text guard. `WorkboardBlobSeamPlatformGuardTests.…` was left exactly as it stands
and passes — its `payloadSeams` list is a subset check, so my new seam is simply unlisted; see
§Requests 3." *(Taken — §1c.)*

---

## 9. Open items — integrate-d's O-1…O-17 reconciled, renumbered for the handoff

**Closed by wave C (nine), with the evidence I checked:**

| Was | Item | Closed by |
|---|---|---|
| O-1 | Cross-process publication residue | c-store's `WorkMaterialPublicationLock` — an App-Group `flock` beside the store, acquired before any blob lookup and released after every rollback path. The schema column is NOT owed; the model can deploy. **Residual is verification, not design** → O-12. |
| O-3 | Mic authority unregistered on iOS | c-session — `ThreadSpeaker`'s registration/claims are `#if os(macOS) \|\| os(iOS)` (`ThreadSpeaker.swift:59-70, 180-184, 217-221, 356-357, 492`); `AudioExclusivityCrossSurfaceTests` 7/0 and `ThreadSpeakerExclusivityTests` 2/0 now assert it on iOS |
| O-6 | `.openPersonalAISettings` had no poster | c-guards — name, four observers and the orphaned `presentPersonalAISettings()` all deleted; `grep` clean |
| O-7 | Hoist the attach/fallback decision, re-anchor the two guards | c-recovery-core built `recover`; c-lanes routed both surfaces and re-anchored `HeadlessRetryGuardSpanTests` first, then converted the call-site guard — the exact order O-7 demanded |
| O-9 | `PendingRetryMetadata.transcript` | c-recovery-core — `let transcript: String?` at `PendingRetryStore.swift:92`, additive-optional with a `= nil` default, decodes nil for existing records |
| O-10 | A dedicated `AppError` for a desk-write failure | c-recovery-core — `.workDeskWriteFailed`, code 78, `isRetryable` + `shouldPreserveForRetry`, deny-listed for Diagnostics; now pinned on the wire by §1a–b |
| O-11 | Should a recovered `.work` retry republish? | c-recovery-core — "republish only when metadata proves phase one never landed", implemented as adjudicated |
| O-12 | Container sniffing at the retry staging sites | c-lanes — `SourceAudioContainer.sniff` at both staging sites and inside `STTClient.multipartAudioPart(for:)`, WAV coverage on both lanes |
| O-14 | The desk banner said "your conversations" | c-guards minted `workboard.sync.banner.*` (3 keys), c-copy-docs spliced them. Chat's `sync.icloud.banner.*` untouched — nothing widened, nothing lost |
| O-17 | The two-store fact stated in both docs | Resolved to ONE home: `project-structure.md:126` carries `Core`/`Blobs`; `spec.md` no longer names it (`grep -n Blobs docs/ai-context/spec.md` → no match). Word count unchanged at 19827 |

**Partially closed:** O-13 — c-session took the audio-session half (one owner, `SpokenAudioSession`,
and `ChatPlaybackSession.swift` deleted). Three of its four consolidations remain → **O-10** below.

**Open, renumbered:**

| # | Item | Why it is open, and who it belongs to |
|---|---|---|
| **O-1** | **NEW — five cases hard-FAIL on a machine whose Speech Recognition TCC row is `denied`/`restricted`.** `InAppAudioRecorder.startRecording()` runs the speech preflight (`:339`) ABOVE the `microphoneStartForTesting` seam (`:376`), and `VoicePermissions.ensureSpeechRecognitionForActiveProvider()` returns the live status under XCTest — its comment assumes `.notDetermined`. My sim carried a stale `kTCCServiceSpeechRecognition\|ai.gigaduck.AgentRelay\|0`; §3 has the full trace and the `simctl privacy reset all` that clears it. Two candidate remedies, both one-line, neither mine to pick: an `XCTSkipUnless` on the status in the two classes' `makeRecorder()` (loses the assertions silently where it matters most — a founder device), or a third `#if CONDUCK_TESTING` seam letting a test pin the preflight verdict (widens the seam surface). **A CI image that pre-seeds TCC turns this into a red suite for a reason that is not the code.** |
| **O-2** | **The cross-process publication lock is proven with two store instances in ONE process, never two.** c-store measured `flock`'s per-descriptor scope as a faithful stand-in and c-drainer's takeover case asserts the ordering it buys; neither built a two-executable harness, and the App-Group path `<AppGroup>/Conversations-Locks/` is exercised only by derivation, never on a signed device. → Gate-2 founder QA (c-store §Requests 5, c-drainer §Requests 6). |
| **O-3** | `IsolatedWorkStores` adoption in the classes c-store and c-drainer did not own (`WorkAssetVaultTests`, `WorkboardMaterialBoardActionsTests`, `WorkboardDeskViewModelTests`, `WorkboardAudioCaptureTests`, every other `ConversationStore(inMemory:)` builder). Measured by me after the full run on `2B6E0EAC`: **57** `conduck-workasset-tests-*` directories, **0** `*-Locks`. Hygiene, not correctness. Recipe in c-store §Requests 4. |
| **O-4** | **`WorkCaptureRetryCoordinator.swift` has ZERO production callers** — verified: `grep -rn WorkCaptureRetryCoordinator Conduck --include='*.swift'` returns a prose reference (`WorkVoiceScreenshotCoordinator.swift:20`), the file's own two lines, an ABSENCE assertion (`WorkboardAudioCaptureTests.swift:748`) and a fixture string literal (`WorkboardVoiceLaneTests.swift:242`). Deleting it compiles. The decision is whether the desk keeps a coordinator-shaped fallback at all now that `recover` is the single answer. c-lanes §Requests 1. |
| **O-5** | Collapse the two iCloud banners. `WorkboardSyncBannerPolicy` (the durable half: the desk's copy + the show decision) should survive; `ICloudUnavailableBanner` gains a `message` parameter and `WorkboardSyncBanner` dies. The chrome is currently stated twice. Three lines across files no wave-C agent owns. c-guards §Requests 1. |
| **O-6** | Three more hardcoded `audio/mp4`/`audio.m4a` container claims, all outside O-12's scope: `STTClient+Background.swift:267-268` (the Watch lane — true today, false the moment anything but the wrist's native AAC feeds it), `QwenSTTProvider.swift:55`, `GeminiSTTProvider.swift:66` (both reachable by a Work retry if selected). Same defect class as the one c-lanes fixed. c-lanes §Requests 2 + 3. |
| **O-7** | `PendingRetryStore.recordPublicationState(_:transcript:ifCurrentID:)` — a metadata-only write inside the same `withExclusiveLock` as the ownership check, exactly like `updateAttemptIfCurrent`. Today `parkRecoveryState` re-commits the whole slot (audio bytes included) to record one field, guarded by a `currentSlot()` read that is a TOCTOU window however small. c-lanes §Requests 4. |
| **O-8** | Should `ReplyVoice.shared` register on iOS? Its self-registration (`ReplyVoice.swift:194-199`) and `SpeechExclusivityParty` conformance (`:1177-1188`) are `#if os(macOS)`. Harmless today (nothing speaks through `.shared` on iOS); a hole the day an iOS surface does. c-session §Requests 2. |
| **O-9** | Carry `WorkMaterial.filename` onto `WorkboardMaterialSnapshot` (`WorkboardViewModel.swift:79` has no `filename`) so a voice note's preview copy gets its real `.m4a` rather than one derived from `audio/mp4`. Playable and correct today, just not the stored name. fix2-audio-card §3 / fix2-canvas §3. |
| **O-10** | The three consolidations of the old O-13 that remain after c-session took the session half: the board-tile radius `13` literal into `WorkboardMetrics`; one shared `WorkboardCardActions` for the two cards' menus; `onCancel` → `onDismiss` on the voice sheet's hand-off (`WorkboardComponents.swift:228`, `WorkboardCaptureCanvas.swift:142`). Behaviour-neutral. |
| **O-11** | The availability glyph/tint/label mapping is still duplicated between `WorkboardSourceCard` and `WorkboardAudioCardView`'s chip — no `WorkboardAvailabilityChip` exists (grep clean). The wave shared the ACTION rule (`WorkboardCardActionPolicy`) and deliberately left the COPY rule alone. fix2-canvas §4. |
| **O-12** | `WorkboardViewModel.workspaceStatus` → `transientStatus`/`deskStatus` (`WorkboardViewModel.swift:408,610`, plus reader lines in `WorkboardView.swift`) — the last "workspace"-named member. Vocabulary only. vm-collapse §2. |
| **O-13** | **The external-storage ceiling memory bound is uncovered by DECISION, not oversight.** c-store deleted r3s#6's bound (a helper process with a high-water mark or an allocator instrument exists nowhere in this bundle) and wrote the gap into the surviving test's doc comment. Accepted debt; reinstating it is its own session. |
| **O-14** | **Watch catalog drift, pre-existing since `efa553e`:** `WatchRecordingService.swift:760` declares `watch.capture.defaultGatewayNotSetUp` = "…isn't **available**…" while the Watch catalog row reads "…isn't **set up**…". The catalog wins at runtime, so the source lies to the next reader. Not a Work string. copy-b §5. |
| **O-15** | **Spec-size debt** — 19827 words against a 16900 ceiling, two unrelated decisions over their 650-word limits. Out of scope by plan §"Out of scope"; recorded as a standing decision. c-copy-docs spent the one sentence copy-b had nominated, so the next cut must come from somewhere else. |
| **O-16** | **Founder copy calls, consolidated.** (a) The voice sheet's new privacy sentence — the first place the product tells a person a recording reaches a provider; c-copy-docs chose unconditional over conditional. (b) The three desk-banner sentences. (c) `workboard.workspace.drop.overlay.caption` = "…Nothing is sent." — true in this product's vocabulary, but it is the surface a person watches while a payload mirrors to their iCloud (c-copy-docs §Requests 2). (d) The recovered-note title: a Work voice capture whose card is gone names its note from the transcript's first line, where the share path says "Share note" (c-recovery-core §Deviations 3). (e) copy-b §Requests 2's tutorial line and large-file confirm. |
| **O-17** | **Founder QA (Gate 2), consolidated — 16 items across five fixnotes, none reachable by a unit test.** c-drainer 6 (reclaimed share while backgrounded > 5 min) · c-guards 6 a–c (signed-out iCloud banner + one dismissal, Work deep link, Personal AI from the Chat banner) · c-lanes 6 a–d (Shortcut→Work before first unlock; STT failure in airplane mode; a retry that must complete with NO network; the macOS menu bar) · c-recovery-core 6 a–c (Record Again; force-quit mid-retry; Chat retry displacing a Work one) · c-session 4 a–e (mic vs desk note, read-aloud vs note, iPad split view, CarPlay refusal, duck/un-duck) · c-store 5 a–b (simultaneous Shortcut + in-app capture of one item; a refused reattach giving the original file back). Plus plan §C's Gate 2 in full: real-CloudKit export/import across both stores, delete/reinstall reimport, actual watch exclusion. **Byte sync does not reach a release build without it.** |

---

## Requests

1. **Orchestrator — the gate is CLOSED on the merged tree.** Every item plan §F names has been run by
   me and is quoted in §2: iOS `build-for-testing`, signed macOS build, full iOS suite (4917 / 1 skip /
   0 fail), full watch suite (232 / 0), the three guard scripts, `git diff --check`, all four catalogs
   parsing, the mirror triplets, and the bidirectional string audit. The spec-size guard exits 1 and
   **must be recorded as pre-existing**, per plan §E — 19827 words, identical to the baseline.
2. **The commit must include the file deletions and the untracked files.** ` D
   Conduck/Conduck/Services/TTS/ChatPlaybackSession.swift` presents as unstaged, and **ten** files are
   untracked: `SpokenAudioSession.swift`, `WorkMaterialPublicationLock.swift`,
   `WorkboardDeepLinkRoute.swift`, `WorkboardDeskPresentation.swift`, `WorkboardSyncBannerPolicy.swift`,
   `AudioExclusivityCrossSurfaceTests.swift`, `WorkCaptureDrainerTakeoverTests.swift`,
   `WorkVoiceRecoveryTests.swift`, `WorkboardDeskPresentationTests.swift`,
   `WorkboardPublicationLockTests.swift`. A `git commit -a` would miss all ten. (Wave B's eight
   untracked files and its one deletion are already in the tree from integrate-d's list.)
3. **Docs agent — three facts are now settled by code and no wave-C fixnote carried them into a
   document.** (a) c-drainer: a capture the app fails to give back to the queue is neither lost nor
   stranded — the process stops counting it as its own and the queue's ordinary recovery pass picks it
   up; no relaunch, no manual step, nothing deleted. (b) c-store: one publication of a material's
   payload is in flight at a time across the whole device, app and headless intent process included,
   through an App-Group advisory lock beside the store. (c) c-store: a reattach that moves a card
   between storage lanes releases the lane it leaves only after the new one is proved readable, so a
   refused reattach gives the card its previous payload back — synced bytes included.
4. **Nobody undo these — they interlock, and each is pinned by a test that measures the cost.** The
   five "nobody undo" lists in c-drainer §1, c-lanes §Requests 5, c-recovery-core §Requests 5,
   c-session §Requests 5 and c-store §Requests 2 all still hold as written after the merge; the full
   suite is the proof that none of them contradicts another.
5. **Whoever runs the next full suite on `2B6E0EAC` — check the TCC row first.** `sqlite3
   ~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Library/TCC/TCC.db "select service, client,
   auth_value from access where client='ai.gigaduck.AgentRelay';"` must return **nothing** (or `2`).
   A `0` costs five red cases that say nothing about the code (§3, O-1).

---

## Deviations

1. **Two rows added to the `isTroubleshootable` deny-list, where the request asked for one** (§1b).
   `.turnStoppedBeforeSend` is the same gap in the same list and the doc's word is "exhaustive".
2. **`ThreadSpeakerExclusivityTests`' compile gate widened, not just its header comment corrected**
   (§1e). The narrower fix would have left a file whose gate contradicts the code it guards. No
   assertion changed; the +2 is measured, and it is the only line of §4's table that is mine.
3. **I did not measure a counterfactual for my own five edits.** Four are guard-list/literal changes
   whose failure mode is an equality between a literal and a table (§1a–c) — an argument from the
   assertion, which the protocol allows and which is stronger here than a rebuild would be. The fifth
   is measured directly (0 → 2 cases). The two comment edits assert nothing.
4. **I reset the simulator's TCC state for `ai.gigaduck.AgentRelay`** (§3). It is environment repair,
   reversible, and scoped to one bundle id on one device; the founder's simulator inventory is
   otherwise untouched. Stated plainly because the first full run's five failures disappeared without
   a code change, and that is exactly the shape of a result that should not be taken on trust.

## What I did NOT verify, plainly

- **No two-process harness** for the publication lock (O-2) and **no signed device** — Gate 2.
- **No UI, no screen.** There is no UI-test target by decision; O-17 is the hand-back.
- **I did not re-run any agent's counterfactual.** Each fixnote records its own measured red run; I
  verified the resulting tree, not their reverted copies.
- **The single skip's subject is unverified by construction** — the website checkout it pins against
  does not exist here, which is what the skip says.
- **`ThreadSpeakerExclusivityTests` on iOS has run twice, both green** (targeted and full). Two cases
  that drive the real `SpeechExclusivity.shared` bus now run on the iOS sim beside c-session's; the
  parties are weak and both runs were clean, but I have not run the suite enough times to call that
  ordering-independent under load.

## Cleanup

`/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh integrate-e` — run at end of
task. **Every log quoted above goes with it** (`ios-bft-1.log`, `ios-full-1.log`, `ios-targeted-1.log`,
`ios-full-2.log`, `mac-1.log`, `watch-1.log`); re-run to reproduce. No bare `rm -rf`, no `/tmp`, no
throwaway tree copy — the gate is on the shared tree by definition. `~/Library/Caches/gigaduck-builds/`
held no other slug before or after.
