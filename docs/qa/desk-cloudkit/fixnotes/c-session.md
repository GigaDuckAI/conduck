# c-session — r3a#2 / O-3 CONFIRMED and fixed; O-13 session half done. Shared tree green in my scope.

Slug `c-session`. Sim `1DCDF41E-D223-48B4-AA8E-147B0A9E2CE1`. No commits/pushes/stash/checkout/index ops.
`Identity-Override.xcconfig` untouched. **No `.xcstrings` opened.** Nothing under `docs/qa/desk-cloudkit/`
touched. No mirror triplet touched. No `project.pbxproj` edit (every file lives under the `Conduck`
synchronized root group, whose only membership exception is `Info.plist` — verified in `project.pbxproj`
lines 174–288 before adding/removing files).

Files I changed:
- `Conduck/Conduck/Services/TTS/SpeechExclusivity.swift` (header + three doc comments; no code)
- `Conduck/Conduck/Services/InAppAudioRecorder.swift` (exclusivity regions only)
- `Conduck/Conduck/Services/TTS/ThreadSpeaker.swift` (exclusivity gates + session-owner call sites)
- `Conduck/Conduck/Views/Workboard/WorkboardAudioCardView.swift` (arbiter's two session calls + header)
- **NEW** `Conduck/Conduck/Services/TTS/SpokenAudioSession.swift`
- **DELETED** `Conduck/Conduck/Services/TTS/ChatPlaybackSession.swift` (renamed into the file above — see O-13)
- **NEW** `Conduck/ConduckTests/AudioExclusivityCrossSurfaceTests.swift` (7 cases)
- `Conduck/ConduckTests/WorkboardAudioCardTests.swift` — **not modified.** Its 27 cases already cover the
  card's half of the bus with an injected registry; what O-3 is actually about is whether the OTHER
  surfaces are wired to the REAL one, which an injected bus cannot see. That belongs in the new file.

---

## r3a#2 / O-3 — iOS mic + read-aloud outside `SpeechExclusivity` — CONFIRMED, fixed

**Verified against the code before editing, by call path:**
- `InAppAudioRecorder.init` registered its authority inside `#if os(macOS)` (was `:264-271`), and the
  `RecordingExclusivityAuthority` conformance itself was `#if os(macOS)` (was `:978-991`) — so on iOS the
  recorder was not merely unregistered, it did not *conform*.
- `startRecording()`'s `SpeechExclusivity.shared.claim(nil)` sat inside the same macOS block as the mic
  lease (was `:342-357`).
- `ThreadSpeaker` registered under `#if os(macOS)` (`:59-67`), claimed under `#if os(macOS)` at all three
  audio-start edges (fresh speak, resume, wrist-raise auto-resume), and its `SpeechExclusivityParty`
  conformance was `#if os(macOS)` (`:487-501`).
- `WorkboardAudioOutput.systemCaptureIsLive()` reads `CarPlayRecordingService.anySessionActive ||
  SpeechExclusivity.shared.isRecordingActive`; with no iOS authority ever registered the second term was
  a constant `false`, so the card's capture refusal on iPhone rested on CarPlay alone.

Both halves of the finding therefore held: a starting composer mic moves the shared session to `.record`
and silences a playing card at the OS level while the card's own machine still reads `.playing`, and a
chat read-aloud and a desk card were two unarbitrated `AVAudioPlayer`s on one session.

**Fix — the gates, and nothing else.** Every changed gate went from `#if os(macOS)` to
`#if os(macOS) || os(iOS)`:

| Symbol | File |
|---|---|
| `InAppAudioRecorder.init` → `register(recordingAuthority:)` | `InAppAudioRecorder.swift` |
| `extension InAppAudioRecorder: RecordingExclusivityAuthority` | `InAppAudioRecorder.swift` |
| `startRecording()` → `SpeechExclusivity.shared.claim(nil)` | `InAppAudioRecorder.swift` |
| `ThreadSpeaker.init` → `register(_:)` | `ThreadSpeaker.swift` |
| `speak(_:messageID:)` fresh-turn `claim(self)` | `ThreadSpeaker.swift` |
| `speak(_:messageID:)` `.paused` resume `claim(self)` | `ThreadSpeaker.swift` |
| `autoResumeIfSystemPaused()` `claim(self)` | `ThreadSpeaker.swift` |
| `extension ThreadSpeaker: SpeechExclusivityParty` | `ThreadSpeaker.swift` |

**Deliberate non-changes, each with its reason:**
- **`acquireMicLease` stays macOS-only.** The adjudication asks for registration + `claim(nil)`, not the
  lease, and the lease exists for a macOS-specific hazard: two in-process `AVAudioRecorder`s (menu-bar
  `DictationService` vs. the composer) with no session to arbitrate them. iOS has one in-app microphone
  and a session that already arbitrates it against CarPlay's, so there is no second start to refuse —
  and adding one would newly let a card or a CarPlay session refuse a composer tap. I split the macOS
  block in two rather than widening it: lease block macOS-only, `claim(nil)` block both platforms.
- **`ThreadSpeaker` is NOT registered on watchOS.** `ThreadSpeaker.swift` compiles into
  `ConduckWatch Watch App` (it is in that target's `membershipExceptions` list) and
  `SpeechExclusivity.swift` is NOT — so `#if !os(watchOS)` would have been a new watch-target build
  break. `#if os(macOS) || os(iOS)` is exact, and the wrist has one speaker and nothing to arbitrate
  against anyway.
- **CarPlay stays out of the bus, explicitly.** `CarPlayRecordingService` is not registered as an
  authority (surfaces that must not play over it read `anySessionActive` directly, as
  `WorkboardAudioOutput` and `ThreadSpeaker` already do), and CarPlay's `ReplyVoice` is its own instance,
  never `.shared`, so no `claim` can reach it. `SpeechExclusivity`'s header now states this as a
  constraint rather than as a platform gate, and one of the new tests asserts it.
- **`ReplyVoice.shared` stays macOS-only.** It is not my file, and registering it would change which
  object the iOS auto-speak path can preempt. §Requests 2.

**Header updated as the adjudication asks.** `SpeechExclusivity.swift`'s "macOS bus / ONLY macOS call
sites register" opening is replaced by the constraint that now binds: both desktop-and-phone platforms
register, because macOS has no arbitration at all and iOS has one that arbitrates between APPS and not
within this one — "the session decides what the hardware does; this bus is what makes the surfaces AGREE
about it". The two surfaces that stay out (watchOS, CarPlay) are named with their reasons. The
`PARTIES`/`PRIORITY RULES` blocks, the `SpeechExclusivityParty` doc, `isRecordingActive`'s "inert on
iOS/watch" line and `acquireMicLease`'s "inert on iOS/watch" line were all false after the change and
are corrected. Two stale "on macOS…" asides in `InAppAudioRecorder` (`isStarting`'s doc and its
`startRecording` twin) likewise.

### Regression test — `AudioExclusivityCrossSurfaceTests`, 7 new cases

New file, because the existing card suite drives an INJECTED bus and the whole point of O-3 is which
surfaces are on the REAL one. Every case drives production objects against `SpeechExclusivity.shared`
(which those objects hardcode), the way `ThreadSpeakerExclusivityTests` does on macOS; parties and
authorities are weak, so each test's instances leave the registry when they die.

| Case | Proves |
|---|---|
| `testTheComposerMicrophoneIsALiveCaptureTheDeskCanSee` | A recording `InAppAudioRecorder` makes `SpeechExclusivity.shared.isRecordingActive` AND `WorkboardAudioOutput.shared.captureIsLive` true — the exact probe the desk asks before playing |
| `testAStartingMicrophoneStopsACardThatIsBringingAudioUp` | `startRecording()`'s own broadcast takes a `.loading` card to `.idle` |
| `testAStartingMicrophoneStopsAReplyThatIsBeingReadAloud` | …and takes a `.playing` `ThreadSpeaker` to `.idle` |
| `testAReplyStartingStopsACardThatIsBringingAudioUp` | A fresh `speak` stops a card mid payload read |
| `testACardTakingOutputStopsAReplyThatIsBeingReadAloud` | A card's claim (which happens BEFORE it decodes) stops the reply — asserted on both the speaker's state and the engine's `stopCount` |
| `testTwoChatSpeakersDoNotOverlapOnThisPlatform` | Cross-INSTANCE parity on iOS: two thread views, each with its own engine, cannot both speak (iPad columns / window + popover) |
| `testTheCarPlaySpeakerIsOutOfReachOfEveryClaim` | A `ReplyVoice` built the CarPlay way (own instance, registered nowhere) survives both `claim(nil)` and a speaker's `claim(self)` untouched |

**How I know they would fail on the old code — MEASURED counterfactual.** Isolated `rsync` copy of the
worktree's `Conduck/` under `~/Library/Caches/gigaduck-builds/c-session/cf/` (never the shared tree),
with `sed` reverting all eight gates back to `#if os(macOS)` (3 in `InAppAudioRecorder.swift`, 5 in
`ThreadSpeaker.swift`; grep confirmed no pre-existing `#if os(macOS) || os(iOS)` was collateral).
`cf-bft-1.log`: 0 `': error: '`, `** TEST BUILD SUCCEEDED **`. `cf-test-1.log`:

```
Test Suite 'AudioExclusivityCrossSurfaceTests' failed
	 Executed 7 tests, with 8 failures (0 unexpected) in 1.199 (1.201) seconds
Test Suite 'WorkboardAudioCardTests' passed
	 Executed 27 tests, with 0 failures (0 unexpected) in 0.047 (0.053) seconds
```

Six of the seven cases fail on the old gates (8 assertion failures — `testTheComposerMicrophoneIsALive…`
and `testACardTakingOutput…` each fail twice). `WorkboardAudioCardTests` passing unchanged in the same
run is the control: the card's own half was already correct, and O-3 was never about it.

**The seventh case passes on old and new code, and that is deliberate** —
`testTheCarPlaySpeakerIsOutOfReachOfEveryClaim` asserts an invariant that must hold on BOTH sides of this
change. It is not evidence that the fix landed; it is the guard that fails the day someone registers
CarPlay's speaker or its recording service on the bus, which is exactly the risk widening the platform
gate creates. Stated plainly rather than counted as a regression test for the finding.

**What no unit test here proves, said plainly:** that the OS actually silences the card (that is the
`AVAudioSession` `.record` switch, not our code), and that a live CarPlay voice session makes the desk
refuse — `CarPlayRecordingService.anySessionActive` is `private(set)` and written only by a real car
connection, so no headless run can set it. Both stay founder QA. §Requests 4.

---

## O-13 (session half) — ONE owner for the spoken-audio session — DONE

`WorkboardAudioOutput.activateSharedSession()/releaseSharedSession()` and
`ChatPlaybackSession.configureAndActivate()/deactivate()` held byte-identical copies of the same posture
(`.playback` / `.spokenAudio` / `[.duckOthers]`, `setActive(false, .notifyOthersOnDeactivation)`) on the
same shared session.

**Mechanism — a rename, not a wrapper.** `ChatPlaybackSession.swift` is deleted and its content lives in
`Services/TTS/SpokenAudioSession.swift` as `enum SpokenAudioSession`, with both surfaces calling it. I
did not simply make the desk call `ChatPlaybackSession`: a desk card depending on a type named for chat
is the same drift in a different disguise, and the honest reading is that neither surface owns the
session — the app's spoken-word posture does. Both files were mine to change, both live under the
`Conduck` synchronized root group, so the rename needs no `project.pbxproj` edit (verified; `git status`
shows no `pbxproj`).

**What did NOT move, and why.** The type owns the session's SHAPE only. Each caller keeps its own policy,
because they are different promises about the same hardware and merging them would break one of them:
- `ThreadSpeaker` keeps its `CarPlayRecordingService` guard on both calls and keeps `try?` (a thrown
  error must not enter the speak path).
- `WorkboardAudioOutput` keeps `throws` on activation — **the fix2-audio-card guarantee that a refused
  activation is a refusal, never a granted claim, is intact**: `activateSharedSession()` still rethrows,
  `claim(for:)` still returns `.sessionUnavailable` and leaves `holder` unset, and the player still
  answers `.failed` rather than calling `AVAudioPlayer.play()`. It also keeps the ownership rule (only
  the holder's `release` deactivates) and the best-effort `try?` on release.
The new file's header states that split so a later reader cannot "simplify" the two policies together.

Behaviour-preserving by construction: same calls, same arguments, same order, same error handling at
every call site. No test was added for it — a behaviour-neutral rename has no counterfactual to measure,
and inventing a source-text guard that both surfaces name one type would be exactly the kind of guard
this wave is converting away. `WorkboardAudioCardTests` injects its session closures, so it neither
notices nor is weakened.

**The cosmetics stay backlogged as adjudicated:** the board-tile radius `13` literal, the shared
`WorkboardCardActions` menu, and `onCancel` → `onDismiss`. Untouched.

---

## Gates run — exact lines

Logs under `~/Library/Caches/gigaduck-builds/c-session/`, each grepped for `': error: '` and the
`BUILD`/`TEST`/`Executed ` verdict strings; never judged from tail or exit code. No `-configuration`
passed anywhere. Caches removed at the end with `.claude/scripts/clean-build-cache.sh c-session`, so
**the logs no longer exist** — re-run to reproduce.

**iOS `build-for-testing`** (sim `1DCDF41E…`) — `ios-bft-1.log` and, after other agents' files moved
under me, `ios-bft-2.log`: `grep -c ': error: '` = **0** both times, `** TEST BUILD SUCCEEDED **` both.

**Targeted `test-without-building`**, one quoted `-only-testing:ConduckTests/<Class>` per class, 13
classes — final run `ios-test-2.log`, `Executed 158 tests, with 5 failures`, all five foreign (below):

| Class | Result line |
|---|---|
| `AudioExclusivityCrossSurfaceTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.327 (0.329) seconds` |
| `WorkboardAudioCardTests` | `Executed 27 tests, with 0 failures (0 unexpected) in 0.044 (0.049) seconds` |
| `SpeechExclusivityTests` | `Executed 16 tests, with 0 failures (0 unexpected) in 0.007 (0.010) seconds` |
| `ThreadSpeakerTests` | `Executed 8 tests, with 0 failures (0 unexpected) in 0.312 (0.314) seconds` |
| `ThreadSpeakerReconcileTests` | `Executed 14 tests, with 0 failures (0 unexpected) in 0.033 (0.036) seconds` |
| `ThreadSpeakerInterruptionTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.033 (0.034) seconds` |
| `ThreadSpeakerStopAndAutoSpeakTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds` |
| `ThreadSpeakerFallbackMarkerTests` | `Executed 2 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds` |
| `CarPlayVoiceTimingContractTests` | `Executed 22 tests, with 0 failures (0 unexpected) in 0.054 (0.058) seconds` |
| `WorkVoiceRecoveryTests` | `Executed 18 tests, with 0 failures (0 unexpected) in 0.141 (0.145) seconds` |
| `WorkboardAudioCaptureTests` | `Executed 19 tests, with 0 failures (0 unexpected) in 0.131 (0.135) seconds` |
| `WorkboardVoiceLaneTests` | `Executed 12 tests, with 5 failures (0 unexpected) in 0.954 (0.956) seconds` — **foreign, see below** |
| `ThreadSpeakerExclusivityTests` | contributed **0 cases** — still `#if os(macOS)`, compiles out on the iOS sim. §Requests 1 |

**macOS `build -destination 'platform=macOS'`** — `mac-build-1.log`: `grep -c ': error: '` = **0**,
`** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`. **Signed
through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed.** Zero `warning:` lines
naming any of my five source files, on either platform.

**Foreign failures, recorded not fixed** — `WorkboardVoiceLaneTests`, 5 failures, every one a source-text
guard over `ContentView.swift` or a byte-count over the Shortcuts lane, both mid-edit by another agent
(`git status` shows `ContentView.swift`, `WorkVoiceCaptureCoordinator.swift`, `STTClient.swift` modified
by others):
```
WorkboardVoiceLaneTests.swift:73  … "The words no longer join the recording they came from."
WorkboardVoiceLaneTests.swift:114 … XCTAssertEqual failed: ("5") is not equal to ("2")
WorkboardVoiceLaneTests.swift:124 … "and the transcript is aimed at it"
WorkboardVoiceLaneTests.swift:364 … "ContentView.swift recovers a Work transcript without offering it to the recording card"
WorkboardVoiceLaneTests.swift:385 … "ContentView.swift no longer carries the fallback publication this guard orders"
```
I edited none of those files. An earlier run (`ios-test-1.log`, ~6 min before) also had
`WorkboardAudioCaptureTests.swift:731` failing on the same `ContentView.swift` guard; it went green on
its own between the two runs, which is what an in-flight foreign landing looks like. My own build never
failed, so the wait-and-retry path was not needed.

**Hygiene:** `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 795 Swift files scanned…`,
exit 0. `git diff --check` → clean, exit 0. `git status --short` shows no `.xcstrings`, no
`Identity-Override.xcconfig`, no `docs/`, no `project.pbxproj` from me.

**NOT run, plainly:** the full iOS suite and the watch suite — neither is in my brief, and no watch sim
is assigned to me. `ThreadSpeaker.swift` IS in the watch target, but every line I changed in it is inside
a `#if os(macOS) || os(iOS)` gate that compiles out on watchOS, so the watch target sees no change at
all; I did not run the watch suite to confirm that and say so rather than implying I did.

---

## Catalog

**Keys I ADDED in source: NONE.** No user-facing copy changed — this is arbitration wiring and a type
rename, neither of which reaches a screen.

**Keys I made DEAD: NONE.** The deleted `ChatPlaybackSession.swift` carried no strings.

---

## Requests

1. **`ConduckTests/ThreadSpeakerExclusivityTests.swift` is now under-scoped (test file, not mine).** Its
   `#if os(macOS)` gate and its header ("`#if os(macOS)` because the registration/claim lines inside
   `ThreadSpeaker` only exist there") are both false as of this change — those lines now exist on iOS,
   and the file contributes 0 cases to the authoritative iOS-sim pass. Widening the gate to
   `#if os(macOS) || os(iOS)` and correcting the header sentence should turn its 3–4 cross-instance cases
   on for iOS. I replicated the one load-bearing case
   (`testTwoChatSpeakersDoNotOverlapOnThisPlatform`) in my new file so the coverage is not missing in the
   meantime, but the original file should not keep saying something untrue.
2. **Whoever owns `Services/TTS/ReplyVoice.swift` — decide whether `ReplyVoice.shared` registers on iOS.**
   Its self-registration is `#if os(macOS)` (`ReplyVoice.swift:194-199`), and so is its
   `SpeechExclusivityParty` conformance (`:1177-1188`). Today that is harmless because the only caller
   that speaks on the shared instance (`ConversationDetailViewModel.speakArrivalOnSharedEngine`, wired at
   `:1470-1485`) is itself macOS-only — so on iOS nothing speaks through `.shared`. It becomes a hole the
   day an iOS surface does. Not a defect I can assert from my files, and not in my ownership.
3. **Two stale doc references to the renamed type, in files I do not own:**
   `Services/TTS/SpeechPlayer.swift:244` ("see `ChatPlaybackSession`") and
   `Services/TTS/SpeechChunkQueue.swift:49` ("iOS `ChatPlaybackSession`"). Both are comments — no build
   impact — and both should read `SpokenAudioSession`. I left them rather than edit foreign files.
4. **Founder QA — additions to the audio list, all needing real audio and/or a real car.** (a) On
   **iPhone**, start a desk voice note playing, then tap the composer mic: the note must STOP and the
   card must return to its idle transport — not keep showing a running clock over silence. (b) On
   **iPhone**, start a chat read-aloud, then tap a desk voice note: the reply must stop, not overlap; and
   the reverse — start a note, then tap Speak on a bubble. (c) On **iPad in split view**, speak a bubble
   in one column and then in the other: only the second may be audible. (d) Connect **CarPlay**, start a
   car voice session, and tap a desk voice note on the phone: the card must refuse with "Audio is in use
   right now" and the car's leg must be untouched (this is the one assertion no headless test can make —
   `CarPlayRecordingService.anySessionActive` is only ever written by a real connection). (e) Pause a
   voice note and confirm other apps' music un-ducks, then resume and confirm it ducks again — the
   session posture is now shared with chat read-aloud, so this exercises both.
5. **Nobody re-add a second copy of the session posture.** `.playback` / `.spokenAudio` / `[.duckOthers]`
   and `.notifyOthersOnDeactivation` exist once, in `SpokenAudioSession`. A third spoken-audio surface
   should call it and keep its own activation policy, not paste the four lines again.

## Refuted

**None.** The finding and both adjudications held against the current code, traced by call path before
any edit.

## Guard verdicts

**None.** I converted, kept and deleted no source-text guard: every case I added is behavioural, and the
five source-text guards that failed in my runs (`WorkboardVoiceLaneTests`) belong to another agent's
files and were left exactly as they are.
