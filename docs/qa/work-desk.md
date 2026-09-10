# Work desk verification

Use the `codex/work-desk-20260909` worktree. Build the `Conduck` scheme for your device or Mac. This checklist covers behavior that compilation and unit tests cannot establish.

Rebuild and relaunch after pulling these fixes; an already running app still holds its old compiled labels.

Check the reported regressions first:

- Work shows readable labels such as Your desk, Projects and Select, with "1 material" or "14 materials" below the title. No internal `workdesk.*` keys appear, including in project sheets and the reviewed Send action.
- On Mac, Work has no New Conversation or Delete All button. Its native sidebar button collapses and expands the project rail. Switch back to Chats and verify its conversation buttons and previous sidebar state return. Repeat quick Work/Chats switches.
- On iPhone and iPad, Work's leading sidebar button opens project navigation. A wide iPad has an expandable rail; a compact window or phone has a picker. Resize across the wide/compact boundary while the picker is open, then return to wide and verify the rail still responds. No hidden Chat toolbar actions should appear in Work.
- The named Desk/Tiles/List control matches what is drawn. With Desk selected, search or open All materials/Pinned: the control should show List. Clear search or return to Your desk: Desk returns. With accessibility text enabled, the control shows List and cannot select a layout the board would ignore.

1. Open Work on iPhone, iPad and Mac. The Desk view should show movable cards and project stacks, with a project picker on a phone and a collapsible rail in a wide window. Switch among Desk, Tiles and List; relaunch and check the choice remains.
2. Capture text, a screenshot, an attached file and a voice note. Repeat with the existing share sheet, Shortcut, menu bar, Watch and CarPlay routes. Each capture should land unfiled on the same desk. Spoken notes keep their words; an audio file deliberately attached in Work remains playable.
3. Move a card using its top handle. Pan empty space, pinch to zoom, use the zoom buttons and Fit. Move cards far apart, leave Work, return and relaunch. Positions should remain, and Fit should reveal the whole arrangement. Capturing after grouping or deleting an early card should use free space.
4. Overlap two cards, or select several and choose Create project. Name it, open it, rename it and move more materials into it. Canceling the naming sheet should keep all materials where they were. Ungrouping a project should return its materials without deleting any file.
5. Pin materials and use Pinned, All materials and search. Search should reveal a matching item even if its canvas position is far away. In Select mode, tapping an audio card should select it; it should not start playback. Move Earlier/Later should move through the visible list, including inside a project.
6. Open a project's Prepare screen. Enter an instruction, choose a configured gateway and review the included materials. Exclude a material and verify it stays in the project. Check a hosted connection and a gateway with file transfer: unsupported files and missing bytes should explain what needs to change before review.
7. Review the prompt and attachment list, then explicitly send to the named connection. Exactly one new bound chat should open, with the original project intact. Double-tap Send. On Mac, use Stop in the resulting chat and verify it cancels that work. Check upload failure and normal Chat retry behavior with a deliberately unavailable test destination.
8. While reviewing, change or delete a selected source, gateway configuration or project on another window/device. Sending or saving stale work should be refused with a recoverable explanation. Test a missing local file and a file still arriving from iCloud. No file should silently turn into only a filename in the handoff.
9. Type an unfinished brief, then open a chat through a deep link. Return to Work: the draft should be retained. Complete a handoff while Work is hidden; it should not replace the chat you opened. Return and use Open chat, or deliberately prepare another handoff. Save & close, edit the project on another device, and reopen: the new edit should appear.
10. Check VoiceOver, keyboard navigation, large accessibility text and Reduce Motion. All organizing actions should remain reachable through selection or menus. Scrolling or tapping the desk should dismiss the capture keyboard; tapping inside the composer should focus it normally.

Private iCloud propagation, production CloudKit schema readiness, real provider behavior and physical capture surfaces require device/account verification. The unit suites use isolated stores and transport doubles; they do not prove those external behaviors.

Automated verification for this worktree:

- iOS suite after the toolbar and copy fixes: 6,033 tests, zero failures, one skipped; `TEST SUCCEEDED`.
- Watch suite: 302 tests, zero failures; `TEST EXECUTE SUCCEEDED`.
- iPhone/iPad simulator Debug-Testing build: passed.
- Native macOS arm64 Release build: passed.
- Compiled Mac Release and iOS English resources: all 107 Work desk/tutorial values match the authored catalog, including the formatted material counts and named Send action. The app suite checks actual bundle lookups and interpolation.
- Localization synchronizer: eight regression tests passed, including generated-symbol contamination, stale/incomplete compiler metadata, conflicting defaults, and preservation of unrelated translations.
- Builds use `CODE_SIGNING_ALLOWED=NO`; these results prove compilation and isolated tests, not signing or installation.
- Independent UI and storage/handoff reviews completed; a follow-up toolbar and localization review also completed. Actionable findings were fixed and affected checks rerun. This is source/failure-case review, not an on-screen UI pass.
- Storage seam, folder map, spec citations/size, bundled legal copies, localization coverage, source headers, diff whitespace and scoped secret scan: passed.

Verification covers local source and builds. No merge, push, deployment or device installation is included. The main checkout's existing changes are preserved. Task-specific build caches are removed after verification.

For future headless Work-copy updates, compile first, then run `python3 scripts/sync-workdesk-strings.py --objects <app Objects-normal/arm64>`. This checks authored compiler defaults without changing the catalog; add `--write` to apply them and rebuild before testing. The synchronizer refuses generated-accessor metadata, stale or incomplete extraction, and conflicting values. Its regression fixtures run with `python3 scripts/test_sync_workdesk_strings.py`; the app suite separately checks the English resources actually compiled into the app.
