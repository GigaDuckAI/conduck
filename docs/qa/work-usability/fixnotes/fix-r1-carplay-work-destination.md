# fix-r1-carplay-work-destination — Codex findings on the CarPlay Work destination

Source: `docs/qa/work-usability/verify/codex-r1-carplay-work-destination.md` (10 findings).
Design: `docs/qa/work-usability/design/carplay-work-destination.md`.

| ID | Verdict |
|---|---|
| CP-R1-02 (P1) | **FIXED** — `CarPlayRecordingService.startConverseHop` |
| CP-R1-03 (P2) | **FIXED** — `CarPlaySceneDelegate` present + dismiss completions |
| CP-R1-04 (P2) | **FIXED** — `CarPlaySceneDelegate` End button + `templateDidDisappear` |
| CP-R1-06 (P2) | **FIXED** — `CarPlaySceneDelegate.observeConversations` |
| CP-R1-09 (P2) | **PARTLY FIXED** — the source guards for the four fixes above, plus the six named mutation holes inside CarPlay tests |
| CP-R1-01 (P1) | **SKIPPED** — out of ownership, and a shipped feature, not a defect (below) |
| CP-R1-05, 07, 08 (P2) | **FORWARDED** — recorder / relay / phone-desk ownership |
| CP-R1-10 (P3) | **FORWARDED** — `handoff.md` belongs to the docs pass |

Files touched: `Conduck/Conduck/CarPlay/CarPlayRecordingService.swift`,
`Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift`,
`Conduck/ConduckTests/CarPlayWorkNoteTests.swift`. **No catalog rows** — every fix is a
guard, and none of them adds a sentence anyone reads.

---

## CP-R1-02 — a hop suspended above the token mint dispatches after End · **FIXED**

`endSession` cancels `currentTurnToken`, and that property is still `0` for this turn until
`startConverseHop` mints it — far below nine suspensions (gateway resolution, the badge
roster, the conversation mint, the user-turn append, the file lane, history assembly). An End
or a switch to Maps anywhere above the mint therefore cancels **nothing**: the resumed hop
mints a fresh token and calls `uploadConverse`, so the transcript the driver abandoned leaves
anyway. And because the hop writes `sessionBoundRef`, `sessionConversationID` and
`currentTurnToken` unconditionally, a Work note started in the meantime has its session
fields overwritten and can be ended outright by the hop's error arm — a private note killed
by a chat's failure line.

**Fix:** the hop takes the listen id and re-asks `isCurrentListen(attemptID)` after every one
of those nine suspensions, and at the top of the catch-all before `speakErrorAndEnd`. This is
the mechanism the Work lane already keeps (`e-carplay.md` → "isCurrentListen after every
suspension"); it was simply never extended to the chat hop, which is what makes the Work
lane's own guarantee breakable from the outside. The two snapshot lookups are hoisted out of
their `guard let` so the staleness check sits BETWEEN the suspension and the refusal it
guards — a check placed after the `guard let` never runs on the refusing path, which is the
path that speaks and ends a session.

Below the mint nothing changes: the token is non-zero there, so `endSession`'s cancel reaches
the uploader and the existing `catch is CancellationError` arm answers, exactly as documented.

**Residual, deliberately not fixed here:** an End landing *inside* the `appendMessage` await
still leaves a user turn at `status: "sending"` (nothing flips it, because only the uploader
does). That is the same artefact the accepted End-at-the-uploader-boundary path produces and
it predates this diff; closing it means a store write on a dead session, which is worse.

## CP-R1-03 — a stale present/dismiss completion tears down the NEWER capture · **FIXED**

Connection identity is not presentation identity. Start A presents; a backgrounding clears
its claim; the driver returns and starts B on the same controller and service. A's delayed
present completion fails `startIsLive` — but its refusal arm dismissed on
`service === recordingService` alone, so it dismissed **B's** modal, and `templateDidDisappear`
then ended B and deleted its partial recording. The dismiss completion had the mirror of the
same hole: it freed the car audio route on controller identity alone, cutting a capture that
had re-presented underneath it.

**Fix:** one new chokepoint, `dismissModalLeftOverBy(refusedStart:)`, called by both starters'
refusal arms (after `releaseStart`, so a claim still standing is provably someone else's). It
dismisses only a modal that belongs to nobody: live service, **no claim held**, **no live
session**. The dismiss completion gets the matching pair — it deactivates only when the modal
is not presented again and no session is live.

## CP-R1-04 — End and a vanished modal did not cancel a start that had not begun · **FIXED**

Between `ensureVoicePresented` and its completion the voice template is interactive with no
session behind it. "End" called `endFromButton()`, whose `endSession` opens with
`guard sessionActive` and returned; `templateDidDisappear` returned at the same guard. The
claim survived both, and the completion — which asks only whether the claim is live — began
recording under a driver who had just cancelled.

**Fix:** `cancelPendingStart(for:)`, called from the End button **before** `endFromButton()`
and from `templateDidDisappear` **above** its `sessionActive` guard. It routes through
`releaseStart` (by serial), so a picker refresh retained under the claim still drains and a
stale connection's End cannot cancel the live one's claim.

## CP-R1-06 — the notification gate dropped refreshes instead of retaining them · **FIXED**

New in this diff. `observeConversations` returned on `pendingStart != nil` without setting
`pickerRefreshPending`, so with no refresh in flight the ask vanished: `releaseStart` found
nothing to drain and a refused start left the Recent list stale for the rest of the drive.
The mid-session arm is unchanged and still DROPS — the session's own teardown refreshes on the
way out.

## CP-R1-09 — the source guards admitted the mutations they claimed to prove · **PARTLY FIXED**

Every guard written for the four fixes above asserts a branch **and its exit**, and each was
run against the pre-fix source (red) and against the mutation Codex named (red). Six of the
named holes in the existing CarPlay guards are closed the same way: `startIsLive` must read
the STORED claim (`claimSerial: pendingStart?.serial`, killing the `claimSerial: serial`
bypass); `releaseStart` must release by serial; `ensureVoicePresented`'s two false answers are
asserted in their own brace-matched arms instead of counted across the function; the Work
note's Mute clear must be the *unconditional* statement after the claim; the no-gateway branch
may mention `firstSectionItems` exactly three times (a `reverse()` fails); and the hint's
destination ternary is pinned in full, so reversing the comparison fails.

**Not closed, and honestly out of reach here:** execution tests that drive competing CarPlay
starts, End during presentation and stale same-connection callbacks. `CarPlaySceneDelegate` is
a `CPTemplateApplicationSceneDelegate` whose starters need a live `CPInterfaceController`, and
the authoritative suite runs on an iOS Simulator with no CarPlay scene — which is why the pure
`CarPlayStartGate` was extracted in the first place. Making these behavioural would mean
protocol-ising the interface controller and the recording service across the whole scene; that
is a design change, not a fix, and belongs to the founder.

## CP-R1-01 — refuted as a defect, and out of ownership

`CaptureWorkboardIntent` declares `supportedModes: IntentModes = [.background]`
(`Conduck/Conduck/Intents/CaptureWorkboardIntent.swift:35`) and is titled "Add to Work" with
the description "Save a thought to your private Work desk without sending it to an AI." A
Shortcut a person wrote and ran is not an unattended trigger; requiring a foreground gesture
would delete the shipped Shortcuts feature (`b2-intents.md`). The product boundary the founder
stated is *"nothing on the desk ever becomes a gateway turn"* — which these paths keep. The
`no unattended trigger can reach Work` phrasing is the design doc's own, and it is the
phrasing that is wrong, not the intents. Files are the shortcuts lane's in any case.

---

## Nobody undo (adds to `e-carplay.md`, `fix-r1-carplay.md`, `fix-r2-carplay.md`)

- **`isCurrentListen(attemptID)` after every suspension in `startConverseHop`, and at the top
  of its catch-all.** Above the token mint `currentTurnToken` is `0`, so cancellation reaches
  nothing; these checks are the ONLY thing standing between an ended session and a dispatched
  transcript, and the only thing that stops a chat's error arm from ending a Work note.
- **The two snapshot lookups stay hoisted out of their `guard let`.** Folding them back puts
  the staleness check after the refusal it exists to guard, which is the same as not having it.
- **A refused start dismisses through `dismissModalLeftOverBy(refusedStart:)`, never
  `ensureVoiceDismissed` directly.** Connection identity is not presentation identity: the
  three conditions (live service, no claim, no session) are what keep a delayed completion
  from deleting a later capture's recording.
- **The dismiss completion checks `!isVoicePresented` and `sessionActive != true` before
  `deactivateAudioSession()`.** A dismiss overtaken by a new present owns neither the modal
  nor the radio.
- **`cancelPendingStart` runs BEFORE `endFromButton()` and ABOVE `templateDidDisappear`'s
  `sessionActive` guard.** Both of those return on exactly the case it covers, so ordering is
  the whole fix.
- **The notification path RETAINS under a claim and DROPS mid-session.** The two arms answer
  different questions — nothing else will repaint after a refused start; the session's own
  teardown already repaints on the way out.
