# f1-voice-source — `sourceDevice` on the Work voice lane

## What changed

- `Conduck/Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift`
  - `publishRecording(...)` gains `sourceDevice: String = SourceDevice.current`, placed
    between `createdAt:` and `store:`. The `WorkMaterialDraft` it builds stamps that
    parameter instead of the hardcoded `SourceDevice.current`.
  - Doc comment states WHY: the publishing process is not always the surface the words
    were spoken at (a wrist recording is relayed and published on the phone), so a
    relaying caller passes its own value while in-process lanes keep the default.
  - Nothing else changed. `republishRecording` (recovery) still calls `publishRecording`
    without the label, so a recovered capture keeps stamping the recovering device — the
    pre-existing behaviour; see Open questions.
- `Conduck/ConduckTests/WorkboardAudioCaptureTests.swift` — one added test (additions only).

## New API

```swift
@discardableResult
static func publishRecording(
    captureID: UUID,
    audio: Data,
    fileExtension: String,
    mimeType: String,
    createdAt: Date = Date(),
    sourceDevice: String = SourceDevice.current,
    store: ConversationStore = .shared
) async throws -> WorkMaterialRecord
```

Callers that capture elsewhere pass their own value, e.g.
`publishRecording(captureID: …, audio: …, fileExtension: …, mimeType: …, sourceDevice: "watch", store: …)`
(Slice C) and `sourceDevice: "carplay"` (Slice E). Every existing call site compiles
unchanged through the default — verified: `ConverseIntent.swift:348`,
`InAppAudioRecorder.swift:682`, the two internal `republishRecording` calls, and three
test call sites.

`attachTranscript(_:toRecording:store:)` needs **nothing**: confirmed by reading
`ConversationStore.applyWorkVoiceTranscript` — it writes only `textContent`, `title`
and `updatedAt` on the existing rows and never touches the `sourceDevice` column, so the
phase-1 stamp survives phase 2 untouched. Do not add a `sourceDevice` argument to it.

## New strings

None.

## Tests

- `ConduckTests/WorkboardAudioCaptureTests` — added
  `testTheCardRemembersTheSurfaceTheWordsWereSpokenAtRatherThanTheOneThatWroteThem`:
  a caller-supplied `"carplay"` lands on the record and reads back off the desk, while an
  omitted argument still stamps `SourceDevice.current`; the desk holds both stamps, so
  the value is persisted rather than re-derived on read.
- Measured (`xcodebuild build-for-testing` 0 errors, then `test-without-building`):
  - `WorkboardAudioCaptureTests` — Executed 11 tests, 0 failures.
  - `WorkboardVoiceLaneTests` — Executed 20 tests, 0 failures.
  - Combined line: Executed 31 tests, with 0 failures.

## Requests

None. No edit is needed in any file I do not own.

## Nobody undo

- **The parameter is defaulted on purpose.** Do not make `sourceDevice` required "for
  explicitness" — every existing call site relies on the default, and the default is what
  keeps in-process lanes spelling one value in one place.
- **Do not "simplify" the draft back to `SourceDevice.current`.** That is the exact bug
  this slice removes: the phone publishes the wrist's recording, so the writer's device is
  not the capture's device.
- **Argument position matters to nobody but readers, but the label does**: Slice C/E call
  sites are specified in the plan as `sourceDevice: "watch"` / `"carplay"` — keep that
  spelling.
- `attachTranscript` deliberately does not carry or rewrite the stamp.

## Open questions

- **Recovery stamps the recovering device.** `WorkVoiceCaptureCoordinator.recover` →
  `republishRecording` re-publishes parked bytes with the default, so a watch/CarPlay
  capture whose phase 1 failed and is recovered later on the phone lands as `"iphone"`.
  Preserving the original would mean carrying `sourceDevice` in `PendingRetryStore`'s
  metadata (it has no such field today) — out of this slice's ownership and not in the
  plan. Flagged for the founder: the plan's decision 9 says nothing renders `sourceDevice`
  yet, so the cost today is zero.
