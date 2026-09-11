# c3-watch-ui — Watch launchpad "Save to Work" + capture screen

Slice C3 of the Work usability wave. UI only: the wrist's second launchpad button, the
route it pushes, and the screen that renders the recorder + the one terminal line. The
relay, the queue and the phone-side write belong to `c2-watch-services`.

## What changed

| File | Symbol | What |
|---|---|---|
| `Conduck/ConduckWatch Watch App/Views/WatchNoteView.swift` | `WatchRoute.workCapture(nonce:)` | New route case + its `logLabel` (`"workCapture"`). Distinct case, distinct payload — no `WatchCaptureTarget`, so no equality/hash path can collapse a Work push into a chat capture. |
| ″ | `WatchNoteView.navigationDestination` | `.workCapture(nonce)` → `WatchWorkCaptureView(requestID:recordingService:)`. |
| ″ | `WatchNoteView.launchpadView` | Bordered `Label("Save to Work", systemImage: "tray.and.arrow.down.fill")` between the prominent Ask button (and its busy caption) and the Conversations link. Conversations' style family, Ask's `.disabled(isBusy && path.isEmpty)` rule, inside the `isWatchEnabled()` branch. |
| ″ | `WatchNoteView.beginWorkCapture()` | New. `refuseAskIfBusy()` → push `.workCapture(nonce)` → `startWorkCapture(requestID: nonce)`. Start at the PUSH SITE, synchronous with the busy check (the `pushNewCapture` pattern); the pushed view starts nothing. |
| **NEW** `Conduck/ConduckWatch Watch App/Views/WatchWorkCaptureView.swift` | `WatchWorkCaptureView` | The capture screen. Recorder states mirror the in-thread chat overlay (`.arming` spinner + "Starting…"; `.recording` ring + timer + "Tap to Stop" + the near-max warning; `.idle`/`.uploading`/`.waiting` → "Saving to Work…"; `.error` → the message). Terminal outcome replaces all of it. Own AOD branch (red dot + timer). Cancel-X while capturing (44 pt hit region, `cancelRecording()` then `dismiss()`), back button hidden only in that window; Done button on every end state. No gateway chooser, no retry affordance, no word for sending. |
| ″ | `WatchWorkCaptureCopy` | **Pure** outcome → copy/glyph/tint/log mapping (`nonisolated enum`), the testable half of the screen. |
| ″ | `WatchWorkRecordingTimer` (private) | Perf-isolated 10 Hz timer leaf, same reason as the chat overlay's own. |
| ″ | `WatchWorkCaptureView` Done button | Calls `recordingService.clearWorkCaptureOutcome()` before `dismiss()` — c2's own hand-off for "the line has been read". |
| `Conduck/ConduckWatchTests/ConduckWatchSmokeTests.swift` | `WatchWorkCaptureUITests` | Appended as a separate `// MARK: - Work capture UI` block at the end of the file — a NEW top-level class, so the c2 block appended after it cannot collide on a method name. |

`WatchAppShortcuts.swift` and the ControlWidget were not opened (Chat-only by decision).
No `.xcstrings` file was opened.

## New API

```swift
// WatchNoteView.swift
enum WatchRoute {                       // existing enum, one new case
    case workCapture(nonce: UUID)
}                                       // logLabel == "workCapture"

// Views/WatchWorkCaptureView.swift
struct WatchWorkCaptureView: View {
    let requestID: UUID
    @Bindable var recordingService: WatchRecordingService
}

nonisolated enum WatchWorkCaptureCopy {
    static func terminalLine(for outcome: WatchWorkCaptureOutcome) -> String
    static func symbolName(for outcome: WatchWorkCaptureOutcome) -> String
    static func isReassuring(_ outcome: WatchWorkCaptureOutcome) -> Bool
    static func logLabel(for outcome: WatchWorkCaptureOutcome) -> String
}
```

Nothing else. The c2 surface this consumes (`WatchCaptureDestination`,
`WatchWorkCaptureOutcome`, `WatchRecordingService.workCaptureOutcome` /
`startWorkCapture(requestID:)` / `clearWorkCaptureOutcome()`) is c2's, and landed
mid-slice exactly as contracted.

## New strings

**All eleven go in the WATCH catalog** (`ConduckWatch Watch App/Localizable.xcstrings`).

```
WATCH: watch.work.launchpad.save | Save to Work | Launchpad button that starts a private voice capture bound for the Work desk. It never reaches an AI.
WATCH: watch.work.capture.title | Save to Work | Navigation title of the wrist's Work capture screen.
WATCH: watch.work.capture.starting | Starting… | Shown while the microphone is arming for a Work capture.
WATCH: watch.work.capture.stop | Tap to Stop | Button that ends a Work voice capture and saves it.
WATCH: watch.work.capture.timeLeft | 1 min left | Warning shown as a Work recording nears its maximum length.
WATCH: watch.work.capture.saving | Saving to Work… | Shown while a finished Work capture is being handed to the iPhone.
WATCH: watch.work.capture.saved | Saved to Work. | Terminal line after a Work capture reached the Work desk.
WATCH: watch.work.capture.deferred | Saved on your watch. It reaches Work when your iPhone is nearby. | Terminal line when the iPhone was not reachable and the recording waits on the watch.
WATCH: watch.work.capture.savedWordsOnly | Saved the words to Work. Update Conduck on your iPhone to keep recordings. | Terminal line when the paired iPhone runs an older build that returned a transcript without keeping the recording.
WATCH: watch.work.capture.done | Done | Dismisses the wrist's Work capture screen after the capture ended.
WATCH: watch.work.capture.cancel | Cancel | Accessibility label for the control that discards a Work capture already in progress.
```

`watch.work.capture.timeLeft` / `.stop` / `.cancel` deliberately duplicate the chat capture
overlay's English ("1 min left", "Tap to Stop", "Cancel") as NEW keys rather than reusing its
bare-literal entries: those literals are their own keys, and a translator retuning the chat
overlay's wording must not silently retune a private-capture screen it never saw.

No unlocalized user-facing literal remains anywhere in this slice.

## Tests

`ConduckWatchTests/ConduckWatchSmokeTests.swift` → new `@MainActor final class WatchWorkCaptureUITests`
(`@MainActor` because `WatchRoute` lives in a SwiftUI file and its `Equatable`/`Hashable`
conformances are main-actor-isolated — comparing routes from a nonisolated test is a Swift 6
error, and it warned before the annotation).

| Test | Asserts |
|---|---|
| `testTheWorkCaptureRouteIsDistinctFromEveryChatCaptureRoute` | `.workCapture` ≠ `.capture(.new)`/`.capture(.existing)`/`.thread`/`.conversations`, and the three capture-ish routes hash to 3 distinct set members. |
| `testTwoWorkCapturePushesAreDistinctRouteValues` | Different nonces ⇒ different route values (remount per tap); same nonce ⇒ equal. |
| `testTheWorkCaptureRouteHasItsOwnLogLabel` | `"workCapture"`, and ≠ the chat capture label. |
| `testEveryTerminalOutcomeRendersItsOwnSentence` | The three durable outcomes render their exact sentences and no two share one. |
| `testARefusalRendersItsOwnReasonVerbatim` | `.refused(reason:)` passes through unflattened. |
| `testNoTerminalLineSpeaksOfSendingAnythingAnywhere` | No durable line contains send/sent/sending/dispatch/draft/brief/reply/agent (word-ish match). |
| `testOnlyARefusalReadsAsAFailure` | `isReassuring` true for saved/deferred/wordsOnly, false for refused. |
| `testTheOutcomeLogLabelCarriesTheKindAndNeverTheReason` | Kind-only labels; a refusal reason never becomes the label. |
| `testTheOutcomeGlyphsSeparateTheDeskFromTheWristAndTheRefusal` | Desk glyph for saved/wordsOnly only. |
| `testTheCaptureDestinationRawValuesAreFrozen` | `"chat"`/`"work"`, case-sensitive — they are persisted on the relay queue entry. |

**Measured**, final run against the tree with c2 landed: `xcodebuild test -scheme
ConduckWatchTests` (watchOS Simulator `28AC563B…`, no `-configuration`) — **Executed 252
tests, with 0 failures (0 unexpected)** in 9.5 s; `Test Suite 'WatchWorkCaptureUITests'
passed` with **Executed 10 tests, with 0 failures**. `grep -c ': error: '` = **0**, and zero
warnings in any file this slice touched. Baseline 232 → 252: +10 this class, +10 c2's own.
An earlier run of this slice ALONE (before c2 landed, against the compile stub) measured
242/0, which is the same +10. Logs: `~/Library/Caches/gigaduck-builds/work-c2b/watch3.log`.
Cache cleaned with `clean-build-cache.sh work-c2b`.

No iOS `build-for-testing` was run for this slice: every file it owns is watchOS-only, and
the `ConduckWatchTests` scheme compiles the Watch app itself.

The launchpad button ordering is NOT expressed as data (it is inline SwiftUI in
`launchpadView`), so the brief's optional ordering test has nothing to assert against;
turning three buttons into a table to test the order would be a worse launchpad. Order is a
founder-QA item instead.

## Requests

**The compile stub is gone and nothing is outstanding.** For the record, since it shaped the
work: at implementation time none of the four contract symbols existed anywhere in `Conduck/`,
so this slice was written against a temporary
`ConduckWatch Watch App/Services/WatchWorkCaptureContract.swift` restating them (deliberately
INERT — it armed no microphone and never called `startCapture`, because reusing the chat entry
point would aim a private Work thought at a gateway). c2 landed mid-slice and the stub was
removed; the final green run is against c2's real service, and every shape matched the
contract with no adaptation:

| Contract point | c2 shipped |
|---|---|
| `startWorkCapture(requestID:)` shape | `@discardableResult func … -> WatchCaptureStartOutcome`, non-throwing — the `startCapture(boundTo:requestID:)` mirror I coded to. |
| Refusals published, not thrown | Both the busy refusal and `canStartWorkCapture()`'s land in `workCaptureOutcome` as `.refused(reason:)`, which is what lets one surface render every terminal line. |
| Outcome cleared at start | `startWorkCapture` sets `workCaptureOutcome = nil` on the arming path (`WatchRecordingService.swift:764`). This was the one behavioural requirement the UI placed on the service, and it is met — the capture view reads the property directly, so a stale line could otherwise open a fresh screen on the previous capture's verdict. |
| `private(set)` on the two properties | Correct, and the view never writes them: it hands the read-line-back through c2's `clearWorkCaptureOutcome()`. |

Remaining, for the **copy agent only**: the eleven WATCH-catalog keys listed above.

## Nobody undo

- **The door is a per-press pick, never a mode.** *Superseded by `design/watch-work-destination.md`: the door is the Add to Work row in Ask's destination chooser, not a second launchpad button.* The rule that survives is the one that matters — no sticky destination toggle on Ask, ever. The failure direction is unrecoverable: a private thought reaching an AI because a switch was still flipped from last time. A chooser that opens on every press has no last destination to leave switched on.
- **`.workCapture` stays its own route case carrying no `WatchCaptureTarget`.** That is the structural reason `navigationDestination` can never build a chat thread for a Work push. Folding it into `.capture(target:)` with a destination field re-opens exactly that.
- **The terminal line has no Retry.** Every outcome except a refusal is already durable (on the desk, or on the wrist awaiting the iPhone); a retry button would ask the user to re-record something that is not lost, and would imply the capture failed.
- **`.deferredToPhone` must never render `"Saved to Work."`** They mean different things to the person reading them, and the cross-wire lies in the reassuring direction. `testEveryTerminalOutcomeRendersItsOwnSentence` is the guard.
- **The cancel-X keeps its 44 pt frame** and the back button stays hidden only while capturing — a swipe-back during a live capture would strand a running recorder off-screen.
- **No word for sending anywhere on this surface**, including a future "nothing was sent" reassurance: naming the thing the lane cannot do is the wrong reassurance on a private-capture screen. `testNoTerminalLineSpeaksOfSendingAnythingAnywhere` guards the lines it can see.

## Founder QA

Build the Watch app to the paired watch, Conduck enabled for Apple Watch in iPhone Settings.

1. **The launchpad reads right.** Raise the wrist on the Conduck root. Expect, top to bottom: the duck, the orange **Ask** button, a bordered **Save to Work** with a tray-with-down-arrow glyph, then **Conversations**. Save to Work is bordered (not orange) — if it is prominent, the launchpad has become a choice instead of an action. Lower the wrist: Always-On shows the dim duck + "Raise to ask" and NO buttons.
2. **Happy path, iPhone nearby.** Tap **Save to Work** → the screen pushes titled "Save to Work", briefly "Starting…", then the red ring + a running timer. Say a sentence. Tap **Tap to Stop** → "Saving to Work…" → **"Saved to Work."** with the tray glyph, a success haptic, and a **Done** button. Tap Done → back on the launchpad. Now open Conduck on the iPhone → the Work desk shows a new card within a few seconds, with the audio playable and the transcript on it.
3. **Ask still goes to Chat.** Tap **Ask** instead. It must behave exactly as before — gateway chooser when you have ≥2 gateways, a chat thread, a spoken/typed reply. Nothing about the Work button may have changed this. Check the iPhone desk afterwards: **no** new Work card from that turn.
4. **Deferred.** Put the iPhone in airplane mode (or walk out of range), then Save to Work and speak. Expect **"Saved on your watch. It reaches Work when your iPhone is nearby."** — NOT "Saved to Work." Bring the iPhone back / leave airplane mode with the watch app open or backgrounded → a local notification **"Saved to Work."** arrives and the card appears on the phone's desk. Failure case worth catching: if step 4 says "Saved to Work." while the phone is unreachable, the wrist is claiming durability it does not have — stop and report.
5. **Queue full.** Repeat step 4 until the relay queue is at capacity (several deferred captures with the iPhone still unreachable), then Save to Work once more. Expect a refusal line on the screen ("Work is waiting for your iPhone. Bring it nearby first."), a failure haptic, an orange warning triangle, and **Done**. Nothing recorded. Critically: the earlier deferred captures must still be there when the iPhone reconnects — a new capture must never evict an old one.
6. **Cancel discards.** Save to Work, start speaking, tap the **✕** at the top-left. It should return to the launchpad immediately and leave nothing behind: no card on the iPhone desk, no deferred notification later. Also confirm a left-edge swipe while the ring is live does NOT dismiss the screen (the ✕ is the only exit while the mic is hot).
7. **Busy interlock.** Start an **Ask** turn and, while it is still answering, go back to the launchpad. Both Ask and Save to Work must be greyed out with the "Still answering your last question." caption. Then start a Work capture and press the Action Button mid-recording — the Work capture must keep running and the press must be refused with a buzz, not hijack the mic.
8. **Master switch.** Turn Conduck off for Apple Watch in iPhone Settings. The launchpad shows only "Turned off for Apple Watch…" and Conversations — no Save to Work. (Open question 1 below: tell me if you want Work capture to survive this switch.)
9. **Small face / large text.** On a 41 mm watch with the largest Dynamic Type, re-run step 4 and confirm the long deferred sentence scrolls and the **Done** button is reachable by crown scroll.

## Open questions

1. **Should "Save to Work" survive the "Enable on Watch" master switch?** I gated it exactly like Ask (hidden when off), because the switch reads as "Conduck is turned off for Apple Watch" and a Work capture still needs the iPhone leg that switch governs. The argument the other way: a Work note reaches no AI, so a privacy-motivated switch-off arguably should not take away a private notepad. One-line change if the founder wants it ungated.
2. **`refuseAskIfBusy()` logs `"ask.refused"` for a Work refusal too.** Reused verbatim as the brief asked; the breadcrumb is therefore slightly mislabelled for the Work lane. Worth a `via:` field on that log, but it is c3-adjacent copy in a shared helper — left alone rather than edited under another agent's nose.
3. **`captureDestination` is not read by the UI.** The screen is destination-scoped by construction (its own route, its own button), so it never asks the service where the capture is going. A belt-and-braces guard — refuse to render the recorder while `captureDestination != .work` — is three lines, but it can also deadlock the screen on a timing difference, so I did not add it unasked. c2's own doc comment says the field is set by every entry point and never inferred, which is the stronger guarantee anyway.
