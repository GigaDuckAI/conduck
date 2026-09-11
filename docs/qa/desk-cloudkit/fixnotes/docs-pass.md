# docs-pass — coherence pass of the two permanent docs against HEAD (`2c10a54`)

Worktree `/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard`, branch
`feature/agent-workboard`. No commits, no pushes, no build. Files touched: `docs/ai-context/spec.md`,
`docs/ai-context/project-structure.md`, `docs/qa/workboard-worktree-handoff.md`. `AGENTS.md` and
`README.md` left untouched — see §4.

---

## 0. Word counts

| File | Before | After | Delta |
|---|---|---|---|
| `docs/ai-context/spec.md` | 16423 | 16607 | **+184** |
| `docs/ai-context/project-structure.md` | 3352 | 3443 | +91 |
| `docs/qa/workboard-worktree-handoff.md` | 209 lines | 7 lines | −202 lines |

The O-18 spec-size debt is **closed by main's `62caa33` trim**, which the merge brought in: the file
entered this pass at 16423 of 16900 with `GRANDFATHERED=()` empty, not at the 19827 five consecutive
integrations recorded. That is what paid for the settled facts below. Headroom after this pass: **293
words**, and the largest unexempt decision is unchanged at 596 of 650.

---

## 1. Verification — every desk/audio/retry claim in `spec.md`, checked against source

**Nothing was found false.** Each claim below was traced to code before it was left standing.

| Claim (`spec.md`) | Traced to |
|---|---|
| payload within `Constants.workboardSyncCeilingBytes` rides CloudKit, larger stays in the vault | `Services/Workboard/WorkMaterialStoragePolicy.swift:27` — `byteSize > 0, byteSize <= Constants.workboardSyncCeilingBytes` else `.localVault` |
| neither durable nor released until its bytes read back at the length written | `ConversationStore+Workboard.swift:962`, `:1082` (`expectedByteCount == byteSize`), `:1868` ("released only once the new leaf reads back") |
| a card names the bytes it was published with | `ConversationStore+Workboard.swift:1523` (`byteSize` match on the pairing read) |
| a publication dying before its card strands a row nothing may sweep | `ConversationStore+Workboard.swift:1199-1213` — "THE BOUND ON THOSE ROWS… NO SWEEP MAY CLOSE THAT" |
| one process imports, one publishes, behind App-Group locks | `Services/Workboard/WorkMaterialPublicationLock.swift` (`flock`, per-material file) + `Services/WorkCaptureInbox.swift` |
| a claim the app cannot hand back is retaken by the recovery pass | `WorkCaptureDrainer.swift:955-980` (`ImportOwnership`, `recordLostClaim`/`endImport`) |
| a recapture repairs a bytes-less card, never one newer than the capture it replays | `ConversationStore+Workboard.swift:736-740` — `publicationDate = draft.createdAt`, `stamp <= publicationDate` |
| one escape identifier, derived, so every process and replay repairs the same card | `Services/Workboard/WorkMaterialCollisionEscape.swift:39` — UUIDv5 over a private namespace |
| a second refusal is terminal, directory copied aside and verified byte for byte | `WorkCaptureDrainer.swift:595` `retireRefusedCapture`, `:615`/`:654` `holdsRetirement`, rename after verify, acknowledge after rename |
| a voice note is durable and playable before the speech hop; degrades to a note only if its card is gone | `Services/Workboard/WorkVoiceCaptureCoordinator.swift:1-40`, `fallbackNoteID(forCapture:)` at `:450` |
| a surface reserves by name where it made the recording, renews, confirms ownership | `PendingRetryStore.swift:727` `claimNext`, `:780` `claim(id:duration:)`, `:811` `renew`, `:843` `confirmOwnership` |
| the sidecar outranks the index; an unreadable one defers | `PendingRetryStore.swift:63-72` — "THE SIDECAR IS AUTHORITATIVE"; "an UNREADABLE sidecar is evidence of nothing" |

Facts I added were traced the same way before writing:

- held capture exempt from the clock → `PendingRetryStore.swift:104` "a live reservation also exempts its capture from the expiry sweep".
- holder-scoped release/delete → `ContentView.swift:1979-1982` (`clear(_ claim:)` not `clear()`), `InAppAudioRecorder.swift:1078` `handBackUnfinishedRetry` (release, no delete).
- a lane holds a claim, not a second copy of the audio → `PendingRetryLaneReserving` in `InAppAudioRecorder.swift:85-93`; the lane stores `heldRetryClaim`, never bytes.
- Discard reserves before it asks; busy line when all are held; cancel returns → `ContentView.swift:1957-1973` (`claimNext()` then `confirmingPendingRetryDiscard = true`; `pendingRetryBusyMessage` when `claimNext()` is nil and `pendingRetryCount > 0`), `:1993` `releasePendingRetryDiscard` → `release(claim)`.
- two registers of the confirmation → `ContentView.swift:1615` `pendingRetryDiscardKeepsRecording` (`.work` + `.published`).
- headless hold matches the notice it posts → `PendingRetryStore.swift:90-96` — "an intent process that is killed announces a retry at 90 seconds, so a ten-minute hold taken there would tell a person to tap a button the store refuses them for another eight". Written without the number, per `spec.md`'s own rule that a constant's name is written down and its value is not.

---

## 2. `spec.md` — every sentence changed, before → after

**(a) `## Work is one desk, and nothing on it becomes a turn`, line 430 — terminal retirement gained its
crash-repair half (integrate-h §7, f-drainer).**

- BEFORE: `…a second refusal is terminal: its directory is copied aside and verified byte for byte before the queue lets the original go.`
- AFTER: `…a second refusal is terminal: its directory is copied aside and verified byte for byte before the queue lets the original go, one already on disk verified the same way rather than trusted, an interrupted copy kept beside it rather than deleted, and nothing retired ever claimed, requeued or swept.`

**(b) `## Data, secrets, and what leaves the device`, line 487 — the audio bullet, six changes.**

1. BEFORE: `A surface reserves the capture it is finishing, by name where it made the recording, renews while it works, and confirms it still holds before handing the words on, so two surfaces never finish the same one; an unrenewed reservation lapses.`
   AFTER: `A surface reserves the capture it is finishing — by name where it made the recording, the moment it queues it — renews while it works, and confirms it still holds before handing the words on, so two surfaces never finish the same one; an unrenewed reservation lapses, and a held capture is exempt from the clock.`
2. INSERTED: `Every act is scoped to its holder: finishing, recording again and discarding each release or delete only that surface's own capture, and a lane holds a claim rather than a second copy of the audio.`
3. INSERTED: `A capture the queue could not keep is still transcribed and delivered — nothing was saved for anyone else to hold, so the copy in hand is the only one.`
4. INSERTED: `Discard reserves before it asks, so the recording removed is the one on screen; where every waiting recording is held elsewhere it says so and asks nothing, and cancelling hands the capture straight back.`
5. INSERTED: `Its confirmation says what is actually lost: where the desk already holds the recording, only the queue's second copy.`
6. BEFORE: `The headless Shortcut route saves it *proactively*: when the OS kills that process mid-transcription no error path is left to run, and a clip saved in advance is the only way back.`
   AFTER: `The headless Shortcut route saves the recording *proactively* — when the OS kills that process mid-transcription no error path is left to run — and holds it only as long as the notice it posts takes to invite a retry, so it comes back exactly when the person is told to come for it.`
   (Two sentences merged rather than appended: the proactive save and the hold's length are one fact about
   the same process, and writing them apart cost ~12 words for no extra claim.)

**Settled facts from integrate-h §7 I deliberately did NOT put in `spec.md`, with the reason:**

| Fact | Why not |
|---|---|
| "The recording a build before capture identifiers parked is deleted only once its bytes are provably parked under an identifier, and before the last thing that names it" | Confirmable by opening ONE file (`PendingRetryStore.swift`, the ON-DISK SHAPE block already states the read-only legacy path and the copy-under-an-id rule). `check-spec-size.sh`'s own cut criterion is exactly this: a sentence belongs in `spec.md` only if it cannot be confirmed by opening one file. |
| "The retry queue has exactly one way to end, restate or release a capture — a token the store issued — and the seam a capture surface writes through carries the arm and nothing else" | Same rule. `PendingRetryQueueWriting` / `PendingRetryLaneReserving` declare it in one file, and `PendingRetrySurfaceHandoffTests`' census enforces it. An API shape held by a census test documents itself. |
| "The one operation that reads every parked recording at once survives only as the control its replacement is measured against, and a source census forbids any production caller of it" | Purely a test-suite fact. Belongs in that test's header, which already carries it. |
| "The ten-minute figure is out of `spec.md` and lives in `PendingRetryStore` alone" | Meta-fact about a previous edit, already satisfied — the number appears nowhere in `spec.md`. Nothing to write. |
| The copy-guard fact ("pins that row on what it asserts, never on its wording") | A property of `WorkboardCopyTruthGuardTests`, one file. |

---

## 3. `project-structure.md` — four rows, each because a folder's role changed at HEAD

The map is **folder-level by contract** — its own line 3 ("It is a map, not an inventory: it never lists
individual files") and `check-folder-map.sh`'s closing line ("The map is folder-level on purpose. Do not
add individual files to fix this"). **So no per-file rows were added.** See §6 for what that means for the
brief's file list.

1. **`Services/TTS/`** — `SpokenAudioSession.swift` is new in this folder and is NOT read-aloud only: the
   desk's audio card calls it (`WorkboardAudioCardView.swift:282`). The row described the folder as
   read-aloud alone.
   - BEFORE ends: `…The Watch has its own engine behind the same protocol. |`
   - AFTER ends: `…The Watch has its own engine behind the same protocol. The one definition of the iOS spoken-audio session lives here too, because a tapped voice note on the desk is the same kind of output as a spoken reply and two copies of that posture would drift. |`
2. **`Services/Workboard/`** — `WorkMaterialPublicationLock.swift` is new and the row named no lock.
   - BEFORE: `…the device-local vault holding the ones that stay, the drainer that empties…`
   - AFTER: `…the device-local vault holding the ones that stay, the filesystem lock that stops the app and the headless intent process publishing one card's payload at the same instant, the drainer that empties…`
3. **`Conduck/ConduckShareExtensionMac/`** — the mirror set is **four names**, not two. `WorkCaptureEnvelope.swift` was already omitted (pre-existing); `WorkCaptureDirectoryPublisher.swift` is added by this branch and is *behaviour*, not a data type, which is the part the old wording could not cover.
   - BEFORE: `…while the snapshot and manifest types are deliberate verbatim mirrors of the main app's, held byte-identical by a test.`
   - AFTER: `…while the snapshot, manifest and capture-envelope types, and the one publication transaction every inert Work capture is written through, are deliberate verbatim mirrors of the main app's, each held byte-identical by a test.`
   - Verified: `find Conduck -name 'WorkCaptureEnvelope.swift' -o -name 'ShareTargetsSnapshot.swift' -o -name 'SharedInboxManifest.swift'` → 3 copies each; `WorkCaptureDirectoryPublisher.swift` → 3 copies (main app `Services/`, both extensions). merge-main §2 measured the publisher triplet byte-identical, `sha256=777159cc94c1cd9a`.
4. **`Views/Workboard/`** — `WorkboardSyncBannerPolicy.swift` and `WorkboardDeepLinkRoute.swift` are new roles the row did not name.
   - BEFORE: `…the voice-capture sheet and the playable voice-note card it leaves behind, and the one-time tutorial.`
   - AFTER: `…the voice-capture sheet and the playable voice-note card it leaves behind, the sync notice raised for the three account states a person can act on, where a Work deep link lands, and the one-time tutorial.`

**Rows checked and left alone because they are already true at HEAD:** `Services/` (the claim/lease/renewal/
sidecar paragraph f-copy-docs wrote covers `PendingRetryLeaseRenewal.swift` by role); `ViewModels/`;
`Intents/`; `Models/` (model 16 is additive, the row's additive-only rule holds); the `Where to start` Work
rows, which already name `ConversationStore+Workboard.swift` and
`Services/Workboard/WorkMaterialCollisionEscape.swift` — both exist.

**Deleted files that no permanent doc mentioned** (checked, nothing to remove): `WorkboardDispatchCoordinator`,
`WorkboardBriefingBuilder`, `WorkBriefAssistant`, `WorkBriefPromptBuilder`, `BriefWorkboardIntent`,
`WorkboardUploadJournal`, `ChatPlaybackSession`, `WorkboardDispatchSheet`, `WorkboardBriefingView`,
`WorkItemStateResolver`. `grep -rn` over `docs/ai-context/`, `AGENTS.md`, `README.md`, `CONTRIBUTING.md` →
zero hits for every one. No directory was added or removed by the branch, which is why
`check-folder-map.sh` never fired.

---

## 4. `AGENTS.md` / `README.md` — untouched, and why

Grepped both for `workboard`, `Work`, `desk`, `share picker`, `dispatch`, `brief`, `project`. **No sentence
in either file describes deleted machinery or contradicts the single desk.** The only hits are unrelated:
`AGENTS.md:76` "dispatch pool" (xcodebuild timeouts), `README.md:32` "at your desk" (a place, not the
feature), `README.md:172` "adapter build brief" (the published adapter contract). The branch's own diff to
these two files is entirely main's — xcodebuild timeout flags, the plain-HTTP LAN wording, the terms row —
and none of it is desk-related.

Noted, not fixed (outside my ownership — it is an absence, not a false rule): **`README.md` never mentions
the Work desk at all.** It was equally absent at `651a859`, so this is pre-existing rather than branch-caused,
but Work is now a shipped user-visible surface and the public README's surface table
(`README.md:49-52`) lists only Chat capabilities.

---

## 5. `docs/qa/workboard-worktree-handoff.md` — retired, not deleted

209 lines describing projects, an editable brief, an immutable dispatch snapshot, the share destination
picker and `WorkBriefPromptBuilder` (all deleted by this branch) replaced by a 5-line stub. The file is kept
because `docs/qa/desk-cloudkit-handoff.md:98` names it. New content verbatim:

```markdown
# Agent Workboard worktree handoff — retired

The design this note described — projects, an editable brief, an immutable dispatch snapshot sent to a gateway, and a share destination picker — is gone. Work is one desk, and nothing on it becomes a turn.

The live handoff is [`desk-cloudkit-handoff.md`](desk-cloudkit-handoff.md); the binding plan behind it is [`desk-cloudkit/plan.md`](desk-cloudkit/plan.md).

Settled product truth lives in [`../ai-context/spec.md`](../ai-context/spec.md), never here.
```

`docs/qa/desk-cloudkit-handoff.md` was NOT edited by me (the orchestrator owns it). Nothing else under
`docs/qa/` was touched.

---

## 6. Gates — verbatim

```
===== check-spec-cites =====
✓ spec citations resolve — 817 Swift files scanned, 1 quoted
  section name(s), every one a live heading in docs/ai-context/spec.md
exit=0
===== check-spec-size =====
✓ docs/ai-context/spec.md within budget — 16607 words of 16900, 39 decisions,
  largest unexempt one 596 of 650 ("What the app hands over by itself is a policy about opening, not a safety boundary")
exit=0
===== check-folder-map =====
✓ folder map current — 36 Swift source directories, all mapped,
  and every path the map names exists
exit=0
===== check-storage-seam =====
✓ storage seam intact — 817 Swift files scanned, no raw store
  or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift
exit=0
===== git diff --check =====
exit=0
```

**No build was run, and none was needed.** `grep -rl 'spec\.md\|project-structure' Conduck/ConduckTests/
Conduck/ConduckWatchTests/` returns four files — `CustomVoiceEndpointMigrationTests.swift:60`,
`CustomSTTEndpointTests.swift:49`, `RemoteAgent/PairingPayloadTests.swift:7`,
`RemoteAgent/PairingPayloadExportTests.swift:7` — and every one is a **bare-path citation inside a comment**.
None reads the file, none asserts on its content. No test class pins spec or doc text, so
`~/Library/Caches/gigaduck-builds/docs-pass/` was never created and `clean-build-cache.sh docs-pass` was
never needed. No `rm -rf` was run, `Conduck/Configs/Identity-Override.xcconfig` was not touched.

Changelog-narration check over both permanent docs: `grep -in 'no longer|previously|formerly|used to |now
uses|(was |## Changelog|Recent Changes'` returns two pre-existing hits, both describing runtime state rather
than a diff (`spec.md:312` "the failure is no longer the conversation's last activity"; `spec.md:533`
"images can no longer be resolved"). Neither is mine and neither is narration.

---

## 7. Found false or incomplete and NOT fixed, inside or outside my ownership

1. **The brief asked for one project-structure row per new Swift file** (`WorkMaterialCollisionEscape.swift`,
   `WorkMaterialPublicationLock.swift`, `WorkCaptureDirectoryPublisher.swift` ×3, `PendingRetryLeaseRenewal.swift`,
   `SpokenAudioSession.swift`, `WorkboardSyncBannerPolicy.swift`, `WorkboardDeskPresentation.swift`,
   `WorkboardDeepLinkRoute.swift`, `WorkboardCardActionPolicy.swift`, `WorkboardAudioCardView.swift`).
   **I did not do this, and it should not be done.** The document's own line 3 and
   `check-folder-map.sh`'s header and failure text both bind the map to folder level, with the reason stated
   in the script: the previous file-level inventory "reached 111 KB, went 12% incomplete, and nobody
   noticed". The guard's last line before exiting 1 is literally *"The map is folder-level on purpose. Do not
   add individual files to fix this."* Every one of those files landed in an already-mapped folder, so the
   guard was never going to fire; what each file does lives in its own header comment, which `CONTRIBUTING.md`
   requires. I covered the four folders whose ROLE genuinely changed instead (§3). If the orchestrator
   wants per-file rows anyway, that is a decision to change the document's contract and the guard's premise
   together, and it needs the founder.
2. **`README.md` documents no Work desk** (§4). Pre-existing, outside my ownership, flagged for whoever owns
   the public-repo surface before release.
3. **`spec.md:440` says "the preserved-audio path above"** while the audio bullets are at `:487`, below it.
   The referent is most likely `:298` ("A capture refused after the user has spoken is kept wherever the
   surface has somewhere to keep it"), which IS above — but the phrase reads as pointing at the bullet.
   Pre-existing on both sides of the merge; ambiguous rather than false, and repairing it means choosing a
   referent, which is a judgement I did not want to make silently. One word ("earlier" → naming the
   decision) would settle it.
4. **`Views/Workboard/` still holds `WorkboardCardActionPolicy.swift` and `WorkboardDeskPresentation.swift`
   unremarked in the map.** Both are genuinely file-level detail (one decides what a card may offer, the
   other which of four states the surface draws) and neither adds a folder-level role the row does not
   already imply, so they got no clause. Recording the decision rather than leaving it silent.
5. **O-5, O-9 and O-10 remain live and are correctly absent from both permanent docs.**
   `deleteSupersededBlobRows`' horizon (O-5) is an unshipped remedy; `WorkCaptureRetryCoordinator.swift`
   still has zero production callers (O-9) and the map does not claim it has any; the two iCloud banners
   (O-10) are still two, and the `Views/Workboard/` clause I added says "the sync notice" without asserting
   there is only one banner type in the app.
