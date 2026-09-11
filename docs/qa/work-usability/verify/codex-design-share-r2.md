1. **P2 — The source predicate still overstates its guarantee.** [Design:198](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/design/share-work-destination.md:198) says pre-selection becomes impossible without editing the test. Adding this to an otherwise compliant view defeats that claim:

   ```swift
   .task {
       destination =
           .work
   }
   ```

   The declaration still satisfies (a); no line contains the literal `destination = ` required by (b); and (c) checks only `.onAppear`. Rules (d)–(h) remain satisfied. Both existing views already use `.task` to assign state ([iOS:301](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckShareExtension/ShareView.swift:301), [Mac:301](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckShareExtensionMac/ShareView.swift:301)). No non-row assignment is needed by the prescribed implementation, but the line rule is formatting-sensitive. **Add this negative control and describe the predicate as targeted regression checks; remove the “impossible” claim.**

The revised retry/row-lock pair closes the original reroute. I found no further mismatch in the permitted paths: the helpers synchronously claim the busy phase, so another ⌘-Return cannot start a commit ([iOS:120](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckShareExtension/ShareView.swift:120)); alert Cancel invokes cancellation ([iOS:321](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckShareExtension/ShareView.swift:321)); and the inspected host completes after writing without first clearing the busy phase ([host:459](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckShareExtension/ShareViewController.swift:459)). The Mac limit disables the primary action and guards `commit()`; with an immutable limit flag, an oversized invocation cannot first produce the Work failure needed to expose retry.

On taste, I support **nothing pre-selected**, **“Where to?”**, and **Work last in its own scrolling section**. They fit the accepted Watch decisions ([Watch design:32](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/design/watch-work-destination.md:32)). Pinning Work below the scroll should remain a response to founder QA showing poor discoverability, rather than the default.

**Verdict: accept with changes. No blocking implementation findings remain. Finding 1 requires correcting the claimed test guarantee.**