# integrate-c — part 2b close-out. PASS. The tree builds again on both platforms; targeted sweep 456 executed / 0 failures across 46 classes.

Slug `desk-integrate-c`. Sim `04DEF4F5-C144-4936-AEC3-A971B4FA9CDC`. Every log under `~/Library/Caches/gigaduck-builds/desk-integrate-c/`, grepped for `': error: '` and the `BUILD/TEST` result lines — never judged from tail or exit code. No `-configuration` passed anywhere. Build cache removed at the end, so the logs no longer exist; re-run if you need them.

**The blocker is closed.** `WorkboardMaterialKind.audio` now exists, the `.audio → .file` narrowing is gone, and the three assertions that encoded the opposite contract were rewritten — see §1 for the decision and why it is the plan's, not mine.

---

## 1. The `.audio` design disagreement — option (a), and the assertion change that comes with it

strings-audit §6 / §Requests 1 and copy-truth §Requests 2 stopped on a genuine cross-slice disagreement: `WorkboardCaptureCanvas` routes the audio card off a presentation-level `WorkboardMaterialKind.audio`, while `WorkboardLiveRepositorySupportTests` asserted a stored `.audio` narrows to the `.file` card shape. Both fixnotes correctly refused to pick.

**Option (a) wins, because the plan already picked it.** Plan §D says a Work voice note becomes a *playable audio card* with play/pause, progress and a transcript caption. Under (b) the stored `.audio` keeps projecting as a `.file` card, `WorkboardAudioCardView` is never reached, and §D ships as a file tile with a Quick Look — i.e. (b) is not a cheaper route to the same product, it is the absence of the feature. The `.file` narrowing predates the audio card and was correct while a recording had no card of its own.

Consequences, all applied:

| File : symbol | Change |
|---|---|
| `Conduck/Conduck/ViewModels/WorkboardViewModel.swift` : `WorkboardMaterialKind` | `case audio`; `title` → `LocalizedStringResource("workboard.material.audio", defaultValue: "Voice note")`; `systemImage` → `"waveform"` |
| `Services/Workboard/WorkboardLiveRepository.swift` : `presentationKind(_:)` | `case .file, .audio: return .file` split into `case .file: return .file` / `case .audio: return .audio` — **the one line that makes the card reachable** |
| same : `materialName(_:)` fallback switch | `case .audio:` → `workboard.material.audio` / "Voice note" |
| same : `storageKind(_:)` | `case .audio: return .audio` |
| same : `publishWorkMaterial`'s `switch material.kind` | `case .image, .file, .audio:` — a recording arrives carrying bytes or a file URL exactly as a file does |
| `Views/Workboard/WorkboardComponents.swift` : `WorkboardMaterialIcon.tint(for:)` | `case .image, .note, .audio: return AppColors.brandAmber` |
| `Views/Workboard/PersonalWorkbenchView.swift` : `present(_:)` | `case .file, .audio:` on the file arm — Quick Look plays it; the board's own card never routes here |

**Assertions rewritten (3, in `ConduckTests/WorkboardLiveRepositorySupportTests.swift`), stated plainly because the standing rule is about exactly this:** none was weakened, skipped or deleted — each still asserts the same property against the contract the plan chose.
- `testPresentationKindNarrowsEveryStoredKindToACardShape`: the `(.audio, .file)` row became `(.audio, .audio)`; the exhaustiveness set `[.image, .file, .link, .note]` became `[.image, .file, .link, .note, .audio]`. Its "every stored kind resolves; a new one must be given a shape here" message survives verbatim, which is the assertion doing the work.
- `testMaterialNameFallsBackFromTitleToFilenameToHostToKind`: a nameless recording is now named `workboard.material.audio` / "Voice note" instead of "File". The rule it encodes ("named by the shape it draws as") is unchanged — the shape moved.
- Both doc comments were rewritten to the new constraint, no changelog narration.

`WorkboardMaterialIcon.symbol(for:)` needed no arm: it special-cases `.file` for mime/extension icons and otherwise returns `kind.systemImage`, so `.audio` draws `waveform`.

## 2. Requests I resolved

**audio-card §Requests 1 + audio-capture §Requests 1 + strings-audit §Requests 1 + copy-truth §Requests 2 — all four are the same blocker, closed by §1.** audio-card's compiler-proven patch list was exact and complete; I applied it verbatim plus the two arms strings-audit's probe found (`publishWorkMaterial`'s payload switch, and `WorkboardMaterialIcon.tint`), and got 0 errors on both platforms first try.

**audio-capture §Requests 4 — the macOS retry gap, closed.** `MenuBar/DictationService.swift : retryLast()` published the recovered transcript unconditionally on the Work arm, so a Work voice capture that failed STT on macOS was recovered as words that never reached the recording card (no duplicate, no note — the upsert returned the existing audio card unchanged — but no transcript either). It now mirrors `ContentView.swift:1554` exactly: try `WorkVoiceCaptureCoordinator.attachTranscript(trimmed, toRecording: pending.metadata.id)` first, publish only on `false`. Same three lines, same comment shape.
- I added the guard that keeps the two surfaces in step: **`WorkboardAudioCaptureTests.testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes`** — a source guard over `ContentView.swift` and `MenuBar/DictationService.swift` asserting each contains `attachTranscript(` and that it precedes `WorkCaptureRetryCoordinator.publish(`. It goes in the existing audio file (no new file, no pbxproj edit) and takes that class 12 → 13.
- `Intents/ConverseIntent.swift:457` also calls `WorkCaptureRetryCoordinator.publish` and is deliberately NOT in the guard: it is a live Action-Button/Shortcuts capture, not a retry surface, and that lane publishes no recording card.

**audio-capture §Requests 3 — already discharged by copy-truth, verified rather than assumed.** `workboard.voice.privacy` now reads *"Keeps the recording on your private desk and adds the words when they're ready…"* and `workboard.voice.stop` reads *"Stop and Save"*, in source and catalog together. New keys were not needed because copy-truth moved the values on both sides. `workboard.voice.context` ("Add context and thoughts") is unchanged and remains a founder copy call.

**copy-truth §Requests 3 — `WorkboardBlobSeamPlatformGuardTests` confirmed live:** `Executed 2 tests, with 0 failures`.

**strings-audit §Requests 6 — does not reproduce.** `WorkCaptureDrainerDurabilityTests` passed **three separate runs** here (`Executed 5 tests, with 0 failures` each). strings-audit observed its two failures under a probe run that had mutated `WorkboardLiveRepository` + `WorkboardViewModel` + `WorkboardComponents`; on the real tree with the real patch it is green. Treating it as a real regression would be wrong on this evidence — but it is a lease/timing test, so a single future red is worth re-running before believing.

**strings-audit §Requests 8 — `workboard.material.audio` is now owed and paid.** Added to `Conduck/Conduck/Localizable.xcstrings` = `Voice note` (§Catalog).

## 3. Requests I deliberately did NOT take, each with its reason

1. **audio-card §Requests 3 — the audio card's "Reattach" chip has no action.** Left as-is, deliberately. The chip is a non-interactive label (`accessibilityHidden`), and `.unavailableOnThisDevice` is **unreachable for a Work voice note**: plan §D caps a recording at ≤15 MB, always under the 30 MB ceiling, so it takes the synced lane and shows `.syncPending` instead. The state only bites an imported audio FILE above the ceiling, seen on a second device. Wiring reattach means a new property + button + menu row + VoiceOver action + tests in a view whose author is gone — not a minimal cross-slice fix at a gate. **It stays a one-line founder decision:** wire `beginReattachment` into the audio branch of `WorkboardCaptureCanvas.card(for:at:)`, or give that case copy that does not name an action the card cannot perform.
2. **audio-card §Requests 4 (radius `13` literal, shared card-menu component, duplicated availability mapping) and §Requests 5 (hoist the audio-session helper out of `ChatPlaybackSession`) and audio-capture §Requests 2 (`onCancel` → `onDismiss` rename).** All four are cosmetic consolidations with zero behaviour change, spanning files with live tests, proposed at the moment the tree first went green. The risk/benefit at a gate is wrong. They are real and should be a follow-up session, not a close-out.
3. **copy-truth §Requests 1 / availability §2 / integrate-b §3 / test-surgery §3 — the desk's iCloud banner saying "your conversations".** Fifth fixnote to raise it; still a founder copy call between widening three shared keys and minting three desk-specific ones. **Plan §C explicitly says the desk banner reads the existing localized `noAccount`/`restricted`/`quotaExceeded`**, so leaving it is the plan-coherent answer, not neglect.
4. **strings-audit §Requests 2 (`WorkboardSurface` has zero consumers) and §Requests 3 ("Add Note" has no door on the desk).** Both are product decisions, both raised repeatedly, neither is breakage. Adopting or deleting either at a gate would foreclose a founder call.

## 4. What I ran, and the exact result lines

**iOS `build-for-testing`** (sim `04DEF4F5…`), `ios-bft-1.log` (after the production changes) and `ios-bft-2.log` (after the guard test): `grep -c ': error: '` = **0** both times, `** TEST BUILD SUCCEEDED **` both times.

**macOS `build -destination 'platform=macOS'`**, `mac-build-1.log`: `grep -c ': error: '` = **0**, `** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`. **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed.**

**Targeted sweep**, `sweep-2.log`, `test-without-building`, one quoted `-only-testing:ConduckTests/<Class>` per class, 46 classes: `** TEST EXECUTE SUCCEEDED **`, `grep -c ': error: '` = 0, and

```
Test Suite 'ConduckTests.xctest' passed
	 Executed 456 tests, with 0 failures (0 unexpected) in 12.009 (12.132) seconds
```

Per class:

| Class | Result line |
|---|---|
| `AudioCompressorTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.097 (0.099) seconds` |
| `CloudSyncMonitorTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.006 (0.009) seconds` |
| `ConversationStoreAtomicWorkCaptureTests` | `Executed 3 tests, with 0 failures (0 unexpected) in 0.031 (0.037) seconds` |
| `ConversationStoreWorkCaptureTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.429 (0.430) seconds` |
| `ConversationsModelMigrationTests` | `Executed 20 tests, with 0 failures (0 unexpected) in 0.821 (0.825) seconds` |
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 2.786 (2.787) seconds` |
| `LockedKeychainKVSLiteralsTests` | `Executed 17 tests, with 0 failures (0 unexpected) in 0.007 (0.012) seconds` |
| `LockedNetworkAndPairingLiteralsTests` | `Executed 13 tests, with 0 failures (0 unexpected) in 0.007 (0.012) seconds` |
| `LockedRawValueLiteralsTests` | `Executed 21 tests, with 0 failures (0 unexpected) in 0.011 (0.017) seconds` |
| `LoggingPrivacyDriftGuardTests` | `Executed 4 tests, with 0 failures (0 unexpected) in 2.293 (2.294) seconds` |
| `MacWorkbenchShellDriftGuardTests` | `Executed 4 tests, with 0 failures (0 unexpected) in 0.042 (0.043) seconds` |
| `PersonalAIVocabularyTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.004 (0.005) seconds` |
| `ShareTargetFilterTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.006 (0.013) seconds` |
| `ShareTargetsSnapshotTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.008 (0.011) seconds` |
| `ShareTargetsSnapshotWriterColorTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.004 (0.007) seconds` |
| `SharedInboxDrainerTests` | `Executed 31 tests, with 0 failures (0 unexpected) in 2.038 (2.045) seconds` |
| `SharedInboxManifestTests` | `Executed 18 tests, with 0 failures (0 unexpected) in 0.007 (0.012) seconds` |
| `SharedInboxRoutingTests` | `Executed 16 tests, with 0 failures (0 unexpected) in 0.046 (0.049) seconds` |
| `SharedInboxUploadKeyTests` | `Executed 10 tests, with 0 failures (0 unexpected) in 0.004 (0.006) seconds` |
| `WorkAssetVaultTests` | `Executed 15 tests, with 0 failures (0 unexpected) in 0.056 (0.059) seconds` |
| `WorkCaptureDrainerDurabilityTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.117 (0.118) seconds` |
| `WorkCaptureDrainerTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.071 (0.073) seconds` |
| `WorkCaptureInboxLeaseTests` | `Executed 14 tests, with 0 failures (0 unexpected) in 0.050 (0.052) seconds` |
| `WorkCaptureInboxTests` | `Executed 30 tests, with 0 failures (0 unexpected) in 0.138 (0.144) seconds` |
| `WorkCaptureRefreshCoordinatorTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 1.012 (1.015) seconds` |
| `WorkMaterialStoragePolicyTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.003 (0.005) seconds` |
| `WorkboardAudioCaptureTests` | `Executed 13 tests, with 0 failures (0 unexpected) in 0.054 (0.057) seconds` |
| `WorkboardAudioCardTests` | `Executed 15 tests, with 0 failures (0 unexpected) in 0.080 (0.083) seconds` |
| `WorkboardAvailabilityTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.059 (0.061) seconds` |
| `WorkboardBlobGCTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.035 (0.037) seconds` |
| `WorkboardBlobPublicationTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.091 (0.093) seconds` |
| `WorkboardBlobSeamPlatformGuardTests` | `Executed 2 tests, with 0 failures (0 unexpected) in 0.033 (0.034) seconds` |
| `WorkboardBoardProjectionTests` | `Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds` |
| `WorkboardChatCaptureTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.042 (0.043) seconds` |
| `WorkboardDeskIdentityDriftTests` | `Executed 2 tests, with 0 failures (0 unexpected) in 0.794 (0.795) seconds` |
| `WorkboardDeskSurfaceDriftGuardTests` | `Executed 4 tests, with 0 failures (0 unexpected) in 0.018 (0.019) seconds` |
| `WorkboardDeskUpsertTests` | `Executed 10 tests, with 0 failures (0 unexpected) in 0.084 (0.086) seconds` |
| `WorkboardDeskViewModelTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.070 (0.071) seconds` |
| `WorkboardLiveRepositorySupportTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds` |
| `WorkboardMaterialBoardActionsTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.014 (0.016) seconds` |
| `WorkboardMaterialPresentationTests` | `Executed 4 tests, with 0 failures (0 unexpected) in 0.002 (0.004) seconds` |
| `WorkboardModelMigrationTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.183 (0.184) seconds` |
| `WorkboardMosaicEngineTests` | `Executed 26 tests, with 0 failures (0 unexpected) in 0.040 (0.044) seconds` |
| `WorkboardPersistenceTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.048 (0.050) seconds` |
| `WorkboardTwoStoreLoadTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.250 (0.252) seconds` |
| `WorkboardWorkspaceCaptureTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.005 (0.006) seconds` |

(`sweep-1.log`, the same 46 classes before the guard test, read `Executed 455 tests, with 0 failures (0 unexpected)`.)

**Flake check on the class strings-audit reported failing** — `WorkCaptureDrainerDurabilityTests` + `WorkCaptureInboxLeaseTests` alone, twice more: `flake-1.log` `Executed 5 / 0 failures` + `Executed 14 / 0 failures`; `flake-3.log` the same. `flake-2.log` between them died with `** TEST EXECUTE FAILED **` and **no test case ever started** — `FBSOpenApplicationServiceErrorDomain Code=1 … Application failed preflight checks / Busy`, a simulator launch refusal from back-to-back runs. Handled per the standing rule (`xcrun simctl shutdown all`, one retry via `test-without-building`) and it passed; recorded here rather than quietly dropped.

**NOT run, plainly:** the **full iOS suite** and the **watch suite**. Neither is in my brief (targeted sweep + two builds), and no watch sim is assigned to me. §Requests 1 carries what the orchestrator still owes.

## 5. Hygiene — every item, with its result

- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 777 Swift files scanned, no raw store or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift`, exit 0.
- `git diff --check` → clean, exit 0.
- **All four catalogs `json.load` clean**: main **2242** (2241 + `workboard.material.audio`) · ShareExtension 43 · ShareExtensionMac 42 · Watch 299 — the last three untouched by me.
- **Mirror triplets**: `WorkCaptureEnvelope.swift` ×3 and `ShareTargetsSnapshot.swift` ×3 are all six **unmodified in `git status`**, and each pair is **byte-identical from `import Foundation` onward** (14,801 and 9,704 bytes; app==iOS and app==macOS both `True`). Bare `cmp` differs only in the per-target header lines, which is what the files' own headers prescribe. `ShareTargetsSnapshotTests` (9/0) and `WorkCaptureInboxTests` (30/0) — the two drift guards — pass.
- **Bidirectional string check** (my own, over every Swift file under `Conduck/`): every `workboard.*` / `intent.workboardCapture.*` key declared in source exists in its catalog and its `defaultValue` **equals** the catalog `en` value — 0 missing, 0 mismatched, in the main catalog and in the Watch catalog. (`workboard.error.contentTooLong`'s `\(limit)` vs `%@` is an interpolated literal and is outside this comparison by construction — copy-truth §6.3 says do not "fix" it, and I did not.)
- `git status --short` for `Conduck/Configs`, `docs/qa/`, `Conduck.xcodeproj` → **empty**. No pbxproj edit was needed: both new Swift files from earlier slices and my test additions live in synchronized groups.
- No commits, no pushes, no stash, no checkout/reset. `Identity-Override.xcconfig` untouched.
- Build cache removed with `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-integrate-c`.

## 6. What the next agent must know

1. **`WorkboardMaterialKind` now has five cases.** Any new switch over it needs an `.audio` arm, and the one that matters is `WorkboardLiveRepository.presentationKind` — if `.audio` ever narrows to `.file` again, `WorkboardAudioCardView` becomes unreachable code and the feature disappears with a green build. `WorkboardLiveRepositorySupportTests.testPresentationKindNarrowsEveryStoredKindToACardShape` is the guard.
2. **The two retry surfaces are now in lockstep and a test holds them there.** `ContentView.retryLast`-side and `MenuBar/DictationService.retryLast` both attach-then-publish. Adding a third retry surface means adding it to `testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes`'s path list, not just copying the publish call.
3. **Main-catalog edits: raw-line splice, never `json.dump`.** I inserted `workboard.material.audio` above the `"workboard.material.card.more"` anchor line with a 12-line block matching the file's 4-space/`"key" : {` formatting, then validated by `json.load` + asserting the parsed dict differs from the pre-edit dict by exactly one added key and **zero value changes on any untouched key**. copy-truth §5's warning holds: do not compute an insertion slot by case-insensitive comparison — name the anchor.
4. **The catalog is now at 2242 keys and the Work family is clean in both directions.** strings-audit §Requests 5 still binds: never run a blanket zero-reference sweep over this file.
5. **`WorkCaptureDrainerDurabilityTests` is green here (3/3 runs).** strings-audit's red was a probe artifact. If it goes red once in a full-suite run, re-run it alone before filing it.
6. **A 24 MB tree copy from the audio-capture slice may still sit at `…/scratchpad/verify-tree-1`** (they could not delete it — `rm -rf` is denied to agents). It is inside this session's scratchpad; the founder can remove it.

---

## Catalog

**Keys I ADDED in source (1)** — and its catalog row, both landed together:

```
workboard.material.audio = Voice note
```
Declared at three source sites: `WorkboardMaterialKind.audio.title` (`ViewModels/WorkboardViewModel.swift`), `WorkboardLiveRepository.materialName(_:)`'s fallback switch, and the assertion in `WorkboardLiveRepositorySupportTests`. It is the noun a nameless recording is named by, and the one `WorkboardAudioCardView`'s accessibility label opens with (audio-card §Deviations 3).

**Keys I ADDED to a catalog (1):** `Conduck/Conduck/Localizable.xcstrings` → `workboard.material.audio` = `Voice note`. Main catalog **2241 → 2242**. No other catalog touched.

**Keys I found DEAD: NONE.** I deleted no code carrying a string; the two source arms I rewrote (`presentationKind`, `materialName`) keep every key they had.

**Verified paid, not assumed:** all 8 keys the audio wave declared (`workboard.audio.{play,pause,playing,paused,loading,failed,position}` + `workboard.voice.recording.untitled`) were already spliced into the main catalog by strings-audit; I re-checked each and each matches its source `defaultValue`. Nothing was owed but `workboard.material.audio`.

---

## Requests

1. **Orchestrator — the gate still owes two runs, and they are the only things between this tree and the plan's §F gate.**
   - **Full iOS suite** on `04DEF4F5-C144-4936-AEC3-A971B4FA9CDC`. Predicted count from integrate-b's 4758 baseline: **+2** (`WorkboardBlobSeamPlatformGuardTests`, already landed at fix-seams' prediction) **+13** (`WorkboardAudioCaptureTests`, 12 from audio-capture plus my retry-parity guard) **+15** (`WorkboardAudioCardTests`) = **4788**, 0 failures, skips unchanged. Treat that number as a prediction, not a claim — I ran 46 classes, not the suite.
   - **Watch suite** on `28AC563B-42C1-4E66-940D-77E63B07918B` (copy-truth §Requests 4 — the Watch catalog and `ConduckWatch Watch App/WorkboardCaptureIntent.swift` changed after fix-seams' last green 231/0). **None of my edits can reach it**: I verified against `project.pbxproj` that no `PBXFileSystemSynchronizedBuildFileExceptionSet` names `WorkboardViewModel.swift`, `WorkboardLiveRepository.swift`, `WorkboardComponents.swift`, `PersonalWorkbenchView.swift` or `DictationService.swift`, so the watch target compiles none of them.
2. **Founder — three copy/product calls, all raised by several fixnotes and none of them mine to make.** (a) The desk's iCloud banner still says "your conversations" (`sync.icloud.banner.*`); plan §C says reuse those keys, so it stays until you say otherwise. (b) `workboard.voice.context` = "Add context and thoughts" is the navigation title of a sheet that now records. (c) The audio card's `.unavailableOnThisDevice` chip says "Reattach" with no way to do it — §3.1 has the two options and why the state is nearly unreachable for a voice note.
3. **Founder QA (Gate 2) — add one macOS item to audio-capture's list.** On macOS, record a Work voice note with STT failing (airplane mode), quit and reopen, then use the menu-bar retry: the recovered words must land on the SAME card — no note beside it. That path had no repair before this slice and no automated test can prove it end to end.
4. **Next session, not this gate — the four consolidations in §3.2** (board-tile radius `13` duplicated into `WorkboardMetrics`; a shared `WorkboardCardActions` for the two cards' menus; one owner for the audio-session category/mode/deactivation now duplicated between `WorkboardAudioCardPlayer` and `ChatPlaybackSession`; `onCancel` → `onDismiss` on the voice sheet's hand-off). Each is behaviour-neutral and each removes a real divergence risk.
5. **Nobody re-narrow `.audio` to `.file`.** It compiles, it goes green everywhere except one assertion, and it silently removes the audio card from the product. §6.1.
