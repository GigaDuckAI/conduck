# Work Usability — Handoff

**Status: BUILT, INTEGRATED, VERIFIED, awaiting founder QA.** Branch `feature/agent-workboard` (worktree `.codex/worktrees/conduck-agent-workboard`, whose root IS the Conduck app repo). Everything is local — never pushed. This wave sits on top of the desk + CloudKit wave; that handoff is `docs/qa/desk-cloudkit-handoff.md` and its release gates carry forward unchanged. Independent verification agents read the finished diff, so the `/code-review` gate is satisfied; do not run it again.

## What this wave is

Work was a desk you could put things on and not much else. It is now a desk you can *use*: a picture card is the picture, a tap opens the right viewer for the kind of thing tapped, and every surface Conduck already owns has a door onto it — the share sheet, two Shortcuts actions, the Mac menu bar's own hotkey, the wrist, and a CarPlay row. Nothing on any of those lanes reaches a gateway, and no capture surface writes a card its own way: they all land through the one desk write, or hand an envelope to the drainer that does.

## Commit chain (all local)

`ec8b27f` (payload store mirrored through its own CloudKit container — the previous wave's tip) → **`f713c52`** foundation: thumbnails at the desk write, model-free gallery, lifted Quick Look coordinator, multi-file envelope publisher, desk-write ownership guards → **`692608d`** surfaces: image-forward cards, gallery + Quick Look preview, Shortcuts file/record intents, Watch Save to Work, Mac ⌃⌘W capture, CarPlay Add to Work → **`5c401df`** the first fix round plus its docs pass → the second fix round's commit that follows (see `git log`).

## Gate at the tip

| Check | Result |
|---|---|
| iOS suite (sim `04DEF4F5`) | **5336** tests / **0** failures / **1** environment skip (`GatewayAdapterBriefTests` clipboard pin — needs the sibling `website` checkout) |
| watchOS suite (`ConduckWatchTests`, sim `28AC563B`) | **269** / 0 — up from the 232 baseline (the wrist's Work lane, its UI assertions, and the relay retryability pins) |
| Signed macOS build | green, real signing through the identity override — no `CODE_SIGNING_ALLOWED=NO` fallback |
| `check-storage-seam.sh` · `check-folder-map.sh` · `check-spec-cites.sh` · `check-legal-copies.sh` · `add-spdx-headers.sh --check` | exit 0 |
| `check-spec-size.sh` | exit 0 — **16,898 of 16,900** words, every decision within its 650-word limit. Two words of headroom: a further sentence there is paid for with a trim in the same decision |
| Mirror triplets (`WorkCaptureEnvelope`, `WorkCaptureDirectoryPublisher`, `ShareTargetsSnapshot` ×3) | byte-identical from `import Foundation`, by SHA-256 |
| Wire enums (the phone's and the Watch's copies) | 14 literals, same order, identical, and no capture lane adds one |
| Catalogs | all four parse, with no duplicate key at any nesting level — iOS 2,296 rows · Watch 318 · `ConduckShareExtension` 43 · `ConduckShareExtensionMac` 42; `workboard.*` bidirectional |
| `git diff --check` | clean |

The eleven new untracked `.swift` files were SPDX-checked by hand (`--check` walks tracked files only): each opens `// SPDX-License-Identifier: Apache-2.0`, a blank line, then its `// Conduck…` header.

## Verification

Two Codex rounds read the finished diff, six lenses each: the five surface slices plus a cross-slice lens whose findings route onto the slice that owns the file. Round 1 raised 17 slice findings and three the cross lens found alone. Round 2 closed 12 of those 20, recorded one open as a founder call (images offer no Share — decision 12), and re-opened seven.

Round 2 raised ten findings of its own — two majors (a Shortcut capture identity taken over bytes it did not publish; a cached terminal relay verdict that stranded a wrist entry and could evict a queued Chat recording) and eight minors, most of them a re-opened item restated. Every one is fixed except **`desk R1`** (`Views/Workboard/PersonalWorkbenchView.swift`), which is the image-Share decision again — the only round-2 finding still open. The two documentation findings, `cross R4` (the README's no-transfer claim) and `cross R5` (the CarPlay ownership rationale, which the CarPlay paragraph below now states correctly: the attach is *not* idempotent, and it asks whether it still owns the capture before it writes), are closed here.

The reports are `verify/codex-r1-*.json` and `verify/codex-r2-*.json`; every fix is argued in `fixnotes/fix-r1-*.md` and `fixnotes/fix-r2-*.md`, and `integrate-2.md` / `integrate-3.md` hold the measured runs behind the gate table above.

A third, focused Codex round re-read only the two round-2 major fixes (`verify/codex-r3-shortcuts.json`, `verify/codex-r3-watch.json`): the wrist acknowledgement is clean; the Shortcut identity fix is closed, and its one new minor — a source enlarged after preflight was copied to scratch in full before its size was refused — is fixed in `Intents/AddFilesToWorkIntent.swift` (the streamed snapshot now aborts and reclaims the moment the next chunk would cross the per-file or aggregate ceiling; `fixnotes/fix-r3-shortcuts.md`). No round-3 finding remains open.

## What shipped

**Thumbnails.** A preview is minted at the one common import site — `ConversationStore.upsertDeskMaterial`, before the write context — and again inside the transaction that replaces a payload, so picker, drop, camera, share sheet, Shortcut drainer and chat capture are all covered by one edit. The decode runs on a `@concurrent` hop, never on the store actor, and the lane gate reads the *staged* storage mode rather than the draft's claim, so vault bytes never buy a preview that CloudKit would carry. `repairMissingWorkThumbnails()` fills rows that carry none, bounded to 96 rows and 4 concurrent decodes per pass, writing every physical row and no `updatedAt` — a revision moved by a preview nobody asked for reads as an edit and invalidates an approved preflight.

**Image-forward cards.** A `.image` card with thumbnail bytes fills its tile at the standard and large footprints: the photo edge to edge, name and footer on a bottom gradient that grows with Dynamic Type, the availability glyph on a dark disc so its tint survives an arbitrary picture. Small keeps the old artwork-plus-name row. The two layouts are two separate view chains, so the glyph card's geometry cannot be moved by the photo card's existence, and the menu corner is drawn outside both.

**Preview per kind.** `AttachmentFullScreenView` is model-free: it takes pages, a start index and a byte loader, and Chat's call site keeps its old convenience init untouched. Tapping any image card — vault lane included — opens a desk-wide gallery of every `.open`-permitted picture in board order, loaded lazily per page, decoded through a strictly bounded ImageIO path at 4096 px with no unbounded platform fallback, and holding at most the current page ± 1; a memory warning drops the radius to zero for the life of the presentation. A load or decode failure shows a message and a Retry rather than spinning forever. Files and recordings go to Quick Look through `FilePreviewCoordinator`, lifted out of `ConversationThreadView` into `Views/Components/` and generalised to a `PreviewedFile { url; reclaim }` so each lane keeps ownership of the unit it created; iOS reclaims on dismissal, macOS leaves the copy to the launch age-sweep because Quick Look's Open With hands another app the live path.

**Shortcuts.** `AddFilesToWorkIntent` copies every source into its own scratch leaf first, taking the copy and its SHA-256 in one streamed pass, and the capture identity is derived from those snapshots — the bytes it goes on to publish — never from the source it read, because a source rewritten between the two reads would otherwise repoint an earlier capture's cards onto different bytes. A digest, read or write failure refuses the whole capture rather than naming an empty one. It then publishes one envelope through `WorkCaptureInbox.publishFileCapture`, which copies bytes rather than reading them (a headless process must not hold 256 MB) and checks per-file and envelope ceilings twice — once against the declared sizes before a byte is copied and once against the staged snapshots — and derives each entry id as a UUIDv5 over the capture id and sequence, so a killed-and-rerun Shortcut repairs its own cards instead of laying a second set. Staging costs peak scratch: a URL-backed set is resident twice, once as the snapshot and once as the queue's copy. `RecordWorkNoteIntent` only launches the in-app recorder, through a consumable pending route that survives a cold launch. The drainer maps an audio `.file` entry to a playable `.audio` card, which the share sheet gets too.

**Watch.** A second bordered "Save to Work" button on the launchpad pushes its own route — not a mode on Ask, because a sticky mode's failure is a private thought going to a gateway. A Work capture always relays, whatever the speech provider, and the reply is typed end to end (`RelayReply { text; workSaved }`), so a work entry can never take a converse hop. The phone reads the bytes before the defer deletes them, publishes with `sourceDevice: "watch"`, then transcribes and attaches; a phase-one throw replies a retryable code so the wrist keeps its clip. Work entries are exempt from both age and count eviction — a capture at capacity is refused up front rather than an older recording being deleted — and the clip goes only on a durable acknowledgement or an explicit discard. A settled failure *after* publication — the desk holds the recording, the words are unrecoverable — replies success-shaped with the stamp and an empty transcript, so the wrist releases its clip and ends on "Saved to Work. Add the words on your iPhone." on both the live and the deferred leg; only a retryable verdict travels back as an error, because the entry that keeps its clip is the one that can still win the words on a re-fire. A phone too old to send the stamp returns words alone, which land as a note under an id derived from the request (so a re-fire repairs rather than duplicates), written and confirmed before the queue entry is claimed.

**Mac menu bar.** `⌃⌘W` records straight to the desk: the popover opens on a compact Work HUD pinned `.applicationDefined` from the moment the start is in flight, not from the moment the mic is live, so a click-away during startup cannot leave a microphone coming up behind a closed popover; the voice press claims the popover *before* it shows it, so summoning Work never marks an unread Chat reply as seen. The acknowledgement is a button that opens the desk with the card already on it (the capture drains inline), and each lane owns its own receipt — voice says "Added to Work. The words came from your speech provider.", the typed quick note says "Added to Work. Nothing was sent.", because only the typed lane can promise that nothing left the device. A voice request that arrives at a fully quit Mac is honoured by the launch lifecycle itself: the app activates and reveals Work rather than waiting for a window that would otherwise never exist. In text mode the same key opens the compose surface in a Work-only state — no Ask affordance, header "Add to Work" — whose composition is stored with its aim, so a dismissed Work draft is never offered to Chat's Return on the next `⌘⇧1`. A "Record to Work…" context-menu item and a "Capture to Work" recorder row in Settings → General are the other two doors, and an Ask press while the Work mic is live shows the running capture instead of pushing dictation into a stale error.

**CarPlay.** A permanent "Add to Work" row in both picker states records one note and never browses. `processRecording` forks after compression: the compressed bytes are written and armed in `PendingRetryStore` with destination `.work` *before* the original CAF is deleted, so every refusal below that point costs the words and never the recording; publication marks the entry `.published` rather than clearing it, so recovery still covers the speech hop and the attach. Empty transcripts and refusals below the fork speak "Saved to Work. Add the words on your iPhone." and never re-arm; `isCurrentListen` is re-checked after every suspension on the lane. The attach asks `PendingRetryGuard.stillOwnsCapture` first and writes nothing if it has lost the capture: `attachTranscript` is idempotent only for identical words, so a lane that no longer owns a capture would silently overwrite a retry's transcript with older ones. A startup failure below `.recording` — audio session, capture file, VAD, exhausted engine retries — ends through one terminal that ends the session and then drives the scene itself, dismissing the modal and refreshing the picker onto the "Mic couldn't start" hint, because `state` never leaves `.idle` on that path and an equal assignment publishes no observation.

**Guards.** `WorkDeskWriteOwnershipDriftGuardTests` walks the app target and the watch target and fails any file other than `ConversationStore+Workboard.swift` (and the wrist's `WorkboardCaptureIntent.swift`) that inserts a `WorkMaterial` or `WorkItem`; the one test seam is exempted by the exact squeezed text of its call, never by filename. `WorkboardCopyTruthGuardTests` gained a seventh rule: no `intent.*.title` or `.description` value may contain a platform word, because Apple rejects uploads that name one.

## Founder decisions taken by default (override at QA)

From the plan:

1. Watch: a separate "Save to Work" button, not a mode on Ask.
2. Image gallery pages across every openable image card on the desk, lazily loaded, decode bounded to 4096 px, current ± 1 pages resident.
3. Non-image files open Quick Look (system share and Open With reachable).
4. Mac preview stays a sheet, not a window.
5. Thumbnail backfill: one bounded pass per reconcile.
6. Shortcuts: two actions beside the frozen text action; more than 24 files refused outright; audio files become playable cards everywhere.
7. CarPlay: transcribe after publishing; row label "Add to Work"; row shown with no gateway configured; row-only entry, no note during a live chat session.
8. Mac: ⌃⌘W; text mode opens the compose surface Work-only; the popover holds the "Added to Work" banner; no screenshot on the hotkey; no discovery tip.
9. `sourceDevice` is stamped ("watch" / "carplay") though nothing renders it yet.
10. Watch: no note-only fallback on eviction, because Work entries are never evicted. The note-only path exists solely for an old phone build that returns a transcript without the Work stamp.
11. CarPlay phase-one failure preserves the recording for retry through the same pending-retry lane the headless Shortcut uses.

Raised by the fixnotes and taken the same way:

12. **Images offer no Share anywhere.** Quick Look supplies the system share for files and recordings, but the gallery is not a Quick Look surface. If Share should come back for pictures, its home is the card's context menu in `WorkboardCaptureCanvas.swift` and it needs a NEW key — `common.share` was removed as an orphan and must not be resurrected.
13. **The Work HUD outranks a live chat capture.** A Work capture parked in its retryable-error state keeps `workCaptureIsActive == true`, so a `⌘⇧1` press in that window does start a chat recording whose own HUD is hidden behind the Work HUD until the Work capture finishes. Both fixnotes forbid narrowing their side of this, so it is a founder call: the Work HUD yields, or the desk's Try Again gets a smaller surface than a full-height HUD.
14. **CarPlay's entitlement category is unsettled.** `com.apple.developer.carplay-communication` is granted for communication apps; a memo that reaches no other person is arguably outside it. Mitigation is already in the build — the row draws no desk content, so removing it is a one-row change. Recommendation: raise it in the review notes rather than wait to be asked.
15. **⌃⌘W is assumed unbound.** Verifiable only on the founder's own Mac, against System Settings *and* any launcher (Raycast, Alfred). If it is taken, the hotkey silently does nothing; remap it in Settings → General → Shortcuts.
16. **`width` / `height` stay nil on captured images.** `ImageProcessor.thumbnailOnly` returns bytes only, and filling the columns would mean a second ImageIO read owned by the store. Nothing reads those fields today; the full-bleed tile crops to the slot, which is what image-forward wants anyway.
17. **A recovered capture stamps the recovering device.** `republishRecording` re-publishes parked bytes with the default `sourceDevice`, because `PendingRetryStore` metadata carries no such field — so a wrist or car capture whose phase one failed and is finished later on the phone reads as the phone. Costs nothing while decision 9 holds.

## Open items

Consolidated from every fixnote's open questions and the requests integrate-1 left open. None blocks the build; each is one decision.

| # | Item | Owning file |
|---|---|---|
| U-1 | `TempScratchSweeper.ownedPrefixes` claims `conduck-workboard-intake-` only because `conduck-workboard-` is a prefix of it; a dedicated entry would read better | `Services/AgentDownloadScratch.swift` + `TempScratchSweeperTests` |
| U-2 | The desk sheet's `statusCopy` / `accessibilityStatusMessage` mapping is duplicated by `MenuBarWorkVoiceStatus`; route it through `resolve` so one recorder state cannot grow two sentences | `Views/Workboard/WorkboardVoiceCaptureView.swift` |
| U-3 | Zoom is not reset when a gallery page leaves the residency window, so a page released at 6× briefly shows a magnified thumbnail before the original re-decodes | `Views/Conversation/AttachmentFullScreenView.swift` |
| U-4 | An audio card published through the file lane keeps the generic "File" fallback title; no new key was minted | `Services/Workboard/WorkCaptureDrainer.swift` |
| U-5 | macOS preview copies live up to ~48 h in `tmp`, because the sweeper reads the container's creation date rather than each copy's | `Services/AgentDownloadScratch.swift` |
| U-6 | `PreviewedFile` is deliberately not `Sendable` (it stores a `@MainActor` closure); a future off-main producer must build it on the MainActor, never add `@unchecked Sendable` | `Views/Components/FilePreviewCoordinator.swift` |
| U-7 | A file card's extracted text is no longer displayed — Quick Look renders the file instead. Looks like a strict improvement; flagged because it is a visible deletion | `Views/Workboard/PersonalWorkbenchView.swift` |
| U-8 | The image-forward availability glyph sits top-leading at both footprints, where the text layout mirrors to trailing at large. Two lines to move | `Views/Workboard/WorkboardCaptureCanvas.swift` |
| U-9 | The image-forward caption drops the kind line and the `detail` preview a large glyph card carries; VoiceOver still hears both | `Views/Workboard/WorkboardCaptureCanvas.swift` |
| U-10 | Copy rule (7) cannot see an intent title written as a bare-English literal, as `ConverseIntent` and `CheckNetworkIntent` do; closing it needs a source-side literal scan | `ConduckTests/WorkboardCopyTruthGuardTests.swift` |
| U-11 | The ownership guard scans directories, not target membership: a file under `Conduck/Conduck` but excluded from the target is still scanned, and one outside both trees is never seen | `ConduckTests/WorkDeskWriteOwnershipDriftGuardTests.swift` |
| U-12 | A deliberate double-run of the files action is a repair, not a second set of cards — the opposite of `CaptureWorkboardIntent`'s fresh-id choice. Dropping the derivation loses the crash-repair property | `Intents/AddFilesToWorkIntent.swift` |
| U-13 | The record action returns as soon as the sheet is asked for, not when the recording is saved, so a shortcut continues while the recorder is still up | `Intents/RecordWorkNoteIntent.swift` |
| U-14 | Refusals name the first offending file only; reporting all of them needs a list the Shortcuts error surface renders badly | `Intents/AddFilesToWorkIntent.swift` |
| U-15 | The files action accepts no bare URL or text by design — `.item` covers files and the text lane is already frozen elsewhere | `Intents/AddFilesToWorkIntent.swift` |
| U-16 | `publishFileCapture` refuses the whole set when one source is unreadable; the share extension instead publishes what it can and reports the misses | `Services/WorkCaptureInbox.swift` |
| U-17 | Should "Save to Work" survive the "Enable on Watch" master switch? Gated like Ask today; the argument the other way is that a Work note reaches no AI | `ConduckWatch Watch App/Views/WatchNoteView.swift` |
| U-18 | `refuseAskIfBusy()` logs `"ask.refused"` for a Work refusal too, so the breadcrumb is mislabelled on that lane | `ConduckWatch Watch App/Views/WatchNoteView.swift` |
| U-19 | `captureDestination` is not read by the UI; the screen is destination-scoped by construction, and a belt-and-braces render guard could deadlock on a timing difference | `ConduckWatch Watch App/Views/WatchWorkCaptureView.swift` |
| U-20 | A cancel landing inside the words-only write keeps the note and fails the claim as `.superseded` — a deliberate asymmetry with Chat, where a cancel drops everything | `ConduckWatch Watch App/Services/WatchRecordingService.swift` |
| U-21 | An empty transcript on the words-only path parks the entry, and Work entries never age out; a permanently old phone plus a silent recording would sit at capacity | `ConduckWatch Watch App/Services/WatchRecordingService.swift` |
| U-23 | If both a capture id and its escape id name cards of another kind, the relay lane has no exit and re-fires forever; the recovery lane answers that state with a fallback note, this one cannot | `Services/AppleSpeechRelayCoordinator.swift` |
| U-24 | The context-menu item reads "Record to Work…" in both input modes, though text mode opens a compose surface rather than a microphone | `MenuBar/MenuBarController.swift` |
| U-25 | While a Work capture is busy the status item shows the Work glyph even if a chat reply is in flight, suppressing both status dots for that window | `MenuBar/MenuBarController.swift` |
| U-26 | The "Added to Work" acknowledgement is sticky until the next Work action clears it, surviving a popover close; `popoverDidCloseHook` is where an expiry would go | `MenuBar/DictationPopoverView.swift` |
| U-27 | A parked Work composition has no visible home until the hotkey is pressed again — nothing in the popover says unsaved Work words exist | `MenuBar/MenuBarCoordinator.swift` |
| U-28 | `workboard.voice.privacy` runs to four `.caption2` lines in a 340 pt popover. It is the honest sentence and the copy guard pins its content | `Conduck/Conduck/Localizable.xcstrings` |
| U-29 | The CarPlay `saving` state is brief, so a fast desk write reads as "Thinking… → Saving… → Thinking…". Collapsing the second `saving` into `processing` is one line | `CarPlay/CarPlayRecordingService.swift` |
| U-31 | `common.share` is deleted. A returning Share control mints a fresh key rather than resurrecting it — a reused row inherits translation memory written for a different grammatical role | `Conduck/Conduck/Localizable.xcstrings` |
| U-32 | The new watch rows carry no `comment`, because no call site passes one. Adding translator context is a per-call-site change, not a catalog edit | `ConduckWatch Watch App/Localizable.xcstrings` |
| U-33 | Carried from the previous handoff and still open: `WorkCaptureRetryCoordinator.swift` has zero callers and the tree compiles without it — delete, yes or no | `Services/Workboard/WorkCaptureRetryCoordinator.swift` |
| U-34 | Images offer no Share on any surface, and this is the one round-2 finding left open (`desk R1`). Its home is the card's context menu, gated on `WorkboardCardActionPolicy.allows(.open, …)`, fed by `makeDisposablePreviewCopy`, under a NEW key `workboard.material.share` — never the retired `common.share`, and never `AttachmentFullScreenView`, whose Chat gallery deliberately has none | `Views/Workboard/PersonalWorkbenchView.swift` |
| U-35 | Staging doubles peak scratch for a URL-backed Shortcut set — about 1 GB at the 512 MB envelope ceiling — because the snapshot and the queue's copy are resident together. The lever is a move entry point on `WorkCaptureInbox`, not taken because that publisher has three other callers | `Intents/AddFilesToWorkIntent.swift` |
| U-36 | A relay that succeeds with an empty transcript — a genuinely silent clip — is indistinguishable on the wire from a settled transcription failure, so both end on "Saved to Work. Add the words on your iPhone." rather than a clean save line | `ConduckWatch Watch App/Views/WatchWorkCaptureView.swift` |

## Release gates

Carried from `desk-cloudkit-handoff.md`, all still binding:

1. **Deploy BOTH containers' schemas to CloudKit Production** before any release carrying these entities — the Core half (model 16 plus `WorkMaterial.contentHash`) to `iCloud.ai.gigaduck.agentrelay`, and `WorkMaterialBlob` to `iCloud.ai.gigaduck.agentrelay.blobs`. A CloudKit field can never be withdrawn, and a container whose Production schema is missing syncs in debug and silently not in TestFlight or the App Store.
2. **Gate 2 — founder signed-device QA**, release-blocking for byte sync: two signed devices on one iCloud account plus the Mac. `desk-cloudkit/spike-fixnote.md` §(c) (18 steps) and the previous wave's 81 fixnote items, plus the script below.
3. **The Gemini WAV canary** (`Conduck-Private/scripts/validation/`) — the branch labels WAV honestly where it used to send it as `audio/mp4`.
4. **Never push unasked.** When this branch is pushed it lands in the PUBLIC repo `GigaDuckAI/conduck`. Nothing under `docs/qa/` contains secrets, but the fixnotes are internal working notes — decide whether they travel.
5. **Distribution and provisioning profiles must name the second iCloud container** (`…blobs`). A profile that predates it produces a build that launches, logs a missing entitlement, and silently never syncs payloads — which looks like a sync bug, not a signing one.

New with this wave:

6. **Name the CarPlay Work row in the App Review notes** (open item 14 above). It is one paragraph, and it is much cheaper than a rejection.
7. **Gate 5 of the previous handoff is closed**: the public README documented no Work desk. It now carries a Work paragraph naming every door.

## Founder QA script

Ordered, grouped by surface, and the first step is the irreversible one. Failure cases are named; "must be true" is the assertion. Where a step says *known behaviour*, it is a decision above, not a bug — report it only if you dislike it.

### First, once, before anything else

1. **Upgrade.** On the OLD build, park a Work voice note offline. Install this build. Go online and retry. *Must be true:* one playable card carrying the words. *Failure:* the card is missing or duplicated, or Diagnostics still reports a waiting recording afterwards. **This is irreversible — the App Group retry container is rewritten on first launch, so it cannot be done after any other step.**

### Mac — the Work desk

2. **Standard image card.** Drop a photo on the desk. *Must be true:* the card IS the photo, edge to edge, name and footer on a dark band. Try a screenshot of a blank document. *Failure:* white text on white photo.
3. **Large, then small.** Card menu → Card Size → Large: same treatment, wider. Narrow the window until four columns are impossible — it falls back to the standard footprint and is still a photo. Card Size → Small: back to a 30 pt thumbnail with one line of name beside it. *Failure:* a caption over the photo at small.
4. **Non-image cards are untouched.** A typed note, a dropped PDF, a link. *Must be true:* exactly as before this branch — glyph, name, preview text, footer, no scrim.
5. **Hover.** The `…` corner still fades in over a photo card, in the same corner as on a text card; the card still lights and still opens on click.
6. **An unavailable card refuses the tap.** Easiest on a second device right after capturing on the first. *Must be true:* the glyph is visible ON the photo (dark disc, top-left) and clicking does nothing — no sheet, no gallery, no hover lift. Same for the teal device-local glyph and the amber reattach glyph, where the tap offers Reattach instead.
7. **Gallery, size and controls.** Click a photo. *Must be true:* a sheet at roughly 900×640 with the picture fit on black; pinch or scroll-zoom, drag to pan, double-click to reset. *Failure:* it opens at ~640×480, or the picture is cropped.
8. **Gallery, membership and order.** Swipe or press → / ←. *Must be true:* the desk's pictures, in the desk's order; notes and the PDF are not pages; a card still syncing is not a page. *Failure:* the first swipe lands on the wrong picture.
9. **A >30 MB photo.** *Must be true:* it opens in the SAME gallery at full quality and is one of the pages. *Failure:* a document icon with an "Open File" button.
10. **Quick Look.** Click the PDF card. *Must be true:* the system Quick Look panel, with its own share and Open With — not a Conduck sheet. Then open a recording through its card menu → Open; Quick Look plays it (the card's own transport still plays inline).
11. **Quick Look does not outlive the section.** With the panel open, click **Chats**. *Must be true:* the panel closes immediately. *Failure:* it stays over the Chats window.
12. **Note and link cards** still open the small sheet with a Done button, unchanged.
13. **Escape.** Escape or ✕ from the gallery returns to the desk with nothing left behind.

### iPhone — the Work desk

14. Repeat steps 2–6 on the phone. *Must be true:* the `…` corner is always visible (no hover) and legible over a photo, and long-press still opens the context menu.
15. **VoiceOver.** Swipe to a full-bleed photo card. *Must be true:* it speaks "Image. ‹name›. [Waiting for iCloud…]. Large. 2 of 5" — the same words a glyph card speaks — and the rotor still lists Reattach / Move Earlier / Move Later / card size / Remove. *Failure:* only the name, "image" twice, or an unlabelled image element.
16. **Dynamic Type at maximum.** *Must be true:* the name and footer still sit on the dark band, which grows with them. *Failure:* the name on bare photo.
17. **Gallery.** Tap a photo: a swipeable sheet with page dots; pinch to zoom, double-tap to reset.
18. **Quick Look and its copy.** Tap the PDF card: full-screen Quick Look with a Share button. Dismiss it. *Must be true:* nothing is left in the app's tmp preview container (iOS reclaims on dismissal; macOS deliberately does not).
19. **Failure state.** In Airplane Mode, open an image whose bytes have not arrived. *Must be true:* "This image couldn't be opened." with a Retry beneath it.
20. **Backfill.** Background and foreground the app once, then look at a legacy image card that had no artwork. *Must be true:* the thumbnail fills in within a moment — one bounded pass per foreground.

### Mac — menu bar

21. **Pre-flight: confirm ⌃⌘W is free** in System Settings → Keyboard → Keyboard Shortcuts *and* in any launcher you run. If it is taken, the hotkey silently does nothing and step 22 fails for an unrelated reason — remap at step 30 and continue.
22. **Voice mode.** Settings → General → "Ask with" = Voice. Press ⌃⌘W from another app. *Must be true:* the popover opens on a compact Work HUD ("Listening", red dot, timer, Stop and Save, ✕ — no gateway chrome, no destination picker, nowhere the word "send"), you hear the start cue, the menu-bar icon becomes the red record dot. Speak, press ⌃⌘W again. *Must be true:* the HUD resolves to a green "Added to Work. The words came from your speech provider." — the voice lane names the transfer it makes
23. **The acknowledgement is a door.** Click that row. *Must be true:* the main window comes forward on the desk with the new card *already there*, not appearing a moment later.
24. **Click-away is refused.** Start a capture and click another app's window while the red dot shows. *Must be true:* the popover stays open. *Failure:* it closes — that orphans the recording.
25. **Click-away during startup.** Press ⌃⌘W and click another app's window immediately, before the red dot appears. *Must be true:* the popover stays open, the recording starts, and the HUD is live when you look back — the pin covers the whole start, not only the live mic. *Failure:* the popover closing with a microphone coming up behind it.
26. **The summon does not mark a reply read.** Leave an unread Chat reply in the popover, then press ⌃⌘W in voice mode and Esc straight out. Press ⌘⇧1. *Must be true:* the reply is still unread — a Work voice press claims the popover before it shows it. *Failure:* the unread mark gone, spent on a screen that never showed the reply.
27. **Busy mic.** Start a recording in the main window's composer, then press ⌃⌘W. *Must be true:* a red "Microphone is in use by another recording." and no HUD, no recording.
28. **No transcript.** With no STT key (or Airplane Mode on a cloud provider), record and stop. *Must be true:* the HUD stays with the typed error plus Try Again / Record Again / Close — **and the recording is already a playable card on the desk**. Try Again attaches the words to that same card, never a second one.
29. **Text mode.** "Ask with" = Text, press ⌃⌘W. *Must be true:* the compose surface opens headed **Add to Work**, placeholder "Write a note for your desk", Cancel and Add to Work, and no Ask button at all. Return and ⌘Return both save, and the receipt reads "Added to Work. Nothing was sent." — the typed lane is the only one that can promise that.
30. **The retention case — the one that matters.** Press ⌃⌘W, type a private sentence, do NOT save, click outside to dismiss. Press ⌘⇧1. *Must be true:* the Chat surface comes back with the Chat draft, Ask visible, Return sending to Chat. Press ⌃⌘W again: the private sentence is still there under "Add to Work". *Failure:* the private sentence appearing in the Chat composer, or Return on the Chat surface sending it to a gateway.
31. **Cancel** on the Work surface discards those words and brings back the Chat surface with its own untouched draft.
32. **Menu door.** Right-click the menu-bar duck. *Must be true:* "Record to Work…" sits directly under "Screenshot & Ask…" and behaves exactly like ⌃⌘W in the current input mode. "Open Work…" is unchanged.
33. **Ask stands down.** While a Work recording is live, press ⌘⇧1 and ⌘⇧2. *Must be true:* neither starts anything; the popover shows the running Work capture. *Failure:* a red "Microphone is in use" appearing AFTER the Work capture is saved.
34. **Esc** during a Work recording closes the popover and saves nothing.
35. **Remap.** Settings → General → Keyboard Shortcut. *Must be true:* three rows — Ask, Screenshot & Ask, **Capture to Work** (tray icon) showing ⌃⌘W. Rebind it; the new combo works and the old one does nothing.
36. **Hints render your bindings.** With an empty popover and no reply yet, two hint lines: press ⌘⇧1 to talk, press ⌃⌘W to keep a private note — showing whatever you bound, not the defaults. *Failure:* a literal `%@`.
37. **No gateway, still works.** With no gateway configured (or the Keychain locked): ⌘⇧1 refuses with the "nothing to send to" empty state, while ⌃⌘W still records and still saves. *Failure:* ⌃⌘W refusing for a gateway reason — that would defeat the whole lane.
38. **HUD precedence** (*known behaviour*, decision 13). Start a ⌃⌘W voice capture, let its transcript fail so it sits on Try Again, then press ⌘⇧1 and speak. The chat recording DOES start and its HUD is hidden behind the Work HUD until you finish the Work capture. Your call which should yield.

### Shortcuts — iPhone and Mac

39. **Reinstall first.** `appintentsd` indexes actions at install, so delete the app and install this build, or the new actions will not appear.
40. **Add Files to Work.** Shortcuts → Get File (or Select Photos) → Add Files to Work; the parameter should already be wired to the previous result. Run it over 2–3 files including a photo and a PDF. *Must be true:* the dialog says "Added to Work. Nothing was sent." and the result value is the file count. On the desk: one card per file in the order chosen; the photo is an image card with a thumbnail that opens the gallery; the PDF opens Quick Look; an `.m4a` is a playable audio card.
41. **A note beside the files** lands as its own note card.
42. **Refusals.** Run with nothing selected ("Choose at least one file to add to Work."), with 25+ files ("That's too many files to add at once…"), and over a file above 256 MB (the message names it in curly quotes). *Must be true, each time:* the desk gains NOTHING. *Failure:* a literal `%@` instead of the file name.
43. **An unreadable source refuses the run.** Delete a file in Files, then run a shortcut that still names it. *Must be true:* "“x” couldn’t be read, so nothing was added to Work." and the desk gains nothing. *Failure:* a named card with no bytes in it.
44. **An oversized note names the note.** Paste a long document into the Note parameter beside one ordinary file. *Must be true:* "That note is too long to add to Work. Shorten it, then try again." — it must not name the file, and nothing lands.
45. **Replay** (*known behaviour*, U-12). Run the same shortcut twice over the SAME files with the same note. *Must be true:* ONE set of cards. Two runs over different files, or the same files reordered, give two sets.
46. **Same name, same size, different bytes.** Run the shortcut over a `memo.txt` holding "alpha" — one card. Rewrite the file to "bravo" (same length) and run again. *Must be true:* **two** cards, the first still holding "alpha"; a third, unchanged run still leaves two. *Failure:* the first card now reading "bravo" — an identity naming bytes it did not publish.
47. **Edited while it runs.** Run it over a large video and rewrite that file while the action is still working. *Must be true:* whatever lands is internally consistent — the card's bytes are what the card claims — and no earlier card is repointed.
48. **Kill test.** Run it, then force-quit Conduck before opening it. Reopen. *Must be true:* the cards are there — the envelope drains at launch.
49. **Record a Note to Work.** "Hey Siri, record a note to Work in Conduck". *Must be true:* Conduck opens ON the desk with the voice sheet already up; the recording becomes an audio card with its transcript, and no gateway is consulted at any point. Then force-quit and repeat — the cold launch must still land. Run it twice in a row: the recorder opens again and two never stack. Cancel the sheet, switch to Chat and back to Work: no recorder reappears.
50. **Mac.** Both actions appear in Shortcuts on the Mac. Add Files to Work produces the same cards. Run Record a Note to Work with Conduck running quiet (menu bar only, no window), then with a window already open on Chats, then fully quit (⌘Q, no menu-bar duck left). *Must be true, all three times:* a window opens by itself on the desk with the sheet up, within about a second, without your touching the Dock. *Failure:* a note stranded until you open a window by hand.
51. **Editor copy.** *Must be true:* neither action's name or description mentions iPhone, Mac, Watch or CarPlay, and neither says send, dispatch, draft or brief. *Failure:* a raw key like `intent.workAddFiles.title`, or the right words with nothing found by the Shortcuts search field.

### Apple Watch

52. **The launchpad reads right.** Raise the wrist on the Conduck root. *Must be true:* duck, orange **Ask**, a *bordered* **Save to Work** with a tray-and-down-arrow glyph, then **Conversations**. Lower the wrist: the dim duck and "Raise to ask", no buttons. *Failure:* Save to Work drawn prominent — that makes the launchpad a choice instead of an action.
53. **Happy path.** Save to Work → "Starting…" → red ring and timer → speak → Tap to Stop → "Saving to Work…" → **"Saved to Work."** with a success haptic and Done. *Must be true:* within seconds the phone's desk holds a **playable audio card** with the transcript, and the Conversations list is unchanged. *Failure:* a conversation appearing anywhere.
54. **Ask still goes to Chat.** A normal Ask behaves exactly as before, and the desk gains nothing from it.
55. **Deferred.** Phone in Airplane Mode or out of range, then Save to Work and speak. *Must be true:* **"Saved on your watch. It reaches Work when your iPhone is nearby."** — NOT "Saved to Work." Bring the phone back: a local notification "Saved to Work." arrives and the card appears with its audio. *Failure:* the wrist claiming success while the phone is unreachable — stop and report.
56. **Queue full — the eviction check.** With the phone away, record until the queue is at capacity, then try once more. *Must be true:* "Work is waiting for your iPhone. Bring it nearby first.", a failure haptic, an orange triangle, Done — and **every earlier deferred capture is still there** when the phone comes back. *Failure:* the oldest recording silently deleted to make room.
57. **Cancel discards.** Start, speak, tap ✕. *Must be true:* straight back to the launchpad, no card, no later notification. A left-edge swipe while the ring is live must NOT dismiss the screen.
58. **Mis-tap.** Start and double-tap immediately. *Must be true:* "That was too short to save. Try again and speak a little longer." — not a stuck "Saving…".
59. **Busy interlock.** Start an Ask turn; while it answers, go back to the launchpad. *Must be true:* both buttons greyed with "Still answering your last question." Then start a Work capture and press the Action Button mid-recording: the Work capture keeps running and the press is refused with a buzz.
60. **The recording survives a failed transcription.** Point STT at a dead custom endpoint, then record a Work note on the wrist. *Must be true:* the wrist ends on **"Saved to Work. Add the words on your iPhone."** with a success buzz — never an error line — and the phone's desk holds a playable card with the untranscribed default title and no words. That is the feature: the words are optional, the recording is not.
61. **The queue empties on a wordless save.** Repeat step 60 several times, then start another Work capture with the phone right there. *Must be true:* it starts — never "Work is waiting for your iPhone." while every card is already on the desk — and a normal Ask still answers. *Failure:* a queued Chat recording evicted to make room.
62. **Deferred, then settled without words.** Phone in Airplane Mode → Save to Work → leave the screen open. Turn the phone's speech provider off, then Airplane Mode off. *Must be true:* the notification and the open screen both read "Saved to Work. Add the words on your iPhone." *Failure:* a plain "Saved to Work." on a card that has no words.
63. **No duplicates.** Record at the very edge of range so the inline send fails and the file transfer retries. *Must be true:* exactly ONE card. Then kill Conduck on the phone right after the wrist says it is sending, relaunch, and confirm one card — not zero, not two.
64. **Provider independence.** Switch the phone's STT to a cloud provider and repeat step 53. *Must be true:* identical result — a Work capture always relays.
65. **Master switch** (U-17). Turn Conduck off for Apple Watch in iPhone Settings. *Must be true:* the launchpad shows only the turned-off line and Conversations. Say whether you want Work capture to survive that switch.
66. **Small face, large text.** On a 41 mm watch at the largest Dynamic Type, re-run step 55: the deferred sentence scrolls and Done is reachable by crown.

### CarPlay

67. **Rig pre-flight.** `docs/qa/carplay-simulator-rig.md`: CarPlay Simulator on the Mac, iPhone attached by cable. If an earlier run showed `engine.start failed … 1852797029`, reboot the iPhone first; confirm Siri hears you; allow the CarPlay Simulator under Privacy & Security → Microphone. The Simulator cannot prove sync — every "the card is there" step is checked on the iPhone.
68. **The row.** Connect. *Must be true:* the picker shows "New voice chat", then **Add to Work** with a tray glyph, then "Recent" — one row shorter than before on a busy account.
69. **Happy path.** Tap Add to Work, say a sentence, stop. *Must be true:* Listening → Thinking… → briefly **Saving…** → Thinking… → Saving… → spoken **"Saved to Work."** → the voice screen dismisses and the radio returns. *Failure:* a second listen starting after the acknowledgement (this is one-shot), or the radio staying muted.
70. **The card.** On the phone: a playable audio card with the transcript. *Failure:* an untranscribed card with no words — that is step 71's outcome reached by accident.
71. **Words lost, recording kept.** Remove the STT key on the phone, then record in the car. *Must be true:* the spoken line is **"Saved to Work. Add the words on your iPhone."** — not an STT-key sentence, not a re-prompt, not a second listen — and on the phone the audio card is on the desk AND a retry card is offered. Restore the key, tap Retry: the words land on **that same card**.
72. **Airplane mode.** Same as 71. *Failure:* the chat lane's "Something glitched…" copy, or a re-arm.
73. **The microphone cannot start.** Deny or revoke the CarPlay Simulator's microphone (or reproduce the `engine.start` FourCC failure), then tap Add to Work. *Must be true:* the Listening modal dismisses itself and the picker returns showing **Mic couldn't start** / *Tap Add to Work to try again.* *Failure:* the modal sitting there over a dead session whose End button does nothing.
74. **A race for the words.** With the STT key removed, record in the car, then tap Retry on the phone's card while the car still says "Thinking…". *Must be true:* the words land once, from whichever surface got there first, and nothing overwrites them afterwards.
75. **Scratch does not accumulate.** After several runs of steps 71–74, nothing named `carplay_work_*.m4a` is left in the app's temp directory — the lane deletes on every exit rather than waiting for the sweep.
76. **No gateway configured.** *Must be true:* the picker shows "Set up your AI on iPhone first." AND **Add to Work**, and the Work row works end to end. *Failure:* the row missing, or refusing with a spoken line about an AI.
77. **Silence, End, Mute.** Say nothing for ~15 s: the session signs off. Start a note and tap End: nothing is saved. Mute mid-note → "Muted" → Unmute → finish: it still saves. (Rig quirk: in the first session after launching the Simulator, End and Mute can be dead — back out to the CarPlay grid and re-enter.)
78. **The next chat is still a chat.** Immediately after a Work note, tap New voice chat and ask something. *Must be true:* it reaches the AI and speaks a reply. *Failure:* the question landing silently on the Work desk. Then run one ordinary multi-turn conversation, follow-up turn included, and confirm nothing about it moved.

### Cross-surface

79. **The wave did not move Chat.** Mac ⌘⇧1 in text mode, a normal iPhone Ask, and a wrist Ask with the phone out of range and then back. *Must be true:* all three behave exactly as before this branch. *Failure:* anything from them landing on the Work desk.
80. **Nothing on the desk reaches a gateway.** One capture on every new door — Mac ⌃⌘W (voice and text), the wrist's Save to Work, CarPlay's Add to Work, both Shortcuts actions, the share sheet. *Must be true:* each produces a card and the Conversations list is completely unchanged.
81. **Catalogs.** Switch the system language to German and open: the desk, the Mac popover's Work surface, the wrist's Save to Work screen, the CarPlay picker, and the two Shortcuts actions. *Must be true:* nothing shows a raw dotted key. English text in a German UI is expected for new rows and is not a failure; the three spoken CarPlay lines are deliberately English-only, matching the "Talk to you later." baseline.

Then the previous wave's remaining 81 fixnote items and the 18 in `desk-cloudkit/spike-fixnote.md` §(c).

## Standing constraints (any future agent)

Build caches under `~/Library/Caches/gigaduck-builds/<slug>` plus `clean-build-cache.sh <slug>`, and **clean only your own slug** — a `work-*` glob wipe turned another agent's in-flight `xcodebuild` into a phantom failure twice in this wave · **never `rm` anything in an agent session**; move unwanted files into the session scratchpad instead · never `-configuration` on `xcodebuild test` / `build-for-testing` · check the simulator's TCC row before trusting a red audio run · never touch the `Conduck/Configs/Identity-Override.xcconfig` symlink · mirror triplets change byte-identically or not at all · parallel agents never edit `.xcstrings` — one serial copy agent owns both catalogs · **one owner per shared contract type**: where two targets hold literal duplicates of a wire enum, one agent edits both copies in one change and updates the drift guards with them, and no agent writes a temporary stub of another agent's type · docs are present-tense end state, no changelog narration · the "Nobody undo" lists in every fixnote interlock — read the relevant one before changing a mechanism · never rebase this branch; merge only · never push unasked.

## Where things are

`work-usability/plan.md` (the binding plan) · `work-usability/fixnotes/` (the six foundation slices, `integrate-0`, the nine surface slices, both copy agents, `integrate-1`, then each fix round's `fix-r1-*` / `fix-r2-*` notes with `integrate-2` and `integrate-3`) · `work-usability/verify/` (the twelve Codex reports, `codex-r1-*.json` and `codex-r2-*.json`) · `docs/qa/desk-cloudkit-handoff.md` (the previous wave, whose release gates still bind) · `docs/qa/carplay-simulator-rig.md` (the CarPlay rig) · `docs/ai-context/spec.md` and `project-structure.md` (present-tense truth).
