# Content sync verification

The simulator suites exercise isolated SQLite files, preference ordering, process
locks, failure recovery and Watch wire handling. They do not establish that
CloudKit stopped exporting or that WatchConnectivity delivered on real hardware.

Use signed builds on two devices with disposable test content. Keep a third device
offline for the delayed-delivery case. Include a paired Watch for capture checks.

1. Open Settings → General. Content sync starts enabled when no preference exists.
   Confirm that conversations, a Work project and a small Work file arrive on the
   second device. Larger files retain their existing device-local behavior.
2. Turn content sync off. Check the confirmation describes the other devices and
   retained iCloud copies. Wait for the local transition to finish; verify the
   choice arrives on the second device. Existing downloaded content stays usable.
3. On each device, create, edit and delete separate test content and attach files.
   Check the changes remain on that device. Change a synced setting and check it
   still arrives elsewhere. Credentials keep their existing transport.
4. Repeat OFF while an AI reply is pending, during a Work file save, and while a
   Shortcut process is active. Replies and captures must save once, without
   repeating the AI request. A remaining mirror keeps the state pending; the
   screen must never claim it has stopped early.
5. Re-enable. Read the confirmation about changes and deletions from all devices.
   Verify additions, edits, deletions and file payloads converge without duplicate
   conversations or cards. Check the cloud's actual activity, not just the switch.
6. With sync off and a file's metadata present but its bytes absent, check that
   Work says the file is unavailable here. Opening/sharing must not promise an
   automatic download. Account/storage warnings should not nag about intentional
   OFF; local-storage failures must remain visible.
7. With sync off, capture both a voice note and a text Shortcut note on Watch.
   A confirmed phone receipt must lead to one Work card on the phone. An
   unavailable or older phone must receive a clear explanation. If OFF arrives
   after a local Watch save, the completion must say where the retained note is;
   it must not invite a retry as though the note had never been saved.
8. Deliver file metadata queued for Watch before OFF. It must not introduce a new
   automatic attachment overlay while OFF. Settings delivery must still work.
9. Bring the offline device back. Its choice applies when received, not while it
   was disconnected. A fresh install can use default ON before account settings
   arrive; an older build does not implement this preference.
10. Check "Delete all conversations" while OFF: conversation deletions remain
    local until sync resumes; Usage clearing still applies across devices through
    the independent settings cutoff. Work remains untouched.

For the macOS startup regression, run the updated signed build with an existing
library. Open Chats, Work and General after iCloud settings initialize. Existing
conversations and downloaded Work files must open, and the sync control must
finish loading. A preference-read failure may leave sync pending, but must still
allow local reads and saves. The automated regression uses isolated Core/Blobs
files and the production policy-file adapter with failed defaults flushing.

For account sign-out, account changes and backup restoration, use test accounts
and disposable libraries. Verify that a known OFF survives absent settings and
that explicit re-enabling identifies the current iCloud account. Existing cloud
copies and device backups are not erased by this switch. Do not interpret an
already accepted export as a new transfer after the local mirrors were detached.
