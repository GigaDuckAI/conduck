# Capture surfaces → single desk: map, design, risks

Repo: `/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard`, branch `feature/agent-workboard` @ 651a859. All paths below are relative to that root; prefix with it for absolute.

---

## 1. CAPTURE INVENTORY

**Nine distinct entry points create a `WorkItem` and/or `WorkMaterial`.** Target-selection column is what must change.

| # | Surface | Entry point | Picks target by | Change for one desk |
|---|---|---|---|---|
| 1 | In-app composer (thought) | `WorkboardViewModel.addWorkspaceThought` `ViewModels/WorkboardViewModel.swift:1383` → `addWorkspaceThoughtUnlocked:1392` → `importWorkspaceMaterialsUnlocked:1470` | caller passes `itemID`; the *provisional* id comes from `beginWorkspace(id: UUID())` `:1249` or `WorkboardView.emptyWorkspaceID` (`Views/Workboard/WorkboardView.swift:19`, regenerated `:163`) | Replace both id sources with the fixed desk id. No other change — path already handles "row doesn't exist yet" |
| 2 | Pane-wide drag/drop | `WorkboardPaneDropModifier` `Views/Workboard/WorkboardCaptureCanvas.swift:841`, `handleDrop:935`, installed at `WorkboardDetailView.swift:55`, `WorkboardView.swift:849` and `:884` | `itemID` parameter, threaded from the same two sources | Same: pass desk id at all three install sites |
| 3 | Photo picker / file importer / camera | `WorkboardCaptureCanvas.swift:133` (`fileImporter`), `:139` (`photosPicker`), `:175` (`CameraPicker`), `importPhotos:687`, batch import `:1075` | `item.id` of the canvas's `WorkboardItemSnapshot` | Canvas is constructed with `WorkboardItemSnapshot(id: emptyWorkspaceID)` at `WorkboardView.swift:952` — becomes desk id |
| 4 | Text/link material sheet | `WorkboardTextMaterialSheet.swift:136,148` → `viewModel.importWorkspaceMaterials(_, to: item.id)` `WorkboardCaptureCanvas.swift:156` | same `item.id` | same |
| 5 | Chat → Work | `ConversationThreadView.swift:1375` → `ConversationStore.captureMessageToWork` `Services/ConversationStore+Workboard.swift:242` | **Always mints a new item**, `createWorkItem(id: message.id, captureEnvelopeID: message.id)` `:296-313` | Must append to the desk instead. Keep `message.id` as the *material* id (already used at `:324`, `:356`) for replay idempotency; drop the item mint |
| 6 | Share extension (iOS + macOS) | `ConduckShareExtension/ShareViewController.swift:774-781` writes envelope; drained by `Services/Workboard/WorkCaptureDrainer.swift:111` `persist`, target chosen in `destination(for:)` `:181-224` | **Recents picker**: `ShareView.swift:63-71` (`ShareDisposition`/`WorkDestination`), rows `:366-420`, unwrap `:222-225`, fed by `share-targets.json` (`Constants.shareTargetsSnapshotFileName`, `Utilities/Constants.swift:2087`), published by `Services/ShareTargetsSnapshotWriter.swift:106-176` from `fetchRecentWorkItemSummaries` (`ConversationStore+Workboard.swift:75`) | Delete the destination picker; `targetWorkItemID` becomes vestigial. Drainer's fallback mint `:206-217` must resolve to the desk (details in §7) |
| 7 | Siri / Shortcuts text capture | `Intents/CaptureWorkboardIntent.swift:62` → `createWorkItem` | **No picker at all** — no `AppEntity`/`EntityQuery` for work items; always a fresh item | Route to desk: `addWorkMaterial(kind: .note)` on the desk instead of `createWorkItem` |
| 8 | Voice-with-`.work`-destination (GigaAction + retry) | `Intents/ConverseIntent.swift:456-462` → `Services/Workboard/WorkCaptureRetryCoordinator.swift:38` → `WorkCaptureInbox.publishAppCapture` (`Services/WorkCaptureInbox.swift:198/218`) → drainer | envelope built with **no** `targetWorkItemID` (defaults nil, `Models/WorkCaptureEnvelope.swift:140`) → always a new item | Set desk id, or fix it in the drainer |
| 9 | macOS menu bar "save to Work" | `MenuBar/MenuBarCoordinator.swift:1697` `saveQuickDraftToWork` → `publishAppCapture:1708` | same as #8 — nil target | same |
| 10 | **Watch** text capture | `ConduckWatch Watch App/WorkboardCaptureIntent.swift:133-141` → `createInertWatchWorkboardCapture:76-103` | **Raw `NSEntityDescription.insertNewObject(forEntityName: "WorkItem")` `:91-98`**, bypasses `ConversationStore+Workboard` entirely (that file is not in the Watch target — `project.pbxproj:210-282` exception list) | Must upsert-by-desk-id: fetch the desk row first, insert a `WorkMaterial` if found, else insert both. Cannot reuse the shared store code without adding the file to the Watch target |

**Not capture surfaces** (verified negative): CarPlay (`Conduck/CarPlay/*` — zero `WorkItem`/`Workboard` hits; it is a scene of the main target, `Info.plist:80-84`, not its own target) and the only WidgetKit target `ConduckWatchExtension`, whose single widget invokes `RecordNoteIntent` (`ConduckWatch/ConduckWatchControl.swift:21`), a Chat lane. **No watch→phone WCSession Workboard path exists** — the watch writes Core Data locally and relies on `NSPersistentCloudKitContainer` mirroring.

Xcode targets (7, `Conduck.xcodeproj/project.pbxproj:488-640`): `Conduck`, `ConduckWatch Watch App`, `ConduckWatchExtension`, `ConduckTests`, `ConduckShareExtension`, `ConduckShareExtensionMac`, `ConduckWatchTests`.

---

## 2. WORKITEM SHAPE

Entity `WorkItem` (`Models/Conversations.xcdatamodeld/Conversations 15.xcdatamodel/contents`, current per `.xccurrentversion`), **all attributes optional, no relationships** — Workboard rows link by UUID attribute so deletes never cascade (`ConversationStore+Workboard.swift:9-11`):

`boardOrder` Int64 · `captureEnvelopeID` UUID · `completedAt` Date · `constraints` String · `context` String · `createdAt` Date · `currentDispatchID` UUID · `desiredOutcome` String · `dueAt` Date · `id` UUID · `isPinned` Bool · `objective` String · `preferredGatewayRef` String · `title` String · `updatedAt` Date

- **`id` is app-generated** (`WorkItemDraft.id = UUID()`, `Models/WorkboardRecords.swift:229-245`), never a CloudKit record name. There is **no revision column**: the optimistic token is derived from `updatedAt` — `workRevision(for:) = Int64(bitPattern: date.timeIntervalSinceReferenceDate.bitPattern)` (`ConversationStore+Workboard.swift`, used at `:466, :904, :977, :1036, :1072`), mirrored bit-exactly in `WorkboardLiveRepository.revision(for:):326`.
- **State is derived, never persisted** — `WorkItemStateResolver.resolve` (`WorkboardRecords.swift:109-134`); only `completedAt != nil` produces `.done`.

**Creates** (9): `createWorkItem:34` · `createWorkItemWithInitialMaterial:709` · `captureMessageToWork:296` · `duplicateWorkItem:583` · `WorkboardLiveRepository.saveDraftAsCopy:653` · `WorkboardLiveRepository.importMaterial:733` · `WorkCaptureDrainer:207` · `Intents/CaptureWorkboardIntent.swift:62` · watch raw insert `WorkboardCaptureIntent.swift:91`.

`createWorkItem` is already **idempotent on both identities** — returns the existing row untouched if `captureEnvelopeID` or `id` matches (`:40-48`).

**Lists**: `fetchWorkItems():66` → private `fetchWorkItems(itemID:captureEnvelopeID:):1582`, sorted `isPinned` desc then `updatedAt` desc (`:1597-1600`); materials fetched `workItemID IN itemIDs` sorted `sequence, createdAt` (`:1605-1610`). Bounded picker read `fetchRecentWorkItemSummaries:75` (predicate `completedAt == nil`, `:83`; over-fetches `limit*4` and de-dupes by id, `:88-103`). Single reads `:108`, `:112`.

**Deletes**: `deleteWorkItem:666` — removes every `WorkMaterial`+`WorkDispatch` with matching `workItemID` (`:672-683`), then **every** `WorkItem` row with that `id` (`:684-689`), and reclaims vault keys (`:693`). UI path: `WorkboardViewModel.requestDelete:1796` → `performConfirmation:1894`.

**Arrangement is flow-based, not coordinate-based.** `WorkboardMosaicLayout.swift:32-34` maps `WorkMaterialCardSize` {small, standard, large} to spans {1×1, 2×2, 4×2} packed into a column grid; order is `WorkMaterial.sequence`. There are no persisted x/y. "Drop/arrange/resize" = `reorderWorkMaterials:1059` + `setWorkMaterialCardSize:1106`.

---

## 3. SINGLE-DESK REPRESENTATION — recommend (a), fixed UUID

**Recommendation: a well-known compile-time UUID, with *no* dedup pass at all.** The existing projection already produces the correct merged desk, which is the decisive fact:

1. `deduplicatedWorkItems` (`:1690-1705`) collapses rows sharing an `id` to one logical row, newest-wins on `(updatedAt, createdAt, title)` — **without deleting either CloudKit record** (`:1685-1689`).
2. Materials are fetched by `workItemID IN itemIDs` (`:1606`) where `itemIDs` is the *deduplicated* set — so every material written against the desk id is fetched **regardless of which physical desk row its device created**.
3. `deduplicatedWorkMaterials` (`:1707-1729`) keys on `(workItemID, materialID)` — distinct materials all survive. **The material sets union automatically.**

So two devices creating the desk offline yields two physical rows and **one correct desk with all materials**. No merge code, no adopt-oldest sweep, no startup pass.

This is the pattern the codebase already blessed, verbatim, at `ConversationStore+Workboard.swift:297-300`: *"Reusing the source turn as both capture identity and item identity means two offline devices still converge on one logical Work id; fetch and mutation paths below tolerate duplicate physical rows."* Fixed-UUID literal precedent: `QA/QAMode.swift:102` (`C0FFEE00-0000-4000-A000-000000000001`). "Write to every matching row" precedent: `reorderWorkItems:219-221`.

**Why (b) "first item by (createdAt, id) is the desk" is unsafe:** two offline devices produce rows with *different* ids, so materials do **not** union — the losing desk's materials are excluded by the `workItemID IN itemIDs` predicate and silently vanish from the board. It also forces every write surface to read the board first, which the watch (raw Core Data insert, `WorkboardCaptureIntent.swift:91`) and the intents lane do not do today. Reject.

**Concrete rule:**
```
Constants.workboardDeskItemID = UUID(uuidString: "…")!   // one literal, mirrored into the Watch target
```
Every surface writes materials with `workItemID = deskItemID`. Row creation stays lazy (§5). Nothing dedups; the projection does it.

**If pruning is ever wanted** (bounded cost: one spare row per device that captured while offline), it must be a bespoke `WorkItem`-row-only delete. **Do not reuse `deleteWorkItem(id:)` — it deletes every material with that `workItemID` first (`:672-683`), which for the shared desk id is the entire desk.** That is the single sharpest footgun in this design.

**Singleton precedent elsewhere in the app:** none in Core Data. Settings/profile singletons live in `SettingsManager` over UserDefaults/NSUbiquitousKeyValueStore, not as a CloudKit-mirrored row, so there is no existing pattern to copy — the dedup-tolerant row above is the closest thing and it is a good fit.

---

## 4. VOICE NOTES — audio is destroyed well before the material exists

**Current pipeline (phone):**
1. `Services/AudioRecorder.swift:69-78` — `AVAudioRecorder` → `temporaryDirectory/conduck-recorder-<uuid>.m4a`, **48 kHz mono AAC**, `.high`.
2. `AudioRecorder.stopRecording():146` reads to `Data`, **`:149` deletes the file immediately**.
3. `Services/InAppAudioRecorder.swift:298` → `AudioCompressor.compress` (16 kHz mono, AAC out `AudioCompressor.swift:388-392`, WAV fallback `:198-204`); scratch files removed by `defer` `:187-190, :279-282`.
4. `InAppAudioRecorder.swift:307-314` writes `temporaryDirectory/conduck-inapp-<uuid>.<ext>` — **this is the last surviving audio artifact**.
5. It is deleted on every path: `:368, :383, :414`, `defer :435` (Apple in-process), and for cloud/BYO by `STTClient.transcribe`'s **first line** `defer { removeItem(audioFileURL) }` (`Services/STTClient.swift:191`).
6. Transcript returns to `WorkboardVoiceCaptureView` (`Views/Workboard/WorkboardVoiceCaptureView.swift:22` constructs `InAppAudioRecorder(retryDestination: .work)`), handed to `onTranscript` at `WorkboardCaptureCanvas.swift:163-172`, which only writes an **in-memory composer draft** (`setWorkspaceComposerDraft`, `WorkboardViewModel.swift:1229`).
7. The material is minted much later by `flushWorkspaceComposer:1432` → `addWorkspaceThought:1383` → `WorkboardViewModel.swift:1399-1403` as **`kind: .note`**.

**So: no, the audio is not on disk at material-creation time** — it is gone by step 5, and the material is minted at step 7 after arbitrary user delay (or never, if the draft is discarded). `WorkMaterialKind.transcript` (`WorkboardRecords.swift:352`, "Audio itself is not retained") is declared and defensively switched on (`ConversationStore+Workboard.swift:1312`, `WorkBriefPromptBuilder.swift:103`, `WorkboardLiveRepository.swift:401`, `WorkboardDispatchCoordinator.swift:283`) but **never constructed in production** — only in tests.

**Minimal change to keep the audio:**
- Capture the compressed file at `InAppAudioRecorder.swift:307-314` before the STT hop consumes it — copy it into `WorkAssetVault` (`Services/Workboard/WorkAssetVault.swift`) and surface the vault key alongside the transcript, letting the existing `defer` deletes stand unchanged. Do **not** move/retain the temp URL: three separate `defer`s assume ownership of it.
- Mint the material immediately at that point (not at composer-flush) via `addWorkMaterialFile(draft, from:byteSize:to:)` (`ConversationStore+Workboard.swift:854`), `kind: .file` or a new `.audio` raw value — `kind` is a plain String column, so **no `.xcdatamodel` version bump is needed**; `WorkMaterialKind(stored:)` already falls back to `.unknown` for older builds (`WorkboardRecords.swift:356-358`).
- Transcript goes in `textContent` (already present on the entity) with `caption`/`title` from `WorkboardWorkspaceCaptureLogic.noteTitle`.
- **Byte-sync caveat:** `addWorkMaterialFile` hard-codes `storageMode: .localVault` (`:879`), which by definition syncs *metadata only* (`WorkboardRecords.swift:366-369`). Audio cards will be device-local until the storage seam moves to `.syncedPayload`; that is the same change every other file card needs, not audio-specific.
- **Playback:** reuse `Services/TTS/SpeechPlayer.swift:137-169` — `AVAudioPlayer(data:)` + `AVAudioPlayerDelegate` completion. Nothing in the app currently plays back a user's own recording (only synthesized TTS), so the card UI is new.

**Watch voice:** records to `temporaryDirectory/watch-capture-<uuid>.m4a` (`ConduckWatch Watch App/Services/WatchRecordingService.swift:956-975`, same 48 kHz mono AAC), then either uploads bytes to cloud STT (`:1363-1370`) or ships the clip to the phone through `AppleRelayPendingQueue` (`AppleRelayPendingQueue.swift:143-192`) + `WCSession.sendMessage`/`transferFile`. The phone deletes the received file on every exit (`AppleSpeechRelayCoordinator.swift:340-342`), replies **text-only** (`:565-603`), and the watch feeds the transcript into `startConverseHop` (`WatchRecordingService.swift:1892`) — **Chat, not Workboard**. There is no watch voice→Work lane today; making one is new work (the watch's only Work lane is the text intent, §1 #10).

---

## 5. EMPTY / FIRST-RUN — recommend lazy creation on first capture

**Today:** with zero items, `WorkboardView.swift:891-921` `emptyBoard` renders `captureWorkspace(id: emptyWorkspaceID, …)` — a **purely in-memory provisional canvas**. `emptyWorkspaceID` is `@State private var emptyWorkspaceID = UUID()` (`:19`), rotated when its item materializes (`:163`). The row is published only when the first material lands: `WorkboardLiveRepository.importMaterial:709-714` routes `expectedRevision == 0` + absent owner to `createWorkItemWithInitialMaterial:733-745`, which writes owner **and** first material in one Core Data save (`ConversationStore+Workboard.swift:760-797`) so a cancelled or unreadable drop leaves no ghost card (`WorkboardViewModel.swift:1491-1494`).

**Recommendation: keep exactly this, with the fixed desk id substituted for `emptyWorkspaceID`/`beginWorkspace()`.** Lazy wins on both axes:
- It reuses a mechanism that is already correct and tested, with zero new creation code.
- Eager creation at first Work visit mints an empty desk row on **every** device the user opens Work on, maximizing duplicate physical rows for no benefit. Lazy creation only duplicates when two devices genuinely capture while both offline.

The provisional-canvas concept survives as "the desk before its first material" — the UI difference is that the id is stable instead of rotating.

---

## 6. TITLE / NAVIGATION

Title display sites:
- `Views/Workboard/WorkboardDetailView.swift:61-64` — `.workbenchNavigationTitle(Text(verbatim: item.displayTitle), …)`. **This is the one that must stop showing a per-item title.**
- `WorkboardView.swift:657-658` "Work" · `:874-880` "All Work" (the overview) · `:963` provisional canvas title · `:947` large-title `Text(title)` in `captureWorkspace`.
- Cards/rows: `WorkboardComponents.swift:260`, `:396` (a11y label); briefing `WorkboardBriefingView.swift:175, :217`; dispatch sheet `WorkboardDispatchSheet.swift:87`; drop overlay caption via `WorkboardCaptureDestination.existingWork(item.displayTitle)` (`WorkboardCaptureCanvas.swift:89`, `WorkboardDetailView.swift:28`).
- Modifier itself: `PersonalWorkbenchView.swift:38-64`.

`displayTitle` (`WorkboardViewModel.swift:272-285`) falls back title → first line of objective → "Untitled brief".

**Should show instead:** the static section title — "Work" (`workboard.title`, `WorkboardView.swift:658`) — on the single desk, and the "All Work" overview (`:874-880`) plus `WorkboardProjectCanvas` (`:865`) disappear entirely along with the project shelf (`:1063-1093`) and the sidebar rows that host the per-project actions.

**Rename must be removed, not just hidden:** `WorkboardViewModel.requestRename:1807` / `commitRename:1820` and the alert at `WorkboardView.swift:264`. Also drop the drop-overlay's `existingWork(title)` copy in favour of a title-free string (`WorkboardCaptureCanvas.swift:911-918`).

---

## 7. RISKS

**a) First-capture race becomes reachable (the one real new bug).** `createWorkItemWithInitialMaterial` **throws** `.staleRevision` when the row already exists (`ConversationStore+Workboard.swift:761-763`), and `importMaterial` only calls it after seeing `fetchWorkItem(id:) == nil` (`WorkboardLiveRepository.swift:703-714`). Today each provisional canvas has a fresh UUID so the window is unreachable; with one shared id, a VM capture racing a drainer/intent that just created the desk fails the user's capture (mapped to `.staleDraft`, `:768-770`). `workInitialMaterialClaims` (`:716-720`) serializes but does not resolve it — the loser still throws. **Fix: make the "already exists" branch fall through to inserting just the material, or have `importMaterial` catch `.staleRevision` and retry as an append.** In-app concurrency is otherwise safe: `acquireWorkspaceMutation` (`WorkboardViewModel.swift:1652-1663`) is a single global slot, and batch imports run serially refreshing `current` each pass (`:1507-1535`).

**b) Optimistic-revision contention.** `expectedOwnerRevision` CAS derives from `updatedAt` (`:904`), and every material insert bumps it (`:925`). One desk means every capture contends on one token. Mitigated because the only CAS-passing caller is the VM (serialized by (a)'s lock) — the drainer calls `addWorkMaterial`/`addWorkMaterialFile` with `expectedOwnerRevision: nil` (`WorkCaptureDrainer.swift:159-166`). Keep it that way; do not add CAS to the drainer.

**c) Drainer replay identity breaks if `captureEnvelopeID` is reused.** The drainer's replay check is `fetchWorkItem(captureEnvelopeID: envelope.id)` (`WorkCaptureDrainer.swift:182-189`), and it mints with `WorkItemDraft(id: envelope.id, captureEnvelopeID: envelope.id)` (`:207-217`). Only one desk row can carry one envelope id, so **that mint must become "resolve the desk, `captureEnvelopeID: nil`"** and replay-safety must rest on the deterministic material ids (`Self.materialIDs(for:)`, `:299-329`) plus `addWorkMaterial`'s existing-id short-circuit (`ConversationStore+Workboard.swift:821-826`) — which is already sufficient. The `.done`-target and `fellBackFromUnavailableTarget` branches (`:191-206`) and the "target unavailable" banner copy (`:236-241`) all become dead.

**d) `deleteWorkItem(id:)` must never be used to prune duplicate desk rows** — it deletes every material with that `workItemID` first (`:672-683`). See §3.

**e) Watch lane bypasses everything.** `createInertWatchWorkboardCapture` (`ConduckWatch Watch App/WorkboardCaptureIntent.swift:76-103`) does a raw `insertNewObject(forEntityName: "WorkItem")` + `context.save()` with no idempotency check, because `ConversationStore+Workboard.swift` is not in the Watch target (`project.pbxproj:210-282`). It needs its own fetch-desk-then-insert-material logic, and the desk-id literal must be mirrored there — the file already documents this duplication pattern for `maximumObjectiveCharacters` (`:21-27`).

**f) Envelope mirror files — 3 byte-identical copies**, guarded by `ConduckTests/WorkCaptureInboxTests.swift`:
- `Conduck/Conduck/Models/WorkCaptureEnvelope.swift`
- `Conduck/ConduckShareExtension/WorkCaptureEnvelope.swift`
- `Conduck/ConduckShareExtensionMac/WorkCaptureEnvelope.swift`

Three more mirror pairs exist in the two share-extension dirs (`ShareTargetsSnapshot.swift`, `ShareTargetFilter.swift`, `SharedInboxManifest.swift`) with their own drift tests. Removing `targetWorkItemID` would touch all three envelope copies; **leaving the field in place and ignoring it is the lower-risk move** (the tolerant decoder at `:228-237` already defaults it).

**g) Share-extension sandbox.** The appex cannot read Core Data at all (`ShareViewController.swift:13-14`) — it only writes envelope directories under the App Group and reads the published `share-targets.json`. So the desk id must be a **compile-time constant in the appex too**, or (simpler) the appex writes `targetWorkItemID: nil` and the main-app drainer resolves the desk. Prefer the latter: one authority, no fourth mirror. `ShareTargetsSnapshot.recentWorkItems` (`ShareTargetsSnapshot.swift:139-163`) and `ShareTargetsSnapshotWriter.makeRecentWorkItems` (`:158-176`) then become dead weight — the gateway/conversation halves of that snapshot are still used by the Send lane, so the file stays.

**h) Constants keys touched:** `Constants.appGroupID:38` · `identityNamespace:29` · `iCloudCloudKitContainerID:51` · `shareTargetsSnapshotFileName:2087` · `workboardTutorialSeenKey:212` (`"workboard_tutorial_seen"`, `Constants.swift`) · `WorkCaptureInbox.directoryName "WorkCaptureInbox":65`, `manifestFilename:66`, Darwin name `:73-74` (independently reconstructed in the appex at `ShareViewController.swift:1031-1039` — must stay byte-identical). A new `workboardDeskItemID` belongs here plus the Watch mirror.

**i) No Core Data migration required.** `WorkItem` is retained unchanged; `kind` and `cardSize` are String columns with total, fallback-tolerant decoders (`WorkboardRecords.swift:356-358`, `:388-403`), so an `.audio` kind needs no model 16. `ConduckTests/WorkboardModelMigrationTests.swift` should still be re-run.
