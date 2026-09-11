# f2-quicklook-lift — Quick Look coordinator lift (slice A3, preview)

## What changed

**NEW `Conduck/Conduck/Views/Components/FilePreviewCoordinator.swift`**
- `struct PreviewedFile { let url: URL; let reclaim: @MainActor () -> Void }` — a
  file on disk plus the closure that releases it. The coordinator never deletes
  anything itself, so it can never guess a parent directory by walking up from
  the URL it was handed; each lane keeps ownership of the unit it created.
- `enum FilePreviewReclaimPolicy { case onDismiss, onAgeSweep }` +
  `static var platformDefault` (`.onAgeSweep` on macOS, `.onDismiss` elsewhere).
  This is the SAME platform rule Chat had as `#if os(iOS)`, moved into a stored
  property so a test on one platform can exercise both halves.
- `@MainActor @Observable final class FilePreviewCoordinator` — lifted verbatim
  from `ConversationThreadView.swift:~3584`, with `AgentDownloadScratch.ScratchItem`
  replaced by `PreviewedFile` and the two `#if os(iOS)` blocks replaced by
  `reclaimPolicy == .onDismiss`. `previewURL`, `beginRequest()`, `isCurrent(_:)`,
  `present(_:token:)`, `handleDismiss()`, `cancelPendingPresentation()` keep their
  exact semantics, including the unconditional (platform-independent) reclaim of a
  file whose claim was superseded before it was ever shown.

**`Conduck/Conduck/Views/Conversation/ConversationThreadView.swift`**
- Removed the in-file `FilePreviewCoordinator` class (73 lines).
- Added Chat's adapter in its place:
  `extension PreviewedFile { init(scratchItem: AgentDownloadScratch.ScratchItem) }`,
  whose `reclaim` is the original `Task { await AgentDownloadScratch.shared.discard(item) }`.
- Two call sites now wrap: `InlineTextFileChip.presentPreview()` (`:~2980`) and
  `ServerFileDownloadChip.presentPreview(tempURL:token:)` (`:~3535`) call
  `filePreview.present(PreviewedFile(scratchItem: item), token: token)`.
- Untouched, as instructed: `@State private var filePreview = FilePreviewCoordinator()`
  (`:168`), `.quickLookPreview(activePreviewURL)` + the `onChange` dismissal bridge
  (`:277`), `activePreviewURL` (`:454`), `cancelPendingPresentation()` in
  `dismissTransientChatUI` (`:470`), and every `beginRequest`/`isCurrent` site.

**`Conduck/Conduck/Services/AgentDownloadScratch.swift` — NOT edited.** See "Sweeper
coverage" below: the prefix Work needs is already there.

## New API

```swift
struct PreviewedFile {
    let url: URL
    let reclaim: @MainActor () -> Void
    init(url: URL, reclaim: @MainActor @escaping () -> Void)   // memberwise
}

enum FilePreviewReclaimPolicy: Equatable {
    case onDismiss      // iOS
    case onAgeSweep     // macOS
    static var platformDefault: FilePreviewReclaimPolicy { get }
}

@MainActor @Observable
final class FilePreviewCoordinator {
    init(reclaimPolicy: FilePreviewReclaimPolicy = .platformDefault)
    var previewURL: URL?
    func beginRequest() -> UInt64
    func isCurrent(_ token: UInt64) -> Bool
    func present(_ file: PreviewedFile, token: UInt64)
    func handleDismiss()
    func cancelPendingPresentation()
}

// Chat-only adapter, defined in ConversationThreadView.swift:
extension PreviewedFile {
    init(scratchItem: AgentDownloadScratch.ScratchItem)
}
```

**How Work's slice plugs in** (`PersonalWorkbenchView.swift`, another agent):

```swift
@State private var filePreview = FilePreviewCoordinator()   // default = platform rule
...
let token = filePreview.beginRequest()          // at the tap, before the async load
// after `makePreviewCopy` returns `previewURL`:
guard filePreview.isCurrent(token) else { /* reclaim the copy, bail */ return }
filePreview.present(
    PreviewedFile(url: previewURL, reclaim: {
        Task.detached { try? FileManager.default.removeItem(
            at: previewURL.deletingLastPathComponent()) }   // the per-copy UUID dir
    }),
    token: token
)
```
plus, on the desk root, the same two modifiers Chat uses:
`.quickLookPreview($filePreview.previewURL)` and an
`.onChange(of: filePreview.previewURL) { old, new in if old != nil && new == nil { filePreview.handleDismiss() } }`.
Do NOT reclaim in the Work code path on macOS yourself — the coordinator's policy
already withholds it there.

## New strings

None. No user-facing copy added or reworded.

## Tests

New `Conduck/ConduckTests/FilePreviewCoordinatorTests.swift` (`@MainActor`, pure
logic, counting-closure ledger, no Quick Look UI, no file system): superseded
claim ignored + reclaimed, latest-tap-wins on out-of-order completion,
`isCurrent` monotonicity, dismissal reclaims under `.onDismiss` / leaves the file
under `.onAgeSweep`, double dismissal never double-reclaims, replacement reclaims
the old file under `.onDismiss` / leaves it under `.onAgeSweep`, cancellation
closes the panel + invalidates in-flight claims (and a late `present` on a
cancelled token still reclaims), `platformDefault` matches the host platform.

Measured (`-derivedDataPath ~/Library/Caches/gigaduck-builds/work-f2/dd`):
- `build-for-testing`: exit 0, `grep -c ': error: '` = **0**.
- `FilePreviewCoordinatorTests` + `AgentDownloadScratchTests` (the existing owner
  of the scratch lane; no other test class names `FilePreviewCoordinator`):
  `Executed 11 tests, with 0 failures` / `Executed 19 tests, with 0 failures` /
  suite total `Executed 30 tests, with 0 failures`.
- The two guards that scan `ConversationThreadView.swift`:
  `ParkedConverseLaneDriftGuardTests` **14 tests, 0 failures**;
  `ErrorSurfaceDriftGuardTests` **21 tests, 1 failure** — NOT mine, see Requests.

## Sweeper coverage for Work's preview copies — already covered, no edit made

`PersonalWorkbenchRouter.makePreviewCopy` (`PersonalWorkbenchView.swift:~563`) and
the inline-bytes branch (`:~447`) both write to
`temporaryDirectory/Conduck-Workboard-Preview/<uuid>/<filename>`.
`TempScratchSweeper.ownedPrefixes` in `AgentDownloadScratch.swift:~253` **already
lists `"Conduck-Workboard-Preview"`** ("Quick Look material preview directory"), and
`sweep()` matches top-level entries in `temporaryDirectory` with
`.skipsSubdirectoryDescendants` + `removeItem`, so the whole container is reclaimed
recursively. macOS's `.onAgeSweep` lifetime therefore has a real sweeper behind it
and **no prefix needed adding** — `AgentDownloadScratch.swift` is untouched.

One property worth knowing (not a defect, no action taken): the age check reads the
CONTAINER's `creationDate`, not each copy's. So the container survives its first
24 h with every copy inside it, and after that a launch sweep takes the container
whole, young siblings included. Both directions are safe — the sweep only ever runs
at launch, when no preview is on screen.

## Requests (files I do not own)

1. **`Conduck/Conduck/Views/Conversation/AttachmentFullScreenView.swift:387`** —
   `ErrorSurfaceDriftGuardTests.testEveryRetryControlConsultsARetryabilityGate`
   fails on the new Retry control there: *"View(s) draw a Retry control that this
   guard has never been told about"*. The gallery agent must record the decision in
   `retrySurfaces` in `ErrorSurfaceDriftGuardTests.swift` — `.notErrorDriven(reason:)`
   fits (it re-runs a local decode, no `AppError` reaches it). Unrelated to this
   slice; my files add no Retry control.
2. **`PersonalWorkbenchView.swift`** — wire the desk's own `FilePreviewCoordinator`
   per the snippet above. Nothing else needs changing in my files to support it.

## Nobody undo

- **`FilePreviewReclaimPolicy` is not decoration — do not collapse it back into
  `#if os(iOS)`.** The macOS half of the rule (never reclaim on dismissal, because
  Quick Look's "Open with" hands another app the LIVE path) is otherwise unreachable
  from an iOS-only test run, and it is the half that silently corrupts a user's
  Open-with session when it regresses.
- **The reclaim closure, not a URL the coordinator deletes.** Chat's unit is
  `AgentDownloadScratch`'s per-download DIRECTORY; Work's is the per-copy UUID
  directory. A "simplification" to `FileManager.removeItem(at: previewURL)` leaves
  Chat's directories behind, and a "simplification" to
  `previewURL.deletingLastPathComponent()` inside the coordinator is a delete of a
  parent it guessed at.
- **The superseded-claim reclaim in `present` is deliberately platform-independent**
  (outside the policy check). That file was never shown, so no other app can hold
  its path — gating it behind `.onDismiss` would leak every stale download on macOS.
- **`beginRequest()` is minted at the moment of user intent, before the async load.**
  Moving it next to `present` makes completion order decide which file gets the
  panel, which is the exact bug the token exists to prevent.
- **`cancelPendingPresentation` advances the token AND clears the URL.** Both halves
  are load-bearing: `dismissTransientChatUI` uses it so a hidden Chat can never
  reopen Quick Look over Work.

## Open questions

- Work's `.onAgeSweep` copies now live up to ~48 h in `tmp` under the container's
  creation-date rule (above). If the founder wants a tighter bound, the fix is a
  per-copy timestamp in the sweeper, not a shorter `maxOrphanAge` — flagging, not
  proposing.
- `PreviewedFile` is intentionally not `Sendable` (it stores a `@MainActor`
  closure). Every current caller is main-actor isolated; a future off-main producer
  must build the value on the MainActor rather than adding `@unchecked Sendable`.
