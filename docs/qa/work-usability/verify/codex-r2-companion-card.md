**P3 — Failed reorder does not restore the companion’s original rank.** [WorkboardViewModel.swift:1077](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/ViewModels/WorkboardViewModel.swift:1077)

- **Scenario:** Persisted order is recording `C=0`, unrelated card `N=1`, picture `P=2`, with C folded into P. Move P before N; both the reorder and corrective reload fail.
- **Wrong outcome:** Rollback restores displayed `[N, P]`, but recomputes ranks as `N=0, P=1, C=2`. The snapshot disagrees with persistence. I reproduced this using the exact reorder/rollback functions in a temporary Swift harness. No visible ordering failure or persisted data loss was confirmed.
- **Smallest fix:** Restore saved sequence values by ID for displayed cards and companions, preserving current presentation fields. Extend the rollback test with a child originally preceding its parent and assert both ranks; the existing fixture uses adjacent ranks and checks identities only.

No other confirmed findings. The round-1 self-link fix is complete in both resolvers.

Validation: **220 simulator tests passed**, macOS app/test bundle compilation passed, and all six repository source guards passed. Rendered layout and live VoiceOver interaction were not exercised. No worktree files were changed.
