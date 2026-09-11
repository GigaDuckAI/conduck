**Not clean: four P3 findings; no confirmed P1/P2. r3-f1 is correct; r3-f3 is only partially complete.**

1. **P3 — Small-card budget still exceeds narrower grid units.** [WorkboardCaptureCanvas.swift:1672](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1672)
   The compact layout requires **76 pt**. The engine grants **71 pt at width 320**, and **64 pt at width 292**. The [test:109](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkboardCompanionCardTests.swift:109) checks only width 360. Its negative control compares arithmetic constants: disabling the compact view branch leaves its assertions passing, despite restoring an overflowing body. Adapt the budget to the granted unit and cover the actual layout branch. **Arithmetic shortfall confirmed; visual clipping not reproduced.**

2. **P3 — Small-card QA requires text deliberately omitted by the fix.** [handoff.md:436](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/handoff.md:436)
   Step 139 requires the recording’s name on the Small band. The `.compact` branch draws only transport; the visible row names the screenshot. Update the expected result.

3. **P3 — VoiceOver QA uses the wrong blocked-state trigger.** [handoff.md:440](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/handoff.md:440)
   Playing another desk recording stops the previous clip and takes ownership; it does not produce `.blocked`. That state requires a live capture. The prescribed scenario therefore cannot verify the new refusal value.

4. **P3 — Fixnote overstates shared status-helper adoption.** [u71-companion-card.md:176](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/fixnotes/u71-companion-card.md:176)
   `statusLabel(for:)` serves the folded tile and List row. The standalone audio card still uses its own switch at [WorkboardAudioCardView.swift:1425](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/WorkboardAudioCardView.swift:1425). Its wording currently matches; the documentation’s implementation claim does not.

The other checks support the fixes:

- **r3-f1:** both tile branches expose availability, playback phase and loaded clock. Labels/actions remain coherent. Exact failed/blocked assertions and the two-branch source guard detect the original omissions.
- **Transport ownership:** output arbiter, exclusivity registry and player implementations are byte-identical to `311b07f`; lazy loading and cleanup remain intact.
- **Standard/large:** both retain two-unit height (`2 × unit + 12`); no new defect attributable to these fixes was confirmed.
- **Five documentation claims checked:** the three mismatches above, plus the correctly updated model-17 release gate and the correct **76-in-81 pt calculation specifically at width 360**.

Validation used source comparison, in-memory arithmetic/mutation checks and scoped diff checking. **XCTest, rendered layout and live VoiceOver were not rerun. No files changed.**
