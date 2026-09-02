# integrate-d — wave B coheres. FULL GATE GREEN.

**iOS `Executed 4874 tests, with 1 test skipped and 0 failures` · watch `Executed 232 tests, with 0
failures` · signed macOS `** BUILD SUCCEEDED **` · all four guard scripts pass · all three mirror
triplets byte-identical · all four catalogs parse · nothing staged, nothing committed.**

The executed count landed on the **exact** figure the fixnotes' deltas predict (§3). Every wave-B
class reports its predicted count with zero failures.

Slug `integrate-d`. Sim `2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF`, watch sim
`28AC563B-42C1-4E66-940D-77E63B07918B`. Every log under
`~/Library/Caches/gigaduck-builds/integrate-d/`, grepped for `': error: '` and the verdict strings —
never judged from tail or exit code. **No `-configuration` passed anywhere.** No commits, pushes,
stash, checkout or reset. `Identity-Override.xcconfig` untouched. Nothing under
`docs/qa/desk-cloudkit/` touched. **No `.xcstrings` opened.** No `.pbxproj` edit. No mirror triplet
touched.

Files I changed — six, each one discharging a named cross-agent Request:

| File : symbol | Why |
|---|---|
| `Conduck/ConduckTests/WorkCaptureInboxTests.swift` : `testShareWritersValidateAndRollbackBeforeAtomicPublication` **DELETED**; `testTheWatchCaptureBoundStillRestatesTheEnvelopeBound` doc comment | fix2-inbox §1 (BLOCKING) + copy-b §1; ui-watch §2 |
| `Conduck/Conduck/Services/Workboard/WorkAssetVault.swift` : `store(_ data:id:suggestedExtension:) -> String` **DELETED** | fix2-vault §1 + fix2-store §1 + vm-collapse §4 |
| `Conduck/ConduckTests/WorkboardLiveRepositorySupportTests.swift` : `testBatchedURLLookupResolvesOnlyPresentSafeKeys` | the two remaining callers → `store(bytes:).key` |
| `Conduck/Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift` : `WorkVoiceAttachOutcome.{recordingMissing,notAudio}`, `fallbackNoteID(forCapture:)` doc comments | fix2-voice-lanes §1 |
| `Conduck/Conduck/Utilities/Constants.swift` : `workboardDeskItemID` doc comment | ui-watch §1 |
| `Conduck/ConduckTests/WorkboardBlobSeamPlatformGuardTests.swift` : `payloadSeams` | fix2-store §5 |

---

## 1. Requests resolved, one by one

### 1.1 fix2-inbox §Requests 1 (BLOCKING) + copy-b §Requests 1 — the superseded share-writer guard. DELETED.

`WorkCaptureInboxTests.testShareWritersValidateAndRollbackBeforeAtomicPublication` (`:297`) failed on
the merged tree at `:308` (`XCTUnwrap failed: expected non-nil value of type "Range<Index>"`) — the
only failure fix2-store, vm-collapse and copy-b each independently reported. It greps both appexes'
`ShareViewController.swift` for `try envelope.validateForPublication()`, which fix2-inbox moved into
`WorkCaptureDirectoryPublisher.commit`.

**Deleted, not re-pointed**, exactly as fix2-inbox asked. Its four clauses are each carried by a
stronger successor, which I verified individually rather than taking on trust:

| Old clause | Successor, verified |
|---|---|
| validate-before-publish | `WorkCaptureSharePublisherTests.testARefusedEnvelopeIsNotPublishedAndTakesItsStagedBytesWithIt` (behavioural, injected filesystem) |
| rollback of the staging copy | same case + `testAStagingWriteThatCannotLandPublishesNothing` |
| ONE atomic rename | `testAStagedCaptureIsPublishedByOneAtomicRename` |
| `targetWorkItemID: nil` | `testBothShareExtensionsPublishThroughThePublisherRatherThanByHand` (kept as a scoped source guard, per fix2-inbox's own verdict) **plus** the publisher's `Failure.envelopeNamesADestination` refusal |

`WorkCaptureInboxTests` 30 → **29**, measured. All 29 pass.

### 1.2 fix2-vault §1 + fix2-store §1 + vm-collapse §4 — the key-only vault write. RETIRED.

Three fixnotes asked for the same two-part change and each could only do its half in a parallel
phase. Both halves were already landed by the time I arrived (fix2-store took `store(bytes:)` at
`stageWorkMaterialBytes` and `addWorkMaterial` and passes `expectedByteCount:` at all three
`confirmPublication` sites), leaving exactly the tail: **two test callers and the transitional
method**.

- `WorkboardLiveRepositorySupportTests.swift:22-23` → `store(bytes: …).key`.
- `func store(_ data: Data, id:suggestedExtension:) throws -> String` **deleted** from
  `WorkAssetVault`.

Verified by grep across every target that no caller of any kind remains: the only `.store(` hits on
the vault are `store(bytes:` (2 production in `ConversationStore+Workboard.swift:1008,1456`, the rest
in `WorkAssetVaultTests`). `WorkboardLiveRepositorySupportTests` 5/0 and `WorkAssetVaultTests` 19/0 in
the full run.

**Why this is the right resolution and not scope creep:** fix2-vault called the survival of that
method a stated deviation from contract C4 whose only reason was the parallel phase, and named the
exact deletion. C4's point is that a caller recording or confirming a byte size must take a MEASURED
length; leaving a key-only door open is how a future capture lane re-acquires a caller's-claim
`byteSize` and silently disarms `expectedByteCount:`.

### 1.3 fix2-canvas §Requests 1 — the audio card adopting the card-action policy. ALREADY DISCHARGED; verified, no edit.

fix2-canvas asked fix2-audio-card for three one-line changes; fix2-audio-card had already made them
(their §C2: "Reuse instead of a second policy"). I confirmed in source rather than trusting either
note — `WorkboardAudioCardView.swift`:

```
:149  WorkboardCardActionPolicy.allows(.open, when: availability) && hasOpenAction
:167  let repairable = WorkboardCardActionPolicy.allows(.reattach, when: availability)
:988  WorkboardCardActionPolicy.allows(.play, when: material.availability)
```

and the call site passes both seams **unconditionally**, which is the half that turns them on
(`WorkboardCaptureCanvas.swift:1169-1170`, `onOpen:` / `onReattach:` on the audio branch, matching
`WorkboardSourceCard` at `:1183-1184`). Zero occurrences of `availability.isAvailable` survive in the
audio card. `WorkboardOpenPathTests` 6/0 and `WorkboardAudioCardTests` 27/0.

### 1.4 The guard test fix2-recorder / fix2-voice-lanes "agreed to retire" — there is none. Nothing deleted.

Checked both notes against each other rather than assuming a pairing:

- fix2-recorder already **converted and deleted** its own two
  (`testTheRecordingIsPublishedBeforeTheTranscriptionHop`,
  `testOneCaptureIdentityNamesBothTheCardAndThePendingRetryRecord`) inside its own slice — nothing
  was left for me.
- On the one guard that spans both of them,
  `WorkboardAudioCaptureTests.testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes` (rated
  `convert`), **both agents independently returned KEEP**, and fix2-voice-lanes §Requests 2 says in
  terms: *"Do not do (a) or (b) without the hoist, and not at this gate — they are the only things
  holding the two surfaces in step today."* Retiring it here would delete the only thing pinning
  `ContentView` and `MenuBar/DictationService` to attach-then-publish while its replacement (a shared
  coordinator entry point) does not exist. **I retired nothing.** The consolidation goes to round 3
  as open item O-7.

### 1.5 ui-watch §Requests 1 — `Constants.swift` names a deleted test file. FIXED.

`workboardDeskItemID`'s doc comment ended *"`WorkboardDeskIdentityDriftTests` fails if the literal is
ever restated outside this file."* ui-watch deleted that file (both cases rated `delete`). Sentence
removed; the preceding one already states the constraint (`Constants.swift` is a Watch-target member,
so every surface reads the value rather than a copy), and the behavioural enforcement is
`ConduckWatchSmokeTests`' two persistence cases, which read the id back out of the store. Verified:
`grep -rn WorkboardDeskIdentityDriftTests Conduck` now returns **nothing**.

### 1.6 ui-watch §Requests 2 — the watch-bound guard's doc comment. FIXED.

It described the failure as *"having `createWorkItem` refuse it — losing a brief the person has no
other copy of."* `createWorkItem` is now `#if CONDUCK_TESTING`-gated (fix2-store t#5) and the wrist
never called it; there is no brief. Retold as `upsertDeskMaterial` refusing the note. One comment,
no assertion touched — the class is 29/0.

### 1.7 fix2-store §Requests 5 — three seams missing from the platform guard. ADDED.

`payloadSeams` gained `var publicationConfirmationHookForTesting`,
`var projectionVaultReadabilityCallsForTesting`, `func _removeIsolatedVaultDirectoryForTesting(`.
I verified the placement before adding rather than after: in `ConversationStore.swift` the
`#if CONDUCK_TESTING` region opens at `:4400` and the nested `#if !os(watchOS)` spans `:4525–4717`,
and all three declarations (`:4660`, `:4685`, `:4713`) fall inside it — so the guard passes as
fix2-store predicted (`WorkboardBlobSeamPlatformGuardTests` **1/0** in the full run, the correct count
after ui-watch's conversion).

**Also checked, because adding rows here could have broken it:** `_mountedStoresForTesting` is at
`:4509`, i.e. **before** the fence opens — which is what ui-watch §Requests 3 asks to be preserved and
what its new watch test needs. The watch suite is 232/0, so it is genuinely reachable there.

### 1.8 ui-watch's recorded git-index accident — clean.

ui-watch reported a `git rm --cached` it restored. Verified: `git diff --cached --stat` is **empty**
and the path presents as a plain unstaged ` D`. Nothing is staged anywhere in the worktree.

## 2. Requests I did NOT take, each with its reason

1. **fix2-store §2 (`WorkboardLiveRepository` adopting `WorkMaterialCommittedUnavailableError`)** —
   real design, not a merge. `importMaterial` would have to present or refresh the card the error
   carries instead of surfacing a bare failure, which changes what a person sees after a failed drop.
   Behaviour is unchanged and nothing is broken by leaving it. → O-1.
2. **fix2-store §4 (`IsolatedWorkStores` in the remaining classes)** — mechanical but wide: four named
   classes plus every other `ConversationStore(inMemory:)` builder, each needing a `tearDown`. It is
   simulator hygiene (measured residue 82 directories / 155 MB), not correctness, and touching a dozen
   suites at a gate to reclaim disk is the wrong trade. → O-2.
3. **fix2-audio-card §1 and §2 (register the mic authority / `ThreadSpeaker` on iOS)** — both are
   product decisions about cross-lane audio arbitration on a platform where the bus is currently
   inert, and fix2-audio-card itself calls §2 a "founder/owner call, not a defect I can assert". → O-3.
4. **fix2-audio-card §3 / fix2-canvas §3 (the preview file's extension)** — the defect is closed (an
   extensionless file is no longer handed to Quick Look); what remains is that `audio/mp4` prefers
   `mp4` over the stored `m4a`, which needs `WorkMaterial.filename` carried onto
   `WorkboardMaterialSnapshot` — a repository + snapshot-type change. fix2-canvas: "Not urgent, not a
   defect." → O-4.
5. **fix2-canvas §4 (the duplicated availability glyph/tint/label)** — a new shared
   `WorkboardAvailabilityChip` component across two view files, behaviour-neutral, at a gate. → O-5.
6. **vm-collapse §1 (`.openPersonalAISettings` has no poster)** — the choice is delete-the-name-plus-
   four-observers or give it a poster, and three of the five sites are Chat-side files. That is a
   decision, and a wrong one silently removes a route to Settings. → O-6.
7. **vm-collapse §2 (`workspaceStatus` → `transientStatus`)** — pure vocabulary, one model member and
   six lines of `WorkboardView.swift`. No invariant rides on it. → O-8.
8. **fix2-recorder §1 and §2 (`PendingRetryMetadata.transcript`, a dedicated `AppError` case)** — both
   are additive changes to files no wave agent owns, one of them to a persisted record shape, and the
   catalog is the serial copy agent's. → O-9, O-10.
9. **fix2-recorder §3 / fix2-voice-lanes §5.2.2 (republishing a recording on a recovered `.work`
   retry)** — the two agents deliberately disagree, with reasons, about whether a recovered capture
   whose card never landed should resurrect the recording; fix2-voice-lanes' objection is that
   `.recordingMissing` also covers *a person deleting the card while STT is in flight*. That is a
   product call about what a person sees, not an integration one. → O-11.
10. **fix2-voice-lanes §5 / integrate-c §4 (the `conduck_retry_….m4a` naming; the four cosmetic
    consolidations)** — behaviour-neutral cleanups spanning files with live tests. → O-12, O-13.
11. **copy-b §3 (`sync.icloud.banner.*` says "your conversations" on the desk)** — sixth fixnote to
    raise it. Plan §C explicitly says the desk banner reuses those keys, so leaving it is the
    plan-coherent answer; changing it is a founder copy call between widening three shared keys and
    minting three desk-specific ones. → O-14.
12. **copy-b §5 (Watch catalog drift on `watch.capture.defaultGatewayNotSetUp`)** — pre-existing since
    `efa553e`, not a Work string, and the two halves disagree in a way only the lane's owner can
    settle. → O-15.
13. **The spec-size guard.** Plan §E: record as pre-existing, cut nothing else. `wc -w
    docs/ai-context/spec.md` → **19827**, against a 16900 ceiling — **two words below** the 19829
    baseline copy-truth recorded, i.e. copy-b paid for five new facts and still came out ahead. Not
    fixed, deliberately.
14. **`project-structure.md`'s mirror sentence.** fix2-inbox §6 wondered whether the folder map lists
    the mirrored files by name. It does not — `:77` says "the snapshot and manifest types are
    deliberate verbatim mirrors … held byte-identical by a test", with no file inventory. Adding
    `WorkCaptureDirectoryPublisher.swift` there would introduce the inventory the document's own
    convention forbids. Nothing owed; `check-folder-map.sh` passes.

## 3. Test-count reconciliation — the delta is exact

Baseline: fix-verify's full run, **4810 executed / 1 skipped / 0 failures**.

| Slice | Class movement | Δ |
|---|---|---|
| fix2-vault | `WorkAssetVaultTests` 15 → 19 | **+4** |
| fix2-drainer | `WorkCaptureDrainerDurabilityTests` 5 → 8 | **+3** |
| fix2-recorder | `WorkboardAudioCaptureTests` 13 → 19 | **+6** |
| fix2-voice-lanes | `WorkboardVoiceLaneTests` NEW 12 | **+12** |
| fix2-audio-card | `WorkboardAudioCardTests` 15 → 27 | **+12** |
| fix2-canvas | `WorkboardOpenPathTests` NEW 6 | **+6** |
| fix2-store | `WorkboardBlobPublicationTests` 15→21, `WorkboardDeskUpsertTests` 11→14, `WorkboardChatCaptureTests` 7→8, `ConversationStoreAtomicWorkCaptureTests` 3→4 | **+11** |
| fix2-inbox | `WorkCaptureSharePublisherTests` NEW 7, `WorkCaptureInboxLeaseTests` 14→15 | **+8** |
| vm-collapse | `WorkboardBoardProjectionTests` 1→4, `WorkboardWorkspaceCaptureTests` 6→5 (one deletion, argued) | **+2** |
| ui-watch | `WorkboardBlobSeamPlatformGuardTests` 2→1, `WorkboardDeskIdentityDriftTests` DELETED (2 cases) | **−3** |
| copy-b | `WorkboardCopyTruthGuardTests` NEW 4 | **+4** |
| **integrate-d (me)** | `WorkCaptureInboxTests` 30→29 (§1.1) | **−1** |
| ui-docs | docs only | 0 |
| | **net** | **+64** |

`4810 + 64 = 4874`. **Measured: 4874.** Zero drift — no case was silently lost or silently added
anywhere in the wave.

Per-class verification from the full run (every one matches its fixnote's own number, 0 failures):

```
WorkAssetVaultTests                       19/0     WorkboardBlobPublicationTests      21/0
WorkCaptureDrainerDurabilityTests          8/0     WorkboardDeskUpsertTests           14/0
WorkCaptureDrainerTests                    9/0     WorkboardChatCaptureTests           8/0
WorkCaptureInboxTests                     29/0     ConversationStoreAtomicWorkCapture  4/0
WorkCaptureInboxLeaseTests                15/0     WorkboardBoardProjectionTests       4/0
WorkCaptureSharePublisherTests             7/0     WorkboardWorkspaceCaptureTests      5/0
WorkboardAudioCaptureTests                19/0     WorkboardBlobSeamPlatformGuard      1/0
WorkboardAudioCardTests                   27/0     WorkboardCopyTruthGuardTests        4/0
WorkboardVoiceLaneTests                   12/0     WorkboardAvailabilityTests          9/0
WorkboardOpenPathTests                     6/0     WorkboardLiveRepositorySupport      5/0
WorkboardDeskSurfaceDriftGuardTests        4/0     MacWorkbenchShellDriftGuardTests    4/0
STTKeyBlackoutLaneTests                   11/0     HeadlessRetryGuardSpanTests        11/0
ErrorSurfaceDriftGuardTests                7/0     WorkboardMaterialBoardActions      12/0
WorkboardTwoStoreLoadTests                 7/0     WorkboardDeskIdentityDriftTests   ABSENT ✓
```

**Failures: NONE.** Summed across every suite in the log: 0.

**Skips: 1, not the plan's 2.** The single skip is
`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`:
`Test skipped - No website source at …/.codex/worktrees/website/src/lib/adapter-contracts.ts`. That
is the environment pin fix-verify §4 already characterised — a missing sibling checkout, not a
deleted case. The executed count rose 4810 → 4874 with 0 failures, so nothing was lost to it.

## 4. The gate — every number, and the exact lines

### (1) iOS `build-for-testing` — `ios-bft-1.log`
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
**Signed through the identity override. No `CODE_SIGNING_ALLOWED=NO` fallback was used or needed.**

### (3) FULL iOS suite, `test-without-building` — `ios-full-1.log`
```
** TEST EXECUTE SUCCEEDED **
	 Executed 4874 tests, with 1 test skipped and 0 failures (0 unexpected) in 82.450 (84.595) seconds
```
No simulator crash, no retry needed.

**The 1808 `': error: '` lines in that log are runtime chatter, and I checked rather than assumed.**
`grep -cE '\.swift:[0-9]+:[0-9]+: error: '` (a compile error) = **0**;
`grep -cE '\.swift:[0-9]+: error: '` (an XCTest failure) = **0**. Every one is Core Data complaining
about deliberately-broken fixtures — the top shapes are `Failed to stat path
'/nonexistent-…/store.sqlite'`, `Sandbox access to file-write-create denied`, `Failed to statfs file;
errno 2`, emitted around cases such as
`ConversationHistoryAssemblerTests.testAssembleThrowsWhenTheStoreCannotLoad` and the wave's own
refused-write fixtures. Pre-existing in kind (fix-verify recorded two such lines); the count is higher
because wave B added many more deliberate-failure fixtures. Recording it so the gate is not surprised.

### (4) FULL watch suite — `watch-1.log`
```
** TEST SUCCEEDED **
	 Executed 232 tests, with 0 failures (0 unexpected) in 9.591 (9.664) seconds
```
0 compile-error anchors, 0 XCTest-failure anchors. **232 as ui-watch predicted** (231 + its one new
`testTheWatchBuildMountsTheCoreStoreAloneAndNoPayloadStore`), and this is the first watch run on the
merged tree — ui-watch's own 232 predated fix2-store's `ConversationStore.swift` edits, which the
Watch target compiles.

### (5) Guard scripts
```
✓ storage seam intact — 786 Swift files scanned, no raw store
  or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift      exit 0
✓ folder map current — 36 Swift source directories, all mapped,
  and every path the map names exists                                                     exit 0
✓ spec citations resolve — 786 Swift files scanned, 1 quoted
  section name(s), every one a live heading in docs/ai-context/spec.md                    exit 0
```
Spec size guard, **PRE-EXISTING FAILURE, not fixed** (plan §E):
```
✗ docs/ai-context/spec.md is 19827 words; the ceiling is 16900.
✗ decisions over their word limit:
    "Sending files and getting them back are two capabilities of one lane"  687 / 650
    "Forgetting a gateway erases the credentials and keeps the colour tag"  701 / 650
```
Both over-limit decisions are unrelated to Work and untouched by the wave. 19827 is **two words below**
the 19829 baseline.

### (6) `git diff --check`
No output, **exit 0**. `git status --short` for `Conduck/Configs`, `docs/qa` and
`Conduck/Conduck.xcodeproj` → **empty**. `git diff --cached --stat` → **empty** (nothing staged).

### (7) Catalogs — `python3 json.load`, all four clean
```
Conduck/Conduck/Localizable.xcstrings                    keys = 2242
Conduck/ConduckShareExtension/Localizable.xcstrings      keys =   43
Conduck/ConduckShareExtensionMac/Localizable.xcstrings   keys =   42
Conduck/ConduckWatch Watch App/Localizable.xcstrings     keys =  299
```
Main catalog flat at copy-b's 2242 (it added 6 and removed 6); the other three are unmodified in
`git status`.

**Bidirectional audit, mine, run over every `.swift` under `Conduck/Conduck`:**
`source-declared workboard.* keys = 144 · source-referenced = 144 · catalog rows = 144 · MISSING from
catalog: [] · CATALOG-ONLY (unreferenced): []`. The only two `defaultValue` ≠ catalog-`en`
differences are `workboard.error.contentTooLong` (`\(limit)` vs `%@`) and
`workboard.workspace.drop.image` (`\(index + 1).\(format.ext)` vs `%1$lld.%2$@`) — the formatted-
literal convention copy-b §Requests 7 and strings-audit §Requests 5 both say must NOT be "fixed". I
did not fix them.

### (8) Mirror triplets — byte-identical below `import Foundation`
| Triplet | bytes below import | app == iOS | app == macOS |
|---|---|---|---|
| `WorkCaptureEnvelope.swift` | 14801 | True | True |
| `ShareTargetsSnapshot.swift` | 9728 | True | True |
| `WorkCaptureDirectoryPublisher.swift` (**new this wave**) | 6198 | True | True |

All nine files carry identical SHA-256 within their triplet. The first two are **unmodified in `git
status`**; the third is fix2-inbox's new triplet, and I checked it on the same rule the plan sets for
the other two. Their drift guards pass: `WorkCaptureSharePublisherTests` 7/0 (which includes
`testThreeCrossProcessPublisherCopiesAreIdenticalBelowImport`) and `WorkCaptureInboxTests` 29/0.

### (9) Build caches — no wave-B leftovers
`ls ~/Library/Caches/gigaduck-builds/` before I started: **empty**. Every wave-B agent ran its own
`clean-build-cache.sh` (each fixnote records it), so there was no stray slug and no stray tree copy to
remove. Only `integrate-d/` existed at the end, and I removed it — see §7.

**One thing I could NOT clean, stated plainly:** integrate-c §6.6 records a ~24 MB tree copy at
`…/scratchpad/verify-tree-1` from the audio-capture slice. It is inside this session's scratchpad, not
under `~/Library/Caches/gigaduck-builds/`, so it is outside both the cleanup script's hardcoded root
and my gate item. The founder can remove it.

## 5. What I did NOT verify, plainly

- **No new regression test of my own.** Five of my six edits are deletions or doc comments, and the
  sixth adds rows to an existing guard. The one behavioural change — the vault's key-only `store(_:)`
  ceasing to exist — is **compiler-enforced**: a caller that wants a key without a measured length no
  longer compiles. That is stronger than any test I could write for it, and it is why I did not write
  one. The deletion of the share-writer guard is proven non-lossy by the successor mapping in §1.1
  rather than by a new assertion.
- **The cross-process halves of the wave's claims.** fix2-store's per-material publication claim is
  process-local by construction and fix2-drainer's takeover is proven with two in-process inbox
  instances. Neither I nor they built a two-process harness. → O-1, and Gate-2 founder QA.
- **Anything a headless run cannot reach.** No UI was exercised; there is no UI-test target by
  decision. The founder QA items every slice contributed are consolidated in §8.

---

## Catalog

**Keys I ADDED in source: NONE.** All six of my edits are headless — two deletions, three doc
comments, one test-guard list.

**Keys I made DEAD: NONE.** I deleted no code carrying a string. The deleted
`WorkAssetVault.store(_:)` and `WorkCaptureInboxTests`' share-writer guard carry none.

**No `.xcstrings` file was opened.**

**Wave-B catalog state, verified end to end (this is the wave's whole string story in one place):**
copy-b spliced the six keys wave B declared in source and swept the six vm-collapse made dead, holding
the main catalog flat at **2242**:

| Added by copy-b | = value | Declared by |
|---|---|---|
| `workboard.audio.busy` | `Audio is in use right now` | fix2-audio-card |
| `workboard.audio.cancelLoading` | `Cancel Loading` | fix2-audio-card |
| `workboard.audio.unavailableHere` | `Not on this device` | fix2-audio-card |
| `workboard.material.preview.syncPending` | `This material is still arriving from iCloud. It will open once it lands on this device.` | fix2-canvas |
| `workboard.voice.error.deskWrite` | `Work couldn’t save this recording just now.` | fix2-recorder |
| `workboard.voice.recordAgain` | `Record Again` | fix2-recorder |

| Removed by copy-b (dead per vm-collapse §5) |
|---|
| `workboard.material.addNote` · `workboard.material.note.title` · `workboard.material.note.body` · `workboard.material.note.name` · `workboard.material.note.footer` · `workboard.material.note.defaultName` |

My independent audit (§4.7) confirms every one landed and nothing else moved: 144 source keys, 144
catalog rows, no missing, no orphans. `WorkboardCopyTruthGuardTests` (copy-b's own bidirectional
guard) is 4/0 in the full run, so the invariant is now held by a test as well as by this check.

---

## Requests

1. **Orchestrator — the gate is CLOSED. Nothing further is owed before the commit.** Every item plan
   §F names has been run on the merged tree by me and is quoted in §4: signed macOS build, full iOS
   suite (4874/1 skip/0 fail), watch suite (232/0), the three guard scripts, `git diff --check`, all
   four catalogs parsing, the mirror triplets, and the bidirectional string audit. The spec-size guard
   fails and must be recorded as pre-existing, per plan §E.
2. **The commit must include the file deletions.** `Conduck/ConduckTests/WorkboardDeskIdentityDriftTests.swift`
   presents as an unstaged ` D` (ui-watch), and eight new files are untracked
   (`WorkCaptureDirectoryPublisher.swift` ×3, `WorkVoiceScreenshotCoordinator.swift`,
   `WorkboardCardActionPolicy.swift`, `WorkCaptureSharePublisherTests.swift`,
   `WorkboardCopyTruthGuardTests.swift`, `WorkboardIsolatedStoreFixture.swift`,
   `WorkboardOpenPathTests.swift`, `WorkboardVoiceLaneTests.swift`). A `git commit -a` would miss the
   untracked ones.
3. **Founder — three copy/product calls survive the wave, all raised by several agents.** (a)
   `sync.icloud.banner.*` still says "your conversations" on a desk full of cards — sixth raise, and
   plan §C's instruction to reuse those keys is why nobody has changed it (O-14). (b) The three lines
   copy-b newly wrote are worth your eye: the tutorial's `Cards sync through your own iCloud — very
   large files stay on the device that captured them.`, the large-file confirm, and the voice sheet's
   `Record a voice note` — the first two are the only places the product tells a user the sync has a
   ceiling. (c) Whether a recovered Shortcuts retry should resurrect a recording whose card never
   landed (O-11).
4. **Nobody undo these, consolidated from the wave's own "nobody" requests** — they now interlock, so
   a later tidy-up that looks local is not:
   - `confirmPublication` stays the only release of a vault staging guard, and `markReferenced` stays
     deleted (fix-verify §7.8, fix2-vault (d)).
   - Reclamation keeps judging by EXISTENCE, never readability; the marker sweep keeps `stagedKeys`,
     not `protectedKeys` (fix2-vault §3).
   - The drainer keeps its structured task group, its pre-write checkpoint and the `endImport()` gate
     on `acknowledge`/`release` (fix2-drainer §2, §3).
   - `requireAdoptable`'s two halves both stay — a missing owner row is not evidence, and the kind
     check is not optional (fix2-store §3).
   - The reattach's readability proof stays BEFORE the CAS and the old vault keys are released only
     after the confirmation (fix2-store §6).
   - Both publication claims stay (fix2-store §7).
   - Phase-1 publication stays above the key pre-flight and the STT hop, on every lane; no capture's
     screenshot or fallback note is ever minted at the capture id, and the two derivations keep
     separate namespaces (fix2-voice-lanes §3, §4).
   - No availability test goes back to a call site; the card asks `WorkboardCardActionPolicy`
     (fix2-canvas §5, fix2-audio-card §6).
   - No board id returns to `WorkboardViewModel` (vm-collapse §3).
   - The share publication stays ONE transaction in three byte-identical copies, and
     `envelopeNamesADestination` stays (fix2-inbox §2, §3).
   - No `send` / `draft` / `brief` / `dispatch` returns to a `workboard.*` string — now held by
     `WorkboardCopyTruthGuardTests` (copy-b §4).
   - `.audio` never re-narrows to `.file` in `presentationKind` (integrate-c §6.1).
5. **Founder QA (Gate 2) — the wave's items, consolidated.** Plan §C makes this release-blocking, so
   they belong in one list rather than in eleven fixnotes. Share a file **above 30 MB** while the
   device is busy → exactly one card, and it opens · share a file, then suspend the app **>5 min** so
   the capture is reclaimed → exactly one card, with its bytes · share the same file twice quickly →
   one card; then share an empty capture → the sheet reports failure and the desk gains nothing ·
   reattach a file onto a card, and if the reattach errors, the ORIGINAL must still open · on a device
   upgrading from a pre-desk build, re-capture an already-captured chat turn → its cards move onto the
   desk once and the old Work item survives, empty · record a Work voice note in airplane mode → the
   sheet offers **Try Again** *and* **Record Again**; Try Again fills the SAME card, Record Again
   leaves the first wordless card standing · run the Shortcut with Destination = Work in airplane mode
   → a playable untranscribed card, later filled in on the same card · same with a Take Screenshot
   step, online → exactly TWO cards, and the recording must still PLAY · on **macOS**, a Work capture
   that failed STT and is recovered from the menu-bar retry lands its words on the same card · start a
   note then a CarPlay voice session → the card refuses with "Audio is in use right now", it does not
   reconfigure the car's session · on macOS, a note stops for menu-bar dictation and for a chat
   read-aloud · start one note, tap a second, let the first's tick land → the second keeps playing ·
   pause a note → other apps' music un-ducks · tap a card mid-load → "Cancel Loading", and the tap
   abandons the read · the paperclip menu offers photos/camera/files/**link** and no "Add Note", and
   the composer's amber arrow still produces a note card.
6. **Release gates (recorded, not this session), unchanged from plan §G.** Deploy model 16 to CloudKit
   Production before any release build carrying byte sync, and complete Gate-2 signed-device QA
   (real-CloudKit export/import across both stores, delete/reinstall reimport, actual watch exclusion,
   and the headless App Intent topology).

---

## Refuted

**Nothing of my own.** Every Request I acted on held against the merged tree when I traced it, and the
one I expected to have to make (fix2-canvas §Requests 1, the audio card's policy adoption) turned out
to be already discharged rather than false — recorded in §1.3 as verified-not-owed, not as a
refutation.

### Every `## Refuted` entry from the wave, verbatim, for Codex round 3

**fix2-vault:** "**Nothing.** Both findings and both adjudications held against the current code."

**fix2-drainer:** "Empty — the finding held in full, and adjudication (e) held with it."

**fix2-recorder:** "**None.** All four findings held against the current tree when traced by call
path; I changed code for every one."

**fix2-voice-lanes:** "**Nothing.** Both findings were verified against the current tree by tracing
the call path before any code changed, and both hold. audio#1's evidence is exact. audio#3's is exact
and, on the collision half, conservative — the measured consequence of publishing bytes at the capture
id is not a dropped card but a **replaced payload** (§1)."

**fix2-audio-card:** "**None.** All five findings held against the current code, traced by call path
before any edit."

**fix2-canvas:** "**Nothing.** All three UI findings and the test-lens item held against the current
code; each is traced in §1–§3 to the line that made it true."

**fix2-store:** "**Nothing.** All five findings and all three adjudications held against the current
tree when traced by call path. The one qualification is r2#4's store half (§3): its consequence no
longer holds because fix2-vault's `urls(for:)` already carries the readability predicate — I adopted
contract C4's `readableKeys(among:)` there anyway and say so rather than claiming a fix I did not have
to make."

**fix2-inbox:** "Empty — both findings held in full."

**vm-collapse:** "**Nothing.** All five UI findings and the test-lens item held against the current
tree when traced by call path before any edit. The only qualification is ui#5's wording: the finding
offers "delete the sheet" as one option, and what I deleted is the sheet's NOTE half — the link half
is reachable, used, and untouched (§5)."

**ui-watch:** "(none — the one finding assigned to me held on inspection)"

**copy-b:** "Empty. Both findings held on trace, and the sibling sweep the second finding asked for
turned up one more false string (`workboard.voice.context`, already named in my brief as item (a)) and
six true ones I left standing with reasons recorded above."

**ui-docs:** no `## Refuted` section; its brief was a single documentation finding, recorded as
discharged ("The Codex finding is discharged: **zero** case-insensitive hits remain for `brief`,
`dispatch`, `preflight` or `review timeline` in the whole document").

**So the wave refuted NOTHING.** Every finding and every adjudication put to it held on trace. The two
qualifications above (fix2-store's r2#4 store half, vm-collapse's ui#5 wording) are the only places an
agent narrowed what it was given, and both are stated as narrowings rather than as refusals.

---

## Guard verdicts — every decision from the wave, verbatim, for Codex round 3

**fix2-vault:** "**None assigned.** My brief names no `t#N` item, and `codex-tests-findings.json`
contains no finding or drift-guard verdict for `WorkAssetVaultTests` or `WorkAssetVault.swift`. I
converted, deleted and kept nothing on that basis."

**fix2-drainer:** "**None assigned.** The independent reviewer's 25 drift-guard verdicts name no test
in either file I own, and neither file contains a source-text drift guard. Nothing kept-with-reason,
nothing converted, nothing deleted."

**fix2-recorder:**
- "`testTheRecordingIsPublishedBeforeTheTranscriptionHop` — **converted, then DELETED.** Its subject is
  now `testTranscriptionBeginsOnlyAfterTheRecordingIsADurableReadableCard`, which reads the desk from
  inside the orchestration instead of counting tokens."
- "`testOneCaptureIdentityNamesBothTheCardAndThePendingRetryRecord` — **converted, then DELETED.** Its
  subject is now the identity assertions at the end of
  `testAFailedTranscriptionCleansTheTemporaryFileAndLeavesTheCardStanding` (the card id IS the pending
  capture's id after a failed transcription). Honest limit: I assert the id the recorder holds, not a
  `PendingRetryStore` round trip — the App Group slot is a process-global singleton and a test that
  wrote to it would race every other capture test in the bundle. The write itself is one line
  (`preserveForRetry`), and `PendingRetryDestinationTests` already pins the metadata shape."
- "`testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes` — **KEPT as a source guard** (rated
  "convert"). A real conversion needs spies inside `ContentView`'s SwiftUI action and
  `MenuBar/DictationService`, neither of which this suite can mount (there is no UI test target, by
  decision) and neither file is mine this wave. Kept, with its doc comment now saying why it is
  source-scoped."

**fix2-voice-lanes:**
- "**`WorkboardAudioCaptureTests.testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes`** (rated
  `convert`): **KEEP.** I did not route the two surfaces through one shared tested coordinator
  (§5.2.3), and a real behavioural conversion needs a mounted SwiftUI view and a live `STTClient` on
  one surface and a menu-bar service on the other — a large abstraction, not one honest seam. It
  passes unchanged against my edits (verified, §6). My cases 10–12 now cover the same two files with
  two further properties (no `try?` collapse; no fallback at the capture id) and a negative control,
  so fix2-recorder may wish to consolidate the three — that is a merge, not a retirement."
- "**My own new guards (cases 6–12)**: kept as guards for the same reason, each paired with a Rule 0
  control so none of them is an assertion nobody has seen bite."

**fix2-audio-card:** "None assigned to me — my brief carries no `t#N` items and I added no source-text
drift guard."

**fix2-canvas:** "**None assigned.** My brief names t#4 only, and no `drift_guard_verdicts` row in
`codex-tests-findings.json` names a test in my ownership — I converted nothing and kept nothing that
was not mine to judge." Plus: "Three existing source guards read files I edited, and all three still
hold (checked, not assumed): `WorkboardAvailabilityTests.testTheDeskBannerReadsAccountStateRatherThanTheLastSyncEvent`
over `WorkboardCaptureCanvas.swift` (I touched neither the banner nor `recentSyncEventLines`), and
`WorkboardDeskSurfaceDriftGuardTests`' two over `PersonalWorkbenchView.swift` (`routeWorkboardDeepLink`
untouched; I added no second `workboardViewModel.load()`)."

**fix2-store:**
- "`WorkboardAvailabilityTests.testAvailabilityIsResolvedOncePerFetchRatherThanOncePerCard` | convert |
  **CONVERTED** to counting collaborators (§9). Source-text assertions deleted."
- "`WorkboardAvailabilityTests.testTheDeskBannerReadsAccountStateRatherThanTheLastSyncEvent` | convert |
  **KEPT as a source guard, with the reason now in its doc comment.** The desk has no presentation
  model to inject monitor states into — the banner is read inside `WorkboardCaptureCanvas`'s body from
  the shared monitor. Converting means mounting SwiftUI (no UI test target, by decision) or extracting
  a desk presentation layer that would exist for this test alone; the canvas is also not my file this
  wave. `CloudSyncMonitorTests` plus the case below it (the three actionable reasons read differently)
  carry the behaviour."
- "`WorkboardAvailabilityTests.testTheAvailabilityProjectionNeverNamesThePayloadColumn` | keep | Left
  exactly as it was."

**fix2-inbox:**
- "**`WorkCaptureInboxTests.testShareWritersValidateAndRollbackBeforeAtomicPublication` — rated
  `convert`. CONVERTED.** Its subject (validate-before-publish, rollback, atomic publication) is now
  four behavioural cases against an injected filesystem, and its `targetWorkItemID: nil` clause is now
  enforced by the transaction itself. The test's own anchors no longer exist in either appex, so it
  fails on my tree; deleting it is §Requests 1." — **executed by me, §1.1.**
- "**One source guard deliberately KEPT — `testBothShareExtensionsPublishThroughThePublisherRatherThanByHand`.**
  Its claim is not "these tokens appear in this order" but "this extension delegates to the tested
  transaction and publishes nothing by hand", which is the only thing that ties the behavioural
  coverage to a target no test bundle can link. It is scoped to the `writeWorkCaptureEnvelope` slice
  (the Send-now path keeps its own rename), and it carries a negative assertion, so dead code
  containing `publisher.commit` alongside a live hand-rolled rename fails it. Converting it further
  would need the appex compiled into a test target, which the duplicate-type-name constraint forbids."

**vm-collapse** — `WorkboardDeskSurfaceDriftGuardTests`, all four KEPT, preceded by: "The brief's
verdict was "convert only those a small honest seam allows … the two that would need SwiftUI view
mounting stay as guards". I converted **none**, and here is the per-test reason. I would rather say
that plainly than manufacture a weaker behavioural test and delete a stronger guard."
- "`testTheDeskRendersTheFixedIdentityAndResolvesNoItem` | **KEEP** | Its subject is
  `WorkboardDetailView`'s `body` — a SwiftUI view with no test target to mount it (`AGENTS.md`: no
  UI-test target, by decision). Still true and now *stronger*: `item(withID:` cannot appear anywhere
  because the method no longer exists."
- "`testTheEmptyDeskShowsTheEmptyStateAndKeepsTheComposer` | **KEEP** | Same file, same reason: what a
  `body` draws is not observable headlessly."
- "`testEveryWorkDeepLinkResolvesToTheDeskThroughTheRefreshCoordinator` | **KEEP** | The brief's
  suggested seam — "drive the deep-link router with **arbitrary payloads**" — no longer applies:
  `routeWorkboardDeepLink()` takes **no parameter** (the shell's `.onReceive` discards the
  notification), so payload-independence is a fact of the signature, not of discipline. What remains is
  two statements inside a `private func` on a `View` struct. Converting means moving the routing onto
  `PersonalWorkbenchModel` **and** injecting a store + inbox into `PersonalWorkbenchModel.init()`,
  because its real init builds `WorkboardLiveRepository(store: .shared)` — a live
  `NSPersistentCloudKitContainer` no unit test in this suite touches. That is a production API change
  to a file where my grant is call sites, in exchange for a flakier assertion than the guard's. Not a
  small honest seam."
- "`testTheRefreshCoordinatorIsTheOnlyBoardLoadOwner` | **KEEP** | It asserts an ABSENCE over a whole
  file (exactly one `workboardViewModel.load()` call site). A behavioural test can only show that one
  *particular* action loads once; it cannot show that no other path exists. The coordinator's own
  behaviour — visibility gate, serialization — is already covered behaviourally by
  `WorkCaptureRefreshCoordinatorTests` (6 cases, green), so the guard is holding the wiring, which is
  what a source guard is for."

**ui-watch:**
- "`WorkboardBlobSeamPlatformGuardTests.testTheMountedStoreSeamStaysAvailableOnTheWatch` — rated
  `convert`, **CONVERTED and deleted**. The conversion is the t#6 test above: a real Watch-suite call
  to `_mountedStoresForTesting()` makes the compiler the guard (sweeping the seam under
  `#if !os(watchOS)` breaks the watch build outright), and the same call verifies the Core-only mount
  the source guard could only infer. I rewrote the four-line paragraph in the file header that claimed
  the guard "pins the exclusion in BOTH directions" to state the new constraint instead (present
  tense, no changelog narration)."
- "`WorkboardBlobSeamPlatformGuardTests.testThePayloadSeamsAreCompiledOutOfTheWatchBuild` — rated
  `keep`, **left untouched**. The helpers it shares with the deleted test (`loadStoreSource`,
  `conditionsByLine`, `conditions(wrapping:)`, `normalised`) are all still used by it; nothing went
  dead."
- "`WorkCaptureInboxTests.testTheWatchCaptureBoundStillRestatesTheEnvelopeBound` — rated `keep`, kept;
  only the expected spelling moved with the rename (see Call-site touches)."

**copy-b, ui-docs:** no `## Guard verdicts` section (neither was assigned a `t#N` item).

**Integrator's note on the pattern, for Codex.** Of the wave's drift-guard verdicts: **3 converted-
and-deleted** (fix2-recorder ×2, ui-watch ×1), **1 converted with the deletion delegated to me and now
executed** (fix2-inbox), **8 kept with a stated reason**, and **the rest not assigned**. Every single
`keep` gives the same underlying reason in a different dress — *the subject is a SwiftUI `body`, an
appex a test bundle cannot link, or an ABSENCE over a whole file*, and there is no UI-test target by
decision. That is worth adjudicating as one question rather than eight: **is a source-text guard the
right instrument for those three shapes, or does the project want a seam that makes them
behavioural?** Two agents (vm-collapse, fix2-voice-lanes) explicitly refused to "manufacture a weaker
behavioural test and delete a stronger guard", which reads to me as the correct call under the current
constraints — but it is a standing policy question, not eleven local ones.

---

## Open items for Codex round 3

**Closed since round 2, so they need no adjudication** — recorded because fix-verify passed them
through and Codex will look for them: fix-verify §8.2's **truncation half** is closed
(`expectedByteCount:` is now passed at all three `confirmPublication` sites, over a `byteSize` column
that records the length the vault measured off the leaf — fix2-vault (b) + fix2-store (b)); its
**untested refusal branch** is closed (fix2-store's `publicationConfirmationHookForTesting`, seam (c),
with all three branches asserted); fix-verify §8.3's **`markReferenced`** is closed (deleted,
fix2-vault (d)); fix-verify §5's missing store→vault confirm test is closed by the same seam.

| # | Item | Why it is open, and who it belongs to |
|---|---|---|
| **O-1** | **The cross-process publication residue.** fix2-store's per-material claim closes the in-process interleaving fix-store §3 described and states the invariant at `deleteBlobRow`; across processes (app + headless intent, deterministic capture ids) the claim does not reach. fix2-store declined a publication-identity column: a schema change to a model headed for CloudKit Production, for a residue it argues is bounded and repairable (adopter's card reads `.syncedPending`; a replay of either capture restages; the drainer's barrier refuses to acknowledge). **Codex should adjudicate whether "bounded and repairable" is the right trade, or whether the column is owed before model 16 deploys** — after deployment it can never be withdrawn. Not verified by any harness on either side. |
| **O-2** | `IsolatedWorkStores` adoption in the classes fix2-store did not own (`WorkAssetVaultTests`, `WorkboardMaterialBoardActionsTests`, `WorkboardDeskViewModelTests`, `WorkboardAudioCaptureTests`, and every other `ConversationStore(inMemory:)` builder). Measured residue: 82 directories / 155 MB in one simulator. Hygiene, not correctness. |
| **O-3** | Register the mic authority (`InAppAudioRecorder`, `MenuBar/DictationService`) and possibly `ThreadSpeaker` on **iOS**, not only macOS. Today an iOS audio card's capture refusal rests on `CarPlayRecordingService.anySessionActive` alone, and a starting recorder cuts playback at the OS level while the card still reports `.playing` over silence. fix2-audio-card §1–§2. |
| **O-4** | Carry `WorkMaterial.filename` onto `WorkboardMaterialSnapshot` so a voice note's preview copy gets its real `.m4a`. Today the extension is derived from the mime type and `audio/mp4` prefers `mp4` — playable and correct, but not the stored name. fix2-audio-card §3 / fix2-canvas §3. |
| **O-5** | The availability glyph/tint/label mapping is still duplicated between `WorkboardSourceCard` and `WorkboardAudioCardView`'s chip. The wave shared the ACTION rule (`WorkboardCardActionPolicy`) and deliberately left the COPY rule alone. A `WorkboardAvailabilityChip` in `WorkboardComponents.swift` closes it. fix2-canvas §4. |
| **O-6** | `.openPersonalAISettings` has **no poster** — deleting `PersonalWorkbenchRouter.openGatewaySettings()` (ui#7's own fix) removed the only one, while the name and four observers survive (`ContentView.swift:291,675`, `PersonalWorkbenchView.swift:900`, `MainWindowView.swift:839`). Either delete the name plus its observers, or give it a poster. Three of the five sites are Chat-side. vm-collapse §1. |
| **O-7** | **Hoist the attach/fallback decision into one shared coordinator, and re-anchor the two guards that hold it in place.** fix2-voice-lanes §5.2.3 + §Requests 2 gives the exact order: `HeadlessRetryGuardSpanTests` re-anchors `workPublish` first (its ordering assertion must survive), then `WorkboardAudioCaptureTests.testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes` asserts the single call. **Do not do either half without the hoist** — today they are the only thing holding `ContentView` and `DictationService` in step. This is also the concrete form of the standing-policy question at the end of §Guard verdicts. |
| **O-8** | `WorkboardViewModel.workspaceStatus` → `transientStatus`/`deskStatus` — the last "workspace"-named member, six reader lines in `WorkboardView.swift`. Vocabulary only. vm-collapse §2. |
| **O-9** | `PendingRetryMetadata.transcript: String?` (additive, decodes nil for existing records exactly like `destination`) so a transcript recovered but not attached before a kill is restored rather than re-derived by a second provider call. fix2-recorder §1. |
| **O-10** | A dedicated `AppError` case for a desk-write failure. It rides `.unknown` today and renders "An unexpected error occurred: Work couldn't save this recording just now." fix2-recorder §2. |
| **O-11** | Should a recovered `.work` pending retry whose card never landed **republish the recording** from the bytes it still holds? fix2-recorder says it could; fix2-voice-lanes declined because `.recordingMissing` also covers *a person deleting the card while STT is in flight*, and republishing would resurrect a deleted card. A product call. |
| **O-12** | Both retry surfaces write recovered bytes to `conduck_retry_….m4a` whatever container they hold, and both lanes now preserve COMPRESSED bytes (which `AudioCompressor` can return as WAV). `SourceAudioContainer.sniff(…).fileExtension` settles it in one line at each site. Pre-existing on one lane, now two. fix2-voice-lanes §5. |
| **O-13** | The four behaviour-neutral consolidations integrate-c §4 deferred and no wave-B agent took: the board-tile radius `13` literal into `WorkboardMetrics`; one shared `WorkboardCardActions` for the two cards' menus; one owner for the audio-session category/mode/deactivation now duplicated between `WorkboardAudioCardPlayer` and `ChatPlaybackSession`; `onCancel` → `onDismiss` on the voice sheet's hand-off. |
| **O-14** | **Founder copy call (sixth raise):** `sync.icloud.banner.{noAccount,restricted,quotaExceeded}` say "your conversations" and `WorkboardCaptureCanvas.deskSyncBanner` renders them verbatim on the desk. Plan §C says reuse those keys, so it stays until the founder rules. Widen the three (Chat loses its specific word) or mint `workboard.sync.banner.*` (3 keys, one edit). copy-b's vocabulary guard does not cover them — they are `sync.*`. |
| **O-15** | Watch catalog drift, pre-existing since `efa553e`: `WatchRecordingService.swift:760` declares `watch.capture.defaultGatewayNotSetUp` = "…**isn't available**…" while the Watch catalog row reads "…**isn't set up**…". The catalog wins at runtime, so the source lies to the next reader. Not a Work string. copy-b §5. |
| **O-16** | **Spec-size debt** — 19827 words against a 16900 ceiling, with two unrelated decisions over their 650-word limits. Out of scope by plan §"Out of scope", recorded so it is a standing decision. copy-b flags the recapture/adoption sentence as the weakest under the one-file rule if the guard is ever fought seriously. |
| **O-17** | **Editorial:** the two-store fact (`Core` / `Blobs`, the Watch mounting only the first) now appears in both `project-structure.md` (build-topology pointer) and `spec.md` (prose boundary). ui-docs §2 argues they are compatible and names the row to delete if anyone wants exactly one home. |

## Call-site touches

**None.** Every symbol I removed had exactly the callers each fixnote named, and I updated those two
(`WorkboardLiveRepositorySupportTests.swift:22-23`) in place. No signature anywhere changed; no file
outside the six in the table above was opened for editing.

## Cleanup

`/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh integrate-d` — run at end of
task. **Every log quoted above goes with it**; re-run if you need them. No bare `rm -rf`, no `/tmp`,
no throwaway tree copy (I made none — the gate is on the shared tree by definition).
