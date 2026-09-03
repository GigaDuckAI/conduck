# integrate-f — wave D coheres. FULL GATE GREEN on the merged tree: iOS 4948 / 1 skip / 0 fail · watch 232 / 0 · signed macOS BUILD SUCCEEDED.

Four wave-D fixnotes read in full (`d-store`, `d-retry`, `d-stt`, `d-copy-docs`), plus `integrate-e.md`
for the 4917 baseline and the O-list. **I changed NO file** — every request resolved either as
already-satisfied inside the wave (with the evidence I checked) or as a real design → open item.
**Nothing refuted by me**; every `## Refuted` the wave produced is reproduced verbatim in §7 so Codex
needs no other file. My slug is removed (§10).

---

## 1. Requests resolved, one by one

Twenty-one request items across the four notes. **Eight already satisfied inside the wave** (verified,
not taken on the agent's word), **seven are standing "nobody undo" constraints** recorded in §8, and
**six are real design or ownership calls** → open items O-16…O-21. **I took none as a code change**,
because every one that was actionable had already been done by another wave-D agent.

### Already satisfied inside the wave — verified by me, so nothing is chased twice

| Request | Satisfied by | Evidence I checked |
|---|---|---|
| d-store §Requests 1 — three collision counterfactuals in `WorkboardVoiceLaneTests` / `WorkboardAudioCaptureTests` need re-anchoring onto `invalidMaterialOwner` | d-retry (§Requests 1, §Deviations 3) | The two notes describe the SAME three cases and agree on the outcome. Measured green in my full run: `WorkboardVoiceLaneTests` **11/0**, `WorkboardAudioCaptureTests` **19/0**. Both gates exist: `ConversationStore+Workboard.swift:593` (`if let existing, existing.kind != draft.kind { throw … }`, pre-staging) and `:710` → `requireMatchingKind` at `:1512` (in-transaction, every physical row) |
| d-retry §Requests 1 — the store agent should know which cases depend on the refusal | d-store §Requests 1 | Symmetric to the row above; the two agents reconciled each other mid-wave with no integrator action owed |
| d-store §Requests 5 — docs agent, fold the settled facts | d-copy-docs §2 | `docs/ai-context/spec.md` + `docs/ai-context/project-structure.md` are modified in the tree; `check-spec-cites.sh` exit 0; `wc -w` **19827**, byte-for-byte the integrate-e/-d baseline. d-store's fact (d) is in the Work decision. *Coverage gap recorded as O-21 — three of d-store's six facts and two of d-retry's seven are in no document* |
| d-retry (implicit docs) — the queue's shape | d-copy-docs §3 | `project-structure.md`'s `Services/` row rewritten to the queue; fact (e) in the Audio decision |
| d-copy-docs §Requests 5 — integrator, record the spec-size guard as pre-existing | me | §2.5: exit **1**, 19827 words, identical to baseline. Recorded, not fixed, per plan §E + §F |
| d-copy-docs §Requests 6 — integrate-e §Requests 3's three docs facts are CLOSED | me | Verified independently: (a) claim-handback, (b) App-Group publication lock and (c) prove-then-release are all in the rewritten Work decision. **integrate-e §Requests 3 is CLOSED** |
| integrate-e §Requests 5 — check the TCC row on `2B6E0EAC` before trusting a red run | me + d-copy-docs | `select service, client, auth_value from access where client='ai.gigaduck.AgentRelay'` → **no rows** (exit 0), i.e. `.notDetermined`. §2.3 ran clean first time |
| O-1 (integrate-e's five hard-FAIL cases) — needs a remedy nobody had picked | d-retry | Remedy 2 taken, not the skip: `InAppAudioRecorder.speechAuthorizationForTesting` declared `:206` **inside `#if CONDUCK_TESTING`** (block `:171`–`:223`), consulted at `:348` inside a second `#if CONDUCK_TESTING`/`#else` pair whose `#else` is the untouched production line. Set to `.authorized` at `WorkVoiceRecoveryTests.swift:676` and `AudioExclusivityCrossSurfaceTests.swift:131` — both are the classes' shared recorder factories, so all five cases are covered. **No skip added.** O-1 **CLOSED**, §9 |

### The one genuine cross-note interaction, resolved as an open item

**d-retry §Requests 2 vs d-store's refusal — CONFIRMED by call path, and it is a design call, not a
tidy-up.** `WorkVoiceCaptureCoordinator.recover` republishes a `.phaseOneFailed` capture at
`WorkVoiceCaptureCoordinator.swift:248-259` with `try await publishRecording(captureID: captureID, …)`,
four lines ABOVE the `guard !words.isEmpty` at `:262`. d-store's gate throws
`WorkboardStoreError.invalidMaterialOwner` when the card at that id is of another kind. So a capture
whose id names a foreign-kind card now THROWS out of `recover` instead of overwriting that card —
strictly better — but the entry stays queued and every subsequent retry fails identically, with no path
forward. Reachable only through a genuine UUID collision or a CloudKit merge that produced a
foreign-kind row at a capture id. **Neither agent designed for it and neither should have**: the two
candidate answers (swallow the refusal in the retry lane, or derive a second id inside `recover`) are
both product decisions about what a person sees when a recording can never land. **→ O-16.**

### Not taken — each with its reason

1. **d-retry §Requests 3 + d-copy-docs §Requests 2 — the "Discard recording" affordance.** VERIFIED
   both halves: `grep -rn 'PendingRetryStore.shared.clear()' Conduck --include='*.swift'` → **zero
   hits**, and `isExemptFromExpiry` (`PendingRetryStore.swift:154-156`,
   `resolvedDestination == .work && publicationState != .published`) is consulted by `isExpired` at
   `:161`. So a Work capture the desk never accepted keeps its bytes in the App Group indefinitely and
   there is no user-facing way out. The missing half is a **call site**, not a string — d-copy-docs is
   right not to mint a key `testEveryWorkCatalogRowIsReferencedInSource` would then fail on. A view
   change in a file no wave-D agent owns. **→ O-17** (the two requests are ONE item; resolved against
   each other here).
2. **d-retry §Requests 4 — `DiagnosticsRunner`'s parked-retry row describes the newest of several.**
   `diagnosticSnapshot()` keeps its signature and its meaning for one capture; it cannot say "and two
   more are waiting". Widening it is a Diagnostics-surface decision in a file d-retry deliberately did
   not open. **→ O-18.**
3. **d-stt §Requests 1 — a WAV canary against the Gemini Interactions endpoint.** Only the private
   validation script can answer whether Google accepts `audio/wav` on that model; no fixture test can,
   and I have no network gate here. d-stt's own argument stands (today's fallback already sent WAV
   bytes under an MP4 label, so the WAV label cannot be worse), but it should be learned rather than
   assumed. **→ O-19.**
4. **d-store §Deviations — `deleteSupersededBlobRows` knowingly accepts r4s#3's hazard class inside the
   publishing transaction.** d-store states the shape of the closure (skip rows whose `updatedAt` is
   newer than this publication's own material read — not a sweep) and says narrowing it was not in its
   brief. Accepted debt with a written remedy. **→ O-20.**
5. **Docs coverage of the wave's remaining settled facts.** d-copy-docs folded FIVE facts at zero word
   cost; d-store contributed six and d-retry seven. The colliding-capture refusal, the
   duplicate-blob-rows-are-normal rule, model 16's added column, and d-retry's legacy-key fold are in
   no document. The spec is 2,927 words over its ceiling and plan §"Out of scope" forbids spending on
   it, so the honest answer is to record the gap rather than to open the file. **→ O-21.**

---

## 2. The gate — every number, the exact lines

Slug `integrate-f`. DerivedData under
`~/Library/Caches/gigaduck-builds/integrate-f/{DerivedData,DerivedDataMac,DerivedDataWatch}`, every log
written there and grepped for `': error: '` and for
`BUILD SUCCEEDED|BUILD FAILED|TEST SUCCEEDED|TEST FAILED|Executed ` — **never judged from a tail or an
exit code**. **No `-configuration` passed anywhere.** No `/tmp`, no bare `rm -rf`, no throwaway tree
copy. HEAD `effc6647efaf53747ed516a568183c6009f0e8d2`, branch `feature/agent-workboard`.

### (1) iOS `build-for-testing` — sim `2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF`, `ios-bft-1.log`
`grep -c ': error: '` = **0**, and:
```
** TEST BUILD SUCCEEDED **
```

### (2) macOS signed build, `-destination 'platform=macOS'` — `mac-1.log`
`grep -c ': error: '` = **0**, and:
```
** BUILD SUCCEEDED **
    Signing Identity:     "Apple Development: Peter Krueck (Z4PNDLZK98)"
```
**Signed through the identity override. No `CODE_SIGNING_ALLOWED=NO` fallback used or needed.**

### (3) FULL iOS suite, `test-without-building` — `ios-full-1.log`
```
** TEST EXECUTE SUCCEEDED **
	 Executed 4948 tests, with 1 test skipped and 0 failures (0 unexpected) in 78.241 (79.667) seconds
```
`grep -cE '\.swift:[0-9]+:[0-9]+: error: '` (a compile error) = **0**.
`grep -cE '\.swift:[0-9]+: error: '` (an XCTest failure) = **0**.
**Summed failures across all 354 parsed suite lines: 0. Failure list: EMPTY — nothing to fix or
report.** The run was green on the FIRST attempt; no re-run, no `simctl` reset, no TCC repair needed.

**The one skip is the environment pin, verbatim:**
```
GatewayAdapterBriefTests.swift:263: -[ConduckTests.GatewayAdapterBriefTests
testClipboardBriefRevisionPinMatchesPublishedContract] : Test skipped - No website source at
/Users/peterkruck/repos/GigaDuck/.codex/worktrees/website/src/lib/adapter-contracts.ts — the
clipboard brief's pin (revision 1.10) was NOT verified against the published contract.
```
A missing sibling checkout. **1 skip, as integrate-d and integrate-e both measured** (the plan's "2" is
stale).

**Simulator TCC, checked FIRST per the standing rule:**
```
sqlite3 …/2B6E0EAC…/data/Library/TCC/TCC.db
  "select service, client, auth_value from access where client='ai.gigaduck.AgentRelay';"
→ (no rows), exit 0
```
No row for the bundle = `.notDetermined`. integrate-e's stale-denial row is gone, and d-retry's seam
now makes the five cases independent of it either way.

### (4) FULL watch suite — sim `28AC563B-42C1-4E66-940D-77E63B07918B`, `watch-1.log`
```
** TEST SUCCEEDED **
	 Executed 232 tests, with 0 failures (0 unexpected) in 9.562 (9.640) seconds
```
`grep -c ': error: '` = 0; 0 XCTest-failure anchors. **232 exactly, as expected.** Model 16's added
`WorkMaterial.contentHash` attribute compiles into the wrist (the `.xcdatamodeld` and
`WorkboardRecords.swift` are Watch target members) and d-stt's two provider files
(`GeminiSTTProvider.swift`, `QwenSTTProvider.swift`, both Watch members) link and pass. No wave-D
fixnote predicted a different number.

### (5) Guard scripts, from the worktree root
```
✓ storage seam intact — 798 Swift files scanned, no raw store
  or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift    exit 0
✓ folder map current — 36 Swift source directories, all mapped,
  and every path the map names exists                                                  exit 0
✓ spec citations resolve — 798 Swift files scanned, 1 quoted
  section name(s), every one a live heading in docs/ai-context/spec.md                 exit 0
```
795 → **798** files is exactly wave D's three new test sources; all three land in
`Conduck/ConduckTests/`, a directory the map already names, so no `project.pbxproj` edit was needed and
**none happened** (`git status --short -- '*.pbxproj'` → empty).

**Spec size guard — PRE-EXISTING FAILURE, not fixed** (plan §E and §F both forbid fixing it), exit
**1**:
```
✗ docs/ai-context/spec.md is 19827 words; the ceiling is 16900.
✗ decisions over their word limit:
    "Sending files and getting them back are two capabilities of one lane"  687 / 650
    "Forgetting a gateway erases the credentials and keeps the colour tag"  701 / 650
```
`wc -w docs/ai-context/spec.md` = **19827** — **identical to integrate-d's and integrate-e's number,
and ≤ 19827 as the gate requires**, even though d-copy-docs folded five new facts and repaired four
falsehoods inside it. Both over-limit decisions are unrelated to Work and untouched by wave D.

### (6) `git diff --check`
No output, **exit 0**. `git diff --cached --stat` → **empty** (nothing staged; no commit, no stash, no
checkout, no reset, no index operation anywhere in this task). `git status --short` for
`Conduck/Configs`, `Conduck/Conduck.xcodeproj` and `docs/qa` → **empty** on all three.
`git diff --check` cannot see the three untracked files, so I checked them by hand:
**0 trailing-whitespace lines and 0 tab lines in all three**, and each opens with
`// SPDX-License-Identifier: Apache-2.0` followed by a header comment.

### (7) Catalogs — `python3 json.load`, all four parse clean
```
Conduck/Conduck/Localizable.xcstrings                    keys = 2245   PARSE OK
Conduck/ConduckShareExtension/Localizable.xcstrings      keys =   43   PARSE OK
Conduck/ConduckShareExtensionMac/Localizable.xcstrings   keys =   42   PARSE OK
Conduck/ConduckWatch Watch App/Localizable.xcstrings     keys =  299   PARSE OK
```
**Dict diff against `git show HEAD:` for all four**, top-level keys other than `strings` compare
**equal** in every one:

| Catalog | keys | added / removed / changed |
|---|---|---|
| `Conduck/Conduck/Localizable.xcstrings` | 2245 → **2245** | +0, −0, **~1** (`workboard.voice.privacy`) |
| `Conduck/ConduckShareExtension/…` | 43 → 43 | none |
| `Conduck/ConduckShareExtensionMac/…` | 42 → 42 | none |
| `Conduck/ConduckWatch Watch App/…` | 299 → 299 | none |

**Bidirectional `workboard.*` audit, mine, over every `.swift` under `Conduck/Conduck`:**
```
source-declared workboard.* keys = 147 · source-referenced = 147 · catalog rows = 147
MISSING from catalog: []   CATALOG-ONLY (unreferenced): []
```
Unchanged from integrate-e's 147/147/147 — wave D minted no key and killed none.
**`defaultValue` vs catalog `en`, all 147 parsed pairs:** the only two differences are the known
formatted-literal exemptions — `workboard.error.contentTooLong` (`\(limit)` vs `%@`) and
`workboard.workspace.drop.image` (`\(index + 1).\(format.ext)` vs `%1$lld.%2$@`) — which copy-b
§Requests 7, strings-audit §Requests 5 and integrate-d §4.7 all say must NOT be "fixed". **I did not
fix them.** `workboard.voice.privacy`'s rewritten value is **byte-equal** between
`WorkboardVoiceCaptureView.swift:275-276` and the catalog row, U+2019 apostrophe and both em dashes
included.

### (8) Mirror triplets — byte-identical from `import Foundation` onward
| Triplet | bytes below import | app == iOS ext | app == macOS ext | SHA-256 (16) |
|---|---|---|---|---|
| `WorkCaptureEnvelope.swift` | 14801 | **True** | **True** | `45a26a6658c92401` |
| `ShareTargetsSnapshot.swift` | 9728 | **True** | **True** | `a72a7d13d6f1e9ec` |
| `WorkCaptureDirectoryPublisher.swift` | 6198 | **True** | **True** | `777159cc94c1cd9a` |

All nine files carry one SHA-256 within their triplet, and **all three SHAs are identical to
integrate-e's** — wave D moved no mirror byte. `git status --short` over all nine paths → **empty**.
Their drift guards are green in the full run: `WorkCaptureSharePublisherTests` **7/0**,
`WorkCaptureInboxTests` **29/0**.
**Path note for the next integrator, correcting integrate-e §2.8:** the app-side envelope and snapshot
are `Conduck/Conduck/Models/WorkCaptureEnvelope.swift` and `…/Models/ShareTargetsSnapshot.swift` (NOT
`…/Services/…`); only the publisher lives in `Conduck/Conduck/Services/`. Guessing `Services/` for all
three silently compares nothing.

### (9) Build caches
`ls ~/Library/Caches/gigaduck-builds/` at the start of my task: **EMPTY — no slug at all.** Every
wave-D agent (`d-store`, `d-retry`, `d-stt`, `d-copy`) had already run its own `clean-build-cache.sh`,
exactly as each fixnote records; d-store's `cf-tree` counterfactual copy went with `d-store`. **No
leftover slug existed, so none needed removing.** Mine is removed at end of task (§10) and
`ls ~/Library/Caches/gigaduck-builds/` is **empty** afterwards.
Still outstanding and NOT mine to clean: integrate-c §6.6's ~24 MB `…/scratchpad/verify-tree-1`, which
sits in the session scratchpad rather than under the cleanup script's hardcoded root.

### (10) The model — one contents file, and v15 provably untouched
```
git diff --name-only 651a859..HEAD -- '*.xcdatamodeld/*'
→ Conduck/Conduck/Models/Conversations.xcdatamodeld/.xccurrentversion
  Conduck/Conduck/Models/Conversations.xcdatamodeld/Conversations 16.xcdatamodel/contents
```
Same two paths including the working tree (`git diff --name-only 651a859 -- '*.xcdatamodeld/*'`).
**Among `*.xcdatamodel/*` files — the model contents themselves — `Conversations 16.xcdatamodel/
contents` is the ONLY one changed on the branch since `651a859`**, working tree included:
```
git diff --name-only 651a859 -- 'Conduck/…/Conversations.xcdatamodeld/*.xcdatamodel/*'
→ Conduck/Conduck/Models/Conversations.xcdatamodeld/Conversations 16.xcdatamodel/contents
```
**Stated plainly rather than glossed:** `.xccurrentversion` also differs, and it is not a model. It is
the one-line plist naming the current version, and its whole diff is
`Conversations 15.xcdatamodel` → `Conversations 16.xcdatamodel` — the required companion of adding a
version, without which model 16 would not be the one the store opens. The brief's pathspec
`-- '*.xcdatamodeld'` returns **nothing at all** (git's `*` matches `/`, so it demands a path ENDING in
`.xcdatamodeld`); `'*.xcdatamodeld/*'` is the one that answers the question.

**Version 15 is byte-identical to `651a859`, by SHA-256, not by eyeball:**
```
git show '651a859:…/Conversations 15.xcdatamodel/contents' | shasum -a 256
  007322f275669bf19967c86484e730cb1cb666b4fa2f53b5b78487d3cec849bc  -
shasum -a 256 '…/Conversations 15.xcdatamodel/contents'
  007322f275669bf19967c86484e730cb1cb666b4fa2f53b5b78487d3cec849bc
```
`git diff --stat 651a859 -- '…/Conversations 15.xcdatamodel/contents'` → **empty**. Model 15 exists on
the founder's dev devices and plan §C forbids editing it; it was not edited.
**Model-16 registration is re-proven from the COMPILED model, not from the source file:**
`WorkboardModelMigrationTests` **6/0** in the full run, including
`testV16AddsTheBlobEntityTheMaterialPairingAndTwoCloudKitConfigurations`, which loads
`Conversations 16.mom` out of the built `Conversations.momd`. No `project.pbxproj` edit — the
synchronized group covers the `.xcdatamodeld`, as model 16 itself established.

### (11) Warnings — none added by wave D
Grepped both build logs by filename for every file wave D touched:
`ConversationStore+Workboard.swift` **0/0** (iOS/macOS) · `InAppAudioRecorder.swift` **0/0** ·
`WorkVoiceCaptureCoordinator.swift` **0/0** · `ContentView.swift` **0/0** · `WorkboardRecords.swift`
**0/0** · `GeminiSTTProvider.swift` **0/0** · `QwenSTTProvider.swift` **0/0** ·
`WorkboardVoiceCaptureView.swift` **0/0**.
Three files carry warnings and **all of them are pre-existing**, matching what the agents measured:
`PendingRetryStore.swift` **10/10** (d-retry reported exactly 10, down from 12) · `ConverseIntent.swift`
**4/4** (the four c-lanes recorded) · `DictationService.swift` **0/2** (the two macOS `startDisplayTimer`
ones). `STTClient+Background.swift` carries **21/21**, which no fixnote quoted — I checked them
individually: **15 distinct Swift-6 concurrency diagnostics in the nonisolated `BackgroundSTT` delegate
class**, at lines 115, 123, 124, 242, 269, 289, 329, 342, 350, 364, 406 and 417. **None is at d-stt's
new `backgroundAudioPart(forFileAt:)` (lines 370–392)**, and the one at `:269` is the pre-existing
`writeBodyFile` main-actor crossing whose isolation context d-stt did not move — its diff changes two
argument expressions only. **d-stt added no warning.**

---

## 3. Failures — there were none

**Nothing to list.** `Executed 4948 tests, with 1 test skipped and 0 failures (0 unexpected)`, summed
failures across every suite line in the log = **0**, and 0 XCTest-failure anchors by regex. The TCC row
was checked before the run per the standing rule and was clean, so no red run had to be diagnosed and
nothing was re-run. The watch suite is likewise 0 failures on its first and only run.

---

## 4. Test-count reconciliation — 4917 → 4948, exact, zero drift

Baseline: integrate-e's full run, **4917 executed / 1 skipped / 0 failures**.

| Slice | Class movement | Δ |
|---|---|---|
| d-store | `WorkboardDeskUpsertTests` 15 → 16 · `WorkboardBlobPublicationTests` 21 → 22 · `WorkboardAvailabilityTests` 10 → 11 · `WorkCaptureDrainerCollisionTests` NEW 1 | **+4** |
| d-retry | `PendingRetryQueueTests` NEW 17 · `WorkVoiceRecoveryTests` 18 → 20 | **+19** |
| d-stt | `STTContainerDescriptionTests` NEW 8 | **+8** |
| d-copy-docs | `WorkboardCopyTruthGuardTests` 6 → 6 (two assertions added INSIDE an existing case, which was renamed) | **0** |
| **integrate-f (me)** | no file changed | **0** |
| | **net** | **+31** |

`4917 + 31 = 4948`. **Measured: 4948.** Zero drift — no case was silently lost or silently added
anywhere in the wave. d-store's own in-flight full run also read 4948; it ran late enough to carry
d-retry's and d-stt's work, and d-copy-docs' later slice is +0, which is why the two numbers agree.

**Every fixnote's arithmetic checks out this wave** — unlike wave C, where c-store's summary line was
off by one against its own table. d-store's "+4", d-retry's "+19", d-stt's implicit +8 and
d-copy-docs' explicit "+0" each match the tree exactly.

**Per-class verification from `ios-full-1.log`, every number against its fixnote, 0 failures each:**
```
WorkboardDeskUpsertTests           16/0    PendingRetryQueueTests             17/0
WorkboardBlobPublicationTests      22/0    WorkVoiceRecoveryTests             20/0
WorkboardAvailabilityTests         11/0    STTContainerDescriptionTests        8/0
WorkCaptureDrainerCollisionTests    1/0    WorkboardCopyTruthGuardTests        6/0
WorkboardBlobGCTests                6/0    WorkboardVoiceLaneTests            11/0
WorkboardModelMigrationTests        6/0    WorkboardAudioCaptureTests         19/0
ConversationsModelMigrationTests   20/0    HeadlessRetryGuardSpanTests        11/0
WorkCaptureDrainerTakeoverTests     1/0    AudioExclusivityCrossSurfaceTests   7/0
WorkCaptureDrainerTests            10/0    PendingRetryDestinationTests        6/0
WorkCaptureDrainerDurabilityTests   8/0    ErrorSurfaceDriftGuardTests         7/0
WorkCaptureInboxTests              29/0    VoicePermissionsTests               6/0
WorkCaptureInboxLeaseTests         17/0    STTKeyBlackoutLaneTests            11/0
WorkCaptureSharePublisherTests      7/0    GeminiQwenSTTWireTests             12/0
WorkboardTwoStoreLoadTests          7/0    WorkboardChatCaptureTests           8/0
WorkboardPublicationLockTests       2/0    ConversationStoreAtomicWorkCapture  4/0
WorkboardBlobSeamPlatformGuard      1/0    WorkAssetVaultTests                19/0
WorkboardDeskPresentationTests      6/0    WorkboardAudioCardTests            27/0
WorkboardDeskSurfaceDriftGuard      1/0    MacWorkbenchShellDriftGuardTests    4/0
ThreadSpeakerExclusivityTests       2/0    AppErrorCodeContractTests          21/0
```
**354 suite lines parsed; summed failures across all of them: 0.**

**One prose miscount worth recording so nobody chases it:** d-stt's unchanged-M4A proof calls
`GeminiQwenSTTWireTests` "7 cases"; the class is **12**, is not in git status (unmodified), and is
green. The wire locks it names do pass — only the count in the sentence is wrong, and it is outside the
delta arithmetic, which reconciles exactly.

---

## 5. Files changed — mine: NONE

**I changed no file.** No new file, no deleted file, no `.xcstrings`, no `.pbxproj`, no
`Identity-Override.xcconfig`, nothing under `docs/qa/`, no mirror triplet, no test.

**Wave D's tree, for the orchestrator's commit — 28 modified + 3 untracked:**

Production (12): `Conduck/Conduck/ContentView.swift` · `Intents/ConverseIntent.swift` ·
`MenuBar/DictationService.swift` · `Models/Conversations.xcdatamodeld/Conversations 16.xcdatamodel/
contents` · `Models/Conversations.xcdatamodeld/.xccurrentversion`¹ · `Models/WorkboardRecords.swift` ·
`Services/ConversationStore+Workboard.swift` · `Services/InAppAudioRecorder.swift` ·
`Services/PendingRetryStore.swift` · `Services/STT/Providers/GeminiSTTProvider.swift` ·
`Services/STT/Providers/QwenSTTProvider.swift` · `Services/STTClient+Background.swift` ·
`Services/Workboard/WorkVoiceCaptureCoordinator.swift` ·
`Views/Workboard/WorkboardVoiceCaptureView.swift`
Catalog (1): `Conduck/Conduck/Localizable.xcstrings` (one value)
Docs (2): `docs/ai-context/spec.md` · `docs/ai-context/project-structure.md`
Tests, modified (12): `AudioExclusivityCrossSurfaceTests` · `RemoteAgent/HeadlessRetryGuardSpanTests` ·
`WorkCaptureDrainerTakeoverTests` · `WorkVoiceRecoveryTests` · `WorkboardAudioCaptureTests` ·
`WorkboardAvailabilityTests` · `WorkboardBlobGCTests` · `WorkboardBlobPublicationTests` ·
`WorkboardCopyTruthGuardTests` · `WorkboardDeskUpsertTests` · `WorkboardModelMigrationTests` ·
`WorkboardVoiceLaneTests`
**Untracked — a `git commit -a` would miss all three:**
`Conduck/ConduckTests/PendingRetryQueueTests.swift` ·
`Conduck/ConduckTests/STTContainerDescriptionTests.swift` ·
`Conduck/ConduckTests/WorkCaptureDrainerCollisionTests.swift`

¹ `.xccurrentversion` appears in `git status` only against `651a859`; it is already committed at
`effc664` and is listed here so the model change reads as complete.

---

## 6. Catalog

**Keys I ADDED in source: NONE.** **Keys I made DEAD: NONE.** No `.xcstrings` file was opened by me.

**The wave's whole string story, verified end to end (§2.7).** d-store, d-retry and d-stt each report
ADDED: none / DEAD: none and none of them opened a catalog — confirmed independently, not taken on
their word: `git status --short -- '*.xcstrings'` lists **only** `Conduck/Conduck/Localizable.xcstrings`,
and its dict diff against `HEAD` is **+0 / −0 / ~1**.

| Key | Change | `= defaultValue` (source, and catalog `en` — byte-equal) |
|---|---|---|
| `workboard.voice.privacy` | **value rewritten, key kept, both halves moved together** | `Keeps the recording on your private desk and adds the words when they’re ready. The audio goes only to the speech provider you chose, and only to be turned into words — never into a conversation, and never through a server of ours.` |

Nothing was minted and nothing was retired. The "Discard recording" key d-retry's §Requests 3 would
want was deliberately NOT minted (a catalog row with no call site is exactly what
`testEveryWorkCatalogRowIsReferencedInSource` forbids) — carried as **O-17**.

---

## 7. Refuted

**Mine: EMPTY.** Every request I resolved was verified against the current code first (§1 names the
`file:line` I traced for each), and every one held. Nothing in wave D was refuted by me, and no DESIGN
DIRECTION was found impossible.

**The wave's own `## Refuted` sections, verbatim, so the next round needs no other file:**

- **d-store** — "**Nothing.** r4s#1, r4s#2 and r4s#3 all held against the current tree when traced by
  call path before any edit, and all three mechanisms are shown red on the reverted tree (§4). The
  DESIGN DIRECTION for r4s#2 was implementable as written: the column is additive, the migration is
  lightweight, and the selection rule fits the one completeness fetch that already existed.
  One clause of r4s#1 is UNDERSTATED rather than wrong, and I say so in §1: the finding describes the
  capture being dropped, but on the synced lane the colliding publication also replaces the standing
  card's payload and retires its blob. Both are measured in §4."
- **d-retry** — "**None.** All four findings were traced against the current tree by call path before
  any code changed, and all four hold exactly as written, at the exact anchors quoted in §Findings. The
  decided design directions were implementable as specified; the only contract line that had to move is
  `PendingRetryRecord`'s tuple initializer (§Deviations 1), which the queue forces because `load()` no
  longer returns a tuple, and it is recorded verbatim.
  One qualification, stated as such rather than as a refusal: r4a#3's brief says 'a terminal STT verdict
  … never deletes the recording'. I implemented that as *the entry is not disarmed*, not as *the
  recording is published on the spot*. Publishing it there would need a second
  `WorkVoiceCaptureCoordinator.recover(` call inside `perform()`, which `HeadlessRetryGuardSpanTests`
  orders against the first and `WorkboardVoiceLaneTests`' `.releasedOnlyOnATerminalOutcome` reads
  positionally — both would need re-anchoring for a card the next retry publishes anyway, now that
  `recover` secures the audio before it looks at the words. The recording is never lost either way."
- **d-stt** — "Nothing. All three hardcoded claims held exactly as the finding described, and the
  design direction was implementable as written (with the mechanism substitution recorded in
  §Decisions 4)."
- **d-copy-docs** — "**Nothing.** r4a#6 held exactly as written when traced against the provider roster
  before any edit — `STTProvider.swift:170-176` and `:229-237` name two AI models among the selectable
  speech providers, and the custom OpenAI-compatible endpoint is arbitrary. The design direction was
  implementable as written, with one substitution recorded as a deviation (§Deviations 1: the product's
  own word 'speech provider' in place of 'transcription service').
  **One clause of the finding is UNDERSTATED rather than wrong**, and I say so in §1: the finding
  scopes the falsehood to the voice sheet, but `spec.md` carried the identical absolute in two places —
  a section heading ('nothing on it is sent') and a decision sentence ('no code path leads from it to
  an AI'). Both are repaired here, at zero word cost."

---

## 8. Guard verdicts

### Mine: NONE — I converted, kept, deleted, narrowed and re-aimed nothing
No test file was opened by me. No `#if CONDUCK_TESTING` seam was added, moved or removed by me.

### Wave D's, verbatim-in-substance, for the record

- **d-store** — "**None assigned, none converted, none deleted, none weakened.**
  `WorkboardAvailabilityTests.testTheAvailabilityProjectionNeverNamesThePayloadColumn` was left exactly
  as it stands and passes — the completeness fetch still projects
  `materialID`/`byteSize`/`contentHash`/`updatedAt` and never `payload`." *Verified in my run: the
  class is 11/0 and that case is inside it.* Two cases assert the opposite of what they asserted before
  (`testABlobLeftByACrashIsAdoptedByTheReplayRatherThanDuplicated` and the newest-wins half of
  `testDuplicateBlobsResolveToTheNewestCompleteRow`) — **replaced, not weakened**, each by a case
  measured red on the reverted tree. **No test seam added** (§Decisions 5: a planned case needing a
  `_setWorkMaterialKindColumnForTesting` seam was DROPPED rather than widen the surface).
- **d-retry** — `HeadlessRetryGuardSpanTests.testPerformDisarmsOnProvableAbsence…` **KEPT, RE-ANCHORED
  and EXTENDED**; "**The disarm COUNT is unchanged at exactly 3 and every ordering assertion is
  byte-identical.** … Nothing was weakened, removed or re-aimed." ·
  `…testTheAbsenceDisarmCheckDistinguishesTheMissingAndOvershotShapes` **KEPT, EXTENDED by a Rule-0
  control** · `WorkboardVoiceLaneTests`' twelve-rule validator **KEPT, unchanged** ·
  `WorkboardAudioCaptureTests.testEveryRetrySurfaceMakesItsDeskDecisionThroughTheOneRecovery` **KEPT,
  unchanged and untouched** · `…testBothRetrySurfacesStageTheRecoveredBytesUnderTheirOwnContainer`
  **KEPT, unchanged**, and deliberately protected (`PendingRetryEntry`'s field is named `audioData`
  precisely so the guard's needle still reads) · three collision counterfactuals **CONVERTED, none
  deleted** · **Test seams: ONE added, none removed** — `speechAuthorizationForTesting`, verified by me
  at `InAppAudioRecorder.swift:206` inside `#if CONDUCK_TESTING` (`:171`–`:223`) with its consult at
  `:348` inside a second `CONDUCK_TESTING`/`#else` pair. **No skip was added.**
- **d-stt** — two NEW comment-stripped source guards (`testTheBackgroundUploadHardcodesNoContainer`,
  `testTheJSONProvidersHardcodeNoContainer`), each asserting the ABSENCE of a literal that is the exact
  text at `effc664`. Nothing converted, kept-on-that-basis or deleted. No seam.
- **d-copy-docs** — `WorkboardCopyTruthGuardTests.testTheVoiceSheetNamesTheSpeechProviderAndDeniesNeither
  TheHopNorTheAI` **KEPT, RENAMED and EXTENDED by two assertions** (an `aiDenialPhrases` scan and one
  POSITIVE requirement, `contains("conversation")`, "what keeps the fix a fix rather than a retreat");
  both existing inertness assertions kept verbatim. Measured red on the pre-fix catalog: `Executed 6
  tests, with 2 failures`, "**exactly the two new assertions, and no pre-existing case moved**".
  Nothing deleted or narrowed. No seam.

**Nobody undo these — they interlock, and each is pinned by a test that measures the cost.** The four
"nobody undo" lists — d-store §Requests 2, 3 and 4, d-retry §Requests 5 (seven clauses), d-copy-docs
§Requests 3 and 4, and d-stt (none) — all still hold as written after the merge, and the full suite is
the proof that none of them contradicts another. Wave C's five lists (c-drainer §1, c-lanes §Requests
5, c-recovery-core §Requests 5, c-session §Requests 5, c-store §Requests 2) also still hold, with **one
deliberate, argued exception**: d-retry §Decisions 2 overturns c-lanes' "do not persist `.published`",
and it does so by showing that the *reason* c-lanes gave ("persisting `.published` re-commits a slot a
newer capture may own") was a property of the whole-slot single-slot `save` that no longer exists.
`recordPublicationState` is metadata-only and keyed by id. **That is not an undo; it is the premise
changing, and it is stated as such.**

---

## 9. Open items — integrate-e's O-1…O-17 reconciled, renumbered for the handoff

**Closed by wave D (three), with the evidence I checked:**

| Was | Item | Closed by |
|---|---|---|
| O-1 | Five cases hard-FAIL on a machine whose Speech-Recognition TCC row is `denied`/`restricted` | d-retry — `InAppAudioRecorder.speechAuthorizationForTesting`, declared `:206` inside `#if CONDUCK_TESTING` (`:171`–`:223`), consulted at `:348` inside a `CONDUCK_TESTING`/`#else` pair whose `#else` is the untouched production line; set at `WorkVoiceRecoveryTests.swift:676` and `AudioExclusivityCrossSurfaceTests.swift:131`, both the classes' shared recorder factories, so all five cases are covered. **Remedy 2 of the two O-1 listed, not the `XCTSkipUnless` — no assertion is lost on the machines where it matters.** Both classes green in my run (20/0, 7/0) |
| O-6 | Three more hardcoded `audio/mp4` / `audio.m4a` container claims (`STTClient+Background.swift:267-268`, `QwenSTTProvider.swift:55`, `GeminiSTTProvider.swift:66`) | d-stt — all three now read `SourceAudioContainer.sniff`; `STTContainerDescriptionTests` **8/0**, including two comment-stripped source guards asserting the literals' ABSENCE. `GeminiQwenSTTWireTests` **12/0** proves ordinary AAC is described byte-for-byte as before. **Satisfied by a stronger mechanism than O-6's literal wording** (sniff inside the factory rather than a threaded MIME parameter — d-stt §Decisions 4) |
| O-7 | `PendingRetryStore.recordPublicationState(_:transcript:ifCurrentID:)` — close the `parkRecoveryState` TOCTOU and drop the whole-slot re-commit | d-retry — `recordPublicationState(id:transcript:publicationState:)`, the id lookup and the metadata write inside ONE `withExclusiveLock`, carrying no payload argument at all so it cannot rewrite audio. `PendingRetryQueueTests` **17/0** |

**Superseded rather than closed:** O-16(a) — the voice sheet's privacy sentence was rewritten
(d-copy-docs r4a#6) and is now the FIRST honest version, but it is still a founder copy call, and a
harder one: it concedes the destination may be an AI. Carried inside O-15 below.

**Open, renumbered:**

| # | Item | Why it is open, and who it belongs to |
|---|---|---|
| **O-1** | **The cross-process publication lock is proven with two store instances in ONE process, never two.** c-store measured `flock`'s per-descriptor scope as a faithful stand-in and c-drainer's takeover case asserts the ordering it buys; neither built a two-executable harness, and the App-Group path `<AppGroup>/Conversations-Locks/` is exercised only by derivation, never on a signed device. → Gate-2 founder QA. *(was O-2)* |
| **O-2** | `IsolatedWorkStores` adoption in the classes c-store and c-drainer did not own (`WorkAssetVaultTests`, `WorkboardMaterialBoardActionsTests`, `WorkboardDeskViewModelTests`, `WorkboardAudioCaptureTests`, every other `ConversationStore(inMemory:)` builder). Hygiene, not correctness; recipe in c-store §Requests 4. *(was O-3)* |
| **O-3** | **`WorkCaptureRetryCoordinator.swift` still has ZERO production callers** — re-verified by me: `grep -rn WorkCaptureRetryCoordinator Conduck --include='*.swift'` returns a prose reference (`WorkVoiceScreenshotCoordinator.swift:20`), the file's own two lines (`:4`, `:15`), an ABSENCE assertion (`WorkboardAudioCaptureTests.swift:761`) and a fixture string literal (`WorkboardVoiceLaneTests.swift:242`). Deleting it compiles. The decision is whether the desk keeps a coordinator-shaped fallback now that `recover` is the single answer. *(was O-4)* |
| **O-4** | Collapse the two iCloud banners. `WorkboardSyncBannerPolicy` survives; `ICloudUnavailableBanner` gains a `message` parameter and `WorkboardSyncBanner` dies. Three lines across files no agent owns. c-guards §Requests 1. *(was O-5)* |
| **O-5** | Should `ReplyVoice.shared` register on iOS? Its self-registration (`ReplyVoice.swift:194-199`) and `SpeechExclusivityParty` conformance (`:1177-1188`) are `#if os(macOS)`. Harmless today; a hole the day an iOS surface speaks through `.shared`. c-session §Requests 2. *(was O-8)* |
| **O-6** | Carry `WorkMaterial.filename` onto `WorkboardMaterialSnapshot` (`WorkboardViewModel.swift:79` has no `filename`) so a voice note's preview copy gets its real `.m4a` rather than one derived from the MIME. Playable and correct today, just not the stored name. *(was O-9)* |
| **O-7** | The three consolidations remaining from the old O-13: the board-tile radius `13` literal into `WorkboardMetrics`; one shared `WorkboardCardActions` for the two cards' menus; `onCancel` → `onDismiss` on the voice sheet's hand-off (`WorkboardComponents.swift:228`, `WorkboardCaptureCanvas.swift:142`). Behaviour-neutral. *(was O-10)* |
| **O-8** | The availability glyph/tint/label mapping is still duplicated between `WorkboardSourceCard` and `WorkboardAudioCardView`'s chip — re-verified: `grep -rn 'WorkboardAvailabilityChip'` is **clean**, no such type exists. The wave shared the ACTION rule (`WorkboardCardActionPolicy`) and deliberately left the COPY rule alone. *(was O-11)* |
| **O-9** | `WorkboardViewModel.workspaceStatus` → `transientStatus`/`deskStatus` — re-verified still present at `WorkboardViewModel.swift:408, 610`, plus readers at `WorkboardCaptureCanvas.swift:583` and `WorkboardView.swift:50, 96`. The last "workspace"-named member. Vocabulary only. *(was O-12)* |
| **O-10** | **The external-storage ceiling memory bound is uncovered by DECISION, not oversight.** c-store deleted r3s#6's bound (a helper process with a high-water mark or an allocator instrument exists nowhere in this bundle) and wrote the gap into the surviving test's doc comment. Accepted debt; reinstating it is its own session. *(was O-13)* |
| **O-11** | **Watch catalog drift, pre-existing since `efa553e`** — re-verified by me this round: `ConduckWatch Watch App/Services/WatchRecordingService.swift:761` declares `defaultValue: "\(name) isn't **available**. Choose which AI new chats use, on your iPhone."` while the Watch catalog row reads `"%@ isn't **set up**. Choose which AI new chats use, on your iPhone."` The catalog wins at runtime, so the source lies to the next reader. Not a Work string. copy-b §5. *(was O-14)* |
| **O-12** | **Spec-size debt** — 19827 words against a 16900 ceiling, two unrelated decisions over their 650-word limits. Out of scope by plan §"Out of scope". d-copy-docs paid for five new facts and four repairs entirely inside the two decisions it owned, so the number has now held at 19827 across three integrations; the next cut must come from somewhere else again. *(was O-15)* |
| **O-13** | **Founder copy calls, consolidated.** (a) **superseded and sharper** — the voice sheet's privacy line is now honest about the AI hop; the call is whether "and only to be turned into words — never into a conversation" reads as reassurance or as a confession (d-copy-docs §Requests 1). (b) the three desk-banner sentences. (c) `workboard.workspace.drop.overlay.caption` = "…Nothing is sent." (d) the recovered-note title. (e) copy-b §Requests 2's tutorial line and large-file confirm. *(was O-16)* |
| **O-14** | **Founder QA (Gate 2), consolidated — now 31 items across nine fixnotes, none reachable by a unit test.** Wave A–C's 16 (c-drainer 6 · c-guards 6 a–c · c-lanes 6 a–d · c-recovery-core 6 a–c · c-session 4 a–e · c-store 5 a–b) plus wave D's 15, listed in full in §Founder QA below. Plus plan §C's Gate 2 in full: real-CloudKit export/import across both stores, delete/reinstall reimport, actual watch exclusion. **Byte sync does not reach a release build without it.** *(was O-17)* |
| **O-15** | **NEW — a `recover` republication can throw forever.** `WorkVoiceCaptureCoordinator.swift:248-259` calls `try await publishRecording(captureID:…)` above the words guard at `:262`; d-store's kind gate (`ConversationStore+Workboard.swift:593`, `:710`→`:1512`) throws `invalidMaterialOwner` when that id names a card of another kind. The entry then stays queued and every retry fails identically, with no path forward. Correct in preferring the throw to the old overwrite; reachable only via a genuine UUID collision or a CloudKit merge. The two candidate answers (swallow the refusal in the retry lane, or derive a second id inside `recover`) are product decisions about what the person sees. d-retry §Requests 2. |
| **O-16** | **NEW — an exempt retry entry has no user-facing discard.** Re-verified: `grep -rn 'PendingRetryStore.shared.clear()'` → **zero hits**, and `isExemptFromExpiry` (`PendingRetryStore.swift:154-156`) means a Work capture the desk never accepted keeps its bytes in the App Group **indefinitely**. The retry card offers Retry and Troubleshoot and no dismiss. The missing half is a call site, not a string — d-copy-docs correctly refused to mint a key with no referent (`testEveryWorkCatalogRowIsReferencedInSource` would fail on it). Add the affordance, then the splice is one line. d-retry §Requests 3 + d-copy-docs §Requests 2, resolved into one item. |
| **O-17** | **NEW — `DiagnosticsRunner`'s parked-retry row describes the newest of possibly several.** `diagnosticSnapshot()` keeps its signature and its meaning for one capture; it cannot say "and two more are waiting". The store can answer a count in one line; d-retry did not widen the signature because the file is not its. d-retry §Requests 4. |
| **O-18** | **NEW — the Gemini WAV canary.** d-stt's fix means a WAV body now goes to the Interactions endpoint labelled `audio/wav` where it previously went labelled `audio/mp4`. Only the private validation script (`Conduck-Private/scripts/validation/`) can learn whether Google accepts it. Today's behaviour cannot be worse (the same bytes were already being sent under a false label), but it should be learned before anyone relies on it. d-stt §Requests 1. |
| **O-19** | **NEW — `deleteSupersededBlobRows` knowingly accepts r4s#3's hazard class.** It still deletes complete rows carrying OTHER bytes inside the publishing transaction, which can in principle delete a peer's republication whose own material update has not landed. d-store argues it is the plan's decided shape ("a replayed material with mismatching hash/size — replace blob, paired") and inside a transaction the publisher owns rather than a post-hoc cleanup. **The remedy shape is written down**: skip rows whose `updatedAt` is newer than this publication's own material read — never a sweep. d-store §Deviations + §Requests 3. |
| **O-20** | **NEW — five of the wave's settled facts are in no document.** d-copy-docs folded five at zero word cost; d-store contributed six and d-retry seven. Not carried: the colliding-capture refusal, "duplicate blob rows for one card are a normal bounded state", model 16's added `contentHash` column, d-retry's legacy-key fold, and the "a verdict never deletes a recording" rule. `spec.md` is 2,927 words over its ceiling and plan §"Out of scope" forbids spending there, so this is a real trade for the founder, not an oversight to fix silently. All ten facts are preserved verbatim in §Settled facts below. |

---

## Requests

1. **Orchestrator — the gate is CLOSED on the merged tree.** Every item plan §F names has been run by
   me and is quoted in §2: iOS `build-for-testing`, signed macOS build, full iOS suite (**4948 / 1 skip
   / 0 fail**), full watch suite (**232 / 0**), the three guard scripts, `git diff --check`, all four
   catalogs parsing with a before/after dict diff, the three mirror triplets byte-identical, and the
   bidirectional string audit (147/147/147). Plus the two checks this round added: the model diff since
   `651a859` with v15 SHA-proven identical (§2.10), and the empty build-cache root (§2.9). **The
   spec-size guard exits 1 and must be recorded as PRE-EXISTING**, per plan §E — 19827 words, identical
   to integrate-d's and integrate-e's number.
2. **The commit must include the three untracked files.** `PendingRetryQueueTests.swift`,
   `STTContainerDescriptionTests.swift`, `WorkCaptureDrainerCollisionTests.swift`. A `git commit -a`
   would miss all three. Wave B's and C's untracked files and deletions are already in the tree at
   `effc664`; `git status` carries no ` D ` row this round.
3. **The `.xccurrentversion` bump is part of the model change, not noise.** It is the only other file
   under the `.xcdatamodeld` that differs from `651a859`, its whole diff is `15` → `16`, and without it
   model 16 is not the version the store opens (§2.10).
4. **Nobody undo the wave's interlocking constraints** — §8 lists them and names the one deliberate,
   argued reversal (d-retry §Decisions 2 over c-lanes' `.published` rule), which is a premise change
   rather than an undo.
5. **Whoever runs the next full suite on `2B6E0EAC` — check the TCC row first anyway.** It was clean
   for me and d-retry's seam now protects the five cases integrate-e lost, but the check costs one
   command and a `0` row still costs a confusing hour anywhere the seam is not set.

---

## Deviations

1. **I answered gate item (10) with a corrected pathspec and reported the extra file.** The brief's
   `-- '*.xcdatamodeld'` returns nothing at all (git's `*` matches `/`, so it demands a path ENDING in
   `.xcdatamodeld`). I used `'*.xcdatamodeld/*'`, which returns two paths, and I report `.xccurrentversion`
   as the second one rather than filtering it out to make the claim read cleanly. Among the model
   CONTENTS files the brief's claim holds exactly.
2. **I checked whitespace in the three untracked files by hand.** `git diff --check` cannot see
   untracked files and `git add -N` is an index operation the standing rules forbid, so the guarantee
   `--check` gives for tracked files is provided by direct grep instead (0 trailing-whitespace lines,
   0 tab lines in all three).
3. **I added a warnings pass that the brief does not require** (§2.11), because `STTClient+Background.swift`
   carries 21 warnings that no wave-D fixnote quoted and a reader would reasonably wonder whether d-stt
   introduced them. It did not — every one is at a pre-existing line and none is inside its new function.
4. **I ran no counterfactual of my own and re-ran no agent's.** Each fixnote records its own measured
   red run; I verified the resulting tree, not their reverted copies.

## What I did NOT verify, plainly

- **No two-process harness** for the publication lock or the retry queue (O-1), and **no signed
  device** — Gate 2. d-retry's actor file I/O, its orphan scan against a real directory and two
  processes contending on `pending_retry.lock` are all untested by construction.
- **No migration was run against a real device's App Group.** d-retry's legacy-key fold is proven as a
  pure function over two encoded blobs; the key swap itself is not.
- **No UI, no screen.** There is no UI-test target by decision; the Founder QA list below is the
  hand-back.
- **No network.** d-stt's WAV labelling is proven against fixtures, never against Google or DashScope
  (O-18).
- **The single skip's subject is unverified by construction** — the website checkout it pins against
  does not exist here, which is what the skip says.
- **I ran the full iOS suite once.** It was green on the first attempt with a clean TCC row, so I have
  no evidence about ordering-independence under repeated load.

---

## Founder QA — consolidated from all four wave-D fixnotes (15 items)

All are two-device or device-only and none is reachable by a unit test. These ADD to integrate-e's
16-item list (now O-14).

**From d-retry (7) — the queue, which is the wave's biggest behaviour change:**
1. **Two recordings waiting at once, which is the whole point.** In airplane mode: make a Work voice
   note from the app (it fails at STT), then immediately run the bundled Shortcut / Action Button with
   Destination = Chat and let that fail too. Come back online and tap Retry twice. BOTH must complete:
   the Work note's words land on its own playable card, and the Chat capture reaches its conversation.
   *Before this round the second capture deleted the first one's recording.*
2. **A recording the desk refused outlives ten minutes.** Fill the device (or otherwise make the desk
   write fail) and make a Work voice note; leave the app for **over ten minutes**, then reopen. The
   retry card must still be there and finishing it must produce ONE playable card carrying the words —
   not a note, and not nothing.
3. **A key that is gone does not take the recording.** With the desk write failing as in (2) and NO STT
   key configured, run the Shortcut with Destination = Work. It refuses ("No STT API key set"), and the
   retry card must SURVIVE that refusal. Add a key, tap Retry: one playable card with words.
4. **First unlock.** Reboot the iPhone, do not unlock it, fire the Action Button with Destination =
   Work. The desk write fails before first unlock; the retry card must appear and later finish onto a
   single card. Repeat once WITH the device unlocked and confirm the card is not duplicated.
5. **Force-quit mid-queue.** Arm two captures as in (1), force-quit before retrying either, reopen.
   Both must still be offered, one after the other.
6. **Nothing accumulates.** After (1)–(5), Settings → Diagnostics must report no parked recording, and
   a later launch must not resurrect one.
7. **Two processes, one queue** (the untested half): while a Shortcut capture is in flight, start an
   in-app capture that also fails. Neither recording may disappear.

**From d-store (3) — the pairing invariant and the reattach swap, both two-device:**
8. **Blob-before-material, and the rollback behind it.** Two signed devices on one iCloud account, byte
   sync on. On device A, capture a small file into Work with the app FORCE-QUIT immediately after the
   progress bar completes (the window between the two saves). On device B, wait for the card. Expected:
   B either shows no card at all, or shows the card and opens it — **never a card that says "Waiting
   for iCloud…" for ever**. Then re-capture the same file on A and confirm B ends with ONE card that
   opens.
9. **A reattach while the other device is republishing.** On A, open a Work card whose payload syncs
   and reattach a LARGE file (over 30 MB, so the card leaves the synced lane). While that runs, on B
   reattach a small file onto the same card. Expected: both devices settle on one card that opens on
   each of them, and neither ends up permanently "Waiting for iCloud…".
10. **A colliding capture is refused, not silently swallowed.** Not directly reachable by hand (ids are
    deterministic), so the proxy: record a Work voice note, let transcription FAIL (airplane mode), then
    use the retry from the menu bar. Expected: the recording card is still there and still plays, and
    the recovered words appear either on that card or as a NOTE beside it — never a card that lost its
    audio, never a silently discarded transcript. *(This is also the observable for O-15.)*

**From d-stt (3) — the container claims, one of which changes on the wire:**
11. **Work voice note whose AAC encode fails → Gemini.** Hard to force by hand; the observable is that
    a recording which previously failed transcription forever now transcribes on retry. If the founder
    can reproduce a stuck Work voice retry from before, that is the case.
12. **Watch → phone background upload, ordinary dictation.** Must be byte-for-byte the old behaviour:
    the wrist records AAC M4A, so the part is still `audio/mp4` / `audio.m4a`. Any regression means the
    head-sniff read the wrong bytes — check that a normal watch dictation still transcribes.
13. **CarPlay dictation** (its tap produces CAF): the upload now claims `audio/x-caf` where it claimed
    MP4. Worth one real transcription against the live provider — this is the one lane whose wire claim
    CHANGES for a payload that previously worked by the endpoint's own sniffing.

**From d-copy-docs (2) — the rewritten privacy sentence, which grew from 33 words to 42:**
14. **The sentence fits, at the size a person actually uses.** Open Work → the microphone → the voice
    sheet, on the smallest iPhone available, with Settings → Display & Brightness → Text Size pushed
    near the top and again with Accessibility → Larger Text on. The sheet scrolls, so the failure to
    look for is a Record button you have to hunt for, not clipped text. Then **read it as a stranger
    would**, once with Apple on-device speech selected and once with a cloud provider: it says the same
    thing in both by design (the sheet cannot see which provider is active), and the founder's call is
    whether the unconditional sentence is honest in the on-device case rather than needlessly alarming.
15. **VoiceOver on that line.** It is a `Label` with a `lock.shield` glyph; confirm VoiceOver reads the
    whole sentence and does not stop at the dash.

---

## Settled facts — consolidated, one sentence each, for whoever writes the docs

**Already written into a document by d-copy-docs (five) — no further action:**
- A Work recording goes to exactly one destination, the speech provider the person selected, and it is
  used only to produce words — it never becomes part of a conversation and never passes through a
  server Conduck operates. *(spec.md, Work decision)*
- Some selectable speech providers are themselves AI models (`gpt-4o-transcribe`, Gemini, and any
  user-hosted OpenAI-compatible endpoint), so no Conduck surface may promise that a recording never
  reaches an AI. *(the guard's own doc comment; the spec heading and decision sentence repaired)*
- What the Work desk actually guarantees is that nothing on it becomes a turn: there is no code path
  from the desk to a gateway. *(spec.md heading + decision)*
- A voice note's bytes live in the database, in the payload store beside the desk, so "there is no
  audio entity" is no longer true of this app. *(spec.md, Audio decision)*
- The rule that an external surface is handed a disposable copy and never the vault's own file lives in
  `project-structure.md`'s `Services/Workboard/` row, not in `spec.md`. *(re-homed, not deleted)*
- A card names the bytes it was published with, so a peer's upload serves it only after a completed
  publication of them. *(spec.md, Work decision)*
- Each waiting capture is queued under its own identifier and keeps its recording; the ten-minute clock
  reclaims a retryable transcription, never a recording that is a card's only copy. *(spec.md, Audio
  decision)*

**True of the code and in NO document — the O-20 gap, preserved here verbatim:**
- A capture whose identifier already names a card of a different kind is refused outright — nothing is
  written, the standing card keeps its bytes, and a share queue keeps its copy for a later retry.
- Two blob rows carrying identical bytes for one card are a normal, bounded state: a publication that
  cannot prove a card already named those bytes writes its own copy rather than trusting one it found.
- Model 16 carries one added column on `WorkMaterial` (`contentHash`); it is optional with no default,
  so an existing card migrates naming no blob and is repaired by its next publication.
- A card that names synced bytes shows as waiting for iCloud until the blob it names is here whole; a
  complete blob that is not the one it names proves nothing about it.
- A reattach that moves a card off the synced lane releases exactly the payload rows the card was on,
  and never one that arrived from another device while the replacement was being proved.
- Finishing or discarding one capture removes exactly that capture's recording and leaves every other
  one waiting.
- A recovered Work capture gets its recording back onto the desk BEFORE its words are considered, so a
  transcription that never succeeds cannot keep the recording off the desk.
- A verdict about the speech-to-text key, or about the audio itself, ends a capture's transcription and
  never deletes its recording.
- A capture whose queue entry a build wrote before the queue existed is read and folded in on first
  launch, never discarded.
- Every STT lane derives its audio container from the bytes via `SourceAudioContainer.sniff` — the
  foreground multipart part, the background multipart part, and both JSON body factories. No lane
  stores a fixed container claim, and unrecognised or short audio resolves to `.m4a` (`audio/mp4` /
  `audio.m4a`), so ordinary AAC traffic is described exactly as before.
- `STTClient.backgroundAudioPart(forFileAt:)` resolves the background lane's `(mime, filename)` from a
  64-byte head of the upload file, so that lane still never holds the recording in memory, and it
  returns the same answer `multipartAudioPart(for:)` gives for the same bytes.
- `GeminiSTTProvider.swift` and `QwenSTTProvider.swift` are members of the `ConduckWatch Watch App`
  target; `STTClient+Background.swift` is not.

**Measured facts about the tree itself, for the next integrator:**
- The wave-D tree is 28 modified files plus 3 untracked test files; the only `.xcstrings` change is one
  value in the main catalog, and the only model change is `Conversations 16.xcdatamodel/contents` plus
  the `.xccurrentversion` pointer.
- The app-side mirror sources live at `Conduck/Conduck/Models/WorkCaptureEnvelope.swift`,
  `…/Models/ShareTargetsSnapshot.swift` and `…/Services/WorkCaptureDirectoryPublisher.swift` — the
  first two are NOT under `Services/`, and comparing the wrong path silently compares nothing.
- `git diff --name-only … -- '*.xcdatamodeld'` matches nothing in this repo; the working pathspec is
  `'*.xcdatamodeld/*'`.

---

## Cleanup

`/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh integrate-f` — run at end of
task, output `removed: integrate-f`; `ls ~/Library/Caches/gigaduck-builds/` is **empty** afterwards.
**Every log quoted above goes with it** (`ios-bft-1.log`, `ios-full-1.log`, `mac-1.log`,
`watch-1.log`); re-run to reproduce. No bare `rm -rf`, no `/tmp`, no throwaway tree copy — the gate is
on the shared tree by definition. No commit, no push, no stash, no checkout, no reset, no index
operation; `Identity-Override.xcconfig` untouched; nothing under `docs/qa/desk-cloudkit/` touched.
