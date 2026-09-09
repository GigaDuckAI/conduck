# Work audio boundary — QA handoff

A spoken Work note is now its words and nothing else. Whichever surface you speak into — the desk's own voice sheet, the Mac menu bar, a Shortcut, CarPlay or the Watch — the recording is kept on the device that made it, only until the words come back, and then it is deleted. Nothing appears on the desk until there are words: a transcription that fails leaves the board exactly as it was and offers Try Again on the recording that is still waiting. The desk still keeps audio **files**, but only through the two doors where a person hands one over deliberately: the attachment button inside Work, and a drop into the Work pane. Every other door — the share sheet, the "Add Files to Work" Shortcut, capturing a chat message to Work — turns a recording away and says where the door is. Recordings already on your desk from earlier builds are untouched: they still play, share, open and reattach.

Branch and worktree: `work-audio-boundary` — a worktree of the `Conduck` repository at `.claude/worktrees/work-audio-boundary`, branched from `main` at 853220b. The monorepo has no branch of its own for this wave; it records only the submodule pointer once the branch is merged.

## Founder decisions (2026-09-09)

Verbatim from the plan.

| Decision | Choice |
|---|---|
| STT fails | Audio waits **only** in the existing device-local, non-syncing retry lane (`PendingRetryStore`) until the words land; then a words-only card is written and the audio deleted. Nothing appears on the desk until the words arrive. Failure → existing Try Again card; a confirmed discard loses the recording for good. |
| Audio **files** via share sheet / "Add Files to Work" Shortcut | **Refused** with a message pointing to the attachment button in Work. Only the in-app chat-bar attachment button and drag-and-drop into the Work pane keep an audio file (as a playable card, never transcribed). |
| Existing `.audio` cards on desks / iCloud | Left alone. Still playable; all `.audio` UI stays. |

## Supersedes

These entries in `docs/qa/work-usability/handoff.md` are no longer the truth. That file is not edited; this table is the correction.

| Old | Said | Now |
|---|---|---|
| Step 28 (in-app, no transcript) | The recording is already a playable card on the desk; Try Again attaches the words to that card. | The desk stays empty. The sheet says the recording is still on this device and Try Again turns it into a note. Try Again writes a **Spoken note** card; there is never a recording card to attach to. |
| Step 60 (Watch, settled STT failure) | Wrist says "Saved to Work. Add the words on your iPhone."; the phone's desk holds a playable card with no words. | Nothing is on the desk. The wrist's failure line says the recording is kept on the phone, and the phone offers a retry card. Retry writes a **Spoken note**. |
| Step 70 (CarPlay, the card) | A playable audio card with the transcript. | A **Spoken note** card with the transcript. No play control, no audio. |
| Step 71 (CarPlay, words lost) | "Saved to Work. Add the words on your iPhone."; the audio card is on the desk **and** a retry card is offered. | The car says the note is kept on your iPhone. **Nothing** is on the desk. Only the retry card is offered, and Retry writes the note. |
| Step 105 (CarPlay, a Work pick is a note) | "Saved to Work." is spoken and the desk holds a playable card with the transcript. | "Saved to Work." is still spoken **only when the words came back**, and the desk holds a **Spoken note**. |
| Steps 135–143 (the companion card) | The picture folds a **recording**; the band carries a play control; the rotor offers Play / Open / Share Recording. | The picture folds the **words**. The band shows the words and no transport. The rotor offers the card's own Share Screenshot and Open, and none of the recording rows. VoiceOver announces "Screenshot with note". Steps 137, 139's play checks, 140's play and 143's "Audio is in use" refusal now apply only to cards recorded on an earlier build. |
| Decision 22 (a screenshot with a voice note is ONE card) | The recording stays its own `.audio` material and carries the picture's identifier. | The **words** are the material that folds (`.transcript`), and it carries the picture's identifier. Every other clause of decision 22 stands unchanged: one card, lowest identifier wins, displayed-vs-stored array, orphans are correct, TEXT mode stays two cards, no backfill. |
| Decision 6 (Shortcuts) | "audio files become playable cards everywhere". | Audio files become playable cards **only** through the Work attachment button and a drop into the Work pane. The files Shortcut refuses one by name. |
| Decision 19 (published Work retry TTL) | The day-long clock is justified because "those bytes are a SECOND copy of a recording already on the desk". | The day-long clock still applies, but a `.published` entry now means the **words card is written and only the clear is outstanding**. An unpublished Work entry answers to no clock at all, because its recording is the only copy of what was said. |

## QA script

Lanes marked **on device** cannot be exercised in the simulator — microphone, Shortcuts, CarPlay and Watch are all founder-on-device.

### The two doors that still keep a recording

1. **Attachment button, iPhone.** Open Work, tap the attachment button, pick an `.m4a` from Files.
   - *Must be true:* a playable card appears, with a transport that plays it. No transcription happens and no words appear on it.
2. **Attachment button, Mac.** Same, from the Mac's Work pane.
   - *Must be true:* same playable card.
3. **Drag and drop, Mac.** Drag an `.m4a` from Finder onto the Work pane.
   - *Must be true:* a playable card. *Failure to look for:* it landing as a plain document card with a paperclip instead of a transport — that means the audio sniffer disagreed with itself between doors.
4. **A file that is audio but badly labelled.** Rename an `.m4a` so Finder reports `application/octet-stream`, then drop it in.
   - *Must be true:* still a playable card. The extension is read when the type is not specific.

### The doors that now refuse one

5. **Share sheet, iPhone.** Share an `.m4a` from Files or Voice Memos, pick Conduck, then **Add to Work**.
   - *Must be true:* Work refuses it with "Recordings can't be shared into Work. To keep one, open Work and add it with the attachment button." Nothing lands on the desk.
   - Then, in the same sheet, send that same recording to a **conversation** instead.
   - *Must be true:* it sends normally. *Failure to look for:* Chat refusing audio too — the refusal belongs to the Work lane alone.
6. **Share sheet, Mac.** Same from Finder, which is the ordinary way a recording arrives there.
   - *Must be true:* same refusal, same Chat behaviour.
7. **"Add Files to Work" Shortcut — on device.** Build a shortcut that hands the action an `.m4a` (alone, then alongside a photo and a PDF).
   - *Must be true:* the action fails naming the file: "'<name>' is a recording. Work keeps recordings only when you add them yourself — open Work and use the attachment button." Nothing from that run reaches the desk.
8. **Capture to Work from a chat message.** Send yourself a message carrying an audio attachment, then capture that message to Work.
   - *Must be true:* the text and any other attachments land, and the banner reads "Added to Work without the recording. Add recordings yourself with the attachment button in Work." No audio card appears.

### The in-app voice lane — on device

9. **The ordinary success.** Open Work's voice sheet, speak a sentence, stop.
   - *Must be true:* nothing appears on the desk while it is transcribing. When the words land, a single **Spoken note** card appears with the words as its title and body, an amber note face, and no play control.
10. **No key, no card.** Remove the speech key (or turn on Airplane Mode with a cloud provider), then record and stop.
    - *Must be true:* the desk is **empty** — no card of any kind. The sheet shows one outcome sentence, "Your recording is still on this device. Try Again turns it into a note on your desk.", the reason under it, and only **Try Again**, **Record Again** and **✕**.
    - *Failure to look for:* any card appearing on the board, or a sentence claiming the recording is on your desk.
11. **Restore the key and retry.** Put the key back, then press **Try Again** on the retry card.
    - *Must be true:* a **Spoken note** card appears and the retry card clears itself. Only one card, however many times you press.
12. **Record Again keeps the previous recording.** Fail a capture as in step 10, then press **Record Again** and speak something new.
    - *Must be true:* the previous recording is still offered as a retry card — it is handed back to the queue, not discarded. Finish the new capture and both settle independently.
13. **Discard says what it costs.** On a retry card for a failed Work note, choose Discard.
    - *Must be true:* the confirmation says the recording is deleted from this device and cannot be recovered. *Failure to look for:* any wording claiming the recording is already in Work and stays there.
14. **The waiting count does not flash.** Watch the retry-card area (and, on the Mac, the menu-bar count) through one ordinary successful capture.
    - *Must be true:* no retry card and no count appear mid-capture and then vanish. A capture that is running is not a capture that is waiting.

### The Mac menu bar — on device

15. **Hotkey with a screenshot.** Press ⌃⌘W, drag a region over something recognisable, speak, stop.
    - *Must be true:* **one** card — the screenshot, with a band across the bottom carrying the words. No play control on the band. The picture's own size and date are still in the footer.
16. **VoiceOver on that card.**
    - *Must be true:* one element announcing "Screenshot with note", the file name, the words, the size and the position. The rotor offers the card's own **Share Screenshot** and **Open**, and offers **none** of Play Recording, Open Recording, Share Recording, Reattach Recording.
17. **Delete the folded card.**
    - *Must be true:* the confirmation names the screenshot and the note inside it, and nothing survives on this Mac or, after sync, anywhere else.
18. **Hotkey without a screenshot.** ⌃⌘W → **Return** → speak → stop.
    - *Must be true:* one plain **Spoken note** card. No band, no phantom screenshot.
19. **Typed press is still two cards.** ⌃⌘W → drag → type → Return.
    - *Must be true:* the note and the screenshot are two cards, exactly as before.
20. **Menu-bar failure.** Remove the key, then ⌃⌘W → drag → speak → stop.
    - *Must be true:* the screenshot lands on the desk **alone** (the menu bar queues the picture before it transcribes), no note or recording card appears, and the popover reads "Your screenshot is on your desk. The words are not yet." (or "…is on its way to your desk…" if the drain has not run) and offers Try Again. Restore the key and press it: the words fold into that same picture — the card count does **not** grow.
    - *Failure to look for:* a second card appearing on Try Again, or any sentence claiming a recording is on your desk.

### The Converse Shortcut — on device

21. **Converse with audio and a screenshot, destination Work.**
    - *Must be true:* one card on the phone: the screenshot with the words in its band. The same one card on the Mac after sync. It may arrive as a picture alone first and gain its band when the words sync — that is the fold working.
22. **Converse with the key removed.**
    - *Must be true:* nothing on the desk, and a retry card on the phone. Restore the key, press Retry: the card appears.

### CarPlay — on device

23. **A Work note that works.** Tap **Add to Work**, say one sentence, stop.
    - *Must be true:* "Saved to Work." is spoken, the session ends, and the desk holds a **Spoken note** with the transcript. The Conversations list is unchanged.
24. **A Work note whose words fail.** Remove the phone's speech key, then record in the car.
    - *Must be true:* the car speaks "Kept on your iPhone. Open Conduck to add it to Work." Nothing is on the desk. A retry card is waiting on the phone, and Retry writes the note.
    - *Failure to look for:* the car saying "Saved to Work" when no words came back, or an STT-key sentence, or a second listen.
25. **A Work note the phone could not even keep.** Fill the phone's disk, or otherwise make the park fail, then record.
    - *Must be true:* the car speaks the plain "Couldn't save — try again." line. It never claims the note is kept on your iPhone when nothing was written.

### The Watch — on device

26. **A wrist note that works.** Ask → Add to Work → speak → stop.
    - *Must be true:* the success line and the success buzz read exactly as they did before this change, and the phone's desk holds a **Spoken note**.
27. **A wrist note whose words fail.** Remove the phone's speech key, then record on the wrist.
    - *Must be true:* the wrist ends on "Kept on your iPhone. Nothing reaches Work until the words land." with a success buzz, never an error line. The wrist's queue lets the clip go, because the phone confirmed it holds the recording. A retry card is waiting on the phone, and Retry writes the note.
    - *Failure to look for:* the old "Saved to Work. Add the words on your iPhone." — nothing is on the desk.
28. **The wrist keeps its clip until the phone has it.** Record on the wrist with the phone out of range, then bring it back.
    - *Must be true:* the clip stays on the wrist until the phone answers, then leaves. No Work clip is ever evicted for age or for the queue's count.

### Cards from earlier builds

29. **Legacy recordings still work.** Find a recording card taken before this build (step 134 of the old handoff created one deliberately; any older Work voice note will do).
    - *Must be true:* it still plays, and **Share Recording**, **Open Recording** and **Reattach Recording** still act on it. A legacy folded pair still shows its transport on the band.
30. **Retry onto a legacy card.** If you still hold a retry card for a capture whose recording is already a card from an earlier build, press Retry.
    - *Must be true:* the words attach to that same card. No second card appears.

### iCloud

31. **A note crosses devices with no bytes.** Take a Work voice note on the phone, then open the desk on the Mac.
    - *Must be true:* the **Spoken note** appears with its words, immediately, with nothing waiting to download and no reattach affordance — a note carries no payload at all.
32. **An attached file still carries bytes.** Attach a small `.m4a` through the Work attachment button, then open the desk on the second device.
    - *Must be true:* it arrives as a playable card, exactly as any other desk material within the sync ceiling does.

## Known limits

- **A park that fails stops the in-app lane, but not CarPlay.** If the retry queue refuses to keep the recording, the in-app and menu-bar lanes stop and say so rather than transcribing something they cannot recover. CarPlay continues to transcription best-effort, because the driver has no way to act on a refusal mid-drive, and it keeps its own container copy instead of deleting it.
- **A file with no type, no MIME and no known extension lands as a document card.** The audio sniffer answers from the declared type first and the extension second; a recording that declares neither is indistinguishable from any other opaque file and becomes a plain document.
- **`carplay.*` and `watch.*` string orphans are not caught automatically.** The copy guard scopes its orphan sweep to `workboard.*` and `pendingRetry.*`, so a retired CarPlay or Watch key has to be grepped for by hand.

## Review gate

This is multi-file active-product app code touching persistence, privacy and the public repository. Paste:

```
/code-review high
```

Scope: **Work voice pipeline inversion + desk audio doors**.
