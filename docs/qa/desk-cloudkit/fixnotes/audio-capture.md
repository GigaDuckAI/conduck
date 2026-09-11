# audio-capture — plan §D two-phase Work voice capture (Codex #9), DATA side. DONE, but verified in a COPY of the tree: the real worktree does not build because of the parallel card-UI agent's in-flight file. Exact errors in §7.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched (the worktree symlink was never opened — §7 explains the scratch copy's own symlink). Nothing under `docs/qa/desk-cloudkit/` touched. **No `.xcstrings` file opened** — I added ONE key, listed in §Catalog. No `.pbxproj` edit (both new files are in synchronized groups and compiled).

Files changed — FOUR, of which two are new:
- `Conduck/Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift` (**NEW**, 178 lines) — the two phases and the one store write they need
- `Conduck/Conduck/Services/InAppAudioRecorder.swift` (+73 / −2)
- `Conduck/Conduck/ContentView.swift` (the Work voice retry branch only, +21 / −6)
- `Conduck/Conduck/Views/Workboard/WorkboardVoiceCaptureView.swift` (+14 / −2, `handle(_:)` only — §Call-site touches)
- `Conduck/ConduckTests/WorkboardAudioCaptureTests.swift` (**NEW**, 432 lines, 12 cases)

**`ViewModels/WorkboardViewModel.swift` was NOT opened.** It was in my ownership list ("voice hand-off area ONLY") and needed nothing: the desk refreshes itself off `postDidChange()` → `.conversationsDidChange` → `PersonalWorkbenchView.scheduleRefresh()`, which is the same path every drainer capture already uses. Leaving it shut also kept me out of the file the parallel agent needs for `WorkboardMaterialKind.audio` (§Requests 1).

---

## 1. The two-phase flow as built (file : symbol)

| Step | Where | What happens |
|---|---|---|
| identity | `InAppAudioRecorder.finishAndUpload()` — `let captureID = UUID()`, immediately after `AudioCompressor.compress` | ONE id per capture, minted before anything durable is written |
| **PHASE 1** | `InAppAudioRecorder.finishAndUpload()` → `WorkVoiceCaptureCoordinator.publishRecording(captureID:audio:fileExtension:mimeType:createdAt:store:)` | gated `if retryDestination == .work`, wrapped `#if !os(watchOS)`. Publishes the `.audio` card through `ConversationStore.upsertDeskMaterial`. Sets `recorder.workRecordingMaterialID` |
| temp file | unchanged, right after phase 1 | the transcription temp file is written AFTER the card exists, and its four `removeItem(at: audioFileURL)` owners are untouched |
| STT | unchanged | |
| **PHASE 2** | `InAppAudioRecorder.finishAndUpload()`, in the success branch just before `CompletionFeedbackPlayer.play` → `WorkVoiceCaptureCoordinator.attachTranscript(_:toRecording:store:)` | writes `textContent` + `title` onto the SAME material |
| the write | `WorkVoiceCaptureCoordinator.swift` → `private extension ConversationStore.applyWorkVoiceTranscript(materialID:transcript:title:)` | one `context.perform`, one save, every physical row, then `postDidChange()` |
| hand-off | `WorkboardVoiceCaptureView.handle(_:)` | card published ⇒ dismiss; no card ⇒ the old composer append |
| retry | `ContentView` retry branch (`pending.metadata.resolvedDestination == .work`) | `attachTranscript(…, toRecording: pending.metadata.id)`; only a `false` answer falls through to `WorkCaptureRetryCoordinator.publish` |

**Phase 1 passes the compressed `Data`, never the temp URL.** `upsertDeskMaterial` → `stageWorkMaterialBytes` → `WorkMaterialStoragePolicy.mode(kind:byteSize:)` measures `payload.count`, so a ≤15 MB voice note takes `.syncedPayload` (blob) and an implausibly large one would take `.localVault` with reattach — no lane decision of my own anywhere (blob-io §1's rule holds: the policy is consulted in exactly one function). The three `defer`s that own the temp file are untouched; a source guard asserts all four `removeItem(at: audioFileURL)` sites still exist.

**Phase 1 failure is swallowed on purpose.** `catch { workRecordingMaterialID = nil }` — surfacing a storage error there would abandon a transcription that has not been attempted yet. The host then behaves exactly as it did before this slice (words → composer), so a store failure costs the card and never the words.

**Phase 2 failure clears the claim, not the transcript.** `if !attached { workRecordingMaterialID = nil }`, so the sheet falls back to handing the words to the composer while the playable card stays on the desk. Nothing is lost in either direction.

## 2. The one identity, and why it is also the note's

`PendingRetryMetadata.id` is now `captureID` (it was a fresh `UUID()` per save). So **capture id == audio material id == pending-retry id**. Three consequences, all deliberate:

1. The retry surface can name the card with a value it already carries. **No new field on `PendingRetryStore`** — I did not open that file.
2. `WorkCaptureDrainer.noteMaterialID(for:)` returns `envelope.id` when no entry claims it, and `WorkCaptureRetryCoordinator.publish` passes `captureID: pending.metadata.id` as the envelope id. So the retry's **fallback** note would be minted at the recording's own id — and `upsertDeskMaterial` answers with the existing `.audio` card, unchanged. The fallback therefore cannot duplicate the utterance or degrade it to a note even if it runs beside a surviving recording. `testTheFallbackPublicationCannotPutTheSameUtteranceOnTheBoardTwice` pins that.
3. `attachTranscript` refuses a card that is not `.audio`. That is load-bearing, not defensive: `WorkCaptureInbox.publishAppCapture` gives its IMAGE entry the capture id too, so a drained Shortcuts capture leaves an `.image` material at exactly the id its pending-retry record carries. Writing spoken words onto a screenshot is the failure the kind check exists to refuse (`testATranscriptIsRefusedForACardThatIsNotARecording`).

## 3. Material contract for the card UI (what the card agent can rely on)

A Work voice note is ONE `WorkMaterialRecord`:

| Field | Before the transcript | After it |
|---|---|---|
| `kind` | `.audio` | `.audio` (never becomes `.note`/`.transcript`) |
| `id` | the capture id | unchanged |
| `workItemID` | `Constants.workboardDeskItemID` | unchanged |
| `storageMode` | `.syncedPayload` (normal) / `.localVault` above the 30 MB ceiling | unchanged — a text edit never moves bytes |
| `availability` | `.synced` once its blob is complete, `.syncedPending` while it is in flight | unchanged |
| `hasPayload` | true when readable — **the play gate** | unchanged |
| `byteSize` | measured bytes | unchanged |
| `mimeType` | `AudioFormat.mimeType` — `audio/mp4` for AAC, `audio/wav`, or the sniffed source container | unchanged |
| `filename` | `voice-note.<ext>` | unchanged |
| `title` | `workboard.voice.recording.untitled` = **"Voice note"** | the transcript's first non-empty line, clipped to 72 (`WorkboardWorkspaceCaptureLogic.title(for:)`) |
| `textContent` | **nil** | the trimmed transcript, newlines preserved |
| `caption` | `""` | `""` — untouched, the house note shape (title + textContent, no caption) |

Bytes come from `ConversationStore.loadWorkMaterialPayload(id:)` (blob or vault, decided for you). **Gate playback on `presentationAvailability` / `WorkboardMaterialAvailability.isAvailable`, never on `storageMode`** — a `.syncedPending` recording has no bytes here yet.

`WorkboardLiveRepository.presentationKind` already maps `.audio → .file`, so an audio card renders as a file card today and is coherent before your `.audio` presentation case lands; `WorkboardMaterialSnapshot.textContent` already carries the transcript through `materialSnapshot`.

## 4. Why the store write lives in a NEW file

No update path for a material's `textContent` exists anywhere in the store, and `ConversationStore+Workboard.swift` is not mine this wave. Rather than edit a file another agent might be in, I put a `private extension ConversationStore` in my own new file: `applyWorkVoiceTranscript` is **fileprivate**, so it adds nothing to the store's global surface and only the coordinator above it can call it. It uses only `internal` members (`ensureLoaded`, `newWriteContext`, `postDidChange`) and mirrors `setWorkMaterialCardSize`'s shape.

Three decisions inside it, each with its reason at the code:
- **Writes every physical row**, then the desk row's `updatedAt`, in one save. The words are board content, so the desk revision advances (`reorderWorkMaterials`' rule), unlike card size which deliberately does not.
- **Refuses rather than throws** when the id names no card, names a non-`.audio` card, or names a card not owned by the desk. A throw would read to the caller as a reason to abandon the words.
- **Writes `textContent` unconditionally.** Whether a card may SHOW stored text is decided once, on the read path, by `workboardSyncedTextContent` — restating that rule in a writer is how a writer and a reader start disagreeing. Consequence worth knowing: that rule suppresses `textContent` for a `.localVault` row, so a hypothetical over-ceiling recording would store a transcript the projection hides. Unreachable in practice (compressed voice ≤15 MB vs a 30 MB ceiling), stated rather than special-cased.

## 5. Behaviour change a person will notice

**The Work voice sheet no longer types into the composer.** It records; the recording becomes a card; the words land on that card. `WorkboardVoiceCaptureView.handle(.success)` dismisses via `onCancel` (the canvas's only dismissal hook) when a card was published, and only falls back to `onTranscript(transcript)` when none was. Without this the same utterance would land twice — once as a playable card, once as a note the person flushes out of the composer.

Two strings on that sheet are now **false** and I did not fix them, because my minimal-touch grant on that file is "voice hand-off call sites only" and copy is plan §E's phase: `workboard.voice.privacy` still says *"Adds editable text to this private draft"*, and `workboard.voice.stop` still reads *"Stop and Add Text"*. Exact proposed replacements in §Requests 3.

## 6. Deviations from the brief, with reasons

1. **`WorkboardViewModel.swift` untouched** (see the header). Nothing in the voice hand-off needed it, and staying out of it removed a collision with the parallel agent.
2. **A second NEW source file.** The brief enumerated one new TEST file; phase 2 had no store API to call and I may not edit `ConversationStore+Workboard.swift` in a parallel wave, so the write lives in my own file as a fileprivate extension (§4).
3. **Verification ran in a COPY of the tree** (§7). The real worktree does not compile for reasons outside my files.
4. **Cancellation during phase 1 is not defended.** `upsertDeskMaterial`'s claim loop awaits, so a cancel landing inside phase 1 would leave no card. Unreachable in practice: the stall-Cancel affordance only appears after `Constants.transcribeStallHintDelay`, seconds into `.processing`, long after phase 1 has returned. Stated rather than wrapped in an uncancellable task.
5. **The "every physical row" claim is implemented but not test-covered.** `WorkMaterialRowProbe` exposes `sequence`/`cardSize`/`updatedAt` and no text, and the canonical read deduplicates, so a duplicate-row fixture could not tell one-row from all-rows apart. Adding a `textContent` field to that probe would make it testable.
6. **No Codex consult.** The one hard call — where to put a store write I am not allowed to add to the store's own file — is an ownership question, not a technical one.

## 7. Gates run (exact lines), and the real-tree failure

Slug `desk-audio-capture`, derivedData under `~/Library/Caches/gigaduck-builds/desk-audio-capture/`, every log written there and grepped. No `-configuration` passed anywhere. Cache removed at the end: `clean-build-cache.sh desk-audio-capture` → `removed: desk-audio-capture` — **the logs no longer exist**; re-run if you need them.

**THE REAL WORKTREE DOES NOT BUILD.** Three attempts (`ios-bft-1.log` 00:28, `ios-bft-2.log` 00:35 after the mandated 120 s wait, `ios-bft-3.log` 01:00 after a further ~6 min wait), all `** TEST BUILD FAILED **` with the SAME two errors, both in a file I do not own and neither of them mine:
```
Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1170:21: error: cannot convert value of type 'WorkboardMaterialKind' to expected argument type 'UTType'
Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1632:30: error: type 'WorkboardMaterialKind' has no member 'audio'
```
The parallel card-UI agent has `WorkboardCaptureCanvas.swift` modified and `WorkboardAudioCardView.swift` / `WorkboardAudioCardTests.swift` added, but has not yet added `case audio` to `WorkboardMaterialKind` in `ViewModels/WorkboardViewModel.swift` (grep count 0 at 01:00). **Zero errors and zero warnings were reported in any of my files in every one of the three runs.**

**So I verified in a throwaway copy** at `…/scratchpad/verify-tree-1` (24 MB, `cp -a` of the worktree; `.git` removed; `WorkboardCaptureCanvas.swift` restored from `git show HEAD:` and the card agent's two new files omitted; its own absolute symlink to `Conduck-Private/Configs/Identity-Override.xcconfig`). **Nothing in the worktree was written by that procedure** — the only worktree command was a read-only `git -C … show`. Everything else in the copy is byte-identical to the worktree, my five files included.

- iOS `build-for-testing`, sim `6C3FB33E-D89F-4D1E-9F0D-3FAC0C089228` → `copy-bft-2.log`: `grep -c ': error: '` = **0**, zero warnings in my files, `** TEST BUILD SUCCEEDED **`. (`copy-bft-1.log` failed first with 12 `'async' call in an autoclosure` errors, all mine, all in the new test file — fixed by hoisting the awaits out of `XCTUnwrap`/`XCTAssertEqual`.)
- iOS `test-without-building`, three quoted `-only-testing:` flags → `copy-test-1.log`, `** TEST EXECUTE SUCCEEDED **`:

| Class | Result |
|---|---|
| `WorkboardAudioCaptureTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.100 (0.104) seconds` |
| `WorkboardBlobPublicationTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.481 (0.484) seconds` |
| `WorkboardDeskUpsertTests` | `Executed 10 tests, with 0 failures (0 unexpected) in 0.092 (0.095) seconds` |
| **total** | `Executed 34 tests, with 0 failures (0 unexpected) in 0.674 (0.683) seconds` |

- macOS `xcodebuild build -destination 'platform=macOS'` → `copy-mac-1.log`: 0 `error:` lines, `** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`. **No `CODE_SIGNING_ALLOWED=NO` fallback needed.** (Insurance — all four of my production files compile for macOS.)
- On the REAL worktree: `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 775 Swift files scanned…`, exit 0. `git diff --check` → clean, exit 0. `git status --short` for `*.xcstrings`, `*.pbxproj`, `Conduck/Configs`, `docs/qa/desk-cloudkit` → **empty**.
- **Full iOS suite and watch suite: NOT RUN.** The full suite cannot run until the real tree builds. Expect **+12** on the iOS executed count (4758 → 4770 before the card agent's own additions). The watch target compiles none of my files: `InAppAudioRecorder.swift`, `ContentView.swift`, `WorkboardViewModel.swift` and `Services/Workboard/*` are all absent from the `ConduckWatch Watch App` membership-exception list, and my new file carries `#if !os(watchOS)` besides.
- The copy at `…/scratchpad/verify-tree-1` is **still on disk** (24 MB) — `rm -rf` is denied to me by `settings.local.json` and `clean-build-cache.sh` only owns the build cache. Delete it when convenient; it is inside this session's scratchpad.

### The 12 new cases

`WorkboardAudioCaptureTests`: a recording is a playable `.audio` card with no transcript at all (synced lane, bytes read back exactly, "Voice note" title) · a replayed publication returns the same card and writes nothing · **the capture's temp file is neither moved nor consumed, and the desk's copy survives its deletion** · the transcript mutates the SAME material (one card, one physical row, bytes untouched, title = first line) · a failed transcription leaves the playable card, and a retry an hour later still finds it · a transcript for a capture that owns no recording is refused **and creates no desk row** · an empty transcript is refused and does not rename the card · a transcript aimed at a non-recording card (the Shortcuts screenshot case) is refused and writes nothing at all · the retry repairs the same id — never a duplicate, never a note · the retry's fallback publication cannot put one utterance on the board twice · **source guard: publication sits after `AudioCompressor.compress` and before every transcription call and phase 2**, one Work gate, published from `uploadData`, four temp-file removals intact · **source guard: one `captureID`, and it names both the card and the pending-retry record.**

Both source guards read the recorder from `final class InAppAudioRecorder {` onward — the file's header names several of the calls they order, and a guard a comment can satisfy holds nothing.

---

## Call-site touches

**`Views/Workboard/WorkboardVoiceCaptureView.swift` — ONE, `handle(_ result:)`, ~10 lines.** Success now dismisses through `onCancel()` when the recorder published a card, and only calls `onTranscript(transcript)` when it did not. No signature, no property, nothing else in the file changed; `WorkboardCaptureCanvas.swift` needed no edit and was never opened by me. See §Requests 2 for the rename that finishes it.

---

## Catalog

**Keys I ADDED in source: ONE.**
```
workboard.voice.recording.untitled = Voice note
```
(`WorkVoiceCaptureCoordinator.untranscribedTitle`, `String(localized:defaultValue:)`, main app catalog.) It is the card's title before a transcript exists and again whenever a transcript has no first line. It deliberately does NOT reuse `workboard.workspace.thought.defaultTitle` = "Thought", which is a captured thought's default and would name a recording wrongly.

**Keys I found DEAD: NONE.** I deleted no code carrying a string. `workboard.voice.privacy` and `workboard.voice.stop` are still referenced and still rendered — but both now say something false (§5, §Requests 3).

---

## Requests

1. **Card-UI agent (parallel, right now) — the tree does not build and it is your two lines.** `WorkboardCaptureCanvas.swift:1170` and `:1632` use `WorkboardMaterialKind.audio`, which does not exist yet in `ViewModels/WorkboardViewModel.swift`. **I deliberately did not add it** — my grant on that file is the voice hand-off only, and `WorkboardMaterialKind` is presentation. When you add it, `WorkboardLiveRepository.presentationKind` currently answers `.file` for `.audio` (`case .file, .audio: return .file`) and that arm has to move with you. Read §3 for the material contract; note especially that `textContent` is nil until the transcript lands and that playability must gate on availability, not on `storageMode`.
2. **Whoever next owns `Views/Workboard/WorkboardCaptureCanvas.swift` — the voice sheet's hand-off is now two closures where one would do.** `onTranscript` is the no-card fallback and `onCancel` is doing double duty as "dismiss". The clean shape is `onDismiss: @MainActor () -> Void` plus keeping `onTranscript` only for the fallback, and the canvas's closure body (`viewModel.setWorkspaceComposerDraft(appending(transcript, to: composerText), …)` at `:141-148`) should stay exactly as it is — it is the path a failed desk write still needs.
3. **Strings/copy phase — TWO strings on the voice sheet are now false, and they are the direct consequence of this slice.** Both need new keys (rewriting a value in source alone changes nothing at runtime; the catalog's en value wins):
   - `workboard.voice.privacy` currently *"Adds editable text to this private draft. It never sends the brief or chooses a gateway."* → proposed key `workboard.voice.privacy.recording`, e.g. *"Keeps the recording on your private Work desk and adds the words when they're ready. It never sends it to a gateway."*
   - `workboard.voice.stop` currently *"Stop and Add Text"* → proposed key `workboard.voice.stop.save`, e.g. *"Stop and Save"*.
   - Also `WorkboardVoiceTarget.context.title` = `workboard.voice.context` = *"Add context and thoughts"* is now the sheet's navigation title for something that records. Founder's call; I changed no copy.
4. **macOS retry surface owner (`MenuBar/DictationService.swift:276`) — one gap I could not close.** `WorkboardVoiceCaptureView` exists on macOS, so a Work voice capture there can fail STT and park a pending retry; that retry is recovered by `DictationService.retryLast`, which I do not own and which still calls `WorkCaptureRetryCoordinator.publish` unconditionally. Consequence today: the recovered words do NOT reach the recording card (the fallback's note is minted at the recording's own id, so `upsertDeskMaterial` returns the existing audio card unchanged — **no duplicate and no note, but no transcript either**). The fix is the same three lines as `ContentView`'s: try `WorkVoiceCaptureCoordinator.attachTranscript(recoveredTranscript, toRecording: pending.metadata.id)` first and publish only on `false`.
5. **Nobody give `PendingRetryMetadata.id` back a fresh `UUID()` in `InAppAudioRecorder.preserveForRetry`.** It is now the capture's single identity — the card's id and the envelope's id as well — and a second UUID there is exactly what would make a recovered transcript unable to find the recording it came from. `WorkboardAudioCaptureTests.testOneCaptureIdentityNamesBothTheCardAndThePendingRetryRecord` fails if it comes back.
6. **Nobody move the phase-1 publication below the STT hop**, however tempting it looks to publish "once we know it worked". That ordering IS the feature; `testTheRecordingIsPublishedBeforeTheTranscriptionHop` fails on it.
7. **Test-surgery / probe owner — one uncoverable claim.** Adding `textContent` to `WorkMaterialRowProbe` (`ConversationStore+Workboard.swift`, `_workMaterialRowsForTesting`) would make "the transcript reaches EVERY physical row of a CloudKit-duplicated card" testable. It is implemented and reviewed, and today unverified (§6.5).
8. **Docs agent — plan §E's `spec.md:503` ("audio not retained") is now settled by code in a specific shape.** A Work voice note is retained as an `.audio` material whose bytes ride the person's private CloudKit under the sync ceiling; its transcript is a `textContent` edit on that same material, written after the recording is already durable, so a failed transcription costs the words and never the recording. Chat voice is unchanged — no bytes are retained there.
9. **Founder QA (Gate 2) — three items this slice adds.** (a) On the Work desk, record a voice note with airplane mode ON: an untranscribed card must appear and PLAY, and the retry card must then fill in its words on the SAME card — no second card, no note. (b) Record normally: exactly ONE card appears and the composer stays empty (the sheet no longer types into it). (c) On a second device, the recording arrives as a card that reads "Waiting for iCloud…" before its bytes land and must not offer Reattach.
10. **Orchestrator — the iOS count.** +12 from `WorkboardAudioCaptureTests`. The suite cannot be run until §Requests 1 lands; my numbers in §7 come from a copy of the tree with the card agent's in-flight file reverted, and I have said so rather than implying a green worktree.
