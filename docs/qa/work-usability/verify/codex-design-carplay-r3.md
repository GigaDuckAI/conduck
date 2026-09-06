Reviewed `a197ccd`, read-only. No simulator or rendered verification.

1. **P1 — The serial closes the original two-start race, but backgrounding leaves a start armed.**  
   A second tap during preflight/presentation is rejected; ordinary refusal, nil-controller and reported presentation failure release correctly; disconnected preflight cannot begin or release a newer claim; a chooser selection landing during a claim is rejected.

   However, [CarPlaySceneDelegate.swift:205](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:205) only clears the presentation flag. [setSceneActive:548](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:548) ends **active sessions**, whereas preflight is idle/inactive. Its claim survives, and `startIsLive` lacks scene activity. It can begin over Maps or after foreground reconciliation has dismissed its modal. A permission refusal blocks continuation only while `.permissionBlocked` remains current.

   **Fix:** Invalidate the claim synchronously on resign/permission refusal; require an active scene when claiming and continuing. Foregrounding must not revive the old start.

2. **P1 — Presentation ownership remains unspecified and unsafe.**  
   [CarPlaySceneDelegate.swift:503](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:503) still treats *presenting* as *presented*. The new Bool does not resolve an unclaimed `applyState` presentation in flight. Foreground dismissal followed by a late successful present completion can likewise pass `startIsLive` without a usable modal.

   Across reconnect, an old failure still resets the **new** `isVoicePresented` flag ([539](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:539)); an old success rejected by `startIsLive` unconditionally dismisses the **new** controller. An old dismiss completion deactivates the **current** service ([583](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:583)). Serial-safe release does not protect these effects.

   **Fix:** Bind presentation/dismissal transactions to controller, service and generation; distinguish pending/completed/dismissing presentation. Stale callbacks must not mutate current UI/audio. Replacement-connect must also invalidate old observation callbacks. Put the nil-controller refusal before any fast path.

3. **P2 — Refresh gates are incomplete, and aborted starts can lose a needed repaint.**  
   The concrete `updateSections` guards lack the promised service/template identity checks. Nav-button mutations at [751 and 778](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:751) happen before those guards. The refresh defer also unconditionally clears shared flags ([699](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:699)), including after reconnect.

   **Repaint answer:** The blocked-permission row remains synchronous and ungated ([677](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:677)). A fresh mic-failure hint normally runs after `begin…` returns and releases the claim, so that path is safe. But foreground/permission-restoration refreshes can finish during a claim, lose their trailing pass, then receive **no replacement refresh when presentation fails**. An older async refresh can also overwrite permission UI after release because it never rechecks permission.

   **Fix:** Gate every template mutation and refresh bookkeeping by originating service/template; recheck permission; retain a dirty refresh through startup and drain it after refusal or session end. Deferring the adopt title is acceptable behind the modal, but the proposed gates currently leave its immediate nav repaint untouched.

4. **P2 — §6 still contains vacuous and brittle predicates.**  
   `isLive` needs a positive live case: constant `false` passes every listed assertion. The source test does not prove conditional `releaseStart`, refusal-defer coverage, or helper wiring. “At least three” checks cannot establish placement: `startSession` has **four lexical awaits**, including separate fetch and snapshot awaits ([364](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:364)). Token counts and “somewhere before” checks can pass guards on the wrong branch.

   **Fix:** Assert each actual continuation/terminal block and independently mutate its protection. Scope `didConnect` by its signature: the helper matches function names, not argument labels. Normalize whitespace for call/array predicates. Allow the decision-2 regression guard to pass at baseline—it already does—rather than requiring every new guard to be red.

5. **P2 — A correct P2-E implementation fails an existing assertion.**  
   [CarPlayWorkNoteTests.swift:295](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/CarPlayWorkNoteTests.swift:295) requires ownership before the **first** `isCurrentListen`. Inserting the specified parking/check sequence reverses that ordering; confirmed by an in-memory substitution.

   **Fix:** Explicitly replace that assertion with separate post-parking, ownership-refusal and ownership-success checks. Also **add** Chat expiry controls to the screenshot cases: their current fixtures are `.work`, not Chat ([1615](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkboardVoiceScreenshotLaneTests.swift:1615)). QA 77a must restore the STT key before expecting Retry to succeed.

6. **PASS — P2-E’s order and ignored result are acceptable.**  
   Park → current listen → ownership → current listen → attach is correct. [PendingRetryGuard.swift:241](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/PendingRetryGuard.swift:241) deliberately permits an unpreserved capture; the subsequent ownership check rejects takeover. A parking write failure need not prohibit a valid attachment.

   **Qualification/fix:** Parking is best-effort. The store also returns false on persistence failure ([970](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/PendingRetryStore.swift:970)), so replace “the three armed exits now leave the words” with “leave the words when parking succeeded.”

7. **P3 — §7 arithmetic is correct; one adjacent retention statement remains stale.**  
   **16,897 + 28 − 16 − 5 − 5 − 3 − 4 = 16,892.** The cuts lose no load-bearing fact; the replacement retention rule preserves the Work protection. However, [spec.md:491](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/docs/ai-context/spec.md:491) still ends by tying headless/CarPlay retention to the retry notice. Remove or qualify that clause for P2-D, and avoid presenting confirmed discard as the only possible removal.

8. **P2, override-only — §9 still leaves an implementer a startup decision.**  
   Its Work row checks before popping but claims **after** the pop, ignores pop success, and specifies no originating-service validation ([design:188](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/design/carplay-work-destination.md:188)).  
   **Fix:** Claim before pop; require success and current ownership afterward; pass the existing serial into the Work starter without reclaiming it. This does not reopen decision 1, but §9 is not yet a ready override.

1. **DISAGREE** — Root-only remains a recorded founder-shape disagreement.
2. **AGREE** — Work must never become a sticky gateway override.
3. **AGREE** — Two-gateway threshold fits the selected AI-only chooser.
4. **AGREE** — Preserve gateway-only types and repair.
5. **AGREE** — Put the working day-one action first.
6. **AGREE** — Names are consistent.
7. **AGREE** — Remove Work’s Mute; render Chat → Work → Chat.
8. **DISAGREE as specified** — Serial ownership works; lifecycle/presentation ownership remains incomplete.
9. **AGREE** — Hint names the accepted startup destination.
10. **AGREE** — Revised parking/ownership order is sound, with best-effort wording.
11. **AGREE** — Retention policy is sound; correct the controls and prose.
12. **DISAGREE** — Modal-over-root stays; lifecycle machinery cannot remain unchanged.
13. **DISAGREE** — Existing U-51 founder call; no new argument.
14. **AGREE** — Post-settle `.chat` guard closes the identified Work re-arm path.

**Verdict: `change_required`; the design is not yet implementation-ready.**

