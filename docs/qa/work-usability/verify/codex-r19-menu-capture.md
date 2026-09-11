Read round 18 fully, `git status --short`, `git diff HEAD`, and the eight untracked files. No edits, builds, or tests run.

**Round-18 status**

| Item | Status | File:line evidence |
|---|---|---|
| NEW 1: Work error blocks Chat mouse-stop | **CLOSED** | Live Chat bypasses the Work arm and reaches stop: [MenuBarController.swift:175](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/MenuBarController.swift:175). |
| NEW 2: dismissed Work debt inaccessible | **CLOSED** | Idle recovery is permitted at [DictationService.swift:238](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/DictationService.swift:238), with its gated control at [DictationPopoverView.swift:1630](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/DictationPopoverView.swift:1630). |
| NEW 3: retirement leaves stale count | **CLOSED** | Successful clear alone posts, outside the lock: [PendingRetryStore.swift:935](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/PendingRetryStore.swift:935). |
| NEW 4: refresh-observed absence reversed | **CLOSED** | Absence latches at [InAppAudioRecorder.swift:1060](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:1060); publication asserts presence inside its success arm at [1249](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:1249). |
| NEW 5: whole-desk emptiness claim | **CLOSED** | Capture-scoped key and wording: [DictationPopoverView.swift:1088](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/DictationPopoverView.swift:1088). |
| Docs 1: acceptance equated with retirement | **STILL OPEN** | Corrected paragraph at [fixnote:735](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/fixnotes/u40-capture-to-work.md:735), but the prohibited broad rule remains verbatim at [850](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/fixnotes/u40-capture-to-work.md:850). |
| Docs 2: facts count / queued means arriving | **STILL OPEN** | Six stored facts plus computed value are correct at [fixnote:322](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/fixnotes/u40-capture-to-work.md:322); raw queued still means “on its way” at [398](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/fixnotes/u40-capture-to-work.md:398). |
| Docs 3: manual check 99 / coordinator comment | **CLOSED** | Corrected matrix at [handoff.md:294](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/handoff.md:294), corrected disposal comment at [MenuBarCoordinator.swift:1957](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:1957). |

1. **NEW — Chat queue recovery can send another composition’s screenshot.**  
   **(a) P2. (b) PRE-EXISTING at HEAD; idle recovery adds another entry. (c) Ordinary sequential use; no race required.**  
   Park failed Chat recording A, switch to Text, drag screenshot B for a new question without submitting it, then Retry A. Text capture stages B without changing dictation state ([MenuBarController.swift:336](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/MenuBarController.swift:336)). Recovery hands A’s words to `onTranscript` ([DictationService.swift:433](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/DictationService.swift:433)); the send reads B from the live image slot ([MenuBarCoordinator.swift:2502](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:2502)) and clears it afterward. HEAD already does this from `.error`; the new idle route does too.  
   **Smallest fix:** pass capture-owned attachments into recovery and preserve any separate staged composition.

2. **NEW — An unexpected recording failure bypasses screenshot recovery.**  
   **(a) P2. (b) INTRODUCED for the new Work screenshot lane. (c) Ordinary capture encountering a recorder failure; no adversarial timing required.**  
   A failed audio delegate callback invokes `onRecordingFailed` ([AudioRecorder.swift:202](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/AudioRecorder.swift:202)). Its owner only sets `.error(.audioMissingData)` ([InAppAudioRecorder.swift:612](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:612)), leaving the screenshot staged without a pending capture. Stop then refuses because recording has ended, and Try Again has no capture to finish. The new empty-audio handling at [1136](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:1136) is never reached.  
   **Smallest fix:** route unexpected Work recording failure through the existing empty-audio screenshot finalization path.

3. **NEW — The fixnote still instructs the opposite of the presence fix.**  
   **(a) P3. (b) INTRODUCED documentation inconsistency. (c) Documentation-only.**  
   [Fixnote:346](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/fixnotes/u40-capture-to-work.md:346) explicitly places `recordingOnDesk` below phase one, outside its success arm—the behavior round 18 just removed.  
   **Smallest fix:** replace that sentence with “Successful publication asserts presence; resumed captures preserve existing facts until a lookup answers.”

**Docs:** Remove the surviving contradictory rules for Docs 1–2. The round-18 handoff paragraph accurately describes the five code fixes, but documentation closure remains incomplete. Catalog arithmetic is confirmed: **19 added / 3 retired / 2,323 total**.

**Clean:** ordinary drag/skip/cancel flow; Work recovery stays on the desk; claim-before-send prevents duplicate recovery sends; retirement refresh; startup recount and weak notification callback; Work HUD suppresses footer; footer does not hide start hints; diff whitespace.

