# chat-capture — plan §A Chat→Work retarget. Code DONE; verified in an isolated COPY of the tree because the shared tree does not compile in a file I do not own.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched (it is a BROKEN symlink in this worktree — `os.path.exists` = False — and the build does not need it). **No `.xcstrings` file opened.** Nothing under `docs/qa/desk-cloudkit/` touched. No mirror triplet touched. Zero call-site touches in the shared tree.

Files I changed, exactly three:
- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` — `captureMessageToWork` only (194 lines → 152; nothing else in the file touched)
- `Conduck/Conduck/Views/Conversation/ConversationThreadView.swift` — **+2 lines, a comment** (§3)
- `Conduck/ConduckTests/ConversationStoreWorkCaptureTests.swift` — the 4 chat-capture cases rewritten to desk semantics
- **NEW** `Conduck/ConduckTests/WorkboardChatCaptureTests.swift` (5 cases, synchronized group, no pbxproj edit)

---

## 1. The flow now

`captureMessageToWork(_:conversationID:)` keeps its signature, its `workMessageCaptureClaims` claim on `message.id`, and its receipt type. Everything it used to decide about a Work ITEM is gone.

```
claim(message.id)
  fetchMessage → fetchConversation
  expectedIDs = attachment ids (+ message.id when the text is non-empty)
  desk        = fetchWorkItem(id: Constants.workboardDeskItemID)      // ONE projection
  existingIDs = desk?.materials.map(\.id)
  wasAlreadyCaptured = !existingIDs.isDisjoint(with: expectedIDs)
  upsertDeskMaterial(note draft, id: message.id)                      // always, if text non-empty
  for attachment in sorted(by: sequence):  upsertDeskMaterial(draft, id: attachment.id)
  receipt(itemID: Constants.workboardDeskItemID, …)
```

| Was | Is |
|---|---|
| `createWorkItem(id: message.id, captureEnvelopeID: message.id)` | **no item mint at all** — `upsertDeskMaterial` creates/adopts the desk row |
| item title from `WorkboardWorkspaceCaptureLogic.title(for:)` / `"Follow up: %@"` | nothing; the desk row's title stays a nil column |
| item objective = the user's short turn, or an inferred sentence | nothing; **the turn's words are ALWAYS a card** (see below) |
| item `context` = "Captured from %@." | the note card's **caption** (same key, same string, new position — §2) |
| item `preferredGatewayRef` = `conversation.backend` | dropped |
| `wasAlreadyCaptured = fetchWorkItem(captureEnvelopeID: message.id) != nil` | the desk already holds one of the ids this turn publishes |
| `addWorkMaterial(_:to: item.id)` ×N | `upsertDeskMaterial(_:)` ×N |
| `sequence: 0` / `baseSequence + offset` | **no `sequence` passed** — the desk write ranks inside its own transaction (`appendRank`), and the publish order (words, then attachments in `sequence` order) is what orders the cards |
| `receipt.itemID = item.id` (one item per turn) | `receipt.itemID = Constants.workboardDeskItemID` |

**The semantics shift you must know about:** `capturesMessageAsMaterial = !isUser || !objectiveFitsOneBriefField` is DELETED. A short user turn used to become the item's *objective* and no card; with no brief field it would have captured **nothing at all** — the person taps "Add to Work" and the desk is unchanged. So the turn's text is now always a note card (when non-empty). That is why the old counts in `ConversationStoreWorkCaptureTests` move by +1 (§5), and it is the one place my change is not behaviour-preserving. It is required by "no objective inference".

**Idempotency / replay.** `message.id` is the note card's id and each attachment keeps its own, exactly as before; `upsertDeskMaterial` is idempotent on `draft.id`, and the `existingIDs` skip keeps `addedMaterialCount` meaning "cards this call actually added". A second capture therefore writes nothing, touches no `updatedAt`, and returns `wasAlreadyCaptured: true` with all three counts at 0 — proven, including at the physical-row level (`_workMaterialRowsForTesting(id:).count == 1`).

**No CAS.** `expectedOwnerRevision` is left nil (desk-upsert §2: only the VM's serialized board path supplies one; a refusal here would drop a capture the person already made).

**Partial reporting is untouched.** The three attachment branches (server reference → `workboard.chatCapture.remote.*`; copyable payload → `.image`/`.file` with bytes; unreadable → `workboard.chatCapture.unavailable.*`) are byte-for-byte what they were apart from the dropped `sequence:`. `referencedOnly` is still incremented when the draft is *built*, so a subsequent write failure cannot hide the fact that a gateway file was only referenced. `failed` still counts a throwing write per material and never aborts the capture.

## 2. One judgement call: the conversation name moved to the card's caption

The item used to carry `workboard.chatCapture.context` = `"Captured from %@."`. With one desk shared by every surface, a card with no trace of its origin is worse than the old per-item context line, so the **same key with the same string** is now the note card's `caption` (it renders through `WorkboardLiveRepository.materialDetail`, ahead of the availability clause). This mints no key and invents no wording; it keeps `workboard.chatCapture.conversation` ("Chat") alive as the untitled-conversation fallback. If the copy phase disagrees, deleting the `caption:` argument is a two-line revert and makes both keys dead.

Card titles are unchanged: `workboard.chatCapture.message` ("Chat message") for a user turn, `workboard.chatCapture.response` ("Chat response") for an agent turn.

**Edge case stated plainly:** a turn with no text and no attachments now publishes nothing and returns an all-zero receipt, so the banner says "Added to Work. Nothing was sent." with nothing added. Before, an (empty) item row was created, so it was equally hollow. I did not add a refusal — that would be new copy and a new error case, neither of which the plan sanctions.

## 3. `ConversationThreadView` — two comment lines, no behaviour change

The result handling already followed the receipt, and the receipt now names the desk, so the toast, the `MessageWorkCaptureNotice`, the banner and the `.openWorkboardDeepLink` post all resolve to the desk with no edit. `PersonalWorkbenchView.routeWorkboardDeepLink` validates the payload UUID and routes to `.work` (desk-vm), so the link opens the desk. Copy is untouched, per my brief.

The only edit is the comment above `presentWorkCaptureNotice(.init(itemID: receipt.itemID, …))` saying why the link resolves to the desk. `MessageWorkCaptureNotice.itemID` stays `UUID?` because nil is still "this was an error, offer no link" — it is not a per-item identity any more, it is the board to open.

## 4. THE BLOCKER — the shared tree does not build, in a file nobody in this wave owns

`build-for-testing` on the shared worktree fails with **4 errors, all in `Conduck/Conduck/Views/Workboard/WorkboardView.swift`**, zero in any file I touched. `WorkboardCaptureCanvas.swift` (capture-canvas agent, mtime 20:17) has collapsed `WorkboardCaptureDestination` to a single `.desk` case, dropped `WorkboardCaptureCanvas`'s `destination:` argument and reduced the modifier to `workboardPaneDropDestination(viewModel:)`. `WorkboardView.swift` (views-core, mtime 20:12, DONE last wave) still calls the old API:

```
WorkboardView.swift:301:38: error: extra arguments at positions #2, #3 in call
WorkboardView.swift:304:27: error: cannot infer contextual base in reference to member 'newWork'
WorkboardView.swift:314:27: error: cannot infer contextual base in reference to member 'newWork'
WorkboardView.swift:314:27: error: extra argument 'destination' in call
```

I waited and retried **three times** over ~20 minutes (`bft-1` 20:14, `bft-2` 20:19, `bft-3` 20:29): identical 4 errors each time, no other error anywhere. `WorkboardView.swift` is not in my ownership and my minimal-touch list is "none", so I did not edit it. The fix is two call sites (§Requests 1).

### How I verified anyway (read this before trusting my green run)
I copied the whole worktree to `…/scratchpad/vtree1` (24 MB, no git operation of any kind), applied ONLY the two-call-site fix to `WorkboardView.swift` **inside that copy**, and built + tested there. The copy carries my three files verbatim (re-synced after my last edit). Nothing in the shared tree was patched to make my build pass, and `vtree1` is a throwaway: **it holds a local-only edit to `WorkboardView.swift` and must never be copied back.** I could not delete it (a bare `rm -rf` is denied by policy and the build-cache script only owns `~/Library/Caches/gigaduck-builds`); it lives in the session scratchpad, not the repo.

## 5. Tests + counts

**`ConduckTests/WorkboardChatCaptureTests.swift` (NEW, 5 cases)** — every one drives the real `ConversationStore(inMemory: true)`, no harness:

| Case | Holds |
|---|---|
| `testCapturingATurnAppendsItToTheDeskUnderTheMessageIdentity` | no Work item exists before the capture; after it exactly one card, `card.id == message.id`, `workItemID == Constants.workboardDeskItemID`, `.note`/`.metadataOnly`, sequence 0, receipt names the desk |
| `testASecondCaptureOfTheSameTurnReturnsTheExistingCardWithoutADuplicate` | second receipt: `wasAlreadyCaptured`, added/referencedOnly/failed all 0; one item, two cards, **every `updatedAt` identical**, ONE physical row for the turn, attachment bytes still readable |
| `testCaptureAppendsAfterTheCardsTheDeskAlreadyHolds` | a card seeded through `upsertDeskMaterial` first → capture lands at sequence 1 on the SAME desk; still one item |
| `testAttachmentsThatCannotBeCopiedAreReportedRatherThanDropped` | local text + gateway reference + empty-image (payload loader skips it) → added 4, `referencedOnlyMaterialCount == 2`, failed 0; the copied card has bytes, both note cards do not, and the two carry DIFFERENT captions (a gateway file and an unreadable file are different problems) |
| `testCaptureMintsNoWorkItemOfItsOwn` | two turns from two conversations → `fetchWorkItems().map(\.id) == [desk]` holding both cards, and `fetchWorkItem(captureEnvelopeID: message.id)` is nil |

**`ConduckTests/ConversationStoreWorkCaptureTests.swift` — 5 cases, still 5.** No case deleted, none renamed, no assertion weakened. What changed and why (all four are assertions of the *pre-desk* truth, now false by design):
- `testJustAppendedMessageCopiesLocalSourcesAndReferencesGatewayFiles`: `captureEnvelopeID == appended.id` → `XCTAssertNil`; `content.objective == "Compare…"` → `""` plus a new assertion that the turn's words are a **card** (`turnMaterial.textContent`); `preferredGatewayRef == "hermes"` → nil; `addedMaterialCount` 3 → **4**; `receipt.itemID == Constants.workboardDeskItemID` added. Every byte-level assertion (image/text payloads, the remote card's `storedKey` non-leak) is unchanged.
- `testRepeatedAndConcurrentCaptureProduceOneItemAndOneMaterialSet`: 10 concurrent captures — `Set(receipts.map(\.itemID)) == [desk]`, exactly one non-replay receipt (unchanged), total added 1 → **2**, and the board is found by `fetchWorkItems()` at the desk id rather than by `captureEnvelopeID`.
- `testZeroByteLocalFileRemainsARealAvailableSource`: `materials.first` → `first { $0.filename == "empty.txt" }` (the note card is now sequence 0). Availability/bytes assertions unchanged.
- `testAnOversizedUserTurnIsCapturedAsAMaterialRatherThanRefused`: the two "objective was not filled with the log" assertions become `content.objective == ""` / `title == ""`; added `material.id == message.id` and `failedMaterialCount == 0`; `textContent == pastedLog`, `.note`, sequence 0 unchanged. Doc comment rewritten present-tense (no brief field exists to be bounded).
- `testTheContentBoundRefusalCarriesCopyAPersonCanActOn`: **untouched** (it exercises `WorkboardStoreError.contentTooLong`, which this lane no longer reaches but `apply(_ content:)` still throws).

**Net for the orchestrator's iOS executed count: +5.**

### Exact result lines (isolated copy `vtree1`, sim `5C851D88-959C-445E-ACC8-A4C6ADB2876C`, derivedData `~/Library/Caches/gigaduck-builds/desk-chat-capture/DerivedDataCopy`, no `-configuration` anywhere)

`build-for-testing` → `bft-copy-2.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
(`bft-copy-1.log` failed with 3 errors, all mine: `'async' call in an autoclosure` — `XCTUnwrap` takes an autoclosure, so each `try await` is now hoisted into its own `let`, matching the house style inbox-lease.md flagged.)

`test-without-building`, six quoted `-only-testing:` flags → `test-copy-1.log`, `** TEST EXECUTE SUCCEEDED **`:

| Class | Result |
|---|---|
| `ConversationStoreWorkCaptureTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.569 (0.571) seconds` |
| `WorkAssetVaultTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.057 (0.060) seconds` |
| `WorkCaptureDrainerTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.119 (0.121) seconds` |
| `WorkboardChatCaptureTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.113 (0.115) seconds` |
| `WorkboardDeskUpsertTests` | `Executed 10 tests, with 0 failures (0 unexpected) in 0.105 (0.108) seconds` |
| `WorkboardPersistenceTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.056 (0.058) seconds` |
| **total** | `Executed 45 tests, with 0 failures (0 unexpected) in 1.020 (1.033) seconds` |

Other gates, run on the SHARED tree:
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 767 Swift files scanned, no raw store or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift`
- `git diff --check` → clean. `git status --short` → no `.xcstrings`, no `Identity-Override`, nothing under `docs/`.
- **NOT run, stated plainly:** macOS build, the full iOS suite, the watch suite, and any run at all on the shared tree — it does not compile (§4). My files contain no platform-conditional code and the watch target compiles neither of them.
- Build cache removed: `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-chat-capture` → `removed: desk-chat-capture`. All five logs are gone with it; re-run if you need them.

---

## Call-site touches

**NONE in the shared tree.** The `WorkboardView.swift` edit exists only inside the throwaway copy `…/scratchpad/vtree1` (§4) and must not be treated as work product.

---

## Catalog

**Keys I ADDED in source: NONE.** Every string this lane emits is a key that already existed. One key MOVED position without changing value: `workboard.chatCapture.context` = `Captured from %@.` (was the Work item's context field, is now the note card's caption — §2).

**Keys I found DEAD** (zero references left in any `.swift` under `Conduck/`, verified by repo-wide grep after the edit; all three were written only by the deleted item-brief inference):

| Key | defaultValue |
|---|---|
| `workboard.chatCapture.followUpTitle` | `Follow up: %@` |
| `workboard.chatCapture.followUpObjective` | `Continue working from this response.` |
| `workboard.chatCapture.longMessageObjective` | `Continue working from the captured message.` |

**Still LIVE in this lane — do not prune on a stale row:** `workboard.chatCapture.conversation` · `.context` · `.message` · `.response` · `.attachment` · `.remote.caption` · `.remote.detail` · `.unavailable.caption` · `.unavailable.detail`, and in the view `workboard.chatCapture.{saved,already,partial,partial.one,remote,remote.one,open}`.

---

## Requests

1. **BLOCKING, serial integration (or the capture-canvas agent):** `Conduck/Conduck/Views/Workboard/WorkboardView.swift` still calls the pre-collapse capture API and is the ONLY reason the shared tree fails to build. Two sites, both mechanical: `:301-305` `.workboardPaneDropDestination(viewModel:itemID:destination:)` → `.workboardPaneDropDestination(viewModel: viewModel)`, and `:310-315` `WorkboardCaptureCanvas(viewModel:item:mode:destination:)` → drop the `destination: .newWork` argument. That is exactly the patch I verified against in the copy, and with it the whole bundle builds clean.
2. **Serial integration / store owner — the second write path is now fully dead in production.** With chat capture retargeted, `addWorkMaterial`, `addWorkMaterialFile` and `insertWorkMaterial` have **no app caller left anywhere** (grep: only `ConduckTests`), and so does `createWorkItem` (the desk row is inserted by `insertDeskRow`). Deleting them is desk-upsert §Requests 2 + desk-vm §Requests 4, but it is bigger than those notes imply: the fixtures in `WorkAssetVaultTests` (5 sites), `WorkboardPersistenceTests` (8+8), `WorkboardDeskUpsertTests` (2), `WorkCaptureDrainerTests` (2) and `WorkboardDeskViewModelTests` (2) build boards with `createWorkItem` + `addWorkMaterial` and would all have to move to `upsertDeskMaterial` — several of them deliberately need a NON-desk owner (`invalidMaterialOwner`, legacy-project-row cases), which the desk op cannot mint. Decide that before deleting, or keep `createWorkItem` as the test-only owner mint and say so at the declaration.
3. **Copy / catalog agent (serial):** delete the three dead keys above; the two `partial`/`remote` toast strings and `workboard.chatCapture.open` are unchanged and still correct for a desk. If you want to reverse §2's caption decision, remove the `caption:` argument from the note draft in `captureMessageToWork` and `workboard.chatCapture.{context,conversation}` go dead together.
4. **Whoever owns `Models/WorkboardRecords.swift`:** `WorkMessageCaptureReceipt.itemID` is now always `Constants.workboardDeskItemID`. It still earns its place as "the board the banner opens", but if you would rather the receipt carry no id at all, dropping the field is a three-line change here plus `MessageWorkCaptureNotice`/`workCaptureBanner` in `ConversationThreadView.swift` (the banner would then post `Constants.workboardDeskItemID.uuidString` itself). I did not do it: `WorkboardRecords.swift` is not mine and the field is not wrong.
5. **ByteSync agent:** chat capture supplies attachment bytes as `WorkMaterialDraft.payload` and nothing else, so it inherits whatever `stageWorkMaterialBytes` decides — wiring `WorkMaterialStoragePolicy` there covers this lane with no chat-specific work. Note this lane is the one that can hand the desk many payloads in a single user action (one turn, N attachments), each its own `upsertDeskMaterial` call and therefore its own claim/stage cycle.
6. **Phase-5 test agent:** `WorkboardWorkspaceCaptureLogic.title(for:)` lost its last *direct* production caller here (it is still reached through `noteTitle(for:)`); `WorkboardWorkspaceCaptureTests` covers it directly, so nothing is uncovered.
7. **Orchestrator:** iOS executed count **+5** (`WorkboardChatCaptureTests`); `ConversationStoreWorkCaptureTests` stays at 5. Watch suite untouched. And please make sure `…/scratchpad/vtree1` is never mistaken for the worktree (§4).
