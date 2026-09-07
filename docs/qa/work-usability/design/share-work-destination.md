# Share extensions — Work as a destination row

Lane: the iOS and macOS share extensions (`Conduck/ConduckShareExtension/`, `Conduck/ConduckShareExtensionMac/`). Tip read: `a278c7b`. Author: designer agent (reads code and docs; writes this file and the Codex reports only). Codex rounds: `verify/codex-design-share-r1.md`, `r2.md`, `r3.md`; §11 records what was accepted, refused and left open.

## The founder's ask, verbatim

> what about the share extension? should also be included there.

Read against the pattern the founder shipped on the other three surfaces this wave: Work is a **destination the person picks in the same list as the gateways** — the last row "Add to Work" of the wrist's "Where to?" chooser (opened on every Ask press, even with one gateway), the root row plus a non-sticky action row in CarPlay's chooser, the Mac's third capture hotkey. One name everywhere: "Add to Work" for the commit. Less is more, fewer controls, reuse what exists.

The boundary that binds: nothing on the Work desk ever becomes a gateway turn (a share to Work is inert; no speech hop even applies here); an implicit trigger must never reroute silently in either direction; and no sticky Work state may survive to the next share on either platform.

## Verdict

**`change_required`.** The share sheet at the tip already reaches Work and writes only an inert envelope when it does — the boundary holds. What does not match the founder's pattern is the **shape**: Work is a *mode* on a segmented control pinned above the list (Work · Send now), not a row in the destination list; the mode hides the whole gateway list and replaces it with an explanatory panel; and the sheet **defaults to Work**, so a person who shares to their AI and taps the big amber button without reading it lands on the desk. The change removes one control, adds one row, and picks nothing until the person does.

## 1. What the sheet does today (both platforms, verified at `a278c7b`)

| Region | iOS (`ShareView.swift`, hosted by `UIHostingController`) | macOS (fixed 480×600 `NSHostingController` panel) |
|---|---|---|
| Top | Nav bar: **Cancel** + title, `"Send to"` (`share.title`) in Send mode, `"Add to Work"` (`share.work.title`) in Work mode | Header bar: ✕ close + the shared-item header; no title |
| Shared item | 36 pt icon/thumbnail + name + type (+ "+N more") | Same, with `NSWorkspace` file icons |
| **Mode** | `Picker` `.segmented`, `ShareDisposition` `.work` / `.send`, **`@State … = .work`**; a11y label "Choose whether to save or send" | Same |
| Safari capture | "Page text" / "Selected text" row + switch, default ON, both modes | Same, plus a selection-text fallback for non-Safari URL shares |
| Search | Only in Send mode, only when gateways + recents > 8 (`ShareTargetFilter.shouldShowSearch`) | Same |
| Middle, Work mode | `workSummary`: glyph, "Everything you share is added to your Work desk." (`share.work.desk.detail`), lock line "Nothing is sent to AI" (`share.work.inert`). Nothing to pick, nothing scrolls | Same (it exists to fill the fixed panel) |
| Middle, Send mode | Scroll: **NEW CONVERSATION** (one collapsed "New conversation" row for a single gateway, else one row per configured gateway), **RECENT CHATS** (≤ 12, most recent first, dead-gateway recents already dropped by the writer); with no gateway and no recent, one **non-selectable** "New conversation" fallback row | Same |
| Default target | Send mode pre-selects the first configured gateway, else the first recent, else `.newConversation(gatewayRef: nil)` (drainer routes to the default gateway) — "Send now always has a default target" | Same |
| Bottom | Caption field "Add a message…" + one amber primary button: **Add to Work** (Work mode) / **Send now** (Send mode); ⌘-Return fires it | Same, plus a "Share up to 10 items" banner that disables the button; plain Return inserts a newline |
| Work commit | `commitToWork(note:includePageText:)` → `writeWorkCaptureEnvelope` → `WorkCaptureDirectoryPublisher` → `WorkCaptureInbox` (App-Group `WorkCaptureInbox/`), **targetless** (`targetWorkItemID: nil`), Darwin wake hint, then `completeRequest`. Failure → alert; only `.unavailable` offers Try Again (same `workCaptureIntentID`, so a retry rewrites, never duplicates) | Same |
| Send commit | `commit(caption:target:includePageText:)` → `writeEnvelope` → `SharedInboxManifest` with `shouldAutosend: true` into `Inbox/`, "Shared to Conduck" notification, `completeRequest` | Same |
| Memory | None. Each invocation is a fresh process; the extension reads the snapshot and writes envelopes; no defaults, no last pick | Same |

Two facts the brief got wrong and the implementer must not look for: **`ShareTarget` has no `.work` case** — it is `.newConversation(gatewayRef:)` / `.existing(conversationID:backendRef:)` only, and the Send writer `writeEnvelope(target:)` switches over exactly those two; Work is reached through a separate closure `onAddToWorkboard` and a separate host method `commitToWork`. And the snapshot's `recentWorkItems` is **always published empty** (`ShareTargetsSnapshotWriter`, pinned by `ShareTargetsSnapshotWriterColorTests.testTheWriterPublishesNoWorkTargets`), and both `ShareView` copies are pinned to never read it (`WorkCaptureInboxTests.testShareSurfacesUseDistinctWorkVocabularyAndAdaptivePrimaryActions`). Work is one desk; nothing here changes that.

What already holds and is kept unchanged: the two inboxes are separate roots with separate drainers, so a Work envelope cannot be sent and a send manifest cannot land on the desk; the Work writer is sliced and pinned by `WorkCaptureSharePublisherTests.appexWorkWriters` (must publish through `WorkCaptureDirectoryPublisher.commit`, one atomic rename, staging discarded on refusal); the extension decodes nothing (spec line 467) — the byte-copy loops, the Safari capture and the web-page markdown are untouched by this design.

## 2. Judgement against the founder's pattern

| Pattern on the sibling lanes | Share sheet at the tip | Verdict |
|---|---|---|
| Work is a **row** in the destination list, named "Add to Work", **last** after the gateways | Work is a **segment** that replaces the list with a panel | Change: row, last |
| The list opens on every use; nothing is remembered | Nothing is remembered (fresh process) — holds | Keep |
| A pick is **per use**; no default that favours a lane | Sheet **defaults to Work**; Send mode defaults to the first gateway | Change: no default |
| One name: "Add to Work" for the commit | "Add to Work" is the Work button — holds; but the segment reads bare "Work", which the Watch design rejected (a custom gateway can be *named* "Work") | Change: the row is "Add to Work"; the bare "Work" segment goes |
| Fewer controls | Mode picker **and** list **and** button | Change: list and button only |
| The chooser's title says nothing about sending | iOS title "Send to" over a list that ends in Work | Change: "Where to?" (the wrist's own string) |

**On the default.** The founder's boundary names both directions: a share meant for a gateway must not land on the desk, and material meant for the desk must not reach a gateway, *without the person naming it*. A pre-selected destination under a big amber button is an implicit choice for the person who does not read the button. Today's default (Work) fails in the recoverable direction — a card that has to be deleted and the share redone. The pre-Work default (first gateway) fails in the unrecoverable one — a private document sent to an AI. Neither is acceptable now that the two are peers in one list, so the sheet pre-selects **nothing**: the rows are the question, the button answers only once a row is tapped. This is the platform norm for a destination list (Messages, Telegram, Files "Save to" all require a pick) and it is exactly the Watch's shape, where the founder accepted one extra tap per Ask to have the question asked every time. Cost, stated honestly: the share-and-go path is two taps (row, Send now) where the pre-Work sheet was one. A one-line reversal exists (§10) but reopens the silent-to-AI direction.

**On remembering the last pick.** Refused. "No sticky Work state that survives to the next share" is verbatim; a remembered *gateway* pick is the same mechanism pointed the other way, and the extension today reads nothing but the snapshot and writes nothing but envelopes — the cleanest possible property to keep. A test pins it (§7).

**On the mode toggle.** Removed. With Work in the list the toggle is a second control saying the same thing, and its hidden-list behaviour is what made Work feel like a different sheet. The Work summary panel goes with it; its one load-bearing sentence, "Nothing is sent to AI", survives as the Work row's subtitle.

## 3. Decisions

| # | Decision | Why |
|---|---|---|
| 1 | **One destination list; "Add to Work" is its last row, always present, in its own section.** Sections in order: New conversation (gateway rows, unchanged) → Recent chats (unchanged) → **Work** (one row: amber badge with the desk's glyph `tray.and.arrow.down.fill`, title "Add to Work" (`share.addToWork`, reused), subtitle "Nothing is sent to AI" (`share.work.inert`, reused), the same selection ring as every other row). The section header reads "Work" (`share.section.work`, new) — the sheet already puts a "New conversation" header over a "New conversation" row, so the pattern is its own. | The founder's shape. Its own section because the list uses pinned section headers: a header-less trailing row would scroll under the pinned RECENT CHATS header and read as a chat. Work last is the wrist's rule and its reason (the AI rows lead; Work last is a stable relationship, not a fixed position). The desk's glyph is what CarPlay, the wrist's intent, the Mac Settings row and the tutorial all use; the sheet's `rectangle.stack.badge.plus` was the odd one out. |
| 2 | **The segmented mode picker and the Work summary panel are removed.** `ShareDisposition` goes; `share.mode.work`, `share.mode.send`, `share.mode.accessibility`, `share.work.desk.detail` and the iOS-only `share.work.title` retire. | §2. The list carries the choice; two controls for one decision is the thing the founder keeps refusing. |
| 3 | **Nothing is pre-selected.** `@State private var destination: ShareDestination?` starts `nil` and the `onAppear` pre-selection is deleted. The primary button is **disabled until a row is picked** and reads "Choose a destination" (`share.destination.choose`, new) in that state; once picked it reads **Add to Work** or **Send now** (existing keys) and ⌘-Return commits it. A disabled button never fires ⌘-Return. | §2. Neither direction of silent rerouting can happen when nothing is chosen for the person. The neutral label keeps the button a verb, tells VoiceOver why it is disabled, and avoids a layout jump. |
| 4 | **Selection is a two-case value, not a third `ShareTarget` case:** `enum ShareDestination: Equatable { case work; case send(ShareTarget) }` beside `ShareTarget` in `ShareView.swift` (both copies). `commit()` switches on it: `.work` → `onAddToWorkboard(caption, includePageText)`; `.send(let target)` → `onSend(caption, target, includePageText)`. `ShareTarget`, `onSend`, `onAddToWorkboard`, `commit`, `commitToWork`, `writeEnvelope(target: ShareTarget)` and `writeWorkCaptureEnvelope` are **unchanged**. | The brief's `ShareTarget.work` does not exist, and adding it would give the Send writer's `switch target` a `.work` arm that must never fire. Wrapping keeps the manifest writer's signature closed over gateway targets by *type*, so a Work pick cannot reach `writeEnvelope` however the view is edited — the same "cannot dispatch" property the two closures already give, now also on the value that carries the pick. |
| 5 | **Zero gateways.** With a decoded snapshot that has no configured gateway and no recent, the two send sections are replaced by one line, "No personal AI available." (`share.destination.noAI`, new, the wrist's exact sentence), and the Work row is the only destination. With **no snapshot at all** (missing file, unreadable, malformed → `snapshot == nil`) the existing legacy "New conversation" row is kept and becomes **selectable** (`.send(.newConversation(gatewayRef: nil))`, the drainer routes to the default gateway), above the Work row. | The decoded-empty case is a route the app itself says cannot succeed (the drainer fails visibly at drain); the wrist and the car both tell the person instead of offering it, and "available" is the honest word under the same ambiguity (I3). The nil-snapshot case is different: the roster is *unknown*, not empty — the app may well have a gateway the extension cannot see — so the legacy route stays, and since nothing is pre-selected any more it has to be tappable. `ShareTargetFilter` gets both rules as pure functions (§4) so the truth table is unit-tested. |
| 6 | **Search never hides the Work row.** The field still appears at > 8 gateways + recents and filters those two sections; the Work section is rendered whether or not a query is typed, including under the "No matches" state. | A destination that never disappears is the wrist's rule. A person searching for a chat and finding none still has somewhere to put the share. |
| 7 | **iOS title: "Where to?"** (`share.destination.title`, new; `share.title` "Send to" and `share.work.title` retire). macOS has no title and gets none. | "Send to" is false the moment Work is a row (the Watch retired "Ask which gateway?" for the same reason); the wrist's string is reused verbatim so the same question reads the same way on two surfaces. New wording is a new key (U-31). |
| 8 | **The caption field, the Safari page-text toggle, the progress labels, the Work failure alert and its Try Again rule, the "Shared to Conduck" notification on Send and the Darwin hint on Work are unchanged.** The caption is the send message for a gateway pick and the envelope `note` for a Work pick, as today. **Try Again stays bound to Work by construction** (it calls the Work-only helper, never the pick-reading `commit()`), and **the rows lock while a commit is in flight**, as the mode picker did at the tip. | Nothing about them was a mode. One field with one placeholder is fewer controls than a placeholder that flips with the row. A retry is a replay of what the person approved; the moment a pick can change the inbox, a retry that reads the pick could send what they asked to keep. |
| 9 | **The Mac pair changes in lockstep, differing only where it already differs.** The rows, sections, `ShareDestination`, `commit()`, the disabled-button rule and every string are the same text in both `ShareView` copies; the Mac keeps its ✕ header, its attachment-limit banner (which still disables the button), its Return-inserts-newline handling and its fixed panel — which no longer needs a filler panel, because the list fills it. `ShareTargetFilter.swift` stays byte-identical below its header in both copies (its drift guard). | The standing rule for the paired copies. The Mac's `workSummary` existed only to fill a fixed panel in a mode that no longer exists. |
| 10 | **The extensions still decode nothing, read nothing but the snapshot, and remember nothing.** No `UserDefaults`, `@AppStorage`, `@SceneStorage` or key-value store anywhere in either `ShareView`; no new provider load; `WorkCaptureEnvelope`, `SharedInboxManifest`, `ShareTargetsSnapshot` and both publishers are untouched, so every mirror triplet stays byte-identical. | Spec line 467 and the founder's no-sticky-state rule, both pinned by tests (§7). |
| 11 | **App side: comment-only edits.** `ShareTargetsSnapshotWriter` keeps publishing `recentWorkItems` empty; `SharedInboxDrainer` and `WorkCaptureDrainer` are untouched. U-16 (the share extension publishes what it can and reports the misses; `publishFileCapture` refuses the whole set) is **not** touched by this design and stays open. | Work is one desk; the app has nothing new to tell the extension. |

## 4. Change list by file

### `Conduck/ConduckShareExtension/ShareView.swift` and `Conduck/ConduckShareExtensionMac/ShareView.swift` (same edits; platform-only differences stay)

1. **Header comment.** Redraw the box: no mode row; the scroll region lists NEW CONVERSATION / RECENT CHATS / WORK (`◯ Add to Work · Nothing is sent to AI`); the bottom is the caption field and one button reading `Choose a destination` → `Add to Work` / `Send now`. Rewrite the "Capture / send boundary" paragraph: Work is the last row of the one destination list; nothing is pre-selected, so no share is routed for the person; a Work pick reaches `onAddToWorkboard` and only the inert Work inbox, a gateway pick reaches `onSend` and the send manifest; the two cannot be confused because the pick is `ShareDestination` and the manifest writer takes only `ShareTarget`. Delete "Send now always has a default target".
2. **Types.** Delete `private enum ShareDisposition`. Add, directly under `ShareTarget`:
   ```swift
   /// What the person picked in the destination list. `.work` is the desk — one
   /// desk, so it names no card — and `.send` is a gateway target. Kept apart from
   /// `ShareTarget` so the send manifest writer, which takes only a `ShareTarget`,
   /// cannot be handed the desk by any edit to this view.
   enum ShareDestination: Equatable {
       case work
       case send(ShareTarget)
   }
   ```
3. **State.** Replace `@State private var disposition: ShareDisposition = .work` and `@State private var selection: ShareTarget?` with a single `@State private var destination: ShareDestination?` — **no initializer**. Delete the `onAppear` block that assigned `defaultSelection`. Delete `defaultSelection`. Replace `isFallback` with two reads of the pure rules: `private var showsLegacyRow: Bool { ShareTargetFilter.showsLegacyNewConversationRow(snapshotDecoded: snapshot != nil) }` and `private var showsNoAILine: Bool { ShareTargetFilter.showsNoAILine(snapshotDecoded: snapshot != nil, gatewayCount: configuredGateways.count, recentCount: recents.count) }`.
4. **Body.** Remove `dispositionPicker` from the pinned stack and delete the property. `if showSearch { searchField }` unconditionally (was gated on `.send`). The middle region is `pickerScroll` (iOS) / `scrollRegion` (Mac) unconditionally; delete `workSummary`. iOS: `.navigationTitle(Text(Strings.title))` with `title` now `"Where to?"`.
5. **Scroll content.** Inside the `LazyVStack`, in order:
   ```swift
   if showsLegacyRow {
       legacyNewConversationRow            // selectable now; see 6
   } else if showsNoAILine {
       noAILine                            // one centred tertiary line, Strings.noAI
   } else if isEmptySearch {
       emptySearchState
   } else {
       newConversationSection
       recentChatsSection
   }
   workSection                             // ALWAYS, last, outside every branch
   ```
   `workSection` is a `Section` with `sectionHeader(Strings.sectionWork)` and one `targetRow(badge: workBadge, title: Strings.addToWorkboard, subtitle: Strings.nothingSent, selectable: true, isSelected: destination == .work, action: { destination = .work })`. `workBadge` is the existing round badge shape (34 pt iOS / 30 pt Mac) filled `Palette.amber` carrying `Image(systemName: "tray.and.arrow.down.fill")` in `Palette.background` instead of a monogram — add a `badge(symbol:fill:)` overload beside `badge(monogram:fill:)`.
6. **Rows.** Every gateway and recent row's `action` becomes `destination = .send(target)` and `isSelected: destination == .send(target)`. The fallback row (`fallbackRow`, renamed `legacyNewConversationRow`) becomes `selectable: true`, `isSelected: destination == .send(.newConversation(gatewayRef: nil))`, `action: { destination = .send(.newConversation(gatewayRef: nil)) }`; rewrite its comment: shown only when no snapshot decoded — the roster is unknown, not empty — and it has to be tappable because nothing is pre-selected.
7. **Bottom bar / composer.** The two commit helpers **stay** and one `commit()` chooses between them by the picked row; the `disposition == .work ? addToWorkboard : send` ternary goes:
   ```swift
   /// The primary button and ⌘-Return. Reads the pick once; each helper below
   /// is bound to ONE inbox by construction and never reads `destination`.
   private func commit() {
       guard let destination else { return }
       switch destination {
       case .work:              addToWorkboard()
       case .send(let target):  send(target)
       }
   }

   /// Work only. Also the alert's Try Again, so a retry can never follow a
   /// row tapped after the failed attempt began.
   private func addToWorkboard() {
       guard submissionState.begin(.addingToWorkboard) else { return }
       onAddToWorkboard(caption, includePageText)
   }

   private func send(_ target: ShareTarget) {
       guard submissionState.begin(.sending) else { return }
       onSend(caption, target, includePageText)
   }
   ```
   (Mac: `commit()` keeps the `guard !attachmentLimitExceeded` first; `send(_:)` replaces the tip's `send()` that read `selection ?? defaultSelection`.) The button label: `.addingToWorkboard` / `.sending` progress rows as today; else `destination == .work` → `Label(Strings.addToWorkboard, systemImage: "tray.and.arrow.down.fill")`; `destination` is `.send` → `Label(Strings.sendNow, systemImage: "paperplane.fill")`; `nil` → `Text(Strings.chooseDestination)`. `.disabled(destination == nil || submissionState.isCommitting)` (Mac: `|| attachmentLimitExceeded`). **The alert's Try Again calls `addToWorkboard()`, never `commit()`** — the retry is bound to the inbox the person approved, not to whatever row is lit when the alert closes. **Rows lock while a commit is in flight:** `targetRow`'s `.disabled(!selectable)` becomes `.disabled(!selectable || submissionState.isCommitting)`, so a tap during the asynchronous copy cannot move the pick under a running commit (the mode picker had this lock at the tip; the rows did not, because the pick could not change the inbox then). Codex round 1 found the sequence: pick Work → commit → tap a gateway row during the copy → `.unavailable` → Try Again; with a pick-reading retry that would have called `onSend`. Both rules close it, and each alone would.
   **Delete `sendCircle` and `SendButtonStyle` in both copies — mandatory, not optional:** `sendCircle` is `Button(action: send)` with `.accessibilityLabel(Text(Strings.send))`; it is dead at the tip but still type-checked, so it stops compiling the moment `send()` becomes `send(_:)`. `Strings.send` (`share.send`) goes with it (§5).
8. **Strings.** Retire `workMode`, `sendMode`, `destinationMode`, `deskDetail`, and on iOS `addToWorkTitle`; iOS `title` becomes key `share.destination.title`, default `"Where to?"`, comment "Share Extension navigation title over the destination list (gateways, recent chats, Add to Work)". Add in both: `sectionWork` (`share.section.work`, `"Work"`, "Picker section header above the Add to Work row"), `chooseDestination` (`share.destination.choose`, `"Choose a destination"`, "Disabled primary button label until a destination row is picked"), `noAI` (`share.destination.noAI`, `"No personal AI available."`, "Shown in place of the gateway rows when the snapshot lists no configured gateway and no recent chat"). `nothingSent` (`share.work.inert`) is reused as the Work row subtitle; update its comment to say so.
9. **Accessibility.** Rows keep `.accessibilityElement(children: .ignore)`, the `"title, subtitle"` label and the `.isSelected` trait, so the Work row reads "Add to Work, Nothing is sent to AI, selected". The section header keeps `.isHeader`. The disabled button reads its own label. Nothing else.

### `Conduck/ConduckShareExtension/ShareTargetFilter.swift` and `…Mac/ShareTargetFilter.swift` (byte-identical below the header)

Add two pure rules with doc comments:
```swift
/// The legacy "New conversation" row (drainer routes to the default gateway)
/// is offered only when NO snapshot decoded: the roster is unknown, not empty,
/// and the app may hold a gateway the extension cannot see.
static func showsLegacyNewConversationRow(snapshotDecoded: Bool) -> Bool { !snapshotDecoded }

/// A decoded snapshot with no configured gateway and no recent chat is told in
/// one line rather than offered a send that the drainer would refuse. "Available",
/// not "set up": an empty roster is also what a stale snapshot reads.
static func showsNoAILine(snapshotDecoded: Bool, gatewayCount: Int, recentCount: Int) -> Bool {
    snapshotDecoded && gatewayCount == 0 && recentCount == 0
}
```
Header comment of both copies: extend the "pure, view-free search/threshold logic" line to "search, threshold and destination-list rules".

### `Conduck/ConduckShareExtension/ShareViewController.swift` and `…Mac/ShareViewController.swift`

Comments only. `viewDidLoad`'s "The picker is always the surface…" paragraph: the view offers one destination list (gateways, recents, Add to Work) and pre-selects nothing; `onSend` is reached only by a gateway pick, `onAddToWorkboard` only by the Work row. `commitToWork` doc comment: "Publish … into the separate Work capture inbox" stays; replace "It names no destination" with "Work is one desk, so the pick names no card". No code change: the guard `WorkCaptureSharePublisherTests.appexWorkWriters` slices `writeWorkCaptureEnvelope` → `loadOne` and must keep passing untouched.

### `Conduck/Conduck/Services/ShareTargetsSnapshotWriter.swift`

Comment only: "the appex's Add-to-Work mode offers no destination and `recentWorkItems` is published EMPTY" → "the appex's Add to Work row names no card, so `recentWorkItems` is published EMPTY". The pinned line `let recentWorkItems: [ShareTargetsSnapshot.RecentWorkItem] = []` stays verbatim.

## 5. Catalog keys (listed, not edited by the designer — one owner per catalog per phase)

`Conduck/ConduckShareExtension/Localizable.xcstrings` (iOS):

| Action | Key | Default value |
|---|---|---|
| add | `share.destination.title` | `Where to?` |
| add | `share.section.work` | `Work` |
| add | `share.destination.choose` | `Choose a destination` |
| add | `share.destination.noAI` | `No personal AI available.` |
| retire | `share.title` | `Send to` |
| retire | `share.work.title` | `Add to Work` (the nav title; the button key `share.addToWork` stays) |
| retire | `share.mode.work` | `Work` |
| retire | `share.mode.send` | `Send now` (the button key `share.sendNow` stays) |
| retire | `share.mode.accessibility` | `Choose whether to save or send` |
| retire | `share.work.desk.detail` | `Everything you share is added to your Work desk.` |
| retire | `share.send` | `Send` (the a11y label of the dead `sendCircle`, removed with it) |

`Conduck/ConduckShareExtensionMac/Localizable.xcstrings` (macOS): the same, minus `share.destination.title` (no title on the Mac) and minus `share.title` / `share.work.title` (never in that catalog). No key listed as retire is referenced outside the two `ShareView` copies and `WorkCaptureInboxTests` (grepped at the tip: `share.title`, `share.work.title`, `share.mode.*`, `share.work.desk.detail`, `share.send` appear in no other Swift, plist or markdown file).

Reused in a second role, no change: `share.addToWork` (row title and button), `share.work.inert` (row subtitle), `share.sendNow`, `share.section.new`, `share.section.recent`, `share.target.newConversation`, every `share.work.error.*`, `share.retry`, `share.cancel`. Validate each edited catalog with `plutil -convert xml1 -o /dev/null`, `python3 -m json.tool` and a duplicate-key check.

## 6. Doc edits

- `docs/ai-context/spec.md`: **no edit.** The Work section says every capture surface lands on the desk and that a Shortcut's files ride the share sheet's envelope queue; the extension paragraph is about decoding. All stay true; the four words of headroom stay.
- `docs/ai-context/project-structure.md` line 76, present tense: "The iOS share-sheet extension. One destination list — every configured gateway, the recent chats, then Add to Work as the last row — and nothing is picked until the person picks it; a gateway pick writes the send manifest, the Work row writes an inert envelope for the desk. Both land in shared App-Group inboxes the app drains when active." Line 77 unchanged.
- `docs/qa/work-usability/handoff.md`: a decision line under "Founder decisions taken by default": "Share sheet (iOS + Mac): Add to Work is the last row of the one destination list, under its own header, with nothing pre-selected — the button reads 'Choose a destination' until a row is tapped, then 'Add to Work' or 'Send now'. The Work / Send now segment and the Work panel are gone; a decoded roster with no gateway shows 'No personal AI available.' above the Work row; no snapshot at all keeps the legacy New conversation row, now tappable." "What this wave is": "On the three satellite surfaces" → "On every satellite surface — the share sheet included". QA steps (numbered by the integrator), each on iOS and Mac: (a) share a photo → the sheet opens on "Where to?" (iOS) with nothing selected and a disabled "Choose a destination" button; ⌘-Return does nothing; (b) tap Add to Work → the button reads Add to Work → tap → a card on the desk, the Conversations list unchanged, no "Shared to Conduck" notification; (c) tap a gateway row → "Send now" → the existing send, and the desk unchanged; (d) tap Work, then a gateway, then Work again → the ring and the button follow every tap; (e) share again immediately → nothing pre-selected (no memory); (f) with > 8 targets type a query that matches nothing → "No matches" and the Work row still below it; (g) zero configured gateways and no recents → only "No personal AI available." and the Work row; (h) delete the App-Group `share-targets.json` (or a fresh install before first launch) → "New conversation" is tappable above Add to Work; (i) Mac: share 11 items → the banner, and the button stays disabled even after a pick; (j) Safari page → the page-text switch still rides both destinations; (k) VoiceOver: the Work row announces "Add to Work, Nothing is sent to AI" and its selected state; the disabled button announces "Choose a destination"; (l) **the retry cannot change lanes:** share a large set, tap Add to Work, tap the button, and while "Adding to Work…" shows tap a gateway row — *must be true:* the row does not take the pick (rows are locked while a commit runs); then force the storage failure (fill the device, or share to a device whose App Group is unwritable) → "Couldn't Add to Work" → Try Again → *must be true:* the retry is a Work retry: a card appears on the desk or the same alert returns, and the Conversations list is unchanged with no "Shared to Conduck" notification.
- `docs/qa/work-usability/fixnotes/u47-work-destination-lanes.md`: no edit — its "Nobody undo" list names no share-sheet mechanism, and the rules it does name (no sticky destination, a pick per use) are what this design applies.
- `README.md` line 55: no edit; "the share sheet on iPhone, iPad and Mac" stays true.

## 7. Tests

Style: `RefusalLaneSource`-free string checks on the two `ShareView` copies as `WorkCaptureInboxTests` already does; every new source guard is run once against `git show a278c7b:<file>` while it is written and must be red there for the stated reason.

| Suite | Change |
|---|---|
| `ShareTargetFilterTests` (pure; compiled from the Mac copy) | **Add** `testTheLegacyRowShowsOnlyWhenNoSnapshotDecoded` (`false` → true, `true` → false) and `testTheNoAILineShowsOnlyForADecodedEmptyRoster` (decoded + 0 + 0 → true; undecoded + 0 + 0 → false; decoded + 1 + 0 → false; decoded + 0 + 1 → false). `testAppexMirrorsAreByteIdenticalBelowHeader` keeps passing because both copies get the same bytes. |
| `WorkCaptureInboxTests.testShareSurfacesUseDistinctWorkVocabularyAndAdaptivePrimaryActions` | **Will break; update.** `expectedWorkKeys`: drop `share.work.desk.detail`; add `share.section.work`, `share.destination.choose`, `share.destination.noAI`. `retiredWorkKeys` (checked absent in source **and** catalog): add `share.work.desk.detail`, `share.mode.work`, `share.mode.send`, `share.mode.accessibility`, `share.work.title`, `share.title`. Add an iOS-only assertion: `ConduckShareExtension/ShareView.swift` contains `String(localized: "share.destination.title"` with `defaultValue: "Where to?"`, and the Mac copy does not. Keep every existing assertion (`.frame(minHeight:`, the `.isSelected` trait, `.isHeader`, the no-`recentWorkItems` read, the no-`share.workboard.` prefix). |
| `WorkCaptureInboxTests` (new, source) | **Add** `testTheShareSheetPicksNoDestinationAndRemembersNone`, written as one pure predicate `shareSheetPicksNothing(source: String) -> [String]` (returns the violated rules) run against both `ShareView` copies read from disk, plus **in-memory negative controls** that mutate the real source and must each report a violation. Rules, each evaluated on the source **after collapsing every run of whitespace (newlines included) to one space**, so a line break cannot split a token the rule looks for: (a) contains `@State private var destination: ShareDestination? ` and the character after that space is not `=` — no initializer; (b) **every occurrence of `destination = ` is immediately preceded by `action: { `**, and there are exactly five of them (the Work row, the collapsed single-gateway row, the per-gateway row, the recent row, the legacy row) — the row closures are `action: { destination = .work }` / `action: { destination = .send(target) }`, so an assignment anywhere else — an `onAppear`, a `task`, an `init`, a `didSet`, however it is wrapped or line-broken — breaks the count or the prefix; (c) neither the `.onAppear {` block nor any `.task {` block, each sliced to its matching brace, contains `destination`; (d) none of `ShareDisposition`, `.pickerStyle(.segmented)`, `UserDefaults`, `@AppStorage`, `@SceneStorage`, `NSUbiquitousKeyValueStore`, `FileManager` inside `ShareView.swift` (the view reads the snapshot through the host; a view that opens files is a view that could read a remembered pick); (e) the `enum ShareTarget` body (sliced to its closing brace) contains no `case work`; (f) the `commit()` body contains `case .work:` → `addToWorkboard()` and `case .send(let target):` → `send(target)`; the `addToWorkboard()` body contains `onAddToWorkboard(` and not `destination`; the `send(_ target: ShareTarget)` body contains `onSend(` and not `destination`; (g) the `primaryButton: .default(Text(Strings.retry))` closure contains `addToWorkboard()` and not `commit()`; (h) `.disabled(destination == nil` and `.disabled(!selectable || submissionState.isCommitting)` are present. Negative controls: the real source with `.onAppear { destination = .work }` inserted before `.task {` → (b) and (c) fail; with a **line-broken** `.task {\n    destination =\n        .work\n}` inserted → (b) and (c) fail (Codex round 2's dodge of the unnormalised line rule); with `: ShareDestination?` rewritten to `: ShareDestination? = .work` → (a) fails; with the retry closure's `addToWorkboard()` rewritten to `commit()` → (g) fails; the tip's `ShareView` (`git show a278c7b:…`) → (a), (d), (f) fail. For both `ShareViewController` copies: `private func writeEnvelope(` takes `target: ShareTarget`. What this proves, stated honestly: these are **targeted regression checks on the source's shape** — each names one way the forbidden mechanisms (a pre-selection, a remembered pick, a retry that follows the current row) were written or could plausibly be re-written, and fails on it. They do not execute the view and they do not prove absence in general; a novel construction the rules do not name would pass, which is why the negative controls are kept beside the rules and extended when a new dodge is found. The invocation-lifetime property — a fresh process per share — is the system's, not ours. |
| `WorkCaptureSharePublisherTests` | No change expected: `appexWorkWriters` slices `writeWorkCaptureEnvelope` → `loadOne`, and neither moves. Run it. |
| `ShareTargetsSnapshotTests`, `SharedInboxManifestTests`, `SharedInboxRoutingTests`, `SharedInboxDrainerTests`, `WebPageCaptureTests` | No change: no wire contract moves. Run them. |
| `ShareTargetsSnapshotWriterColorTests.testTheWriterPublishesNoWorkTargets` | No change (the pinned line stays). |
| `ErrorSurfaceDriftGuardTests` | Both `ShareView` copies stay `.notErrorDriven`; the alert's Try Again still fires only on `.unavailable`. Run it. |
| `TempScratchLeafDriftGuardTests` | Scans the extension targets; no new scratch path. Run it. |

Not unit-testable and therefore QA: the row order on screen, the disabled button, the pinned header behaviour, the Mac panel with the list filling it.

## 8. Risks

- **Two taps on the share-and-go path** (row, then Send now) where the pre-Work sheet was one. The founder's own trade on the Watch. Reversal: one line in `onAppear`, `if destination == nil, let first = configuredGateways.first { destination = .send(.newConversation(gatewayRef: first.ref)) }` — which reopens the direction the boundary calls unrecoverable, so it is a founder call, not an implementer's.
- **Work is a scroll away on a long list.** Twelve recents plus gateways put the Work row below the fold on an iPhone. Accepted, as on the wrist ("a stable relationship, not a fixed position"). The remedy if QA finds it wrong: pin the Work row beneath the scroll region as a fixed last row rendered with the same `targetRow`; it costs a visual gap on a short list, which is why it is not the default.
- **"No personal AI available." on a stale snapshot.** The writer regenerates on every conversation and settings change, but a snapshot written before a gateway was configured and never refreshed would hide the send route. The person opens Conduck once and the writer runs. Recorded, not guarded.
- **A custom gateway named "Add to Work"** would collide with the row's title. Nobody names a server that; no guard.
- **The iOS title.** "Where to?" over a system share sheet is unusual. It is the wrist's string and the honest question; the founder may prefer "Conduck" or no title at QA — a one-key change.

## 9. Out of scope, recorded

- U-16 (partial publish and reporting misses) is unchanged; the Work writer still fails the whole capture when a provider load throws on iOS and on the Mac.
- The caption placeholder "Add a message…" is kept for both destinations; a Work-flavoured placeholder would be a second string for one field.

## 10. Reversals, for the record

Each is one edit and named here so a QA override is a decision rather than a rediscovery: pre-select the first gateway (§8, first bullet); keep the iOS title "Send to" (drop the `share.destination.title` add and the `share.title` retire); pin the Work row under the scroll (§8, second bullet); render the Work row without a section header by moving it out of the `LazyVStack` (same as pinning).

## 11. Codex rounds

**Round 1** (`verify/codex-design-share-r1.md`, gpt-6-astra, xhigh; verdict "accept with the listed changes", two blocking). All three findings accepted and folded in:

1. *Blocking — Try Again could reroute.* The draft had the alert's Try Again call the pick-reading `commit()`, and the rows stayed tappable during a commit; Work → commit → tap a gateway during the copy → `.unavailable` → Try Again would have called `onSend`. Fixed twice over: Try Again calls the Work-only `addToWorkboard()` (§4.7), rows are `.disabled` while `submissionState.isCommitting` (§4.7), and both are pinned by the guard's rules (g) and (h) (§7) and by QA step (l) (§6).
2. *Blocking — `sendCircle` references `send`.* Deleting `send()` while leaving the dead `sendCircle` "optional" would not compile. Removal of `sendCircle`, `SendButtonStyle` and `Strings.send` is now mandatory; `share.send` retires in both catalogs (§5).
3. *The no-pre-selection guard proved less than it claimed.* Its checks would have passed with `.onAppear { destination = .work }` re-added. The guard is now a pure predicate with a line rule ("every `destination = ` line is a row `action: {`"), an `onAppear` slice rule, and in-memory negative controls that mutate the real source and must fail (§7); its wording says what a source check proves and what it does not.

**Round 2** (`verify/codex-design-share-r2.md`; "accept with changes, no blocking implementation findings"). Confirmed the retry/row-lock pair closes the reroute and found no other pick/inbox disagreement on the permitted paths (the helpers claim the busy phase synchronously, so a second ⌘-Return cannot start a commit; the alert's Cancel cancels; the host completes after writing without clearing the phase; the Mac limit flag is immutable per invocation). Supported the three taste calls — nothing pre-selected, "Where to?", Work last in its own scrolling section — and agreed pinning under the scroll should follow founder QA, not precede it. One finding, accepted: the line rule (b) was formatting-sensitive (`.task { destination =\n .work }` dodged it) and the design overclaimed "impossible". Rules now run on whitespace-collapsed source with an exact count of five row assignments and a `.task` slice rule; that dodge is a negative control; the guard is described as targeted regression checks (§7).

**Round 3** (`verify/codex-design-share-r3.md`; **"accept as is, no blocking findings remain"**). Confirmed the whitespace-normalised rule set closes the round-2 dodge, that the count of five assignment sites is correct for §4.5–4.6 (sites, not rendered rows), and recorded no remaining disagreement.

**Remaining disagreements: none.** The three taste calls (nothing pre-selected, "Where to?", Work last in its own scrolling section) stand with Codex's support and remain founder-reversible per §10.

Codex declared, in round 1, catalog-wide references and unlisted guards unverified under its read budget; both were checked by the designer at the tip (§5 last paragraph; §7 lists every guard that walks the extension directories: `ErrorSurfaceDriftGuardTests` registers both `ShareView` copies as `.notErrorDriven` with reasons that stay true, `TempScratchLeafDriftGuardTests` scans both targets, `WorkCaptureSharePublisherTests.appexWorkWriters` slices the untouched writer).
