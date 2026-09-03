# d-stt — r4a#5 (O-6). CONFIRMED on all three lanes; fixed. Nothing refuted.

Slug `d-stt`. Sim `5C851D88-959C-445E-ACC8-A4C6ADB2876C`, watch `28AC563B-42C1-4E66-940D-77E63B07918B`.
No commits/pushes/stash/checkout/reset/index ops. `Identity-Override.xcconfig` untouched. Nothing under
`docs/qa/desk-cloudkit/` touched. **No `.xcstrings` opened. No `.pbxproj` edit. No mirror triplet
touched. No file outside my ownership edited** — including `STTClient.swift`, which I did NOT need to
change (see §Decisions 1).

| File | Change |
|---|---|
| `Conduck/Conduck/Services/STT/Providers/GeminiSTTProvider.swift` | `private static let audioMIME` → `private static func audioMIME(for audioData: Data)` = `SourceAudioContainer.sniff(audioData).mimeType`; the inline audio part is built from it |
| `Conduck/Conduck/Services/STT/Providers/QwenSTTProvider.swift` | `private static let audioMIMEPrefix` → `private static func audioMIMEPrefix(for audioData: Data)`, same sniff; the data URI is built from it. `QwenSTTProbe.probeAssetMIME` (`audio/wav`, a bundled WAV) untouched — it was already true |
| `Conduck/Conduck/Services/STTClient+Background.swift` | new `static func backgroundAudioPart(forFileAt:)`; `transcribeBackground`'s multipart branch takes `audioMIME`/`audioFilename` from it. Its `audioFileURL` doc line (“M4A AAC”) corrected |
| `Conduck/ConduckTests/STTContainerDescriptionTests.swift` | NEW, 8 cases (see below) |

---

## Finding

### r4a#5 (minor, O-6) — three hardcoded container claims. CONFIRMED, all three, fixed.

**Verified by call path before changing anything.**

- `GeminiSTTProvider.swift` held `private static let audioMIME = "audio/mp4"` and inserted it into the
  Interactions audio part unconditionally. Reachable with non-M4A bytes: `AudioCompressor.compress`
  returns `.wav` on an AAC encode failure (`AudioCompressor.swift:180` sniffs the source and the WAV
  fallback path exists), `WorkVoiceCaptureCoordinator.swift:236` and `PendingRetryStore.swift:176`
  both derive a container from preserved bytes, and the Work retry surfaces re-upload exactly those
  bytes. So the claim is false on precisely the recordings that already failed once — and a retry
  re-sends the same false claim, which is why the finding says “rejected on every attempt”.
- `QwenSTTProvider.swift` held `private static let audioMIMEPrefix = "audio/mp4"`, wrapped into a
  `data:<mime>;base64,…` URI. DashScope reads the container off that prefix, so the same defect.
- `STTClient+Background.swift` passed the literal pair `audioMIME: "audio/mp4"` /
  `audioFilename: "audio.m4a"` to `STTMultipartBuilder.writeBodyFile`. True for the Watch's native AAC
  today, false the moment anything else feeds the background lane — and it is a general entry point
  (`transcribeBackground` is the documented opt-in for long clips and risk-averse callers, not a
  Watch-only method).

**Fix.** One rule, three lanes, all reading `SourceAudioContainer.sniff` — the same shared truth
`STTClient.multipartAudioPart(for:)` (c-lanes, O-12) and the retry surfaces already use, so no two
lanes can describe one payload differently. M4A and unrecognised bytes both resolve to `audio/mp4` /
`audio.m4a`, which is byte-for-byte what all three lanes sent before.

**Regression tests** — `STTContainerDescriptionTests`, 8 cases:

| Case | What it bites |
|---|---|
| `testGeminiLabelsTheInlinePartWithTheContainerItIsSending` | WAV→`audio/wav`, CAF→`audio/x-caf`, M4A/unrecognised→`audio/mp4`, each paired with the base64 of the very bytes |
| `testGeminiNeverCallsWAVBytesAnM4APayload` | no MP4 claim survives anywhere in a WAV body |
| `testGeminiM4APayloadIsDescribedExactlyAsBefore` | the raw body still carries `"mime_type":"audio\/mp4"` and no other container name |
| `testQwenWrapsTheDataURIWithTheContainerItIsSending` | the WHOLE audio field asserted byte for byte, per container |
| `testTheBackgroundLaneDescribesTheFileItIsAboutToUpload` | four containers written as real 4 KB files; also asserts the answer is identical to `STTClient.multipartAudioPart(for:)` for the same bytes |
| `testAMissingFileFallsBackToTheSniffDefaultRatherThanFailingHere` | the helper never invents a second competing I/O error |
| `testTheBackgroundUploadHardcodesNoContainer` | comment-stripped source guard: `audioMIME: "audio/mp4"` and `audioFilename: "audio.m4a"` absent, `backgroundAudioPart(forFileAt:` present |
| `testTheJSONProvidersHardcodeNoContainer` | comment-stripped source guard on both providers: no `= "audio/mp4"` constant, `SourceAudioContainer.sniff(audioData)` present |

*How I know they bite on the old code:* the three behavioural WAV/CAF cases assert a MIME the old
constants could not produce for any input (the constants were literals, not functions of the bytes);
`backgroundAudioPart` did not exist at `effc664`, so those two cases cannot even compile there; and
the two source guards assert the ABSENCE of literals that are the exact text of `GeminiSTTProvider.swift:66`,
`QwenSTTProvider.swift:55` and `STTClient+Background.swift:267-268` at `effc664`.

**Unchanged-M4A proof, in two halves.** (a) By construction: `SourceAudioContainer.sniff` answers
`.m4a` for `ftyp` bytes AND for unrecognised/short bytes, and `.m4a.mimeType == "audio/mp4"`,
`.fileExtension == "m4a"` — the identical strings. (b) Measured: the pre-existing wire locks
`GeminiQwenSTTWireTests` (7 cases, whose fixtures `0x010203` / `0xCAFEBABE` are unrecognised bytes and
so take the fallback) still pin `"audio/mp4"` and `data:audio/mp4;base64,…` and pass untouched, as do
`STTProviderTests` / `STTCustomModelTests`, which build multipart bodies with the same MIME.

---

## Decisions

1. **`STTClient.swift` needed no edit at all.** `multipartAudioPart(for:)` is already `internal static`
   on `STTClient`, and `STTClient+Background.swift` is an extension of it in the same module — the
   background helper calls it directly. Reusing the member rather than re-exposing it means the
   foreground and background lanes cannot drift, and it keeps my diff off a file three other findings
   touch. The brief permitted an edit there; none was necessary.
2. **The background lane sniffs a 64-byte HEAD, not the file.** `transcribeBackground` deliberately
   never loads the recording into memory (`uploadTask(with:fromFile:)` streams it, and the size guard
   reads `attributesOfItem` rather than the bytes). Loading a 15 MB recording just to read 12 magic
   bytes would undo that. 64 is headroom over the 12 `sniff` inspects. Stated as a constraint in the
   helper's header.
3. **An unreadable file falls back to `.m4a` rather than throwing.** `STTMultipartBuilder.writeBodyFile`
   is immediately downstream and already reports the real I/O failure as `audioMissingData`; a throw
   in the sniff would produce a second, competing error for the same cause. Asserted.
4. **A parameter on `STTJSONBodyFactory.buildRequestBody` was considered and rejected.** Threading the
   MIME in would have touched the protocol plus five call sites in files I do not own (`STTClient`,
   `STTClient+Background`, `WatchAudioUploader` ×2, `WatchNetworkClient` ×2), and — the real argument —
   it would make “a caller passes a container that does not match its bytes” expressible. Sniffing the
   `audioData` the factory already holds cannot be got wrong. Same reasoning c-lanes recorded for the
   foreground multipart part; O-6's wording (“pass the MIME into every JSON body factory”) is satisfied
   in substance by the stronger mechanism.
5. **Gemini's `audio/mp4`-is-undocumented-but-accepted note is preserved**, moved onto the function.
   It is a tested compatibility dependency with a live canary in
   `Conduck-Private/scripts/validation/`, and it now covers the fallback branch too.

## Deviations

None from the brief. The one departure from O-6's literal wording is §Decisions 4 (sniff inside the
factory instead of a threaded parameter), taken under the brief's “if a better mechanism exists inside
your ownership, use it and say why”.

## Verification — exactly what I ran

- **iOS build-for-testing** (`-scheme Conduck`, sim `5C851D88-…`, derivedData under
  `~/Library/Caches/gigaduck-builds/d-stt/`): `** TEST BUILD SUCCEEDED **`. Grep for `error:` returns
  only two source lines containing the token `error: Error` — zero diagnostics.
- **Targeted iOS run** (`test-without-building`, 12 classes: `STTContainerDescriptionTests`,
  `GeminiQwenSTTWireTests`, `GeminiSTTProviderTests`, `QwenSTTProviderTests`, `STTCustomModelTests`,
  `STTProviderTests`, `STTStatusMapTests`, `STTTranscriptBoundaryTests`, `CustomSTTEndpointTests`,
  `CustomOpenAISTTProbeTransportTests`, `WorkboardVoiceLaneTests`, `AudioCompressorTests` — the
  complete `grep -l 'STTClient\|GeminiSTT\|QwenSTT'` set minus the ones whose hits are unrelated
  RemoteAgent/CarPlay classes, plus `AudioCompressorTests` because it owns the sniff):
  `Executed 171 tests, with 0 failures (0 unexpected) in 1.719 (1.764) seconds`, `** TEST EXECUTE SUCCEEDED **`.
  My class alone: `Test Suite 'STTContainerDescriptionTests' passed` … `Executed 8 tests, with 0 failures (0 unexpected)`.
- **Watch suite** (`-scheme ConduckWatchTests`, `28AC563B-…`, full `xcodebuild test`): run because
  `GeminiSTTProvider.swift` and `QwenSTTProvider.swift` ARE in the `ConduckWatch Watch App` membership
  list (`project.pbxproj` exception set `63E4A001…`) — `Executed 232 tests, with 0 failures (0 unexpected) in 9.430 (9.508) seconds`,
  `** TEST SUCCEEDED **`. `STTClient+Background.swift` is NOT in that list, so the background change
  cannot reach the wrist.
- **macOS build: not run.** Nothing platform-conditional in the diff, the same three files compile in
  the shared `Conduck` target the iOS build covered, and a macOS build in a tree two other agents are
  editing would measure their work, not mine. It stays a gate step.
- Simulator TCC not consulted — no audio-permission class in my run went red.
- `git diff --check` clean. `~/Library/Caches/gigaduck-builds/d-stt` removed via
  `.claude/scripts/clean-build-cache.sh d-stt` (`removed: d-stt`).

## Catalog

No keys added, none made dead. No user-facing copy in this change.

## Requests

1. **Gate owner:** the Gemini `audio/mp4` compatibility dependency now has a second live case worth a
   canary run — a WAV body against the Interactions endpoint. Only the private validation script can
   answer whether Google accepts `audio/wav` on that model; no fixture test can. Today's fallback
   already sent WAV bytes under an MP4 label, so the WAV label cannot be worse, but the canary should
   learn the truth before anyone relies on it.
2. **Nothing else.** No file outside my ownership needs a change for this finding.

## Refuted

Nothing. All three hardcoded claims held exactly as the finding described, and the design direction
was implementable as written (with the mechanism substitution recorded in §Decisions 4).

## Founder QA (device-only)

1. **Work voice note whose AAC encode fails → Gemini.** Hard to force by hand; the observable is that
   a recording which previously failed transcription forever now transcribes on retry. If the founder
   can reproduce a stuck Work voice retry from before, that is the case.
2. **Watch → phone background upload, ordinary dictation.** Must be byte-for-byte the old behaviour:
   the wrist records AAC M4A, so the part is still `audio/mp4` / `audio.m4a`. Any regression here means
   the head-sniff read the wrong bytes — check that a normal watch dictation still transcribes.
3. **CarPlay dictation** (its tap produces CAF): the upload now claims `audio/x-caf` where it claimed
   MP4. Worth one real transcription against the live provider, because this is the one lane whose
   wire claim CHANGES for a payload that previously worked by the endpoint's own sniffing.

## Settled facts

- Every STT lane derives its audio container from the bytes via `SourceAudioContainer.sniff` — the
  foreground multipart part, the background multipart part, and both JSON body factories (Gemini's
  inline `mime_type`, Qwen's data-URI prefix). No lane stores a fixed container claim.
- `STTClient.backgroundAudioPart(forFileAt:)` resolves the background lane's `(mime, filename)` from a
  64-byte head of the upload file, so the lane still never holds the recording in memory; it returns
  the same answer `STTClient.multipartAudioPart(for:)` gives for the same bytes.
- Unrecognised or short audio resolves to `.m4a` (`audio/mp4` / `audio.m4a`), the recorders' native
  container, so ordinary AAC traffic is described exactly as before.
- `GeminiSTTProvider.swift` and `QwenSTTProvider.swift` are members of the `ConduckWatch Watch App`
  target; `STTClient+Background.swift` is not.
