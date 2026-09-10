# Work desk polish — local verification

The freely arranged Desk supports movement from the whole object, including
overview cards. Search lives in project navigation and finds materials across
Work. Creating a project keeps the desk visible at the intended location.

## Automated verification

- Full iOS simulator app suite: 6,121 tests, zero failures; `TEST SUCCEEDED`.
- Native macOS arm64 Release build: `BUILD SUCCEEDED`.
- All 113 authored Work strings match the compiled English resources on both
  platforms. Localization synchronizer: nine tests passed.
- Storage seam, source headers, folder map, spec citations/size, bundled legal
  copies, scoped secret scan and diff whitespace checks passed.
- Independent implementation/design review and separate first-time/frequent
  user reviews completed; actionable findings were resolved.

The unsigned tested app is installed and launched on the iPhone simulator.
The build cache is temporary; installed simulator app data is separate.
Test/build logs are `/private/tmp/conduck-work-polish-ios-final-tests.log` and
`/private/tmp/conduck-work-polish-mac-build.log`. No commit, push or release is
included. Unrelated existing localization edits are preserved.

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
5. Pin a project, open Pinned, and check both the project and navigation count.
   Search by project title and confirm its materials are discoverable too.
   Inside a project, the composer names Your desk as its destination. Capture
   a note and use its destination link to find the new card on Your desk.
6. On an empty desk, pan before adding the first material. It should become
   visible. After arranging existing materials, deliberately pan to blank
   space, search or switch layout, and return: the camera must stay there.
7. On a narrow phone project view, the title and Prepare action remain usable;
   layout options are available in the project options menu. Check large text,
   VoiceOver selection/pin/movement actions, and keyboard movement from a grip.
8. Delay/fail a save, drag again, and ensure old completions cannot undo the
   newer position. Delete or reassign a selected source in another window
   before release: the stale movement must fail without scattering the group.

These checks cover native gesture arbitration and actual presentation. Unit
tests and unsigned builds do not prove pointer/touch feel, private iCloud
propagation, physical capture surfaces, or provider behavior.
