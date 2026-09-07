The diff implements the planned destination-row redesign. I found **five P3 issues and no demonstrated P1/P2 regression introduced by this diff**. The gateway/Work inbox separation holds in the inspected code. Runtime behavior remains unverified.

## Findings

**S-R1-1 — P3 — Search hides the selected gateway without disabling its commit.**  
Files: [iOS ShareView.swift:828](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckShareExtension/ShareView.swift:828), [Mac ShareView.swift:878](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckShareExtensionMac/ShareView.swift:878).

With more than eight targets, select gateway A, then enter a query matching nothing. The selected row disappears; the screen shows “No matches” and an unselected Work row. **Send now remains enabled, and Cmd-Return still sends to A.** The displayed list no longer identifies the outstanding selection. This behavior survives the redesign and defeats the requested visible-selection/stale-keyboard check.

**Smallest fix:** derive whether the selected target remains in the displayed results; when absent, show the neutral button label and refuse both button and keyboard commits. This requires no automatic destination assignment.

**S-R1-2 — P3 — The selectable legacy “New conversation” row can continue an existing conversation.**  
Files: [iOS ShareView.swift:637](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckShareExtension/ShareView.swift:637), [Mac ShareView.swift:676](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckShareExtensionMac/ShareView.swift:676), [SharedInboxRouting.swift:193](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/RemoteAgent/SharedInboxRouting.swift:193).

Make the snapshot unavailable while the app has a live continuation pointer on its default gateway. Select **New conversation** and send. The all-nil routing fields enter the legacy resolver, which returns the existing conversation. No new conversation is created. The underlying behavior predates this diff, but the newly selectable row explicitly offers something it cannot guarantee.

**Smallest fix:** give this fallback its own honest label, such as “Continue or start a conversation,” in both catalogs. Also qualify [handoff.md:399](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/handoff.md:399): a fresh install without a configured gateway cannot satisfy its promised successful delivery.

**S-R1-3 — P3 — The inbox-binding guard accepts a Work helper that also sends.**  
File: [WorkCaptureInboxTests.swift:511](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkCaptureInboxTests.swift:511).

Mutate each real ShareView by adding this immediately after its Work callback:

```swift
onSend(caption, .newConversation(gatewayRef: nil), includePageText)
```

The predicate still returns `[]`: it checks that the expected callback exists, but never rejects the opposite callback. That mutation would allow a Work commit to reach both writers. **The shipped helper does not contain this leak; its purported guard misses it.**

**Smallest fix:** reject `onSend(` in the Work helper and `onAddToWorkboard(` in the send helper; add both mutations as negative controls.

**S-R1-4 — P3 — The disabled-button guard does not check the disabling condition.**  
File: [WorkCaptureInboxTests.swift:526](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkCaptureInboxTests.swift:526).

Change the real primary-button expression from `destination == nil || …` to `destination == nil && …`. The predicate still returns `[]`, although the button becomes enabled with no selection and during an existing submission. The helpers prevent a second publication, but the promised disabled-button behavior is broken.

**Smallest fix:** assert the complete normalized condition separately for iOS and Mac, and add this one-token mutation as a negative control.

**S-R1-5 — P3 — The lifecycle guard reports executable behavior from comments.**  
File: [WorkCaptureInboxTests.swift:486](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkCaptureInboxTests.swift:486).

The actual tip fails rule (c) because its `onAppear` comment says “Send always has a **destination**”; its executable assignment names `selection`. Likewise, adding a harmless comment containing “destination” inside a current `.task` makes rule (c) fail.

**Smallest fix:** exclude comments from lifecycle-body inspection and add a comment-only control that must remain green.

## (1) Design and founder-ask verification

I checked decisions 1–11 and the file, catalog, documentation and test change lists.

| Decisions | Result |
|---|---|
| 1, 2, 6 | Work is last, in its own pinned-header section, outside every search/roster branch. The segmented picker and summary panel are removed. |
| 3, 4 | Optional destination starts nil; `ShareDestination` wraps the unchanged gateway-only `ShareTarget`; `commit()` dispatches through the appropriate helper. |
| 5 | Both visibility truth tables match the design. The legacy route’s conversation semantics have the S-R1-2 qualification. |
| 7 | iOS uses “Where to?”; Mac gains no title. |
| 8 | Work-only retry, submission lock, caption, capture toggle and progress behavior are preserved. |
| 9 | Both copies receive the same destination logic; platform differences remain accounted for. |
| 10 | No new provider load, payload decoder or persistent destination storage is introduced. |
| 11 | Both controllers and `ShareTargetsSnapshotWriter` change comments only. Both drainers are unchanged. |

The mandatory removal of `sendCircle`, `SendButtonStyle` and `Strings.send` is complete. The required accessibility traits remain.

The folder-map edit is present-tense. The handoff gains the decision and twelve QA steps. `spec.md`, README and the U-47 fixnote are unchanged. The requested tests are present, subject to S-R1-3–5.

**Not checked:** compilation, rendered layout, pinned-header behavior or accessibility announcements.

## (2) Attempts to refute “no regression”

| Path | Source-traced outcome |
|---|---|
| Named gateway | Its exact ref reaches `newConversationGatewayRef`; no default substitution. |
| Collapsed single-gateway row | Carries the sole gateway’s explicit ref, not nil. |
| Recent conversation | Carries conversation ID and backend hint. A deleted conversation can mint on that same gateway; an unavailable explicit gateway fails instead of switching gateways. |
| Default route | All-nil refs use the existing continuation/default resolver; see S-R1-2. |
| Decoded empty roster | No send row; “No personal AI available.” plus selectable Work. |
| Missing/unreadable/malformed snapshot | All produce nil and the selectable legacy row. They do not select it automatically. |
| Safari page/selection | Existing memoized capture, carrier exclusion, markdown generation and toggle-independent URL recovery are unchanged. |
| Mac non-Safari URL fallback | Existing URL-echo rejection and selection-text fallback are unchanged. |
| Attachment limits | Mac rejects more than ten providers in the UI and host helpers. iOS retains its activation predicate and defensive provider prefix. |

**Preserved failure limitations:** a thrown provider/write failure on Send cleans staging and dismisses without a failure alert. Mac security-scoped copy failures can return nil and omit an item while other material publishes. Work propagates thrown failures and discards staging, but cannot detect a failure already swallowed by its loader. These are existing failure-path limitations within the design’s deferred U-16 scope; the comment-only controller edits do not fix them.

**Memory:** no new attachment bytes are loaded or retained by the redesign. Existing snapshot decoding, bounded 128-pixel thumbnail generation and browser-text processing remain. Thus “decodes nothing” is not literally a description of every existing operation; the relevant verified property is **no newly introduced payload decoding**.

**Mirrors:** I compared every paired file. JavaScript remains fully byte-identical. Filter, web-capture helper, snapshot, manifest, envelope and publisher bodies match below their headers; all four app/extension contract triplets match. Remaining view/controller/configuration differences concern platform behavior. The mirror tests compare from `import Foundation`; the JavaScript test compares whole files. `check-legal-copies.sh` checks only the three bundled legal documents, and passed.

**Drainers:** neither changed. Send and Work publish under separate roots. Both use `manifest.json`, but their mandatory identity keys differ (`uuid` versus `id`), so an accidentally misplaced ordinary envelope would fail decoding rather than become the opposite lane’s input. `recentWorkItems` remains explicitly empty.

**Not checked:** real provider failures, storage exhaustion, extension termination, notification delivery or actual draining.

## (3) No silent rerouting

The inspected source contains exactly five destination assignments per platform:

- iOS: lines **535, 594, 605, 625, 641**.
- Mac: lines **574, 633, 644, 664, 680**.

All are row actions. No initializer, lifecycle hook, error dismissal or persistence mechanism assigns the destination.

`begin()` claims the submission phase synchronously. Rows disable while that phase exists. Retry calls the Work-only helper, and only `.unavailable` offers it. `commit()` rejects nil; Mac additionally rejects over-limit input. Plain Return in the Mac caption inserts a newline.

The primary button correctly identifies the **lane**. It does not identify a particular gateway, and S-R1-1 leaves a hidden selection actionable.

**Not proved:** the claim that every invocation is a fresh process. Source establishes per-view/per-controller state and no saved pick; repeated invocation and actual keyboard/alert event delivery require runtime QA.

## (4) Tests and negative controls

I replayed the predicate logic in Python against both real worktree sources and actual `git show a278c7b` sources. Swift XCTest was not executed.

| Input | Reported violations |
|---|---|
| Current source | None |
| Inserted `onAppear` assignment | Assignment prefix/count and lifecycle rules |
| Line-broken task assignment | Assignment prefix/count and lifecycle rules |
| State initializer | Rule (a) |
| Pick-reading retry | Rule (g) |
| Reconstructed tip shape | Rules (a), (d), (f) |
| Actual tip | Rules (a), (b-count), (c), (d), (f), (h) |

Whitespace normalization handles the promised line-break dodge, and five assignment sites is correct. The controls mutate real source. Actual-tip failures on **(a), (d), (f)** have the intended reasons; its additional **(c)** failure is the comment issue above.

Catalog assertions match the catalogs. Publisher source slices are unchanged and satisfy their existing source assertions. Both views remain registered as `.notErrorDriven`; the scratch guard still scans both extension targets.

**Not run:** the requested simulator suites, publisher runtime tests, routing/drainer tests or other Swift guards. Catalog format/duplicate checks, byte comparisons, legal-copy check and `git diff --check` passed.

## (5) Copy and catalogs

The share copy matches the shipped sibling vocabulary:

- **Add to Work** — row and commit.
- **Where to?** — iOS chooser, matching Watch.
- **No personal AI available.** — matching Watch.
- **Capture to Work…** — remains the Mac command.

Every one of the **34 `String(localized:)` calls in each ShareView** has a corresponding catalog entry with the matching English default. Each catalog has 40 keys; neither contains duplicate keys. Every specified retired key is absent from both ShareViews and both catalogs.

The sole iOS-only key is `share.destination.title`; the sole Mac-only key is `share.error.tooManyItems`. The shared storage-error sentence differs only by “device” versus “Mac.”

**Not checked:** runtime localization extraction, VoiceOver output or visual truncation.

Clean

