**Two confirmed P3 findings; one plausible layout issue. Both prior fixes remain correct.**

1. **P3 — CONFIRMED: folded tiles omit recording state from VoiceOver.**
   [WorkboardCaptureCanvas.swift:1899](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1899)
   **Scenario:** Activate “Play Recording” through VoiceOver when decoding fails or another capture owns audio. The player becomes `.failed` or `.blocked`, but the entire companion band is accessibility-hidden. The exposed tile has no recording accessibility value, and both states offer “Play Recording” again without explaining the refusal. Standalone audio cards and List rows expose that explanation.
   **Smallest fix:** Add a companion accessibility value to both `tileControl` branches, using the recording’s availability, playback phase, and loaded clock.

2. **P3 — CONFIRMED: the release gate still names model 16.**
   [spec.md:430](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/ai-context/spec.md:430)
   **Scenario:** A maintainer follows the documented gate and verifies deployment of model 16. That satisfies the written instruction without verifying the new model-17 companion column. The brief’s stated gate update has not landed.
   **Smallest fix:** Change “Deploy model 16” to “Deploy model 17.”

3. **P3 — PLAUSIBLE: small folded tiles exceed their vertical budget.**
   [WorkboardCaptureCanvas.swift:1934](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1934)
   **Scenario:** At a 360-point board width, a small tile is 81 points tall. The companion band requires at least 38 points; the existing thumbnail and vertical padding already require another 48, before the screenshot’s name and spacing. This likely clips or obscures screenshot content, with additional pressure after the playback clock appears. **Not visually reproduced.**
   **Smallest fix:** Give small folded cards a compact layout that fits both components within the existing footprint.

The remaining review supports the implementation:

- **r1-f1 fixed:** both resolvers reject self-links before examining either candidate.
- **r2-f1 fixed:** rollback restores saved parent and matching companion sequences while retaining current card fields. I found no new defect introduced by `restoreMaterialOrder`.
- Fold eligibility, escape order, lowest-UUID selection, displayed-order expansion, relative/VoiceOver moves, and displayed-only position counts match the brief.
- Group deletion validates the supplied child, collects every distinct vault key, deletes both materials and blob lanes, and performs one revision update, save, and explicit notification.
- Companion Open/Share/Reattach routes retain the child’s identity; share revalidation remains member-specific. Player ownership, exclusivity, disappearance cleanup, and lazy loading remain intact.
- Retry metadata survives restatement, image discard, claim handoff, and legacy decoding. TTL logic is unchanged. Intent publication and escape recovery preserve the original picture identity.
- Model 16 is byte-identical to baseline. Model 17 adds exactly the optional UUID column. The migration test reopens the same SQLite stores with migration enabled.
- No additional Chat/Ask, CarPlay, or Watch regression was identified.

All six repository guard checks passed; three used in-memory temporary-data adaptations. Diff, model, and localization checks passed. **XCTest and visual/VoiceOver execution were not rerun**, so the reported 384-test result is not independently reconfirmed. No files were modified.
