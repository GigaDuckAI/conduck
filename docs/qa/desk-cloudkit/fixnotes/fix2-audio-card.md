# fix2-audio-card — all 5 findings CONFIRMED and fixed. C2 landed. Shared tree green: `** TEST BUILD SUCCEEDED **`, `WorkboardAudioCardTests` `Executed 27 tests, with 0 failures`, signed macOS `** BUILD SUCCEEDED **`.

Slug `fix2-card`. Sim `1DCDF41E-D223-48B4-AA8E-147B0A9E2CE1`. No commits/pushes/stash/checkout.
`Identity-Override.xcconfig` untouched. **No `.xcstrings` opened.** Nothing under `docs/qa/desk-cloudkit/`
touched. No mirror triplet touched.

Files I changed — exactly the two I own:
- `Conduck/Conduck/Views/Workboard/WorkboardAudioCardView.swift`
- `Conduck/ConduckTests/WorkboardAudioCardTests.swift` (15 → 27 cases)

---

## C2 — final signatures, verbatim

```swift
struct WorkboardAudioCardView: View {
    let material: WorkboardMaterialSnapshot
    var size: WorkMaterialCardSize = .standard
    var grantedColumns: Int = WorkboardMosaicSpan.large.columns
    var boardPosition: Int = 0
    var boardCount: Int = 0
    var loadPayload: (UUID) async throws -> Data? = { id in
        try await ConversationStore.shared.loadWorkMaterialPayload(id: id)
    }
    var onOpen: (() -> Void)? = nil
    var onReattach: (() -> Void)? = nil
    var onSetSize: ((WorkMaterialCardSize) -> Void)?
    var onMoveEarlier: (() -> Void)?
    var onMoveLater: (() -> Void)?
    var onRemove: (() -> Void)?
```

`onOpen` / `onReattach` sit between `loadPayload` and `onSetSize`, i.e. the same slot
`WorkboardSourceCard` puts them in. **fix2-canvas's call site already passes both in exactly that
order** (`WorkboardCaptureCanvas.card(for:at:)`, audio branch) and the shared tree compiles, so the
contract is closed on both sides — I verified the call site, I did not edit it.

Gating, as C2 specifies:
- **Open row** — `WorkboardAudioCardPresentation.showsOpenAction(availability:hasOpenAction:)`, true iff
  the board's permission policy allows `.open` for that availability AND `onOpen != nil`. It appears in
  the ellipsis/context menu (`workboard.material.open`) and as a VoiceOver custom action.
- **Chip** — `.unavailableOnThisDevice` with `onReattach != nil` draws a **Button** (`Reattach`,
  `workboard.material.reattach.short`), plus a menu row and a VoiceOver custom action
  (`workboard.material.reattach.action`). With `onReattach == nil` the same corner draws **non-action
  status copy** (`workboard.audio.unavailableHere` = "Not on this device") and no control. Every other
  availability state is status-only whatever is wired.
- The chip Button is `accessibilityHidden` inside the tile (the card is `.accessibilityElement(children:
  .ignore)`, so a nested control would be unreachable) — the reattach ACTION reaches VoiceOver as a
  custom action instead, which is the only shape that works there.

**Reuse instead of a second policy:** `isPlayable`, the Open gate and the reattach gate all route
through fix2-canvas's new `WorkboardCardActionPolicy` rather than re-deriving `availability.isAvailable`
locally. That file is not mine; I only call it. Reason: its own header says every card surface must ask
one policy, and an audio card that opened what a source card beside it refuses is exactly the drift it
exists to stop.

---

## Findings

### audio#5 — iOS session reconfigured/deactivated unconditionally — CONFIRMED, fixed

Verified at HEAD: `activateSession()` was `try? setCategory(.playback…)` + `try? setActive(true)` with no
CarPlay guard, no capture probe and no ownership; `releaseSession()` was an unconditional
`try? setActive(false)`; `begin` trusted `engine.play()` after both errors were swallowed. `ThreadSpeaker`
guards the same calls with `CarPlayRecordingService.anySessionActive` (`ThreadSpeaker.swift:388,397`), so
the asymmetry the finding describes was real.

Fix — a new process-wide arbiter in my file, `WorkboardAudioOutput` (`WorkboardAudioOutputArbiter`
protocol; `WorkboardAudioOutputClaim { granted, captureIsLive, sessionUnavailable }`):
- **Refuses while a capture is live** — `CarPlayRecordingService.anySessionActive` (iOS) or any live
  `SpeechExclusivity` mic authority. The refusal is probed in `begin`/`resume` BEFORE anything is claimed,
  so a refused card never stops the card that is playing on its way to saying no. The card lands in a new
  `WorkboardAudioPhase.blocked` — not `.failed`, because the recording is fine.
- **Ownership** — `claim(for:)` records the holder weakly; `release(for:)` deactivates only for the client
  that is still the holder. A stale terminal from a card that already lost output can no longer deactivate
  the session under the card that took it.
- **A refused activation is a refusal** — `activateSharedSession()` throws instead of `try?`, `claim`
  returns `.sessionUnavailable` and leaves the holder unset, and the player surfaces `.failed` rather
  than calling `AVAudioPlayer.play()` behind a swallowed error.
- Session category/mode/options are unchanged (`.playback` / `.spokenAudio` / `.duckOthers`); the release
  stays best-effort by design (`setActive(false)` throws busy while another leg holds audio I/O).

### audio#6 — macOS card bypasses SpeechExclusivity — CONFIRMED, fixed

Verified: `WorkboardAudioCardPlayer` conformed only to `WorkboardAudioExclusive` (desk cards), so a chat
read-aloud could overlap it and `DictationService`/`InAppAudioRecorder`'s `SpeechExclusivity.claim(nil)`
could not stop it.

Fix: `WorkboardAudioCardPlayer: SpeechExclusivityParty`.
- **Registers** at the start of a payload read (`start(load:)`) — so a mic starting during the read stops
  the card instead of racing it — and **claims** (`register` + `claim(self)`) immediately before every
  start and resume, which stops every other registered speaker.
- `stopForSpeechExclusivity()` tears the card down and returns it to `.idle`, and **no-ops when the card
  is not producing audio** (idle/failed/blocked), mirroring `ThreadSpeaker`'s guard — every claim
  broadcasts to every party, and an idle card must not report a state change for someone else's audio.
- The bus has **no resign API** (claims are broadcasts, not leases), so "resign on every terminal" is
  satisfied by construction: a stopped party holds nothing. The desk's own one-card-at-a-time registry
  (`WorkboardAudioExclusivity`) still does the resign bookkeeping it always did.

**Deviation, stated plainly:** the card joins the bus on **both** platforms, while `SpeechExclusivity`'s
header says only macOS registers. Reason: it is the mechanism the task names for stopping competing chat
playback, it costs nothing where it is inert, and it cannot break the invariant the platform gate exists
for — CarPlay registers no party, so nothing here can preempt its exactly-once / deactivate-once legs.
On iOS the bus is inert today (no iOS party or authority registers), so this changes nothing until
someone registers there; see §Requests 1 and 2. Registration is lazy (first action, not `init`) because
SwiftUI re-evaluates an `@State` default initializer on every struct init and would otherwise churn the
registry with throwaway players — the same footgun `SpeechExclusivity`'s own header records.

### audio#7 — no Open action from the card — CONFIRMED (my half), fixed

The card had no Open command, so the canvas's `.audio` Quick Look presenter was unreachable. C2's `onOpen`
plus the Open menu row and VoiceOver action closes the reachability half.

**The extensionless-preview-file half is NOT mine and is NOT fixed here** — it lives in the canvas /
`PersonalWorkbenchView` materialization path (`material.name` is a title such as "Voice note", not
`voice-note.m4a`). §Requests 3.

### audio#10 — loading phase announces "Play" — CONFIRMED, fixed

Verified: `transportActionTitle` distinguished only `.playing`, while `toggle` handles `.loading` by
cancelling. Fix: `WorkboardAudioCardPresentation.transportAction(for:)` returns `.cancelLoading` for
`.loading`, and the menu label + glyph (`xmark`) and the accessibility label all read from it, so the
words and the tap cannot drift apart. New key `workboard.audio.cancelLoading` = "Cancel Loading".
I chose the label over disabling activation because cancelling a slow payload read is the useful
affordance, and a disabled control drops its VoiceOver custom actions (the card would become
unarrangeable while loading).

### ui#6 — unavailable chip says "Reattach" with no action — CONFIRMED, fixed

Closed by C2 above: the chip is a real control when `onReattach` is wired (and fix2-canvas now wires it),
and non-action status copy when it is not.

---

## Regression tests — `WorkboardAudioCardTests`, 15 → 27

All 12 new cases are behavioural; no source-text guard was added.

| Case | Proves |
|---|---|
| `testOnlyTheClientThatClaimedOutputCanDeactivateTheSession` | A release from a client that already lost output deactivates nothing; the holder's release deactivates exactly once |
| `testAClaimTheSessionRefusedLeavesNoHolderAndNeverDeactivates` | A refused activation grants nothing, so a later release cannot deactivate a session it never brought up |
| `testALiveCaptureIsRefusedBeforeTheSessionIsTouched` | `.captureIsLive` with **zero** activations — a live capture's session is never reconfigured |
| `testTheHolderReclaimingDoesNotReactivateTheSession` | Idempotent claim (pause→resume rides the route it holds) |
| `testALiveCaptureRefusesTheCardWithoutClaimingAnything` | Player-level: `.blocked`, no output claim, the playing card is not stopped, the card stays retryable |
| `testASessionThatRefusesToActivateFailsTheCardInsteadOfPlayingBlind` | `.failed` instead of trusting `play()`; nothing claimed ⇒ nothing released |
| `testAMicrophoneClaimStopsACardThatIsBringingAudioUp` | `bus.claim(nil)` (the mic's own call) stops a card mid payload read |
| `testTheBusCannotStopACardThatIsNotProducingAudio` | A broadcast claim does not disturb an idle card |
| `testTheLoadingPhaseOffersCancelRatherThanPlay` | `.loading → .cancelLoading`, every other phase mapped |
| `testOpenIsOfferedOnlyForReadableBytesAndOnlyWhenTheBoardWiredIt` | Open gate over the 4×2 matrix |
| `testTheUnavailableChipIsAnActionOnlyWhenReattachIsWired` | `.reattach` (isAction) vs `.notOnThisDevice` (status) |
| `testTheOtherAvailabilityStatesAreNeverActionsWhateverIsWired` | `.available` → no chip; `.syncPending`/`.localOnly` never actions |

**How I know they would fail on the old code — two MEASURED counterfactuals**, each applied in an
isolated copy under my slug dir (never in the shared tree), rebuilt and re-run:

1. Arbiter reverted to the old shape (unconditional `release`, no capture probe): `cf-test.log` →
   `Executed 27 tests, with 5 failures`, failing exactly
   `testOnlyTheClientThatClaimedOutputCanDeactivateTheSession` ("1" ≠ "0" — *Only the holder may
   deactivate the session*), `testALiveCaptureIsRefusedBeforeTheSessionIsTouched` ("granted" ≠
   "captureIsLive") and `testAClaimTheSessionRefusedLeavesNoHolderAndNeverDeactivates`.
2. Player reverted to the old shape (no pre-claim capture probe; a refused session falls through to
   `play()`): `cf2-test.log` → `Executed 27 tests, with 3 failures`, failing
   `testALiveCaptureRefusesTheCardWithoutClaimingAnything` and
   `testASessionThatRefusesToActivateFailsTheCardInsteadOfPlayingBlind`.

The presentation cases are argued from the assertion rather than measured: `transportAction(for: .loading)`
was `Play` at HEAD by construction (the old ternary keyed only on `.playing`), and the Open row and the
chip action did not exist at all.

**What no unit test here proves**, said plainly: real playback. Reaching `.playing` needs a real
`AVAudioPlayer` decoding real audio on a real route; I deliberately did not synthesize a clip to force
it, because a test that depends on the simulator's audio stack answering `play() == true` is a flake, not
a guarantee. The mic-stops-a-playing-card path is proven at the `.loading` edge (same `deactivate()` call
and the same guard set, which includes `.playing`) — the audible half stays founder QA (§Requests 5).

## Guard verdicts

None assigned to me — my brief carries no `t#N` items and I added no source-text drift guard.

---

## Gates run — exact lines

Every log under `~/Library/Caches/gigaduck-builds/fix2-card/`, each grepped for `': error: '` and the
`BUILD`/`TEST` verdict strings; never judged from tail or exit code. No `-configuration` passed anywhere.

**Shared tree (final state):**
- iOS `build-for-testing` → `ios-bft-6.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
- `test-without-building`, one quoted `-only-testing:ConduckTests/WorkboardAudioCardTests` → `ios-test-1.log`:
  `** TEST EXECUTE SUCCEEDED **`, `Executed 27 tests, with 0 failures (0 unexpected) in 0.414 (0.429) seconds`.
- Neighbouring suites my bus participation could disturb → `ios-test-2.log`: `** TEST EXECUTE SUCCEEDED **`,
  `Executed 34 tests, with 0 failures (0 unexpected)` — `SpeechExclusivityTests` `Executed 16 tests, with 0 failures`,
  `ThreadSpeakerStopAndAutoSpeakTests` `Executed 6 tests, with 0 failures`,
  `WorkboardMaterialBoardActionsTests` `Executed 12 tests, with 0 failures`.
  (`ThreadSpeakerExclusivityTests` contributed no cases — it is macOS-gated and compiles out on the iOS sim.)
- macOS `build -destination 'platform=macOS'` → `mac-shared-1.log`: 0 `error:`, `** BUILD SUCCEEDED **`,
  `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`. **Signed through the identity
  override; no `CODE_SIGNING_ALLOWED=NO` fallback needed.**
- Zero warnings in either of my files on either platform.

**Foreign failures I waited out, recorded because they were real for most of the wave** (four earlier
shared-tree attempts, ~15 min, all in files I do not own and never edited):
`ContentView.swift:1567` then `InAppAudioRecorder.swift:363/491` then six type errors and four
`'async' call in an autoclosure` errors in `ConduckTests/WorkboardAudioCaptureTests.swift` — all of them
the C1 `WorkVoiceAttachOutcome` migration landing file by file. The fifth attempt was clean. While
waiting I verified my own files in an isolated `rsync` copy under `~/Library/Caches/gigaduck-builds/fix2-card/verify/`
(with `Conduck-Private` symlinked so the repo's relative `Identity-Override.xcconfig` resolves), patching
ONLY those foreign call sites inside the copy: `verify-bft-5.log` 0 errors + `** TEST BUILD SUCCEEDED **`,
`verify-test-2.log` `Executed 27 tests, with 0 failures`, `verify-mac-2.log` 0 errors +
`** BUILD SUCCEEDED **` signed. Nothing in the shared worktree or in `Conduck-Private` was written by it.

**Hygiene:** `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 780 Swift files scanned…`,
exit 0. `git diff --check` → clean, exit 0. `git status --short` shows no `.xcstrings`, no
`Identity-Override.xcconfig`, no `docs/`, no `project.pbxproj` from me. Both my files are pre-existing, so
no pbxproj edit arose.

**NOT run, plainly:** the full iOS suite and the watch suite. Neither is in my brief; the watch target
compiles neither of my files (`WorkboardAudioCardView.swift` is app-target only). Build caches removed at
the end with `.claude/scripts/clean-build-cache.sh fix2-card`, so **the logs above no longer exist** —
re-run if you need them.

---

## Catalog

**Keys I ADDED in source (3)** — `key = defaultValue`, all in `WorkboardAudioCardView.swift`, main app
catalog. Each verified absent from `Conduck/Conduck/Localizable.xcstrings` by a read-only `json.load`:

- `workboard.audio.cancelLoading` = `Cancel Loading`
- `workboard.audio.busy` = `Audio is in use right now`
- `workboard.audio.unavailableHere` = `Not on this device`

`workboard.audio.busy` is the caption AND the accessibility value of a card refused because a capture
owns audio; `workboard.audio.unavailableHere` is the non-action reading of the availability corner when
no reattach action was wired.

**Keys I newly REFERENCE (already in the catalog — do not delete on a stale scout row):**
`workboard.material.open`, `workboard.material.reattach.action`. Still referenced from my file, unchanged:
`workboard.material.syncPending` · `workboard.material.localOnly` · `workboard.material.reattach.short` ·
`workboard.material.card.more` · `workboard.material.card.size{,.small,.standard,.large}{,.action}` ·
`workboard.material.card.position` · `workboard.material.remove.action` · `workboard.action.moveEarlier` ·
`workboard.action.moveLater` · `workboard.audio.{play,pause,playing,paused,loading,failed,position}`.

**Keys I made DEAD: NONE.** I deleted no code carrying a string.

---

## Requests

1. **Whoever owns `Services/InAppAudioRecorder.swift` (and `MenuBar/DictationService.swift`) — register the
   mic authority on iOS, not only on macOS.** `SpeechExclusivity.shared.register(recordingAuthority: self)`
   is inside `#if os(macOS)` (`InAppAudioRecorder.swift:134`), so `isRecordingActive` is permanently false
   on iOS and my capture refusal there rests on `CarPlayRecordingService.anySessionActive` alone. Dropping
   the `#if os(macOS)` around the registration (registration only — the mic LEASE and the `claim(nil)`
   can stay macOS-only) would make an audio card refuse to play into a live in-app capture on iPhone too.
   Not breakage today: on iOS a starting recorder puts the shared session on `.record`, which stops our
   playback at the OS level — but that is the OS cutting audio, not the card deciding, and the card would
   then report `.playing` over silence.
2. **Whoever owns `Services/TTS/ThreadSpeaker.swift` — consider registering the speaker on iOS.**
   `SpeechExclusivity.shared.register(self)` is macOS-only (`ThreadSpeaker.swift:66`, reason given: "on iOS
   the audio session arbitrates"). That is true BETWEEN apps and false WITHIN one: two `AVAudioPlayer`s in
   the same process on one session overlap. My card already claims the bus on iOS, so the day a speaker
   registers there, a desk card and a chat read-aloud stop overlapping with no further change. CarPlay
   registers nothing, so its invariants are untouched either way. Founder/owner call, not a defect I can
   assert from inside my file.
3. **fix2-canvas / serial — audio#7's second half is still open.** The `.audio` arm that materialises a
   synced payload for Quick Look names the file from `material.name`, which for a voice note is a title
   ("Voice note", or the transcript), so the disposable preview file is extensionless and Quick Look has
   nothing to route on. Derive the extension from `mimeType` (or carry the stored filename into the
   snapshot). My Open action now makes that path reachable, which is what turns it from theory into a
   visible failure.
4. **Serial / copy pass — three keys need catalog rows** (§Catalog). All three are source-only in this
   phase; I opened no `.xcstrings`.
5. **Founder QA — what a headless run cannot prove.** Additions to the audio-card list, all needing real
   audio: (a) start a note, then start a **CarPlay** voice session — the card must refuse rather than
   reconfigure the car's session, and must say "Audio is in use right now" rather than "This recording
   couldn't be played"; (b) on **macOS**, start a note then start a **menu-bar dictation** — the note must
   stop; and start a note while a **chat read-aloud** is speaking — the speech must stop, not overlap;
   (c) start a note, tap a second one, then let the first one's tick land — the second must keep playing
   and must not be silenced by the first's teardown (the ownership rule); (d) pause a note and confirm
   other apps' music **un-ducks**, then resume and confirm it ducks again; (e) tap a card while its bytes
   are loading — the menu and VoiceOver must both say "Cancel Loading", and the tap must abandon the read.
6. **Nobody re-narrow the audio card's permissions locally.** `isPlayable`, the Open row and the reattach
   chip all read `WorkboardCardActionPolicy`. Re-deriving any of them from `availability.isAvailable`
   inside the card would reopen exactly the one-surface-opens-what-another-refuses drift that policy exists
   to close.

## Refuted

**None.** All five findings held against the current code, traced by call path before any edit.
