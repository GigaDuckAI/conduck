# copy-ios — iOS/macOS string catalog

## What changed (file + symbol)

`Conduck/Conduck/Localizable.xcstrings` only. No Swift file touched. No watch catalog
touched (c2/c3's rows are the watch agent's).

25 rows added, 5 rows removed. 2273 → 2293 keys. Diff is exactly +275/−55 lines
(11 lines per row), so nothing else in the file moved.

Every added key was grepped in source first and its `defaultValue:` literal read at the
call site — the source literal is the value written into the catalog, and in every case it
matched the fixnote verbatim. Row shape copied from `workboard.menuBar.saved`
(`extractionState` / `localizations.en.stringUnit {state:"new", value}`); the file's
`"key" : {` spacing, 4-space entry indent and missing trailing newline are preserved.

`extractionState` is `extracted_with_value` for compiler-extractable literals and
`manual` for the three rows whose call site interpolates at runtime (Xcode cannot extract
those) — matching the shipped `popover.start.withShortcut` precedent.

### Rows added (key | value | source of the literal)

| key | value | call site |
|---|---|---|
| `attachment.gallery.loadFailed` | This image couldn't be opened. | `Views/Conversation/AttachmentFullScreenView.swift:369` |
| `attachment.gallery.retry` | Retry | `AttachmentFullScreenView.swift:386` |
| `carplay.picker.addToWork.title` | Add to Work | `CarPlay/CarPlaySceneDelegate.swift:614` |
| `carplay.voice.saving.title` | Saving… | `CarPlay/CarPlayRecordingService.swift:231` |
| `carplay.work.notSaved.speak` | Couldn't save that yet. Open Conduck to retry. | `CarPlayRecordingService.swift:1728` |
| `carplay.work.saved.speak` | Saved to Work. | `CarPlayRecordingService.swift:1718` |
| `carplay.work.savedWithoutWords.speak` | Saved to Work. Add the words on your iPhone. | `CarPlayRecordingService.swift:1722` |
| `intent.workAddFiles.description` | Save files to your private Work desk without sending them to an AI. | `Intents/AddFilesToWorkIntent.swift:50` |
| `intent.workAddFiles.error.fileTooLarge` (manual, `%@`) | “%@” is too big to keep in Work. | `AddFilesToWorkIntent.swift:331` |
| `intent.workAddFiles.error.noFiles` | Choose at least one file to add to Work. | `AddFilesToWorkIntent.swift:318` |
| `intent.workAddFiles.error.setTooLarge` | Those files are too big to add at once. Add them in smaller batches. | `AddFilesToWorkIntent.swift:336` |
| `intent.workAddFiles.error.tooManyFiles` | That’s too many files to add at once. Add them in smaller batches. | `AddFilesToWorkIntent.swift:326` |
| `intent.workAddFiles.error.unreadableFile` (manual, `%@`) | “%@” couldn’t be read, so nothing was added to Work. | `AddFilesToWorkIntent.swift:341` |
| `intent.workAddFiles.files` | Files | `AddFilesToWorkIntent.swift:64` |
| `intent.workAddFiles.note` | Note | `AddFilesToWorkIntent.swift:76` |
| `intent.workAddFiles.title` | Add Files to Work | `AddFilesToWorkIntent.swift:44` |
| `intent.workRecordNote.description` | Open Work and start recording a voice note. Nothing is sent to an AI. | `Intents/RecordWorkNoteIntent.swift:40` |
| `intent.workRecordNote.title` | Record a Note to Work | `RecordWorkNoteIntent.swift:34` |
| `menu.recordToWork` | Record to Work… | `MenuBar/MenuBarController.swift:925` |
| `popover.start.workShortcut` (manual, `%@`) | Press %@ to keep a private note | `MenuBar/DictationPopoverView.swift:1347` |
| `settings.mac.general.shortcut.captureToWork.label` | Capture to Work | `Views/Settings/MacGeneralCategory.swift:242` |
| `workboard.menuBar.compose.work.placeholder` | Write a note for your desk | `MenuBar/DictationPopoverView.swift:564` |
| `workboard.menuBar.compose.work.title` | Add to Work | `DictationPopoverView.swift:548` |
| `workboard.menuBar.saved.open.help` | Open Work and see the new card | `DictationPopoverView.swift:1064` |
| `workboard.menuBar.voice.cardMissing` | That recording is no longer on your desk. | `MenuBar/MenuBarCoordinator.swift:1983` |

Note the two `intent.workAddFiles.error.*` rows and `popover.start.workShortcut` carry the
typographic quotes / `’` exactly as the Swift literal writes them, so a `%@`-substituted
string is byte-identical to what the code renders.

The three `carplay.work.*.speak` rows ship `en` only — the same single-language coverage as
the `Talk to you later.` baseline row that `CarPlayVoiceTimingContractTests` measures
against, so the "every spoken CarPlay line ships in the same languages" assertion stays
green.

### Rows removed (all confirmed 0 references anywhere in source, not just Swift)

```
common.share
workboard.material.file.ready
workboard.material.openFile
workboard.material.preview.unavailable.message
workboard.material.preview.unavailable.title
```

`common.share` was orphaned by the a3 preview rewrite (it is referenced at `HEAD` in
`PersonalWorkbenchView.swift:1144` and nowhere on this branch); a3 left the call to the
copy agent, and an unreferenced row is dead weight a translator would still be billed for.

**KEPT deliberately:** `workboard.material.preview.unavailable` (no suffix) is still
referenced at `Views/Workboard/PersonalWorkbenchView.swift:707`. Only the `.title` /
`.message` pair beneath it died.

## New API

None. This slice adds no symbol.

## New strings

All 25 are listed in the table above (`key | value`), all in the **iOS/macOS app catalog**
`Conduck/Conduck/Localizable.xcstrings`. **No watch-catalog row was written here** — the
c2/c3 `watch.work.*` keys belong to `ConduckWatch Watch App/Localizable.xcstrings` and are
outside this slice's ownership.

## Tests

No test file added or changed. Ran the catalog-reading and copy-contract classes with the
iOS recipe (slug `work-copy`), build-for-testing `0` errors:

| class | executed | failures |
|---|---|---|
| `WorkboardCopyTruthGuardTests` | 29 | 0 |
| `WorkCaptureInboxTests` | 22 | 0 |
| `CarPlayVoiceTimingContractTests` | 15 | 0 |
| `WorkShortcutIntentsTests` | 11 | 0 |
| `MacMenuBarWorkShortcutDriftGuardTests` | 10 | 0 |
| **total** | **87** | **0** |

JSON validity re-checked with `json.load` after the write; key count 2293.

## Requests

None outstanding. Two notes for the integrator:

1. If any later slice reworders one of these 25 strings, that is a NEW key — the value in
   this catalog is pinned to the current source literal, and `WorkboardCopyTruthGuardTests`
   walks `workboard.*` in both directions, so a silent edit on one side turns it red.
2. The watch catalog still needs the eleven c3 rows and the six c2 rows. Nothing in this
   slice covers them.

## Nobody undo

- Do not re-add `common.share`, `workboard.material.openFile`, `workboard.material.file.ready`,
  or the `workboard.material.preview.unavailable.title` / `.message` pair. They have no call
  site; a row with no reference cannot be reached and only costs translation.
- Do not delete `workboard.material.preview.unavailable` (the suffix-less key). It is live.
- Do not "fix" the file by letting Xcode rewrite it wholesale — the file has **no trailing
  newline** and uses `"key" : {` spacing; a reformat would bury this diff.
- Do not give the three `carplay.work.*.speak` rows extra languages unless
  `Talk to you later.` gets them too — the timing contract test compares the two sets.
- The `%@` in `intent.workAddFiles.error.fileTooLarge` / `.unreadableFile` /
  `popover.start.workShortcut` is a real runtime substitution; dropping it silently loses
  the file name or the user's actual key binding.

## Founder QA

Everything here is text-only; nothing changes behaviour. What to check:

1. **Shortcuts app → search "Conduck".** Two new actions must read exactly
   *Add Files to Work* and *Record a Note to Work*, with their one-line descriptions
   underneath. Failure case: an action shows a raw key like `intent.workAddFiles.title`, or
   shows the right words but the Shortcuts *search field* finds nothing — that means the
   row is present but the AppShortcut phrase is not.
2. **Add Files to Work → run it with no file chosen.** The error must read
   "Choose at least one file to add to Work." Then run it on a very large file: the error
   must name the file in curly quotes — “MyMovie.mov” is too big to keep in Work. Failure
   case: the sentence shows a literal `%@` instead of the file's name.
3. **macOS menu bar → right-click the status item.** A *Record to Work…* item must sit under
   *Open Work…*. Failure case: the item reads `menu.recordToWork`.
4. **macOS Settings → General → Shortcuts.** The new recorder row must be labelled
   *Capture to Work*. Rebind it to something other than ⌃⌘W, then open the menu-bar popover
   with nothing in it: the second hint line must read "Press ⌥⌘K (or whatever you bound) to
   keep a private note" — the *actual* binding, not ⌃⌘W. Failure case: it shows `%@`, or
   shows ⌃⌘W after you rebound it.
5. **macOS menu bar → press your Capture-to-Work key.** The compose surface header must say
   *Add to Work* and the field's grey placeholder must say *Write a note for your desk* —
   not "message". Save it; the acknowledgement is a button, and hovering it must show the
   tooltip *Open Work and see the new card*.
6. **CarPlay picker.** A row reading *Add to Work* with a tray icon. Record a note: the
   screen says *Saving…*, then the car speaks "Saved to Work." Failure case: silence, or a
   spoken key name.
7. **Work desk → open an image card full-screen, with the phone in Airplane Mode and the
   image not yet downloaded.** The page must show "This image couldn't be opened." with a
   *Retry* button beneath it.
8. **Regression check on the deletions:** open a file card on the Work desk and tap it. It
   must still preview, and when it cannot, the card must still say the existing
   "No Preview" line. Failure case: an empty string or a raw key appears where that line was
   — that would mean the wrong row was removed.

## Open questions

- `common.share` is deleted on the assumption the a3 preview rewrite is final. If a Share
  control comes back to the Work desk, mint a fresh key rather than resurrecting this one:
  a returning control is unlikely to want the bare word "Share" in the same grammatical
  role, and a reused row silently inherits any translation memory attached to the old one.
