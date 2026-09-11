# copy-watch — Watch string catalog

## What changed (file + symbol)

`Conduck/ConduckWatch Watch App/Localizable.xcstrings` only. No Swift file opened, no
iOS catalog touched (copy-ios owns that one). No symbol added anywhere.

17 rows added, 0 removed. 299 → 316 keys. Diff is exactly +187 lines (11 lines per row),
so nothing else in the file moved.

Method, same as copy-ios: every key was grepped in Watch source first and the
`defaultValue:` literal read at the call site; the SOURCE literal is what was written into
the catalog. A script then re-parsed the catalog and re-matched all 17 values against their
call-site literals — **0 mismatches**, and every value matched the c2/c3 fixnotes verbatim,
typographic `’` included (`watch.work.refusal.busy`, `watch.work.noteUnwritten`).

Row shape copied from the file's own `extracted_with_value` rows (e.g.
`activity.a11y.newReply`): `extractionState` + `localizations.en.stringUnit {state:"new",
value}`. This catalog carries **no `comment` field on any row** (296 of 299 pre-existing
rows have none, and none has a comment), so the comments below live in this fixnote rather
than being introduced as a shape this file has never used. `extractionState` is
`extracted_with_value` for all 17: every call site is a literal key + literal
`defaultValue:` with no runtime interpolation, so the compiler extracts them.

Key order is the file's plain codepoint sort; the block sits between
`watch.thread.error.expandHint` and `workboard.item.untitled`. Validated with
`json.load` plus an explicit `sorted(key=codepoints)` assertion. The file's `"key" : {`
spacing, 4-space entry indent and missing trailing newline are preserved.

## New API

None.

## New strings — all in the **WATCH** catalog

`key | defaultValue | comment`

```
watch.work.capture.cancel | Cancel | Accessibility label for the control that discards a Work capture already in progress.
watch.work.capture.deferred | Saved on your watch. It reaches Work when your iPhone is nearby. | Terminal line when the iPhone was not reachable and the recording waits on the watch.
watch.work.capture.done | Done | Dismisses the wrist's Work capture screen after the capture ended.
watch.work.capture.saved | Saved to Work. | Terminal line after a Work capture reached the Work desk.
watch.work.capture.savedWordsOnly | Saved the words to Work. Update Conduck on your iPhone to keep recordings. | Terminal line when the paired iPhone runs an older build that returned a transcript without keeping the recording.
watch.work.capture.saving | Saving to Work… | Shown while a finished Work capture is being handed to the iPhone.
watch.work.capture.starting | Starting… | Shown while the microphone is arming for a Work capture.
watch.work.capture.stop | Tap to Stop | Button that ends a Work voice capture and saves it.
watch.work.capture.timeLeft | 1 min left | Warning shown as a Work recording nears its maximum length.
watch.work.capture.title | Save to Work | Navigation title of the wrist's Work capture screen.
watch.work.launchpad.save | Save to Work | Launchpad button that starts a private voice capture bound for the Work desk. It never reaches an AI.
watch.work.noteUnwritten | Couldn’t add that to Work yet. It’s still on your watch. | Shown when a relayed Work transcript could not be written to the desk; the recording stays queued on the watch.
watch.work.notification.saved | Saved to Work. | Local notification on the watch when a deferred Work recording the iPhone published finally settles.
watch.work.notification.wordsOnly | Saved the words to Work. Update Conduck on your iPhone to keep recordings. | Local notification when the paired iPhone returned a transcript but kept no recording (a build predating Work).
watch.work.refusal.busy | Finish what you’re doing first, then try again. | Shown when a Work capture is refused because another turn owns the wrist.
watch.work.refusal.queueFull | Work is waiting for your iPhone. Bring it nearby first. | Shown when a Work capture is refused because the relay queue is full of recordings still waiting on the iPhone.
watch.work.tooShort | That was too short to save. Try again and speak a little longer. | Shown when a Work capture is discarded as a mis-tap or a header-only recording.
```

`watch.work.capture.timeLeft` / `.stop` / `.cancel` intentionally duplicate the chat
overlay's English as NEW keys (the chat overlay's own entries are bare-literal keys —
`"1 min left"`, `"Tap to Stop"`, `"Cancel"` — which stay untouched), so a translator
retuning the chat overlay cannot silently retune a private-capture screen.
`.capture.saved` / `.notification.saved` and `.capture.savedWordsOnly` /
`.notification.wordsOnly` are deliberate value twins on two surfaces (screen line vs
notification body) that must be translatable apart.

No row says send/dispatch/draft/brief. No App Intent title/description was touched; no
`intent.*` row exists in this catalog.

### Rows removed

None. A scan of every dotted key in the Watch catalog against all non-catalog sources in
`Conduck/` returned **0 orphans**, so c2's deletion of the `WatchWorkCaptureContract.swift`
stub left nothing behind (the stub was inert and localized nothing).

## Tests

No test file touched. Whole watch suite, `-scheme ConduckWatchTests`, watchOS Simulator
`28AC563B-42C1-4E66-940D-77E63B07918B`, `-derivedDataPath
~/Library/Caches/gigaduck-builds/work-copyw/ddwatch`, no `-configuration`:

```
Test Suite 'All tests' passed
Executed 252 tests, with 0 failures (0 unexpected) in 9.583 (9.670) seconds
```

`xcodebuild` exit **0**, `grep -c ': error: '` = **0**. Matches c2's and c3's reported
baseline of 252 (232 + 10 + 10), i.e. the catalog rows changed no count. Cache cleaned with
`.claude/scripts/clean-build-cache.sh work-copyw`.

## Requests

None outstanding. If a later slice adds or rewords a WATCH-catalog string, it belongs in a
fixnote row, not in this file — this is the only agent that opened it.

## Nobody undo

- **These rows carry the SOURCE literal, not the fixnote's transcription.** They were
  matched against the call sites mechanically. Re-typing a value by hand (especially the two
  with `’`) breaks the `defaultValue:`↔catalog equality that keeps the shipped string and the
  translator's source string identical.
- **`.capture.saved` and `.notification.saved` stay two keys** even though their English is
  identical today. Collapsing them makes one translation govern a screen line and a
  notification body — different length budgets, different reading context.
- **`.capture.deferred` must never be reworded toward "Saved to Work."** It is the one line
  that tells the truth about a recording still sitting on the wrist; c3's
  `testEveryTerminalOutcomeRendersItsOwnSentence` guards the mapping, not the wording.
- **No `comment` field was introduced.** This catalog has never had one; adding comments to
  17 rows out of 316 would read as a partial migration.

## Founder QA

Nothing here is behaviour — the surfaces are c2's and c3's, and their QA scripts stand. What
this slice can be wrong about is a string rendering as a raw key.

1. Run c3's Founder QA steps 1–6 on the wrist. **Must be true:** every line reads as English.
   *Failure case to catch:* any screen showing a literal `watch.work.…` identifier instead of
   a sentence — that means a key is missing or misspelled in the catalog.
2. Deferred settlement (c2 step 2 / c3 step 4). **Must be true:** the local notification body
   reads "Saved to Work." — not a key, not empty.
3. Refusal at capacity (c3 step 5). **Must be true:** "Work is waiting for your iPhone. Bring
   it nearby first."
4. Mis-tap (c2 step 3). **Must be true:** "That was too short to save. Try again and speak a
   little longer."
5. Chat surfaces unchanged: the in-thread capture overlay still reads "Tap to Stop" /
   "1 min left". *Failure:* those going blank, which would mean the bare-literal chat rows
   were disturbed.

## Open questions

- **The comment text lives only here.** Xcode writes `comment` into a catalog row when the
  call site passes `comment:`; none of these 17 call sites does, and I do not own the Swift
  files to add them. If translator-facing context is wanted in the catalog itself, that is a
  one-line-per-call-site change in c2's and c3's files, not a catalog edit.
- **`extracted_with_value` vs `manual`.** I chose extractable for all 17 because each call
  site is a literal pair. If a future edit interpolates into any of these (none does today),
  its row must flip to `manual`, as copy-ios did for its three `%@` rows.
