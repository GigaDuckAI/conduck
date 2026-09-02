# ui-watch — Watch capture vocabulary (ui#10) + Watch topology test (t#6) + drift-guard deletions (t#12, convert)

Parallel phase. No commits/pushes/stash. `Identity-Override.xcconfig` untouched. No `.xcstrings` opened. Nothing under `docs/qa/desk-cloudkit/` touched. No pbxproj edit (all files sit in synchronized groups; the deleted files are removals, and a removal from a synchronized group needs none).

Files changed — only files I own:
- `Conduck/ConduckWatch Watch App/WorkboardCaptureIntent.swift`
- `Conduck/ConduckWatchTests/ConduckWatchSmokeTests.swift`
- `Conduck/ConduckTests/WorkboardBlobSeamPlatformGuardTests.swift`
- `Conduck/ConduckTests/WorkCaptureInboxTests.swift` (ONE assertion line — see `## Call-site touches`)
- DELETED `Conduck/ConduckTests/WorkboardDeskIdentityDriftTests.swift`

---

## ui#10 — "the Watch capture intent still models a note as an objective" — **VERDICT: fixed**

**Verified against current code first.** At the time I opened it the file still declared `WatchWorkboardCapture { let title; let objective }` (line 26-29), `static let maximumObjectiveCharacters = 16_000` (line 37), and wrote `row.setValue(capture.objective, forKey: "textContent")` — so the value named `objective` was in fact going straight into the material's `textContent` column, exactly as the finding claims. The iOS `Intents/CaptureWorkboardIntent.swift` models the same input as `@Parameter var thought` bounded by `WorkCaptureEnvelope.maximumNoteCharacters` and passes it as `WorkMaterialDraft(textContent:)`. The evidence held.

**What changed (symbols):**
- `WatchWorkboardCapture.objective` → `WatchWorkboardCapture.textContent`. Chose `textContent` over `thought`/`text` because the struct is the wrist's stand-in for `WorkMaterialDraft` — it pairs `title` with the value that becomes `WorkMaterial.textContent`, and the iOS intent's own identifier for that value at the store boundary is `textContent`. (`thought` is the *parameter* name, and that name is frozen and already identical on both intents — `@Parameter var thought` is untouched.)
- `WatchWorkboardCaptureText.maximumObjectiveCharacters` → `maximumNoteCharacters`, byte-for-byte the spelling of the constant it mirrors (`WorkCaptureEnvelope.maximumNoteCharacters`). Value unchanged (`16_000`).
- Call sites inside the file: the `guard normalized.count <= maximumNoteCharacters` bound check, the `WatchWorkboardCapture(title:textContent:)` construction in `prepare`, and `row.setValue(capture.textContent, forKey: "textContent")` in `ConversationStore.upsertDeskMaterial`.
- Added a one-line doc comment on `WatchWorkboardCapture` stating the constraint (its field names are the material's, matching what the iOS intent hands `WorkMaterialDraft`), and extended the bound's existing comment to say the name is deliberately identical to the envelope's so the source guard has two comparable spellings.

**No behaviour touched.** The rename is purely nominal: same bound, same normalisation, same title derivation, same column writes, same error cases, same `String(localized:)` keys, same `AppIntent` identifiers (`CaptureWorkboardIntent`, `intent.workboardCapture.*`, `Summary("Add \(\.$thought) to Work")`).

**Remaining `objective` occurrences are correct and were left alone:** `WorkItem.objective` is a real Core Data column (the desk writes nil into it, and the Watch smoke test asserts that nil) — that is model vocabulary, not brief-layer vocabulary in the capture type.

**How the rename is pinned (regression proof):** `WorkCaptureInboxTests.testTheWatchCaptureBoundStillRestatesTheEnvelopeBound` greps the Watch source for the literal `"maximumNoteCharacters = " + <envelope value rendered with underscores>`. Argument from the assertion: the old code's source text is `maximumObjectiveCharacters = 16_000`, which does not contain the expected substring, so that test fails on the old spelling — and it equally fails if the bound's *value* drifts from `WorkCaptureEnvelope.maximumNoteCharacters`. I checked the new name cannot be satisfied accidentally by the file's prose: the only other occurrence of `maximumNoteCharacters` is in a comment reading ``Mirrors `WorkCaptureEnvelope.maximumNoteCharacters`, the bound …``, which is not followed by `" = 16_000"`. The type rename is compiler-pinned (the Watch suite constructs `WatchWorkboardCapture(title:textContent:)` in four places and reads `capture.textContent`).

---

## t#6 — "the Watch suite never proves the production Watch build mounts only the Core store" — **VERDICT: fixed**

**Verified.** Confirmed no method in `ConduckWatchSmokeTests.swift` called `_mountedStoresForTesting`, and confirmed `WorkboardTwoStoreLoadTests.testTheWatchShapeOpensTheSameCoreFileCleanlyWithNoPayloadStore` hand-builds an iOS-hosted `NSPersistentContainer` with one `core` description (`core.configuration = "Core"`, `container.persistentStoreDescriptions = [core]`) rather than driving `ConversationStore.storeDescriptions` — so it cannot observe a regression of the `#if os(watchOS) return [core]` branch. Evidence held.

**What changed:** added `ConduckWatchSmokeTests.testTheWatchBuildMountsTheCoreStoreAloneAndNoPayloadStore()` to the EXISTING watch test file (no new watch test file → no pbxproj edit). It creates `ConversationStore(inMemory: true)`, awaits `_mountedStoresForTesting()`, and asserts `mounted.map(\.configuration) == ["Core"]`. Asserting the exact array (not a `count`/`contains` pair) covers both halves in one line: a `Blobs` store appearing fails, and a seam that silently returns `[]` (the `isIsolatedTestStore` guard) fails too, so the test cannot pass vacuously. `coreConfigurationName` is `private static`, so the literal `"Core"` is the only spelling available from the test target; the message names what a `Blobs` mount would mean for the wrist.

**Regression proof — MEASURED counterfactual, not an argument.** In an isolated copy under my slug dir (`~/Library/Caches/gigaduck-builds/ui-watch/cf`) I removed the `#if os(watchOS) / return [core] / #else … #endif` fence from `ConversationStore.storeDescriptions` so the watch build mounts both stores, and ran the watch suite class:

```
Executed 7 tests, with 1 failure (0 unexpected) in 0.185 (0.187) seconds
** TEST FAILED **
…/ConduckWatchSmokeTests.swift:169: error: -[ConduckWatchTests.ConduckWatchSmokeTests testTheWatchBuildMountsTheCoreStoreAloneAndNoPayloadStore] : XCTAssertEqual failed: ("["Core", "Blobs"]") is not equal to ("["Core"]") - The wrist mounted ["Core", "Blobs"] rather than Core alone. A Blobs store on watchOS puts every synced material payload on the watch.
```

Exactly one failure, and it is the new test. The copy is gone with the cleanup script.

---

## t#12 + guard verdict `delete` ×2 — `WorkboardDeskIdentityDriftTests` — **VERDICT: fixed (file deleted)**

**Verified.** `testTheWatchCaptureIntentNamesTheCanonicalDeskConstant` searched the WHOLE Watch source for `Constants.workboardDeskItemID`; that token appears three times in that file's header/doc comments alone, so replacing the executable `let deskID = Constants.workboardDeskItemID` with a minted `UUID()` satisfies both assertions (only `UUID(uuidString:` is forbidden). Evidence held. Both tests in the file are rated `delete`.

**What changed:** deleted `Conduck/ConduckTests/WorkboardDeskIdentityDriftTests.swift` (both `testTheDeskIdentityLiteralExistsOnlyInConstants` and `testTheWatchCaptureIntentNamesTheCanonicalDeskConstant`). What actually protects the invariant is behavioural and already present: `ConduckWatchSmokeTests.testWorkboardCapturePersistsOnlyAnInertNoteOnTheDesk` and `…AppendsToTheSameDeskInsteadOfCreatingASecondOne` read the PERSISTED `id`/`workItemID` back out of the store and compare them to `Constants.workboardDeskItemID` — a minted id there fails, comments or not.

**Bookkeeping accident, repaired:** my first attempt used `git rm --cached` on that path, which staged a deletion. I restored the index entry immediately (`git restore --staged` on that one path — index only, working tree untouched) and then removed the working file, so the change presents as a plain unstaged ` D` exactly like every other agent's edits. `git status` for the path now reads ` D Conduck/ConduckTests/WorkboardDeskIdentityDriftTests.swift`. No other index or worktree state was touched. Recording it because the standing rules ban git index/checkout operations and I made one.

---

## Guard verdicts

- `WorkboardBlobSeamPlatformGuardTests.testTheMountedStoreSeamStaysAvailableOnTheWatch` — rated `convert`, **CONVERTED and deleted**. The conversion is the t#6 test above: a real Watch-suite call to `_mountedStoresForTesting()` makes the compiler the guard (sweeping the seam under `#if !os(watchOS)` breaks the watch build outright), and the same call verifies the Core-only mount the source guard could only infer. I rewrote the four-line paragraph in the file header that claimed the guard "pins the exclusion in BOTH directions" to state the new constraint instead (present tense, no changelog narration).
- `WorkboardBlobSeamPlatformGuardTests.testThePayloadSeamsAreCompiledOutOfTheWatchBuild` — rated `keep`, **left untouched**. The helpers it shares with the deleted test (`loadStoreSource`, `conditionsByLine`, `conditions(wrapping:)`, `normalised`) are all still used by it; nothing went dead.
- `WorkCaptureInboxTests.testTheWatchCaptureBoundStillRestatesTheEnvelopeBound` — rated `keep`, kept; only the expected spelling moved with the rename (see Call-site touches).

## Call-site touches

- `Conduck/ConduckTests/WorkCaptureInboxTests.swift:572` — `let expected = "maximumObjectiveCharacters = "` → `let expected = "maximumNoteCharacters = "`. This is the single assertion line that pins the renamed identifier; nothing else in that file was opened or changed.
- `Conduck/ConduckWatchTests/ConduckWatchSmokeTests.swift` — nine `objective:`/`.objective`/`maximumObjectiveCharacters` references updated to the new names (I own this file), plus the new topology test.

## Catalog

No string key added, removed, or made dead. No `String(localized:)` key or `defaultValue` in any file I touched changed — the Watch intent's `intent.workboardCapture.*` keys and `workboard.item.untitled` are byte-identical to before.

## Refuted

(none — the one finding assigned to me held on inspection)

## Requests

1. **`Conduck/Conduck/Utilities/Constants.swift` (I do not own it):** the doc comment on `workboardDeskItemID` ends with "`WorkboardDeskIdentityDriftTests` fails if the literal is ever restated outside this file" (around line 2101). That test file no longer exists. Please drop that sentence — the preceding sentence ("`Constants.swift` is a member of the Watch target too, so every surface reads this value rather than a copy") already states the constraint, and the Watch persistence tests enforce it.
2. **`Conduck/ConduckTests/WorkCaptureInboxTests.swift` doc comment (I touched only the assertion line):** the comment above `testTheWatchCaptureBoundStillRestatesTheEnvelopeBound` still says a too-long dictation would leave "`createWorkItem` refuse it — losing a brief the person has no other copy of." The wrist no longer calls `createWorkItem` and there is no brief; whoever owns that file this wave should retell it as `upsertDeskMaterial` refusing a note. I left it alone rather than widen my touch beyond the one assertion line.
3. **`Conduck/Conduck/Services/ConversationStore.swift` (fix2-store / whoever owns it):** the comment above the `#if !os(watchOS)` payload-seam fence says "`_mountedStoresForTesting` stays outside this guard — asserting the wrist mounts Core ALONE is the whole point of it there." That is still true and now has a real caller; no change needed unless the seam moves. Flagging only so nobody sweeps the seam into the fence and breaks the watch build.

## Verification — exactly what I ran

**1. Watch suite, live worktree, `28AC563B-42C1-4E66-940D-77E63B07918B` (the gate for my change):**
`xcodebuild test -scheme ConduckWatchTests -destination 'platform=watchOS Simulator,id=28AC563B-…'`, derivedData under `~/Library/Caches/gigaduck-builds/ui-watch/DerivedData`, log grepped (not tailed):
```
Executed 232 tests, with 0 failures (0 unexpected) in 9.563 (9.640) seconds
** TEST SUCCEEDED **
```
231 → 232 = the one new test, as predicted. The log shows it running and passing:
```
Test Case '-[ConduckWatchTests.ConduckWatchSmokeTests testTheWatchBuildMountsTheCoreStoreAloneAndNoPayloadStore]' passed (0.002 seconds).
Test Suite 'ConduckWatchSmokeTests' passed
```

**2. Counterfactual watch run** (isolated copy, payload-store fence removed): `Executed 7 tests, with 1 failure`, `** TEST FAILED **`, quoted in full above.

**3. iOS `build-for-testing` on the LIVE worktree FAILED — entirely in files I do not own.** Five attempts (one plus the four retries over ~9 min). The errors moved between attempts as other agents saved, and never once landed in a file of mine:
```
…/Conduck/Services/Workboard/WorkAssetVault.swift:156:35: error: cannot find 'readableByteCount' in scope   (and :199, :266, :292, :305, :320)
…/Conduck/Services/Workboard/WorkAssetVault.swift:355:57: error: cannot find type 'StoredFile' in scope     (and :371)
…/Conduck/Views/Workboard/WorkboardAudioCardView.swift:215:70: error: call to main actor-isolated static method 'systemCaptureIsLive()' in a synchronous nonisolated context   (and :216 activateSharedSession, :217 releaseSharedSession)
…/Conduck/ContentView.swift:1567:20: error: binary operator '??' cannot be applied to operands of type 'WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome?' and 'Bool'
…/Conduck/Services/InAppAudioRecorder.swift:611:20: error: binary operator '??' cannot be applied to operands of type 'WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome?' and 'Bool'
…/Conduck/Services/InAppAudioRecorder.swift:796:41: error: cannot find 'WorkVoiceCaptureError' in scope
```
These are mid-flight C1/C2/C4 states in fix2-vault / fix2-audio-card / fix2-recorder / fix2-voice-lanes territory. I edited none of them; serial integration resolves them.

**4. iOS verification in an isolated copy instead** (`~/Library/Caches/gigaduck-builds/ui-watch/iso`): `git archive 223ac35` extracted, then ONLY my five changes overlaid (four files copied in, `WorkboardDeskIdentityDriftTests.swift` removed) — i.e. HEAD + my diff and nothing else.
- `xcodebuild build-for-testing -scheme Conduck -destination 'platform=iOS Simulator,id=D4046F86-…'` → `** TEST BUILD SUCCEEDED **`, zero `error:` lines. My files compile.
- `xcodebuild test-without-building … '-only-testing:ConduckTests/WorkCaptureInboxTests' '-only-testing:ConduckTests/WorkboardBlobSeamPlatformGuardTests'`:
```
Test Suite 'WorkCaptureInboxTests' passed        —  Executed 30 tests, with 0 failures (0 unexpected)
Test Suite 'WorkboardBlobSeamPlatformGuardTests' passed  —  Executed 1 test, with 0 failures (0 unexpected)
Executed 31 tests, with 0 failures (0 unexpected) in 0.202 (0.313) seconds
```
`WorkboardBlobSeamPlatformGuardTests` = 1 test, the correct count after deleting the converted one.

**What I could NOT verify, plainly:** I never got a green iOS run against the LIVE worktree, so the two iOS test classes above are proven only against HEAD-plus-my-diff. `WorkboardBlobSeamPlatformGuardTests.testThePayloadSeamsAreCompiledOutOfTheWatchBuild` reads `ConversationStore.swift` off disk via `#filePath`, so its result depends on whoever is editing that file right now — the integration run must re-run it against the merged tree. I also did not run the full iOS suite or a macOS build (not asked, and not reachable while the tree is red in foreign files).

**Cleanup:** `.claude/scripts/clean-build-cache.sh ui-watch` → `removed: ui-watch`. Both derivedData trees, both isolated copies and every log are gone; no `/tmp` use, no bare `rm -rf`.
