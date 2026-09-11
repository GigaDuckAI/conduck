# Work desk polish — local verification

The freely arranged Canvas uses one uniformly scaled surface per object, including
overview cards. Organization actions live in item menus; pinning is absent. Search lives
in project navigation and finds materials across Work. Creating a project keeps
the desk visible at the intended location.

See [Work desk verification](work-desk.md) for the sidebar, capture, migration and
selection checks. This checklist focuses on native interaction and appearance.

## Hands-on checks

1. Open Work on Mac, iPad and iPhone. Search belongs in the sidebar/project
   picker. On a phone, submit or choose Show results to dismiss the picker.
   Find a material inside another project, then clear the query: the previous
   location and camera should return. On Mac, Command-F opens/focuses search.
2. Drag a note by its text, an image by its preview, and a project by its body.
   Repeat in overview and Select mode. Ordinary clicks still open previews,
   select items and toggle playback once. Dragging across those controls must
   never open or play them on release. In overview, Select mode still toggles
   selection and every selected card retains its outline.
3. Drag left/up through the original desk origin and beyond all four viewport
   edges. Selected groups retain spacing. Escape during a held drag cancels
   once; continued pointer movement must not restart it. Two-finger navigation
   and switching to Chats also cancel the old drag.
4. Pan/zoom the desk, then create a project with the sidebar plus. It appears
   in the visible area, with the desk still open. Select cards and create a
   project: it appears at their cluster. On Mac, right-click blank desk space
   and create a project there. Cancel naming: nothing moves or groups.
5. Search by project title and confirm its materials are discoverable. Inside
   a project, the composer names that project. Capture a note and find the same
   card in the project and All materials. Repeat with the microphone, attachments
   and a drop. Start recording in the project, then navigate before transcription
   finishes: the note retains its original destination. Search captures, including
   the microphone, go to All materials.
6. On an empty desk, pan before adding the first material. It should become
   visible. After arranging existing materials, deliberately pan to blank
   space, search or switch layout, and return: the camera must stay there.
7. On a narrow phone project view, the title and Prepare action remain usable;
   layout options are available in the project options menu. Check large text,
   VoiceOver selection and movement actions, and keyboard movement with the
   whole card focused. Verify pin actions are absent from card and project menus.
   Select/Done and Select all remain reachable in a narrow window. A project
   first opens as Tiles; choosing Canvas or List there leaves All materials and
   other projects unchanged. Relaunch and check each remembered layout returns.
8. Delay/fail a save, drag again, and ensure old completions cannot undo the
   newer position. Delete or reassign a selected source in another window
   before release: the stale movement must fail without scattering the group.
9. Zoom through the overview threshold repeatedly. Material and project faces
   should scale as single surfaces, with no separate top section or abrupt face
   replacement. Separate cards retain their spacing at small zoom levels.
10. On Mac, start far zoomed out and make small trackpad pinches in both
    directions: changes remain proportional and reverse immediately. On touch,
    move the pinch centre while zooming; the same content follows the fingers.
    Lift one finger and end the gesture without a jump. Repeat after leaving
    and re-entering the canvas, and near excluded zoom controls.
11. Use Fit from several starting zoom levels: the resulting framing is the
    same. Tap close to a tiny overview card to focus it. A nearby card's touch
    reach must not cover the visible face of another card.

These checks cover native gesture arbitration and actual presentation. Unit
tests and unsigned builds do not prove pointer/touch feel, private iCloud
propagation, physical capture surfaces, or provider behavior.
