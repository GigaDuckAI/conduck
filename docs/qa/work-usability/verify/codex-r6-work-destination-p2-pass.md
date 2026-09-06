# Codex round 6 — work-destination R5 spot-check

Scope: the seven round-5 findings only (`codex-r5-work-destination-closeout.md`), judged against the uncommitted diff since baseline `8ed1e9c`. Static review; no builds, no tests, no file modifications. Regressions counted only where this diff introduces them. P1 = data loss, a private note reaching a gateway, a desk item becoming a gateway turn, a stuck microphone, a crash. P2 = a false receipt or a broken/withheld retry.

| Finding | Verdict | Evidence |
|---|---|---|
| **R5-1** | **Closed** | Refresh restores Retry independently of the newest entry's historical error code. Diagnostics and the existing handling of live terminal failures remain intact. |
| **R5-2** | **Closed** | The final ownership refusal no longer preserves the capture or recreates its retired queue entry. The added test exercises that refusal through the recorder and checks that no second save occurs. |
| **R5-3** | **Not closed — P3, test coverage only; production fixed** | The busy-message assertion at `MenuBarWorkCaptureStateTests.swift:327` searches the entire sheet, so removing the new stopped-state message still satisfies it through the existing `.error` message at `WorkboardVoiceCaptureView.swift:231`. Scenario: cancel transcription, claim the recording through menu-bar Retry, press the sheet's Try Again — that mutation refuses silently without failing the assertion. |
| **R5-4** | **Closed** | The stopped receipt follows `workCaptureFacts.recordingOnDesk`; confirmed deletion selects the separate no-card sentence. Recovery stays confined to Work. |
| **R5-5** | **Closed** | Extraction ends at the phase-two switch's matching brace, and both refusal arms must end with `return`. Removing the retryable arm's return can no longer borrow a later catch-arm return. |
| **R5-6** | **Closed** | The typed CarPlay refusal occurs after permission returns and before recorder construction. Caller mappings and both session-protection halves remain intact. |
| **R5-7** | **Not closed — P3 residual** | At `ContentView.swift:1288`, consumption clears the flag before awaiting the count. Scenario: finish retry A; that read snapshots zero; CarPlay queues B before the awaiting caller resumes. `isRetrying` is still true, so B's notification sets the flag again — the stale zero hides the card and the run exits without consuming the newly set flag. B stays undiscovered until another refresh. The added presence assertions do not constrain this interleaving. |

No Nobody-undo rule in `u47-work-destination-lanes.md` is broken by the diff, and no regression against the behaviour standing at `8ed1e9c` was established.

## Result

Clean — nothing P1 or P2 remains across R5-1..R5-7. The two open items (R5-3 test-coverage residual, R5-7 interleaving residual) are P3.
