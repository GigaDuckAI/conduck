# b2-intents — Shortcuts actions for Work (files + voice launcher)

## What changed

**NEW `Conduck/Conduck/Intents/AddFilesToWorkIntent.swift`**

- `struct AddFilesToWorkIntent: AppIntent` — `[.background]`, `[IntentFile]` + optional
  `note`, `Summary("Add \(\.$files) to Work") { \.$note }`, returns
  `ReturnsValue<Int> & ProvidesDialog`.
- `perform()` builds `[WorkCaptureFileInput]` preferring `file.fileURL` (handed over
  unread — f5's publisher holds the security scope and copies), falling back to a
  `file.data` write under `temporaryDirectory/conduck-workboard-intake-<uuid>/`, publishes
  ONE envelope through `WorkCaptureInbox.publishFileCapture`, then drains inline exactly
  as `WorkCaptureRetryCoordinator.publish` does.
- `static func refusal(for:)` — the whole-set refusal rules as a pure function.
- `static func captureIdentity(note:files:)` — UUIDv5 over the note plus, IN ORDER, each
  file's name and size, namespace `A11F0000-0000-4000-A000-000000000001`.
- `enum WorkFileCaptureRefusal: LocalizedError, Equatable` (file scope) — the five
  user-facing refusals, plus an initializer that restates the queue's verdicts.

**NEW `Conduck/Conduck/Intents/RecordWorkNoteIntent.swift`**

- `struct RecordWorkNoteIntent: AppIntent` — `[.foreground]`, no parameters.
  `@MainActor func perform()` calls `WorkVoiceCaptureLaunchRoute.shared.request()` (which
  sets the flag AND posts `.showWorkboardVoiceCapture`) and then posts `.showWorkboard`,
  both in one main-actor turn. It owns no recorder: the in-app Work voice lane is the only
  capture pipeline.

**NEW `Conduck/Conduck/Views/Workboard/WorkVoiceCaptureLaunchRoute.swift`**

- `extension Notification.Name { static let showWorkboardVoiceCapture }`.
- `@MainActor final class WorkVoiceCaptureLaunchRoute` with `static let shared`,
  `request()`, `consume() -> Bool` — the `GatewayFixRoute` shape, minus the
  re-validation (see Nobody undo).

**`Conduck/Conduck/Intents/AppShortcuts.swift`** — two `AppShortcut` entries appended. The
three shipped entries are byte-for-byte unchanged and now pinned by a test.

**`Conduck/Conduck/ConduckApp.swift`** (macOS scene only, beside the existing
`.showWorkboard` row) — `.onReceive(… .showWorkboardVoiceCapture) { openWindow(id: "main") }`.
Nothing else in that file changed.

**`Conduck/Conduck/Services/WorkCaptureInbox.swift`** — inside `publishFileCapture`'s
staging loop only (plus `import UniformTypeIdentifiers`): an entry whose `mimeType` starts
`image/`, or whose `typeIdentifier` conforms to `UTType.image`, is published as
`kind: .image` instead of `.file`. The sanitized `mimeType` / `typeIdentifier` are now
bound to locals (they were inline arguments) because the classification reads them. This
is integrate-0's carried-forward f5 request 2, taken at the publisher instead of in the
drainer so slice A's `.image` branch is untouched.

## New API (exact signatures)

```swift
// Views/Workboard/WorkVoiceCaptureLaunchRoute.swift
extension Notification.Name {
    static let showWorkboardVoiceCapture: Notification.Name   // "showWorkboardVoiceCapture"
}

@MainActor
final class WorkVoiceCaptureLaunchRoute {
    static let shared: WorkVoiceCaptureLaunchRoute
    func request()
    func consume() -> Bool
}

// Intents/AddFilesToWorkIntent.swift
struct AddFilesToWorkIntent: AppIntent {
    static func refusal(for files: [WorkCaptureFileInput]) -> WorkFileCaptureRefusal?
    static func captureIdentity(note: String?, files: [WorkCaptureFileInput]) -> UUID
}

enum WorkFileCaptureRefusal: LocalizedError, Equatable {
    case noFiles
    case tooManyFiles(limit: Int)
    case fileTooLarge(name: String)
    case setTooLarge
    case unreadableFile(name: String)

    init(publicationFailure: WorkCaptureEnvelope.PublicationValidationFailure,
         files: [WorkCaptureFileInput])
}

struct RecordWorkNoteIntent: AppIntent {
    @MainActor func perform() async throws -> some IntentResult
}
```

**For the a2-image-card agent** (the consumer): call `WorkVoiceCaptureLaunchRoute.shared.consume()`
from BOTH an `.onReceive` of `.showWorkboardVoiceCapture` AND the desk's appearance — a warm
app hears the post, a cold launch never does. `request()` fires the notification itself; the
intent posts `.showWorkboard` after it, so the desk becomes the visible destination a beat
after the request is armed.

## New strings

App catalog (`Localizable.xcstrings`); the confirmation dialog REUSES the shipped
`intent.workboardCapture.confirmation` verbatim and mints no key.

```
intent.workAddFiles.title | Add Files to Work | Shortcuts action name for saving files to the private Work desk.
intent.workAddFiles.description | Save files to your private Work desk without sending them to an AI. | Shortcuts action description; must never name a platform (ITMS-90626).
intent.workAddFiles.files | Files | Parameter label for the files a Shortcut hands to the Work desk.
intent.workAddFiles.note | Note | Optional parameter label for a note saved beside the files.
intent.workAddFiles.error.noFiles | Choose at least one file to add to Work. | Shortcuts error when the action is run with no files.
intent.workAddFiles.error.tooManyFiles | That’s too many files to add at once. Add them in smaller batches. | Shortcuts error when more than 24 files are handed over; the whole set is refused.
intent.workAddFiles.error.fileTooLarge | “%@” is too big to keep in Work. | Shortcuts error naming the one file that exceeds the 256 MB per-file ceiling. %@ is the file's name.
intent.workAddFiles.error.setTooLarge | Those files are too big to add at once. Add them in smaller batches. | Shortcuts error when the whole set exceeds the 512 MB envelope ceiling.
intent.workAddFiles.error.unreadableFile | “%@” couldn’t be read, so nothing was added to Work. | Shortcuts error when a chosen file cannot be read; the whole set is refused. %@ is the file's name.
intent.workRecordNote.title | Record a Note to Work | Shortcuts action name for opening Work and starting a voice note.
intent.workRecordNote.description | Open Work and start recording a voice note. Nothing is sent to an AI. | Shortcuts action description; must never name a platform (ITMS-90626).
```

Two call sites interpolate (`fileTooLarge`, `unreadableFile`), so those two rows carry a
`%@` placeholder in the catalog. The `AppShortcut` phrases and `shortTitle`s carry the
existing `// xcstrings` marker style and are extracted by the compiler as their own literal
keys, exactly as the three shipped entries are.

## Tests

`Conduck/ConduckTests/WorkShortcutIntentsTests.swift` (new, 15 tests):

| Symbol | What it asserts |
|---|---|
| `testARequestIsConsumedOnceAndOnlyOnce` | request → consume true → consume false. |
| `testConsumingWithoutARequestAnswersNothing` | a desk mounting for any other reason opens no recorder. |
| `testTheFlagIsAlreadySetWhenTheNotificationIsDelivered` | SET-THEN-POST: an observer reading during the post already sees the flag. |
| `testNoNewIntentTitleOrDescriptionNamesAPlatform` | the four `intent.workAddFiles.*` / `intent.workRecordNote.*` identity rows, read as `(key, defaultValue)` pairs out of the SOURCE, carry no platform word (f6's word set, matched word-ish). |
| `testTheNewIntentsDeclareKeyedIdentityRatherThanBareLiterals` | closes f6's open question 1 for these two files: no `static var title: LocalizedStringResource = "…"` and no `IntentDescription("…")`. |
| `testTheShortcutProviderCarriesTheFrozenEntriesAndTheTwoNewOnes` | the three shipped phrases + short titles pinned as text; the two new entries pinned too. |
| `testNoShortcutPhraseNamesAPlatform` | every `\(.applicationName)` phrase line is platform-free (≥ 9 scanned). |
| `testASetWithinEveryLimitIsNotRefused` / `testAnEmptySetIsRefused` / `testOneFileAboveTheEntryLimitIsRefusedWhole` / `testAFileOverTheFileCeilingIsRefusedByName` / `testASetOverTheEnvelopeCeilingIsRefusedAsASet` / `testAnUnreadableSizeDoesNotRefuseTheCapture` | the pure refusal rules, ceiling-exact. |
| `testTheCaptureIdentityIsDerivedFromTheInput` / `testTheCaptureIdentityIsANameBasedUUID` | a rerun reproduces the id; reordering, a different note and a changed size do not; version-5 + RFC 4122 variant bits. |

`Conduck/ConduckTests/WorkCaptureFileCaptureTests.swift` — ONE test added,
`testAnImageIsPublishedAsAnImageEntryAndOtherFilesStayFiles` (image by mime, image by type
identifier, PDF stays `.file`; all three stay file-backed).

Measured from `~/Library/Caches/gigaduck-builds/work-b2/test3.log` (one
`test-without-building` invocation, five suites, every suite's `Test Suite … started` line
present so no filter passed vacuously):

| Class | Executed | Failures |
|---|---|---|
| `WorkShortcutIntentsTests` (new) | 15 | 0 |
| `WorkCaptureFileCaptureTests` (8 pre-existing + 1 new) | 9 | 0 |
| `WorkCaptureInboxTests` (untouched; pins the intent literals) | 29 | 0 |
| `WorkCaptureDrainerAudioKindTests` (regression on the kind mapping) | 4 | 0 |
| `TempScratchLeafDriftGuardTests` (claims the new temp leaf) | 3 | 0 |
| **Total** | **60** | **0** |

Builds, all `-derivedDataPath ~/Library/Caches/gigaduck-builds/work-b2/…`, no
`-configuration` flag:

| Target | Result |
|---|---|
| iOS `build-for-testing` (sim `04DEF4F5`) | exit 0, **0** `: error: ` |
| macOS `build` (`platform=macOS`) | red on slice D — see "Tree state" |

One test run was lost to the SHARED simulator (`Test crashed with signal kill before
establishing connection` while another agent's run was installing); the retry was clean.

**Tree state.** This slice's files compile clean on both platforms, but the whole-tree
builds were repeatedly red on OTHER slices' in-flight edits — `WatchRecordingService.swift`
(`RelayReply` vs `String`), `PersonalWorkbenchView.swift` (`FilePreviewCoordinator` actor
isolation + a missing `import QuickLook`), and `MenuBarController`/`MenuBarCoordinator`
(duplicate `workVoiceRecorder` / `workCaptureIsActive` declarations). The iOS
`build-for-testing` above went green once the first two cleared. The macOS build was still
red across three attempts spanning ~20 minutes, with **15 errors, every one of them in
`MenuBar/MenuBarController.swift` or `MenuBar/MenuBarCoordinator.swift`** (`invalid
redeclaration of 'workVoiceRecorder' / 'workCaptureIsActive' / 'openComposeForWorkOnly()' /
'beginWorkVoiceCapture()' / 'finishWorkVoiceCapture()' / 'workCaptureFeedbackIsShowing'` and
the ambiguous uses that follow from them) — slice D appears to have added its members twice.
Swift type-checks the whole module before it emits, so a green iOS build plus a macOS build
whose error list contains NOTHING from `Intents/`, `ConduckApp.swift`, `WorkCaptureInbox.swift`
or `Views/Workboard/WorkVoiceCaptureLaunchRoute.swift` is evidence this slice type-checks on
both. The integrator should still re-run `xcodebuild build -destination 'platform=macOS'`
once slice D's duplicates are gone — `AppShortcuts.swift` and the `ConduckApp` row are
macOS-compiled code that no iOS build covers.

## Requests (files I do not own)

1. **a2-image-card / the desk surface** — consume the route from BOTH
   `.onReceive(.showWorkboardVoiceCapture)` and the canvas's appearance, and present
   `WorkboardVoiceCaptureView` on a true. A cold launch delivers the notification before any
   observer exists; an appearance-only read drops the warm case.
2. **Serial copy agent** — the twelve rows above. Two carry a `%@`. Every `intent.*.title` /
   `.description` value must stay platform-free (`WorkboardCopyTruthGuardTests` rule 7).
3. **Docs pass** — `project-structure.md` gains three source files:
   `Conduck/Intents/AddFilesToWorkIntent.swift`, `Conduck/Intents/RecordWorkNoteIntent.swift`,
   `Conduck/Views/Workboard/WorkVoiceCaptureLaunchRoute.swift`. The spec's Work ingress
   paragraph should say that a Shortcut's files publish through the same envelope queue as
   the share sheet, that images from that lane become image cards (thumbnail + gallery), and
   that the voice action only LAUNCHES the in-app recorder.
4. **`TempScratchSweeper.ownedPrefixes` owner (nobody in this wave)** — the data-only
   fallback writes under `conduck-workboard-intake-`, which is claimed today only because
   `conduck-workboard-` is a prefix of it. A dedicated entry with its own comment would read
   better; adding one means editing `AgentDownloadScratch.swift` AND the writer list in
   `TempScratchSweeperTests`, both outside this slice.
5. **Slice D (menu bar)** — `MenuBarCoordinator` currently declares `workVoiceRecorder`,
   `workCaptureIsActive`, `workCaptureFeedbackIsShowing`, `openComposeForWorkOnly()`,
   `beginWorkVoiceCapture()` and `finishWorkVoiceCapture()` TWICE, which is the only thing
   keeping the macOS build red (15 errors, listed under Measured). Nothing in this slice
   touches those files.

## Nobody undo

- **`request()` is set-then-post, and the intent calls it BEFORE `.showWorkboard`.**
  `.showWorkboard` can mount a desk synchronously; a desk that mounts before the flag is set
  reads an empty route and opens on nothing. This is the same ordering rule `GatewayFixRoute`
  documents one level down, applied one level up.
- **The route does NOT re-validate on consume.** `GatewayFixRoute.consumeIfStillBroken`
  re-reads the default because it describes a STATE that can heal itself between the ask and
  the landing. This route describes an ACT the person asked for; nothing about the desk can
  make "record a note" the wrong answer by the time the canvas appears, and a condition here
  would only invent a way to drop the request.
- **The capture id is DERIVED, and order is part of it.** The entry ids under it are
  `WorkCaptureInbox.fileEntryID(forCapture:sequence:)` — derived from the id AND the
  position — so an order-insensitive hash would let a reordered rerun repair card 3 with the
  bytes of card 1. Do not "improve" this by sorting the inputs.
- **It hashes names and sizes, never bytes.** A headless intent process must not read a
  quarter of a gigabyte to decide what to call something.
- **`file.fileURL` is handed over unread.** The publisher opens the security scope and
  copies; touching `file.data` on a URL-backed file loads the whole thing into a process the
  system kills without warning. The `data` fallback exists only for files that arrive with no
  URL at all.
- **The dialog is true at PUBLICATION time.** It returns the number of files handed to the
  queue, not a count of rows in the store: the inline drain is best-effort and a killed
  process still lands the cards at the next launch. Do not "fix" this by counting imported
  materials — that would make a successful capture read as a failure.
- **`refusal(for:)` duplicates limits the queue also enforces, on purpose.** The queue
  refuses one error per RULE; a person who chose forty files is owed the sentence that says
  which rule they met. The queue's copy stays the authority — this one only buys the wording.
- **The image classification lives in the PUBLISHER, not the drainer.** It is where the
  caller's metadata is still in hand, and it keeps the drainer's shared `.image` branch out
  of this slice.
- **The three shipped `AppShortcut` entries are frozen** and now pinned as text by
  `testTheShortcutProviderCarriesTheFrozenEntriesAndTheTwoNewOnes`. An installed Shortcut and
  a spoken request are bound to those exact phrases.

## Founder QA

Every Shortcuts item below needs ONE reinstall first: `appintentsd` indexes an app's actions
at install time, so a fresh build's new actions do not appear until the app is reinstalled
(delete the app, then install). Both new actions appear in Shortcuts under **Conduck**.

**iPhone — Add Files to Work**
1. Shortcuts → new shortcut → **Get File** (or **Select Photos**) → **Add Files to Work**.
   The parameter should already read "Files" and be wired to the previous action's result.
2. Run it, pick 2–3 files including one photo and one PDF. Expected: the dialog says
   "Added to Work. Nothing was sent." and the action's result value is the number of files.
3. Open Conduck → Work. Expected: one card per file, in the order chosen; the photo is an
   IMAGE card with a thumbnail and opens into the gallery; the PDF is a file card that opens
   in Quick Look. An `.m4a` picked here becomes a playable audio card.
4. Add a Note in the action's parameters and run again with different files. Expected: the
   note lands as its own note card beside them.
5. FAILURE CASES to try: run it with no files selected ("Choose at least one file to add to
   Work."); run it over 25+ files ("That's too many files to add at once…") and check the
   desk gained NOTHING; run it over a very large video (>256 MB) — the message names that
   file and, again, nothing lands.
6. REPLAY: run the same shortcut twice over the SAME files with the same note. Expected: ONE
   set of cards, not two — the capture is named after its input so a rerun repairs. Two runs
   over DIFFERENT files (or the same files reordered) give two sets.
7. KILL TEST: run it, then force-quit Conduck before opening it. Reopen Conduck → Work; the
   cards must be there (the envelope drains at launch).

**iPhone — Record a Note to Work**
8. Say "Hey Siri, record a note to Work in Conduck" (or run the action from Shortcuts).
   Expected: Conduck opens ON the Work desk with the voice-capture sheet already up; speak,
   finish, and the recording becomes an audio card with its transcript attached. Nothing is
   sent to any AI, and no gateway is consulted at any point.
9. COLD LAUNCH: force-quit Conduck first, then say it again. The sheet must still come up —
   this is the case the launch route exists for.

**Mac**
10. Shortcuts on the Mac shows both actions. Run **Add Files to Work** with a couple of files
    → the same cards appear on the Mac desk.
11. Run **Record a Note to Work** while Conduck is running QUIET (menu bar only, no window):
    the main window must OPEN on the Work desk with the capture sheet up. Repeat with the app
    fully quit.

**Both**
12. Check the Shortcuts editor copy: neither action's name or description mentions iPhone,
    Mac, Watch or CarPlay (Apple rejects uploads that do), and neither says send, dispatch,
    draft or brief.

## Open questions

1. **A deliberate double-run is a repair, not a second set of cards.** That is what f5's
   request asked for and it is what makes a killed-and-rerun Shortcut safe, but it is the
   OPPOSITE of `CaptureWorkboardIntent`'s choice (a fresh id per run, "two runs carrying the
   same words are two cards the person asked for"). Founder call at QA step 6: if adding the
   same set twice on purpose should give two sets, the derivation has to be dropped and the
   crash-repair property goes with it.
2. **`RecordWorkNoteIntent` returns as soon as the sheet is asked for**, not when the
   recording is saved — an intent cannot wait for a person to stop speaking without holding
   the Shortcut open for minutes. A shortcut that runs actions AFTER it will continue while
   the recorder is still up.
3. **Refusals name the first offending file only.** A set with three oversized files reports
   one. Reporting all of them needs a list in a dialog, which the Shortcuts error surface
   does not render well.
4. `AddFilesToWorkIntent` deliberately does not accept a bare URL or text — `.item` covers
   files, and `CaptureWorkboardIntent` already owns the text lane.

## Orchestrator edit (03:35)
`perform()` is nonisolated, so the `@MainActor` route call needs `await`: line 54 now reads `await WorkVoiceCaptureLaunchRoute.shared.request()`. One keyword; it was the sole compile error blocking every agent build.
