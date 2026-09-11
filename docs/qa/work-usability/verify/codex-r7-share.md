A successful local reattach rewrites **every known duplicate** with replacement bytes and `Date()`: secondary keys choose the physical row, but it serves the replacement. A backward revision still fails the share gate’s equality check; owner CAS uses a separate `WorkItem` timestamp. [ConversationStore+Workboard.swift:2136](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/ConversationStore+Workboard.swift:2136)

A peer import updating only one duplicate **can be worse than before**. With `now=100`, prior `A=90/B=160`, rollback produces approximately `A=160.001/B=160.002`. If a corrected-clock peer update imports `B=101`, stale **A wins**. Previously, restoring `A=90/B=160` followed by that import selected **B=101**. The edit gives the previously unfuturistic loser a future stamp. That switch changes revision, so sharing refuses an earlier preparation; exact timestamp ties are a separate weakness.

1. **Confirmed for any duplicate count with a defined prior winner.** Descending stamps preserve index zero under both selectors, now at [ConversationStore+Workboard.swift:3081](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/ConversationStore+Workboard.swift:3081) and [:3160](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/ConversationStore+Workboard.swift:3160). A complete pre-existing tuple tie has no guaranteed winner.

2. **Confirmed.** With the default step, the last stamp clears the prior maximum by at least 1 ms; all others are higher. The payload-bearing metadata is restored verbatim. [ConversationStore+Workboard.swift:2452](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/ConversationStore+Workboard.swift:2452)

3. **Confirmed: exactly one builder.** `workMaterialRows` → order-preserving `map` → `WorkMaterialReattachSwap`, at lines 2136, 2155 and 2217. The contract is documented at 2319. [ConversationStore+Workboard.swift:2155](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/ConversationStore+Workboard.swift:2155)

4. **Refuted as a global guarantee.** Nothing reserves these timestamps against peers. A winning peer update with the same timestamp, kind and readable availability passes the share gate despite changed bytes. That collision weakness and material-before-owner import gap predate this edit; owner CAS does not compare material revisions. [WorkMaterialShareCoordinator.swift:329](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/WorkMaterialShareCoordinator.swift:329)

5. **Confirmed.** The test constructs distinct 31-byte and 36-byte blobs, then asserts preserved winner/payload and changed revisions/share refusal. [WorkMaterialShareTests.swift:1226](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkMaterialShareTests.swift:1226)

**STILL OPEN overall; A’s immediate ordering defect is fixed.** Smallest fix for the new regression: preserve order while advancing each row beyond **its own** prior stamp, rather than forcing every row above the global maximum; add the partial-peer-update case.

Regression from this edit only: promotion of losing duplicates can suppress a subsequently imported legitimate winner update.

Clean: payload restoration and builder ordering check out; read-only source review, no builds or tests run.

