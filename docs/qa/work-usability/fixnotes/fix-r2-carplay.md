# fix-r2-carplay — Codex R2 findings on the CarPlay "Add to Work" lane

Source: `docs/qa/work-usability/verify/codex-r2-carplay.json` (round-1 re-verdicts + one new
finding, R1). R1 is **fixed**. Nothing refuted, nothing left open.

R2 re-closed S1 and S2 and re-opened S3 as R1: the round-1 fix rendered the hint in the
no-gateway picker, but nothing ever refreshes that picker on the failure it describes.

Files touched (ownership only):

| File | Why |
|---|---|
| `Conduck/Conduck/CarPlay/CarPlayRecordingService.swift` | R1 — one shared terminal for pre-`.recording` failures; the scene is told AFTER the teardown |
| `Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift` | R1 — the failure handler now runs the transition instead of only setting a flag |
| `Conduck/ConduckTests/CarPlayWorkNoteTests.swift` | one new case (21 → 22) |

**No catalog rows.** R1 needs no new copy: it makes the row added in round 1
(`carplay.hint.captureStartFailed.title` / `.detail.work`) actually reachable.
`Localizable.xcstrings` is untouched by this round.

---

## R1 — minor — initial microphone failures never trigger the hint or the modal dismissal · **FIXED**

### Verified, and it is worse than the report states

The report's mechanism is exactly right. `CarPlayRecordingService.State` is `Equatable` and
starts at `.idle`; `beginWorkNote()` (like `beginSession`) flips `sessionActive` and leaves
`state` alone; `state` becomes `.recording` only at the commit at the bottom of
`startListening`. Every failure BEFORE that commit ran `endSession(speak: nil)`, whose no-TTS
arm ends with `state = .idle` — an assignment of the value the property already holds. The
scene's only subscription is `withObservationTracking { _ = service.state }`, and the
`@Observable` macro publishes nothing for an equal assignment, so `applyState(.idle)` never
ran: no `ensureVoiceDismissed`, no `refreshPicker`, no hint.

What the report does not spell out, and what raises this above "no feedback": the modal that
stays up is **not dismissible from itself**. Its "End" button calls `endFromButton()` →
`endSession(speak:)`, which opens with `guard sessionActive else { return }` — and the silent
teardown already cleared that flag. So the driver is parked on a "Listening" screen over a dead
session, with the car audio session never deactivated (that deactivation lives in the
`dismissTemplate` completion) and the only exit being a scene background/foreground cycle.

This is a property of the lane, not of the gateway state: it fires on the Chat lane too, which
is why the round-1 hint was rarely seen at all. The Work lane simply made it easy to reach —
"Add to Work" is startable with nothing set up.

### What changed

**One terminal for every listen that fails before `.recording`** —
`CarPlayRecordingService.endSilentlyAfterCaptureStartFailure()`:

```swift
private func endSilentlyAfterCaptureStartFailure() {
    guard sessionActive else { return }
    let shouldNotifyScene = isSceneActive && (isVoiceModalPresented?() ?? true)
    endSession(speak: nil)
    if shouldNotifyScene { onCaptureStartFailed?() }
}
```

Three things about that shape:

- **The notification moved AFTER the teardown.** It is now the event the scene acts on, so it
  has to describe a session that is already torn down. Moving it costs the round-1 ordering
  nothing on the paths where `state` genuinely changes (a re-arm failing out of `.speaking`):
  observation is delivered on a main-actor hop, so the observer's own `refreshPicker` still
  runs after the flag is set. Both routes are idempotent against each other —
  `ensureVoiceDismissed` guards on `isVoicePresented`, and `refreshPicker` has its own
  in-flight latch.
- **The gate is computed BEFORE the teardown** and is verbatim the round-1 condition
  (`isSceneActive` + modal still presented). `endSession` dismisses nothing, so the reading is
  unchanged either side of it; computing it first keeps the semantics obviously identical.
- **`guard sessionActive`** — a start that lost its session mid-`await` (End, disconnect,
  backgrounding) must not accuse the microphone of the driver's own action, and that end owns
  its own scene transition already.

Four call sites, all inside `startListening`, all pre-`.recording`: audio-session activation
failure, capture-file creation failure, VAD detector start failure, engine-start retry
exhaustion. The report names the first and the last; the middle two are the same event with the
same stuck modal and were ending silently with no hint at all, so they route through the same
terminal rather than being left as two known holes with identical consequences. The
retry-exhaustion site keeps its explicit `if sessionActive` wrapper — that is the one site
where recovery can genuinely have raced us, and its comment says so.

**The scene handler is now the missing transition**, not a flag-setter
(`CarPlaySceneDelegate.didConnect`):

```swift
service.onCaptureStartFailed = { [weak self, weak service] in
    guard let self, let service else { return }
    self.oneShotStartFailureHint = true
    self.applyState(service.state, service: service)
}
```

`applyState` is the existing chokepoint and is deliberately reused whole: its `.idle` arm is
`ensureVoiceDismissed(animated:)` + `refreshPicker()`, which is precisely the transition the
equal assignment failed to deliver — the dismiss (whose completion frees the car audio session,
never before the modal is gone: g3) and the repaint that renders the hint. Setting the flag
first is load-bearing, or the refresh paints a picker without it. `weak service` because the
closure is stored on the service.

Nothing else moved: the ends stay silent (no TTS over a wedged session, no `CPAlertTemplate`
racing a dismiss), no wire string, no copy key, no envelope or model change.

### Test that pins it

`CarPlayWorkNoteTests.testASilentStartupFailureEndsTheSessionAndThenDrivesTheSceneItself` —
source guards in the neighbouring `RefusalLaneSource` style, on comment-stripped source:

- the terminal ends the session and only THEN notifies (`endSession(speak: nil)` before
  `onCaptureStartFailed?()`), and carries the `sessionActive` guard;
- `startListening` contains no bare `endSession(speak: nil)` and no bare
  `onCaptureStartFailed?()` — every pre-commit exit goes through the terminal — and exactly
  four calls to it;
- the scene's `onCaptureStartFailed` closure sets the hint flag and then calls `applyState(`,
  in that order;
- `applyState`'s body still contains both halves of the transition
  (`ensureVoiceDismissed(animated: animated)`, `refreshPicker()`), so the guard cannot be
  satisfied by a call into a chokepoint that stopped dismissing.

Against pre-fix source it is red three times over: the terminal does not exist (the body lookup
throws), `startListening` still ends sessions itself, and the handler contains no `applyState`.

### "Nobody undo" entries

Nothing in `fix-r1-carplay.md`'s Nobody-undo list is contradicted. Its S3 entry — the hint row
belongs in the no-gateway branch, with the `.detail.work` sentence — is preserved verbatim and
is what this fix makes reachable. S1's ownership gate and S2's compressed-file cleanup are
untouched (R2 closed both).

### Out of my ownership, forwarded

Cross-slice **R5** (`docs/qa/work-usability/handoff.md:106`) says the handoff restores the
"attachment is idempotent by capture ID, so no ownership re-check is needed" rationale that
`fix-r1-carplay.md` disproved. The disproof stands: `WorkVoiceCaptureCoordinator`'s
short-circuit requires EVERY row to already carry the same `textContent` AND `title`, so a
second delivery of DIFFERENT words is a full overwrite, and the ownership gate at the
attachment site is required. `handoff.md` is not in my ownership; flagged to the docs pass.

---

## Measured

| Run | Result |
|---|---|
| `build-for-testing` (iOS sim, scheme Conduck) | 0 errors (first attempt hit 4 errors in another fixer's in-flight `AddFilesToWorkIntent.swift`; retried after a wait, clean) |
| `CarPlayWorkNoteTests` + every `CarPlay*` class (8 classes) | **105 tests, 0 failures** — `CarPlayWorkNoteTests` 22 (was 21), `CarPlayVoiceTimingContractTests` 22 |
| `STTKeyBlackoutLaneTests` + `HeadlessRefusalLaneDriftGuardTests` (the other suites that scan these two files' source) | 16 tests, 0 failures |

Red-without-fix, checked by running the new case's predicates against `git show HEAD:` copies of
both files: terminal function **missing** (body lookup throws), `startListening` still contains
`endSession(speak: nil)` **and** `onCaptureStartFailed?()`, 0 calls to the terminal, and the
scene handler contains no `applyState(`. Post-fix: present / absent / absent / 4 / present.
