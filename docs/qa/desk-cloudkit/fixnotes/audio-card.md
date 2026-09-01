# audio-card — plan §D, the audio card UI. Card + player + dispatch DONE and PROVEN GREEN in isolation; the SHARED tree does not build, because `WorkboardMaterialKind.audio` does not exist yet (§5A, exact patch in §Requests 1).

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. **No `.xcstrings` file opened.** Nothing under `docs/qa/desk-cloudkit/` touched.

Files I changed — exactly three, all mine:
- `Conduck/Conduck/Views/Workboard/WorkboardAudioCardView.swift` — **NEW** (card + its player + the exclusivity registry + the clock arithmetic).
- `Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift` — the card-rendering dispatch, and one `previewText` switch arm for exhaustiveness. Nothing else.
- `Conduck/ConduckTests/WorkboardAudioCardTests.swift` — **NEW**, 15 cases, `Executed 15 tests, with 0 failures`.

---

## 1. What the card does

`WorkboardAudioCardView` draws a voice note as a **transport**, not a preview. The whole tile is the play/pause control — exactly as the other board cards make the whole tile the open control — so the glyph is presentation and the hit region is the card. The ellipsis menu sits outside the button in the same `ZStack`, at the same inset, with the same hover rule (`isHovering` on macOS, always visible on touch).

| Element | Behaviour |
|---|---|
| Transport glyph | `play.fill` idle/paused · `pause.fill` playing · `hourglass` while bytes load · `exclamationmark.triangle` failed · `icloud.and.arrow.down` when the bytes are not readable here |
| Progress | Capsule track + amber fill, `player.fraction`, **drawn only once a clip has decoded** (`duration > 0`) — before that the length is genuinely unknown and a zeroed track beside "0:00 of 0:00" would state a fact the card does not have |
| Clock | `WorkboardAudioTiming.label` — `m:ss`, growing an hour field past 3600 s, monospaced digits |
| Caption | `material.textContent` trimmed, when non-empty. **An untranscribed note draws no caption at all** and is fully playable — no placeholder, no "Transcribing…" that could become permanently true after an STT failure |
| Failure | The caption slot carries `workboard.audio.failed` in `AppColors.warning`; the card stays tappable, because the next tap is the only way to find out whether the bytes have since arrived |
| Footer | Byte count + relative `createdAt`, byte-for-byte the same row `WorkboardSourceCard` draws |
| Availability | Chip (glyph + short label) whenever `availability != .available`, using the SAME glyph/tint/copy mapping the source card uses — `internaldrive`/teal, `icloud.and.arrow.down`/tertiary, `paperclip.badge.ellipsis`/warning |

**Sizing/metrics reuse.** `layoutSize` clamps `.large` to `.standard` when the mosaic granted fewer than `WorkboardMosaicSpan.large.columns`, the padding is 9/12 by size, the menu hit target is `WorkboardMetrics.touchTarget` (30 on `small`), the reserved corner gap is 26 — all lifted from `WorkboardSourceCard` so a board of mixed cards reads as one grid. The 13 pt tile radius is a private constant with a comment saying it matches the board tile; see §Requests 4.

## 2. The availability rule (availability.md conformance)

`isPlayable == material.availability.isAvailable`. That is the fixnote's own rule and it is why nothing here re-derives readability: `isAvailable` names the READABLE cases (`.available`, `.localOnly`), so a state added later fails closed instead of opening a transport over bytes that are not here.

**A non-playable card is not wrapped in a `Button` at all.** Not disabled — not a button. Consequences, all deliberate:
- no button trait and no activation that would do nothing;
- no `.disabled` dimming, which would have made audio the only kind of card that greys out while a pending image card beside it renders normally;
- the arrange actions (Move Earlier/Later, Card Size, Remove) stay reachable, both in the menu and as VoiceOver custom actions — a disabled control drops its custom actions, which would have made a pending voice note unarrangeable and unremovable by VoiceOver.

A `.syncPending` card therefore shows the sync glyph + **"Waiting for iCloud…"** (`workboard.material.syncPending`, foundation.md's key — I minted no second copy of it), reads that phrase as its accessibility value, and cannot be played. `.unavailableOnThisDevice` gets the same treatment with "Reattach" — the card has no Reattach ACTION of its own (that seam belongs to the canvas's `beginReattachment`, which is not wired to audio); see §Requests 3.

## 3. The player

`WorkboardAudioCardPlayer` — `@Observable @MainActor`, one per card via `@State`.

- **`AVAudioPlayer(data:)`, following `SpeechPlayer.playCloud`'s shape, and NOT `SpeechPlayer` itself.** Chat's stack (`ReplyVoice`/`SpeechPlayer`/`ThreadSpeaker`) carries a per-turn exactly-once completion contract, an Apple on-device fallback leg, and CarPlay's activate-once session invariant. A board card needs none of it and must never be able to disturb it. **I did not open, call, or modify any file in `Services/TTS/`.**
- **Terminal detection is the progress tick, not `AVAudioPlayerDelegate`.** The tick (100 ms) reads `currentTime` and treats "the player stopped while the card still believes it is playing" as the end — a natural finish or a mid-clip decode failure, both of which leave the card ready to be tapped again. The delegate's identity-guard machinery exists in `SpeechPlayer` to keep a stale terminal from firing a NEW leg's completion; this card has no second leg and no completion a caller waits on, so it would buy nothing.
- **Phases**: `idle · loading · playing · paused · failed`. A tap during `loading` cancels the payload read rather than queueing a second one.
- **Bytes are read on the first play, never on a board refresh** — `loadPayload` is a closure the card calls only when it actually needs audio. Its default is `ConversationStore.shared.loadWorkMaterialPayload(id:)` (`PersonalWorkbenchView`'s precedent for a view reaching the store); injectable, which is what makes the failure paths testable.

### Exclusivity — one card at a time
`WorkboardAudioExclusivity` (process-wide `.shared`, plus an injectable instance for tests) holds the card that owns output **weakly**:
- `claim(next)` stops the previous holder, so a second tap plays that note INSTEAD of the first, never over it;
- `resign(self)` clears the slot **only if the resigning player is still the holder** — a terminal that lands after a newer card claimed output cannot silence that newer card;
- weak, so a card scrolled out of existence reads as no holder rather than as a corpse to send `stopForExclusivity` to.

`.onDisappear` calls `player.deactivate()`: the in-flight payload read is cancelled, the player stops, the session is released and the slot is resigned.

### Audio session (iOS) — read this before "simplifying" it
The desk has **no session owner**, and `InAppAudioRecorder` — the thing that produces these notes — leaves the shared session on `.record` and inactive. Playing into that is silence. So the card configures `.playback` / `.spokenAudio` / `.duckOthers` around its own playback window and releases it at every terminal and on pause, which is exactly what `ChatPlaybackSession` does for the chat read-aloud path and for exactly the same reason.

I deliberately did **not** call `ChatPlaybackSession`: it is `#if os(iOS)`, it is documented as *the chat path's* session owner, and routing Work through it would make the desk a client of Chat's speech path — the one thing §D forbids. The duplication is four lines and a divergence risk; §Requests 5 proposes hoisting it in the serial pass.

Both calls are `try?`. That is not sloppiness: `setActive(false)` **throws busy while another leg still holds audio I/O**, which is precisely the case (Chat speaking in the other pane on iPad/macOS) where releasing would be wrong. The swallowed throw is the protection.

## 4. The rendering dispatch (the hook)

`WorkboardMaterialBoard.body`'s `ForEach` now calls one `@ViewBuilder private func card(for:at:)`; the mosaic size modifier and `.draggable` stay on the outside, unchanged:

```swift
card(for: material, at: index)
    .workboardMosaicCardSize(material.cardSize)
    .draggable(WorkMaterialDragPayload(itemID: Constants.workboardDeskItemID, materialID: material.id))
```

`card(for:at:)` is a single `if material.kind == .audio` — audio card, else `WorkboardSourceCard` with the identical argument list it had before. **The kind decides the CONTENT of the tile and nothing about its place on the board**: both branches take the same `grantedColumns` / `boardPosition` / `boardCount` and the same `onSetSize` / `onMoveEarlier` / `onMoveLater` / `onRemove`, so footprint, order, drag and removal behave identically whichever card is drawn. The two `onMove*` closures are hoisted above the branch so the index arithmetic is stated once.

The audio branch is given **no `onOpen` and no `onReattach`** — playback is the card's own action, and the reattach seam is the canvas's file-importer, which is not wired for audio (§Requests 3).

Second canvas edit, one line: `WorkboardSourceCard.previewText`'s switch gains `.audio` to stay exhaustive, with a comment saying it is there for exhaustiveness only because a voice note never draws that card.

## 5. Gates run (exact lines)

Slug `desk-audio-card`; every derivedData path and every log under `~/Library/Caches/gigaduck-builds/desk-audio-card/`; every log grepped for `': error: '` and the `BUILD/TEST` result lines — never judged from tail or exit code. No `-configuration` passed anywhere. Sim `5C851D88-959C-445E-ACC8-A4C6ADB2876C` throughout.

### A. Shared worktree — RED, on a symbol another agent owes me

`ios-bft-1.log`: `** TEST BUILD FAILED **`, `grep -c ': error: '` = **2**, both mine-by-location and caused by the missing enum case:
```
Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1170:21: error: cannot convert value of type 'WorkboardMaterialKind' to expected argument type 'UTType'
Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1632:30: error: type 'WorkboardMaterialKind' has no member 'audio'
```
(The first is the same defect wearing a costume: with no `.audio` case, `== .audio` resolves against `UTType.audio`.)

`mac-build-1.log`: `** BUILD FAILED **`, `grep -c ': error: '` = **2**, the SAME two lines verbatim — so the failure is platform-independent and is one missing enum case, not a platform quirk.

`WorkboardMaterialKind` — in `ViewModels/WorkboardViewModel.swift`, a file I do not own and have no minimal-touch rights on — still reads `image · file · link · note`. My brief's CONTRACT with audio-capture is `kind == .audio`, so I coded to it. I polled the shared tree repeatedly across the wave; audio-capture landed `WorkVoiceCaptureCoordinator.swift`, `InAppAudioRecorder.swift`, `ContentView.swift`, `WorkboardVoiceCaptureView.swift` and `WorkboardAudioCaptureTests.swift`, but **not the presentation-side enum case**. §Requests 1 is the exact, proven patch.

I did not simply give up on the wait: audio-capture's last write to the tree was `WorkboardAudioCaptureTests.swift` at 00:27, and I kept polling `WorkboardMaterialKind` every 15–20 s until 00:48 (through a full macOS build of the shared tree in between). The case never appeared. Their slice writes `WorkMaterialKind.audio` at the STORAGE level (`WorkVoiceCaptureCoordinator.publishRecording`), which is correct and complete on its own terms — the presentation-side case was evidently not in their brief, so it fell between us.

**Stated plainly: at the time I finished, the shared tree did not build, and the two errors are in a file of mine.** They are one missing enum case away from gone, and I proved it — below.

I did NOT reach for the escape hatch that would have gone green: comparing `material.kind.rawValue == "audio"` compiles today whether or not the case exists, and I rejected it deliberately. It is a second, stringly copy of the enum's raw value, and if the case is ever spelled differently the dispatch silently never fires — a card that quietly stops existing is worse than a build error that names its own fix. Nor did I edit `WorkboardViewModel.swift` to unblock myself: the standing rules forbid editing a file I do not own to make my build pass, and this is exactly the case they are written for.

### B. Isolated verification copy — GREEN on both platforms, and the tests pass

"It fails on someone else's symbol" is not evidence my code is right, so I verified it without touching the shared tree: `rsync` of the worktree into `…/desk-audio-card/verify/fake/.codex/worktrees/tree`, with `…/verify/fake/Conduck-Private` symlinked to the real `Conduck-Private` so the repo's own relative `Identity-Override.xcconfig` symlink resolves (capture-canvas's recipe). **Nothing in the shared worktree and nothing in `Conduck-Private` was written.** In the copy I applied exactly the §Requests 1 patch — the enum case and the switches it obliges — and nothing else. The whole `verify/` tree died with the slug directory.

- `verify-bft-4.log` — iOS `build-for-testing`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
- `verify-test-2.log` — `test-without-building`, one quoted `-only-testing:ConduckTests/WorkboardAudioCardTests`: `** TEST EXECUTE SUCCEEDED **`, `Executed 15 tests, with 0 failures (0 unexpected) in 0.136 (0.141) seconds`.
- `verify-mac-2.log` — macOS `-destination 'platform=macOS'`: `grep -c ': error: '` = **0**, `** BUILD SUCCEEDED **`. **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback was needed.**
- **Zero warnings in any file of mine**, on either platform: `grep -E "(WorkboardAudioCardView|WorkboardAudioCardTests|WorkboardCaptureCanvas)\.swift:[0-9]+:[0-9]+: warning"` → no output in all three logs.

The §Requests 1 patch list is not guesswork: it is the exhaustive set the compiler demanded, discovered by adding the case and rebuilding until green (four rounds — `verify-bft.log` → `verify-bft-3.log`).

### C. Hygiene
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 775 Swift files scanned, no raw store or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift`, exit 0.
- `git diff --check` → clean, exit 0. `git status` shows no `.xcstrings`, no `Identity-Override.xcconfig`, nothing under `docs/`.
- **NOT run, stated plainly:** the full iOS suite and the watch suite. Neither is in my brief; the shared tree could not build a test bundle; and the watch target compiles none of my files (`WorkboardAudioCardView.swift` is app-target only, and `AVAudioSession` there is `#if os(iOS)`).
- Build caches removed at the end with `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-audio-card` (the script lives in the MAIN repo's `.claude/`, not in this worktree), so **the logs above no longer exist** — re-run if you need them.
- Both new files are in synchronized groups (`Views/Workboard`, `ConduckTests`) — compiled and ran with **no pbxproj edit**.

### The 15 cases
**Clock and progress (5).** Progress is 0 until a length is known (0, negative, NaN, infinite duration) · the clamped fraction, including `currentTime` reading a shade past the end on the last tick · `m:ss` growing an `h:mm:ss` field · **truncation, not rounding** — 7.9 s reads `0:07`, because `0:08` beside a bar that has not reached it is a lie · unusable values read as the start of the clip.

**Exclusivity (5).** Starting one card stops the card that held output · re-claiming the SAME card does not stop it (resume-after-pause claims again; stopping there would make resume unreachable) · **a stale terminal cannot silence the card that took output** · resigning clears the slot when the resigner is the holder · the registry does not keep a finished card alive (weak).

**Transport (5).** A fresh player is idle, zeroed, and its next tap starts playback · bytes that do not decode leave the card `failed`, still tappable, **not holding output** · a card with no bytes behind it fails rather than claiming output (what a pending card would answer if ever asked) · leaving the board returns the card to idle and releases the slot · a second tap during the load abandons the attempt instead of queueing a second read.

Playback of real audio needs a real `AVAudioPlayer` and a real session, so it is **founder QA, not a unit test** — §Requests 6.

## 6. Deviations from the brief, with reasons

1. **The card's menu is not shared with `WorkboardSourceCard`.** `WorkboardSourceCard` and its `cardMenuContent` are `private` to `WorkboardCaptureCanvas.swift`, and my ownership there is the dispatch only, so a shared menu component would have been a rework of a file I do not own. My menu therefore repeats the Card Size picker / Move Earlier / Move Later / Remove rows **from the same keys** (no new copy), plus a Play/Pause row and no Open/Reattach. §Requests 4 proposes hoisting the shared rows in the serial pass.
2. **No new "card position" key.** `WorkboardSourceCard.boardPositionLabel` is private to another struct; my card reads the SAME key (`workboard.material.card.position`) through a private helper of its own, so two cards on one board cannot describe their place in the order differently.
3. **No new kind noun.** The card's accessibility label opens with `material.kind.title`, i.e. whatever `WorkboardMaterialKind.audio` is named by the agent who adds it — I did not mint a second name for the same thing. (In my verification copy I named it `workboard.material.audio` = "Voice note"; that key is audio-capture's or the integrator's to add, not mine — see §Catalog.)
4. **`WorkboardVoiceCaptureView.swift` untouched** (capture-canvas §Requests 6 handed me the seam). The two-phase capture is audio-capture's; nothing in my slice pre-empts it, and my card reads only the snapshot.
5. **No Codex consult.** The one genuinely hard call was the audio-session ownership question (§3), and `ChatPlaybackSession`'s own header already documents the failure mode and the answer.

---

## Call-site touches

**NONE outside my own files.** Everything that would have been one is a Request below.

---

## Catalog

**Keys I ADDED in source (7)** — `key = defaultValue`, all in `WorkboardAudioCardView.swift`, main app catalog. Each verified absent from `Conduck/Conduck/Localizable.xcstrings` by a read-only `json.load`, and each appearing in exactly one source site (`workboard.audio.failed` in two — the caption and the accessibility value, same string):

- `workboard.audio.play` = `Play`
- `workboard.audio.pause` = `Pause`
- `workboard.audio.playing` = `Playing`
- `workboard.audio.paused` = `Paused`
- `workboard.audio.loading` = `Loading`
- `workboard.audio.failed` = `This recording couldn’t be played`
- `workboard.audio.position` = `%1$@ of %2$@`

`workboard.audio.position` is a two-placeholder positional format (elapsed, duration) — it must keep both placeholders in any translation.

**Keys I found DEAD: NONE.** I deleted no code that referenced a key.

**Reused, do NOT delete on a stale scout row** — my file is now a live reference for each: `workboard.material.syncPending` · `workboard.material.localOnly` · `workboard.material.reattach.short` · `workboard.material.card.more` · `workboard.material.card.size` · `workboard.material.card.size.{small,standard,large}` · `workboard.material.card.size.{small,standard,large}.action` · `workboard.material.card.position` · `workboard.material.remove.action` · `workboard.action.moveEarlier` · `workboard.action.moveLater`.

**Not mine to add, but owed by the enum case:** `workboard.material.audio` (the `WorkboardMaterialKind.audio` noun). See §Requests 1.

---

## Requests

1. **audio-capture, or the serial integrator — add `WorkboardMaterialKind.audio`. This is the whole of what stands between the tree and green, and the patch below is COMPILER-PROVEN, not proposed.** Five files; I applied exactly this in an isolated copy and got `** TEST BUILD SUCCEEDED **` + `** BUILD SUCCEEDED **` (macOS) + 15/15 tests.
   - `ViewModels/WorkboardViewModel.swift`, `enum WorkboardMaterialKind`: `case audio`; `title` → `LocalizedStringResource("workboard.material.audio", defaultValue: "Voice note")`; `systemImage` → `"waveform"`.
   - `Services/Workboard/WorkboardLiveRepository.swift`, `presentationKind(_:)`: split `case .file, .audio: return .file` into `case .file: return .file` / `case .audio: return .audio`. **Without this one line the card is unreachable** — every stored `.audio` still projects as a `.file` card and my dispatch never fires. It is the single most important line in this list.
   - Same file, `materialName(_:)` fallback switch: `case .audio: return String(localized: "workboard.material.audio", defaultValue: "Voice note")`.
   - Same file, `storageKind(_:)`: `case .audio: return .audio`.
   - Same file, `importMaterial`'s `switch material.kind`: `case .image, .file, .audio:` — audio arrives carrying `data`/`fileURL` exactly like a file. (Only matters if a `.audio` material is ever imported through the repository rather than through `upsertDeskMaterial`; it must compile either way.)
   - `Views/Workboard/WorkboardComponents.swift`, `WorkboardMaterialIcon.tint(for:)`: `case .image, .note, .audio: return AppColors.brandAmber`.
   - `Views/Workboard/PersonalWorkbenchView.swift`, `present(_:)`: `case .file, .audio:` on the file arm — Quick Look then plays the recording, which is the right answer for Share/Open even though my card never routes there.
2. **audio-capture — the placeholder title and the transcript update both reach my card unchanged, but confirm two things.** (a) The card's caption is `material.textContent` and NOTHING else, so phase 2 must land the transcript in `textContent` on the SAME material id (your `WorkVoiceCaptureCoordinator` reads that way — good). (b) `WorkboardMaterialSnapshot.byteCount` is what the footer shows; if a `.audio` draft leaves `byteSize` unwritten the footer silently loses its size line. Your `publishRecording` sets it — keep it.
3. **desk-vm / serial — a voice note whose LOCAL bytes are gone has no repair path.** My card correctly refuses to play an `.unavailableOnThisDevice` recording and says "Reattach", but it is given no `onReattach`: the canvas's reattach seam opens a file importer scoped to the source card. Decide deliberately — either wire `beginReattachment` into the audio branch of `card(for:at:)` (one argument), or accept that an audio card is repaired only by CloudKit and change its copy for that case. Today the chip says a thing the card cannot do. Note this is unreachable for a `.syncedPayload` note (which goes `.syncPending` instead) and only bites a `.localVault` one above the 30 MB ceiling — a ~15 MB voice note is below it, so this is a corner, not a common path.
4. **Serial integration — three small consolidations I could not make from inside my ownership.**
   - The board tile radius `13` is now a literal in two files (`WorkboardSourceCard` and my card). It belongs in `WorkboardMetrics` beside `cardCornerRadius` (which views-core §Requests 5 reports is unread) — one is the project card's radius, the other is the board tile's.
   - The card menu's shared rows (Card Size picker, Move Earlier/Later, Remove) and the matching VoiceOver actions now exist twice, from the same keys. A `WorkboardCardActions` component in `WorkboardComponents.swift` consumed by both would remove the copy; neither file was mine to restructure.
   - The availability glyph/tint/label mapping is likewise duplicated between the two cards, deliberately (availability.md §Requests 1 is about to change it). **Whoever lands that `syncPending` presentation case must land it in BOTH cards** — mine already handles `.syncPending` distinctly, so it needs no change if the enum keeps its four cases.
5. **Serial / copy pass — the audio session helper wants hoisting.** `WorkboardAudioCardPlayer.activateSession/releaseSession` duplicate `ChatPlaybackSession`'s category, mode, options and deactivation flags. Hoisting them into one neutral owner (`AppPlaybackSession`, say, with `ChatPlaybackSession` kept as its chat-named caller) removes the divergence risk. I did not do it: `Services/TTS/ChatPlaybackSession.swift` is not mine, and §D says the desk must not reach into Chat's speech path.
6. **Founder QA — what a headless run cannot prove.** Every item below needs a device or simulator with real audio:
   - Record a voice note in Work, then tap the card **immediately** — it must play. This is the case the session handling exists for: the recorder leaves the session on `.record` and inactive, and without the fix the card would be silent.
   - Play a note with the **hardware silent switch on** — it must still be audible (`.playback`, matching the chat Speak control's posture).
   - Music playing in another app must **duck** during the note and come back after it, and after a **pause** too.
   - Two audio cards: start one, then the other — the first must STOP, not play underneath.
   - Start a note, then **navigate away from Work** — audio must stop.
   - Start a note, then start a **chat read-aloud** in the other pane (iPad/macOS) and vice versa: neither should be left playing on a dead session. This is the interaction my `try?`-swallowed release is designed to survive, and it is the one I could not test.
   - VoiceOver on a card: label reads kind, name, "Play", transcript, size, position; value reads the state and the clock; Move/Resize/Remove are available as custom actions — **including on a "Waiting for iCloud…" card**, which is not a button at all.
   - Reduce Motion on: the progress fill must jump rather than animate, and the ellipsis affordance must not fade.
   - An **untranscribed** card (kill STT / go offline mid-capture) must be playable and caption-free — never a note, never lost.
7. **Nobody make the card load bytes eagerly.** `loadPayload` is called on the first tap and nowhere else. A board of voice notes that reads every payload on every refresh is exactly the failure Shape B was chosen to avoid (plan §C) — the blob rows are out-of-line precisely so a board projection does not touch them.
