# Agent Workboard worktree handoff

Snapshot date: 2026-08-31

This is a continuation note for the dedicated Agent Workboard feature branch. It is not the canonical product specification. Keep `docs/ai-context/spec.md` authoritative for settled product decisions, update this note if the branch materially changes, and remove or archive it when the worktree is merged.

## Open this worktree

- Worktree: `/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard`
- Branch: `feature/agent-workboard`
- Xcode project: `/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck.xcodeproj`
- Remote: `git@github.com:GigaDuckAI/conduck.git`
- The branch has no upstream and was not pushed as part of this handoff.

Claude Code can read and edit this path directly. Start its session in the worktree root, not in the parent GigaDuck repository:

```sh
cd /Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard
git status --short
git log --oneline --decorate -5
```

This is a worktree of the nested Conduck repository. To enumerate it, run `git worktree list` from `/Users/peterkruck/repos/GigaDuck/Conduck`; the parent monorepo's worktree list is a different Git repository and will not show it.

Signed Xcode builds are ready. The required gitignored identity override exists at:

```text
Conduck/Configs/Identity-Override.xcconfig
  -> ../../../../../Conduck-Private/Configs/Identity-Override.xcconfig
```

Do not delete that symlink. A newly created Conduck worktree needs the same override or Xcode will ask for a development team and the macOS Share Extension entitlements will fail signing. Also do not use `URLSessionConfiguration.ephemeral` in macOS code; it is unavailable there.

## Product in one sentence

Work is a private pre-flight workspace where a person can collect rough thoughts and source material, shape them into a deliberate brief, explicitly send one immutable snapshot to one configured AI gateway, and return to review the linked result.

The load-bearing flow is:

```text
Workboard -> editable brief -> immutable dispatch snapshot -> Conversation -> Review
```

Capture never executes. A draft cannot reach a gateway until the person enters Review & Send, chooses a gateway, reviews the exact packet, and confirms the send.

## What the user can do

### Work and Chat shell

- Switch between Work and Chats from one fixed top-right control.
- Keep the original Chat sidebar/new-message/delete-all toolbar positions in both modes.
- Expand and collapse the native `NavigationSplitView` sidebar without custom width handling.
- Preserve unsent Chat drafts, staged attachments, the selected thread, Work thoughts, and the selected project while switching. On macOS, Work's two columns mount only while Work is on screen, so everything durable lives on `WorkboardViewModel`, on the window host, or on the always-mounted presentation modifier — never as column-local `@State`. iPad and iPhone keep both destinations mounted.
- Use a continuous 160-point Work/Chats selector with full segment fills, a hard overlaid divider, hover/press feedback, and a 44-point touch height on iPad.
- Use short, scoped, opacity-only mode transitions; Reduce Motion receives a shorter linear transition.

### Work capture and organization

- Create provisional New Work that is not persisted until the first thought or material is safely stored.
- Type a thought into the pinned Work composer and save it locally with the trailing arrow button.
- Capture a voice transcript into the Work draft; audio is not retained.
- Add files, Photo Library images, an iOS camera photo, links, screenshots, text, or pane-wide drag-and-drop content.
- Select up to 12 Photo Library images in one operation and confirm unusually large imports.
- Preview available material, see an honest unavailable-on-this-device state, and reattach local-only files.
- Search across briefs, material, and linked result text from the sidebar.
- Filter by derived lifecycle, pin projects, drag projects within their pinned/unpinned cohort, duplicate, delete, mark Done, and reopen.
- Capture an existing Chat message and its recoverable attachments as inert Work, with explicit partial/reference-only reporting for server-only files.

### Briefing and dispatch

- Edit title, objective, context, desired result, constraints, an optional review-by date, preferred gateway, pin state, and materials in a document-style editor. The review-by date is inert brief content: it is shown on the card, the detail view, the preflight and the canonical prompt, and it schedules nothing.
- Resolve optimistic edit conflicts by loading the latest version or saving the local edit as a copy.
- Optionally use the on-device Apple model to shape rough material into a proposed brief; nothing replaces the person's text until accepted.
- Generate a deterministic private “Brief My Work” overview and read it aloud.
- Open Review & Send, explicitly choose one configured gateway, exclude optional materials, and inspect the canonical prompt/manifest. Every gateway row carries the same one-line configuration status; no gateway is ranked, recommended, or presented as more available than another, and a route check names materials that stay behind because they are unsupported by the chosen gateway or unavailable on this device.
- Revalidate the brief and every material revision before dispatch.
- Deep-copy selected inputs into an immutable run snapshot, create the linked conversation/initial turn atomically, then use Conduck's existing transport and retry authority.
- Review replies or delivery failures from Work, open the linked Chat, acknowledge an exact result, continue refining, send again, or mark the objective Done.
- Inspect the immutable run timeline and generated-output links.

### Entry points outside the board

- macOS menu bar: explicitly Add to Work from typed text or a screenshot; normal Ask remains Chat.
- GigaAction/Converse intent: choose Chat or Work; Chat remains the migration-safe default and retries preserve the original destination.
- App Shortcuts/Siri: Add to Work and Brief My Workboard.
- Apple Watch: text-only Add to Workboard shortcut.
- iOS and macOS Share Extensions: choose existing Send or Add to Work, then create a new draft or append idempotently to a recent open item.
- Chat bubbles: preserve a turn as Work and deep-link to the resulting item.
- Work deep links: foreground the correct window and item.

## State model and privacy boundaries

- Human-visible state is derived as Draft, Waiting, Review, or Done.
- Only an explicit human action marks Done. Transport activity may request Review but cannot complete an objective.
- Review wins over Waiting when any unacknowledged result exists, including an older run.
- A linked Chat reply belongs to a Work run only if it is the first agent reply after that run's exact user turn and before the next user turn.
- Deleting a Chat preserves the Work brief and immutable run ledger. Deleting Work cannot cascade into Chat.
- Brief fields, text material, identifiers, lifecycle metadata, and immutable run metadata live in the existing private Core Data/CloudKit store.
- Binary source bytes—including screenshots and documents—are deliberately device-local in `WorkAssetVault`; only metadata and an opaque vault key sync. Another device shows reattach instead of pretending the file exists.
- Preview/share surfaces receive disposable copies, never authoritative vault URLs.
- The branch carries no backend, telemetry, automatic dispatch, or team collaboration.

## Capture and dispatch invariants

- `WorkCaptureEnvelope` is inert and contains no gateway, conversation, or dispatch field.
- The main app, iOS Share Extension, and macOS Share Extension carry mirrored envelope definitions. Change all three together and keep the mirror tests green.
- App-Group publication and claiming use atomic directory moves, claim tokens, bounded validation, and idempotent envelope/material identifiers.
- `WorkBriefPromptBuilder` creates the single canonical preview/dispatch packet.
- Preflight never silently chooses or falls back to another gateway.
- Dispatch freezes and persists the snapshot before crossing the transport boundary.
- `ConversationDetailViewModel.retry` remains the sole authority for network attempts.
- `WorkboardUploadJournal` may reclaim only upload keys that never became owned by the durable conversation.

## Architecture map

### Shell and presentation

- `Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift` — Work/Chats router, destination mounting, selector, deep links, preview host, and durable-storage reconciliation. Its `WorkCaptureRefreshCoordinator` is the board's sole reload owner: the first pass always runs, later reloads while Work is hidden are marked stale and replayed once on the switch back, and capture drains are never gated.
- `Conduck/Conduck/Views/Components/WorkbenchDestinationGate.swift` — the environment flag naming the on-screen destination and the binding wrapper every gated presentation uses, so a hidden destination contributes no chrome and originates no sheet or picker.
- `Conduck/Conduck/Views/Conversation/MainWindowView.swift` — macOS native split shell. Chat is always mounted; Work's columns mount while Work is active and stay for a short dissolve grace period after it deactivates.
- `Conduck/Conduck/Views/Workboard/WorkboardView.swift` — `WorkboardSidebarColumn` (search, lifecycle filter, one section per `WorkItemState.attentionOrder` lane), `WorkboardDetailColumn` (loading/error/project/new-work/overview routing), `WorkboardProjectCanvas` (pinned and project shelves with drag rails), and `WorkboardPresentationModifier`, which owns every sheet, confirmation and toast on the always-mounted split view.
- `Conduck/Conduck/Views/Workboard/WorkboardDetailView.swift` — lifecycle-specific project/result detail and run timeline.

### Capture, editing, and preflight

- `Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift` — thoughts, voice, attachments, camera/photo/file/link capture and drag/drop.
- `Conduck/Conduck/Views/Workboard/WorkboardEditorView.swift` — durable brief editor and conflict handling.
- `Conduck/Conduck/Views/Workboard/WorkboardDispatchSheet.swift` — gateway/material preflight and explicit send.
- `Conduck/Conduck/Views/Workboard/WorkboardBriefingView.swift` — private deterministic overview.
- `Conduck/Conduck/ViewModels/WorkboardViewModel.swift` — presentation state, autosave, capture, reordering, briefing, preflight and result actions.

### Persistence and records

- `Conduck/Conduck/Models/WorkboardRecords.swift` — sendable records, pure lifecycle resolver, reply correlation and immutable snapshot types.
- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` — Core Data transactions, optimistic revisions, idempotency, ordering and ledger persistence.
- `Conduck/Conduck/Models/Conversations.xcdatamodeld/Conversations 14.xcdatamodel/contents` — additive relationship-free Work entities linked by UUID.
- `Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift` — repository adapter used by the view model/services.
- `Conduck/Conduck/Services/Workboard/WorkAssetVault.swift` — durable device-local binary vault and reconciliation.

### Ingress and dispatch services

- `Conduck/Conduck/Models/WorkCaptureEnvelope.swift` — durable cross-process capture contract.
- `Conduck/Conduck/Services/WorkCaptureInbox.swift` — atomic App-Group publication/claim/validation.
- `Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift` and `WorkCaptureRetryCoordinator.swift` — idempotent import and retry.
- `Conduck/Conduck/Services/Workboard/WorkBriefPromptBuilder.swift` — canonical prompt and manifest.
- `Conduck/Conduck/Services/Workboard/WorkboardDispatchCoordinator.swift` — immutable prepare-and-dispatch boundary.
- `Conduck/Conduck/Services/Workboard/WorkboardUploadJournal.swift` — crash-safe upload ownership/reclamation.
- `WorkBriefAssistant.swift` and `WorkboardBriefingBuilder.swift` — optional shaping and the private overview.

### Platform integrations and tests

- `Conduck/Conduck/Intents/`, `Conduck/Conduck/MenuBar/`, both Share Extension folders, and `Conduck/ConduckWatch Watch App/WorkboardCaptureIntent.swift` own the additive entry points.
- Workboard-focused tests live under `Conduck/ConduckTests/Work*` plus atomic capture, migration, retry-destination, share-target, storage-seam and Watch smoke coverage.

## Shell and composer behavior

- Work's pinned composer keeps its own box and position and reuses Chat's paperclip, filled microphone, and filled arrow geometry.
- The paperclip menu is explicitly purpose-scoped: Work offers local camera/photo/file/link actions and can never expose Chat's gateway file-transfer setup.
- Composer chrome carries no privacy sentence of its own; privacy is stated in the action hint, the status message, and the full-canvas footer.
- The top selector has touching button halves and draws its separator as a non-interactive overlay, so there is no dead center strip.
- Hidden destination keyboard shortcuts, search focus, composers, attach menus, send/mic actions, and iPad recording/transcription are locally gated or cancelled through `workbenchDestinationIsActive`, so neither tree receives a changing `isEnabled` environment on a mode switch.
- Work screenshot thumbnails decode off the main actor through a revision-aware cache, preventing mode/sidebar animation from synchronously decoding image bytes.
- Each Work column computes its derived lists once per body pass, sidebar search filtering reads a debounced applied needle rather than the live field, and no-op observable cleanup writes are avoided.
- Destination motion is a short opacity-only dissolve; native sidebar and column layout remain system-owned. On macOS the Work layer mounts already opaque, so Work appears at once while Chat fades out beneath it, and Work's list scroll offset does not survive a section switch.

## Verification snapshot

State of this branch's working tree:

- Signed macOS Debug build: passed, including `ConduckShareExtensionMac` signing/embedding.
- Generic iOS Simulator Debug build: passed, including iOS camera and wide-iPad code.
- Full iOS suite: 4,692 executed, 0 failures.
- Full Watch suite: 229 executed, 0 failures.
- `git diff --check`: passed.
- SPDX headers: passed, new files included.
- Storage seam: passed across 769 Swift files.
- Folder map: passed across 36 Swift source directories.
- Spec citations: passed.
- Bundled legal-copy byte comparison: passed.
- All four `Localizable.xcstrings` catalogs parse with `jq`, and every key the deleted views owned is gone from both the sources and the catalogs.

The only failing repository guard is pre-existing documentation debt: `docs/ai-context/spec.md` is 19,830 words against a 16,900 ceiling, and two existing decisions exceed the 650-word per-decision ceiling. This branch does not edit that spec.

Build artifacts belong only in `/Users/peterkruck/Library/Caches/gigaduck-builds/<slug>` and are removed with `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh <slug>` once results are no longer needed.

## Manual QA still required

Automated tests protect persistence and dispatch boundaries, but a human should still verify the visual interaction wiring:

1. Populate Work with several screenshots, type unfinished text in both Work and Chat, then switch rapidly. Drafts and attachments must survive; titles and toolbar controls must not flash or move. On macOS, Work appears at once instead of fading in, and its list scroll offset restarts at the top — both are expected; a lost selection, a lost composer draft or a re-anchored sheet is not.
2. Expand/collapse the sidebar in Work and Chats. The native toggle, new-message and delete-all controls must remain in their original slots, and the section selector must stay fixed.
3. Test the Work paperclip on Mac and iOS. Confirm Files, Photo Library and Add Link; confirm Camera on a real iOS device; confirm Work never offers Set Up File Transfer.
4. Type a Work thought and press the arrow. It must add only to Work, clear only after a successful save, and never create a Chat/network request.
5. Start Chat recording on wide iPad, switch to Work, and confirm recording/transcription stops. Start Work voice capture and confirm the transcript returns only to the Work draft.
6. Test drag/drop onto an existing project, onto New Work, and between project cards. Verify files/photos/text/URLs route correctly and project order persists.
7. Exercise Review & Send with compatible, incompatible, excluded, and missing-local materials. Confirm one explicit gateway with no preselection and no ranking between rows, the route-check summary for anything staying behind, one exact preview, and one send.
8. Verify reply, failure, retry, acknowledgement, Send Again, linked-Chat opening, Done/reopen, and immutable timeline behavior.
9. Test the menu bar, GigaAction destination/retry, Shortcuts, Watch, Chat-turn capture, both Share Extensions, stale/Done share targets, the review-by date (set, change, clear, and its appearance on the card, detail view and preflight), multi-device metadata sync, and local-file reattachment.
10. Test Reduce Motion, keyboard Tab/Space operation, VoiceOver selected states, and the selector's full hit regions.
11. On macOS, share or capture something into Work while sitting in Chats, then switch to Work. The capture must be there on arrival, and a board left open must pick up changes made while it was hidden without a manual reload.

## Known non-blocking follow-ups

- The custom Work/Chats control is accessible and keyboard-operable with Tab/Space, but unlike the native segmented Picker it does not yet support Left/Right-arrow segment navigation.
- There is no focused SwiftUI automation for `AttachmentMenuPurpose.work`, iOS camera-to-Work wiring, or the navigation-title preference proxy. Founder UI QA is the current guard for those paths.
- A same-ID material reattachment can briefly show the prior thumbnail while the new revision decodes; the revision key prevents a permanently stale cache result.
- The Mac pointer wash, disabled opacity and animation constant live on `MacPointer` in `MacPointerTargets.swift`. `SettingsSegmentedPicker` still carries its own near-identical segment body, and `WorkbenchSectionSegmentButtonStyle` still re-derives `PrimaryCTAButtonStyle.CTABody`'s brightness ramp; both are candidates for the same promotion.
- Model 14 must be deployed to the production CloudKit schema before release.
- Team collaboration remains future scope; the current implementation is deliberately personal, private, and backend-free.
