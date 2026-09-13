# QA hand-off — project threads recognisable outside Work

Build state at hand-off: iOS suite, Watch suite and macOS compile results are in the session summary. Not pushed. Three files carrying a concurrent session's QA-mode desk seeding (`AppDelegate.swift`, `RootView.swift`, `QA/QAMode.swift`) were left untouched.

## What changed, in one breath

A conversation started from a Work project now says so wherever it is listed outside Work: a folder (the project's colour, `archivebox` when archived) before the title in Chats, the project name in the date slot while the row is idle, a line under the navigation bar with "Show in Work" once the thread is open, a small folder plus the project name at the right end of the Watch row's date line, and on CarPlay the project name after the date with a trailing folder on the same line. A project that cannot take a new turn (archived, or a free library over its allowance with no choice made) now says why above the composer, with a way to Work, and refuses the send with that same sentence instead of a generic failure, and CarPlay speaks that reason instead of "couldn't reach your AI".

## Setup

- iPhone + iPad + Mac on the same iCloud account with content sync on; a Watch paired to the iPhone; the CarPlay simulator rig (`docs/qa/carplay-simulator-rig.md`).
- In Work, create a project **Q3 launch** (pick a non-amber colour), add a note, and start a conversation from its Brief on any gateway. Send one turn and wait for the reply.
- Keep one ordinary chat around for comparison.

## Chats list (iPhone, iPad sidebar, Mac sidebar)

1. The Q3 launch thread's row shows a folder in the project's colour before its title. Ordinary rows show nothing and their titles have not moved.
2. Idle, its date slot reads `Q3 launch · <time>`. Send a turn: while it works the slot shows the usual status words and the name is gone; the folder stays. After the reply lands (unseen, bold) the name is back.
3. Rename the project in Work → the row updates without a new message. Recolour → the folder recolours.
4. Search for `q3` in Chats → the thread is found. Search for the project name with different casing/accents → still found.
5. VoiceOver on a project row: title, then "In project Q3 launch", then the gateway, in that order. On an ordinary row nothing new is spoken.

## Thread screen

6. Open the Q3 launch thread from Chats on iPhone, iPad and Mac: a thin line under the bar reads folder + `Q3 launch` + `Show in Work`. Open an ordinary chat: no line.
7. Tap `Show in Work`: Work opens at Q3 launch with this thread selected (iPhone: the tab switches; Mac: the window comes forward). Repeat from a cold launch straight into the thread.
8. Open the same thread from inside Work: no header line (the workspace frames it).

## Locked composer

9. Archive Q3 launch in Work, return to the thread in Chats. On iPhone, iPad and Mac the composer stays where it is and a notice above it reads `Restore this project before continuing its conversations or adding materials.` with a `Show in Work` button; the Retry chip on a failed turn (if any) is gone. Typing or recording still lands in the draft; tapping Send shows the same sentence and keeps the draft. Before archiving, stage an attachment (Mac and iPad) — it must survive the lock and the unlock.
10. Tap the notice's `Show in Work`: Work opens at Q3 launch. Restore the project; back in Chats the composer is live again and the header line loses "Archived".
11. iPad: while locked, press ⌘Return with text in the field — nothing sends, the reason shows, the draft stays.
12. Free plan over the allowance (sign out of Pro or use a free account): with four active projects the notice reads `Choose up to 3 active projects to continue on the free plan…`; its button lands on Work Home with the selection sheet.
13. Archive the project on the Mac while the iPhone is on the thread → within a few seconds the iPhone locks too (sync). Type and send before it does: the send is refused with the same sentence and the draft stays.

## CarPlay

14. Recent list: the Q3 launch row's grey line reads `1 day ago · Q3 launch` with a trailing folder at its right end; the gateway badge is where it was; the title is not truncated worse than before (check the longest title you have). Tapping the row still resumes the thread. Rename the project to something very long (30+ characters): the name is cut with `…` and the date still shows after it.
15. Archive Q3 launch, tap its row: the car speaks `This project is archived. Restore it in Work on your iPhone to continue.` and nothing is presented or recorded. The picker still works afterwards.
16. Restore, start the thread, and archive it on the Mac mid-session, then speak: the reply is the same spoken line, not "couldn't reach your AI".

## Watch

17. The Q3 launch thread's row shows the full title up top (no folder in front of it any more) and, at the right end of its date line, a small grey folder plus `Q3 launch`; the date stays at the left. VoiceOver says "In project Q3 launch". Ordinary rows: nothing, and their height matches. Send a turn from the phone: while the row says "Answering…" the folder and name are gone; when the reply lands they are back. Rename the project to something very long: the name is cut with `…` and the date is still whole.
18. Delete the project in Work (keep the conversations): folders vanish on the Watch, in Chats and in the car; the threads stay listed and open.

## Things that look wrong and are not

- A project thread whose project has not synced to this device yet shows a grey folder and no name in Chats; it names itself once the project arrives. On Watch and CarPlay it shows nothing until then.
- CarPlay puts the date first and caps the project name at 24 characters; the Watch lets the name run to the row's edge. Both are by design: the car's grey line clips at its end, and the date must never be what it clips.
- Archived idle rows show `Q3 launch · Archived` in place of the time.
