# ui-docs — `docs/ai-context/project-structure.md` made true at HEAD. PASS, all three guards exit 0.

One file changed: `docs/ai-context/project-structure.md` (`git diff --stat` → `11 insertions(+), 10 deletions(-)`; nine rows rewritten, one row added). No Swift, no catalog, no
`docs/qa/`, no commits/stash/checkout/reset. `git status --short` shows that file and nothing else.

The Codex finding is discharged: **zero** case-insensitive hits remain for `brief`, `dispatch`,
`preflight` or `review timeline` in the whole document. Every surviving `project` / `target` is the
Xcode sense (§Grep justification).

---

## 1. What changed, row by row

Nine rows. Register unchanged throughout — plain prose, present tense, one folder per row, no file
inventories. Numbers are named, never written (`Constants.workboardSyncCeilingBytes`), per the file's
own convention and `CONTRIBUTING.md` §Documentation.

| Row | Was false | Now says |
|---|---|---|
| `Services/Workboard/` | "immutable prompt and dispatch preparation, on-device brief shaping, and deterministic briefing" — all four files deleted | The storage-policy decision, the device-local vault, the capture drainer, the two-phase voice capture, the live adapter. Plus the byte-lane boundary: within `Constants.workboardSyncCeilingBytes` bytes ride the person's private CloudKit; above it they stay in the vault and another device asks for the file. Closes with "no network dependency of any kind" |
| `Views/Workboard/` | "per-project card board … exact dispatch preflight, result-first review timeline and deterministic briefing"; also "material shelf", which no longer exists (`grep -ri shelf` over `Conduck/Conduck` = 0 hits) | The desk plus the Work/Chats shell; one board, mosaic placement, pinned composer, link/note sheets, voice sheet and the playable voice-note card, the one-time tutorial |
| `Intents/` | "inert Workboard capture **and briefing**"; "Work never dispatches" | "inert capture onto the Work desk"; "the Work leg reaches no gateway" |
| `Conduck/ConduckShareExtension/` | "Work can create a new draft or append to a recent open item" | "Work is one desk, so sharing into it is one tap with nothing to choose between"; Chat keeps its destination list |
| `ViewModels/` | "the private Workboard presentation boundary" | "the Work desk's presentation boundary" |
| `Services/` | "the share-sheet inbox and its drainer" read as if one queue and one drainer lived here | "the share-sheet capture queues and the drainer that turns a queued Chat capture into a sent turn", + one clause saying Work's drainer is one folder down |
| Where-to-start: the desk | "The private Agent Workboard or dispatch preflight" | "The Work desk, or a card on it" |
| Where-to-start: **NEW** capture row | absent | Routes a new capture surface to the one desk write, and names the Watch exception the shared-source list forces |
| Where-to-start: schema row | silent on the two-store topology | + one sentence: the model carries two named configurations, `Core` and `Blobs`, and `Blobs` backs a sibling store the Watch never mounts |

**Two stale cites fixed while I was in the routing rows** (item 3 of my brief). The `scripts/` row and
the `Conduck/ConduckTests/` row both pointed at "the verification table in `spec.md`". **`spec.md` has
no table** — that material is now the prose section beginning `## How the rules are enforced`
(`spec.md:~600`, confirmed by `grep -n -i verification docs/ai-context/spec.md` → one hit, a prose
line). Both now point at the document without naming a structure that does not exist. I did not quote
the heading: `check-spec-cites.sh` scans Swift only, so a quoted name here is unguarded and would rot
at the next rewording.

## 2. What I verified against source, not against the plan

Every claim I wrote was checked by `ls` or `grep` in the worktree. The load-bearing ones:

| Claim | Evidence |
|---|---|
| One fixed desk | `Constants.swift:2104` `workboardDeskItemID`; `WorkboardViewModel.swift` header "Work is ONE desk at a compile-time id"; `WorkboardDetailView.swift` header "resolves no item and takes no id" |
| Ceiling constant, not a number | `Constants.swift:2114` `workboardSyncCeilingBytes` |
| Second store, its filename and entity | `ConversationStore.swift:1244` `blobStoreFilename = "ConversationBlobs.sqlite"`; `:1250-1251` `coreConfigurationName = "Core"` / `blobsConfigurationName = "Blobs"`; entity `WorkMaterialBlob` fetched at `ConversationStore+Workboard.swift:1013,1056,1130,1176` |
| The Watch mounts one store, and that omission IS the payload exclusion | `ConversationStore.swift:1478-1503` — `#if os(watchOS) return [core]`, else `[core, blobs]` |
| Vault = the lane above the ceiling, with reattach | `WorkAssetVault.swift` header; reattach is wired in the UI at `WorkboardCaptureCanvas.swift:307,315,321,687,705` |
| Voice notes kept as playable audio | `WorkVoiceCaptureCoordinator.swift` header (publish before the speech hop); `WorkboardAudioCardView.swift` exists and owns its own `AVAudioPlayer` |
| Targetless share capture | `ShareView.swift:350` "Work is ONE desk, so there is no destination to…"; `ShareViewController.swift:775` (iOS) and `:966` (macOS) both send `targetWorkItemID: nil`; `ShareTargetsSnapshotWriter.swift:141` publishes `recentWorkItems` empty |
| Drainer resolves no destination | `WorkCaptureDrainer.swift` header + `:198,229,236` all route to `upsertDeskMaterial` |
| Inbox claim leases | `WorkCaptureInbox.swift` header — claiming rename + lease file + heartbeat |
| One desk write, and the Watch exception | 6 production call sites of `upsertDeskMaterial` in the app target (drainer ×3, intent, voice coordinator, live repository) + `captureMessageToWork` from `ConversationThreadView.swift:1375`. The wrist does **not** call it — `ConduckWatch Watch App/WorkboardCaptureIntent.swift:105` declares its own, and its header says why |
| Board is a mosaic, not board/list | `WorkboardExperience` (`WorkboardView.swift:34-65`) has only `detailColumn`; no sidebar column survives anywhere under `Conduck/Conduck` |

## 3. Where the code contradicts the plan, or a fixnote

Two places. Neither changed what I wrote beyond the wording noted.

1. **The plan's §A "no dedup/merge/prune pass" and the map are consistent, but the capture row I added
   would have been FALSE as first drafted.** Plan §A says "ALL surfaces route through it
   [`upsertDeskMaterial`]" and then, three lines later, that the Watch mirrors the logic locally. Those
   read as one sentence contradicting itself. The code settles it: `ConversationStore+Workboard.swift`
   is not in the Watch target, so the wrist restates the contract. My row now says exactly that rather
   than "every surface", because a reader adding a Watch capture would otherwise look for a call that
   cannot compile there.
2. **The audio card's reattach is a label, not a control** (`WorkboardAudioCardView.swift:646` uses
   `workboard.material.reattach.short` and integrate-c §3.1 records it as non-interactive by decision).
   The general material card's reattach IS wired. I therefore wrote "another device shows the card and
   **asks for** the file" rather than "offers to reattach it", which would have overclaimed on one card
   shape. Not a defect I am reporting — a wording constraint I obeyed.

Nothing else in the tree contradicted plan §A/§C/§D/§B/§E as far as this document's claims reach.

## 4. Guards — exact output lines

```
✓ folder map current — 36 Swift source directories, all mapped,
  and every path the map names exists
```
exit 0.

```
✓ spec citations resolve — 777 Swift files scanned, 1 quoted
  section name(s), every one a live heading in docs/ai-context/spec.md
```
exit 0.

```
✓ storage seam intact — 777 Swift files scanned, no raw store
  or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift
```
exit 0 (run as a sanity check only — my diff cannot reach it).

`git diff --check` → no output, exit 0.

**Reverse-pass note for the next editor:** `check-folder-map.sh` treats every backticked span
containing a slash as a path that must exist. Both new file paths I wrote resolve
(`Conduck/Conduck/Services/ConversationStore+Workboard.swift`,
`Conduck/ConduckWatch Watch App/WorkboardCaptureIntent.swift`), and `ConversationBlobs.sqlite`,
`Core`, `Blobs`, `Constants.workboardSyncCeilingBytes` carry no slash, so none of them is a path
candidate. Do not add a backticked shell command with a slash to this file.

## 5. Grep justification — every surviving hit

`grep -ci -E 'brief|dispatch|preflight|review timeline'` → **0**.

`project` and `target`, all Xcode-sense, all pre-existing except line 130 which is mine:

| Line(s) | Word | Why it stays |
|---|---|---|
| 3 | target | "when the Xcode **target** topology changes" — the file's own scope statement |
| 13 | project | "the words this **project** uses" — the repository, in the README row |
| 24, 28, 32 | project | "The Xcode **project** and all Swift source", the section heading, "The **project** file" |
| 39 | target ×2 | "One **target** covers iPhone, iPad and Mac"; "no scheme or workflow names a visionOS destination… " |
| 51 | target | "every spoken reply on this **target**" — the app target vs the Watch's own engine |
| 72, 92, 94, 96, 100, 102, 106, 108, 112 | project / target | The two build-topology sections: seven targets, synchronized groups, the hand-maintained Watch membership list, `ConduckWatchTests`, the pbxproj footguns |
| 77 | target | "the **target** filter" — `ShareTargetFilter.swift`, a real file in both extension folders, filtering Chat destinations. Live code, not desk drift |
| 78 | target | "see the **target** table below" |
| 130 | target ×2 | **My new row** — "every capture surface in the app **target**"; "that file is not in its **target**" |
| 136 | target | "a file the Watch compiles from the app **target**" |

## 6. Prohibitions I checked myself against

- No changelog narration:
  `grep -niE '\bwas\b|used to|no longer|previously|formerly|now uses|## Changelog|## Recent|## History'`
  over the finished file → **no matches**.
- No literal numbers added. The one quantity I needed is named as its constant.
- No row turned into a file inventory. I named a file only in rows that already name files (the
  Where-to-start table names `ConversationStore.swift`, `Constants.swift`, `AudioRecorder.swift`,
  `Localizable.xcstrings` today) and only where the reader must go there.
- `spec.md` untouched.

---

## Requests

1. **spec.md owner —** the `## How the rules are enforced` section is now the destination two rows of
   `project-structure.md` point at descriptively ("`spec.md` says which rules are upheld by one of
   these rather than by review"). If that section is renamed or split, those two pointers want a
   re-read. I deliberately did not quote the heading, so nothing breaks; it just gets vaguer.
2. **spec.md owner — the two-store fact now appears in BOTH documents.** I put one sentence in this
   file's schema routing row (`Core` / `Blobs`, and the Watch mounting only the first) because a
   person adding an entity has to pick a configuration and no folder tells them that. copy-truth §2
   records that it deliberately kept the SQLite filenames and configuration names OUT of `spec.md` on
   the one-file rule and the size guard. Those two decisions are compatible — mine is a build-topology
   pointer, theirs is a prose-boundary call — but if anyone later wants exactly one home for it, this
   is the row to delete.
3. **Nobody re-add "brief", "project" (product sense), "dispatch", "preflight" or "review timeline" to
   this document.** Same convention copy-truth §Requests 6 asked for on user-facing copy and source
   comments. `check-folder-map.sh` does not police vocabulary — only paths — so this is held by
   convention alone on the docs side too.
4. **Whoever runs the gate:** nothing I changed compiles, so no build or suite is owed on my account.
   The three guard scripts above are the whole of my verification surface and all three pass.
