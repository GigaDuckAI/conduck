# Work chrome — QA handoff

The Chats / Work switch now lives in the same place on iPad as it does on the Mac, and the phone gets Apple's tab bar in the brand colour. Mac is untouched.

## What changed, per platform

### iPad

Work is reachable again. The amber **Chats | Work** switch sits at the far right of the navigation bar in **both** sections — the same position and size in Chats and in Work, so it never slides sideways when you move between them.

Previously nothing drew it at all on iPad: the switch was declared above each section's navigation container, where no bar collects it. Each section now declares it inside its own container — the conversation column for Chats, the board's own stack for Work.

Work's bar also gains a **view menu** (the small tiles/list glyph) immediately to the left of the switch. It holds the board's Tiles / List choice, with a checkmark on the current one. That choice is remembered between launches.

Because the view menu owns the choice, the segmented **Board view** picker and the **Drag to reorder** hint are gone from the scrolling board area — the cards now start at the top of the pane. The tutorial that runs the first time you open Work already teaches dragging.

### iPhone

The bottom tab bar reads **Chats** then **Work**, left to right, matching the order on the switch used by iPad and Mac. The selected tab is drawn in Conduck amber; everything else keeps the system colour.

The amber is scoped to the tab bar alone, and it is scoped by construction rather than by care: the colour is set on the system's tab-bar appearance, which reaches the bar itself and nothing else. Everything the tabs contain — navigation-bar buttons, links, toggles, filled buttons, even the text cursor and selection in the message box — keeps the ordinary iOS accent, exactly as it does on iPad and on any sheet the app puts on screen. The obvious alternative — painting the colour onto the screen the tabs contain and hoping it only shows up in the bar — tints everything inside them as well, and clearing it back out from inside a tab does not undo it.

This also leaves the Mac alone. The app deliberately ships without a global accent colour so the Mac honours whatever accent the user has chosen in System Settings, and nothing here changes that.

The **Conversations** button in the top-left uses a sidebar-style glyph, so it visually rhymes with the sidebar toggle the iPad and the Mac both put in the same corner. It still opens the conversation list as a sheet, and it is still called "Conversations" for VoiceOver. **New conversation** stays top-right.

Work's bar on the phone shows the title, the view menu top-right, and nothing top-left. The Chats / Work switch never appears on the phone — the tab bar is the only section switch there.

### iPhone Pro Max, landscape

A large phone in landscape reports the same width class as an iPad, so it stays explicitly on the phone layout: tab bar, single column, no Chats / Work switch.

### Mac

Nothing changed. `MainWindowView.swift` and `LeadingToolbarChrome.swift` are untouched by this work.

## Files changed

- `Conduck/ContentView.swift`
- `Conduck/ViewModels/WorkboardViewModel.swift`
- `Conduck/Views/Conversation/ConversationLibraryView.swift`
- `Conduck/Views/Workboard/PersonalWorkbenchView.swift`
- `Conduck/Views/Workboard/WorkboardCaptureCanvas.swift`
- `Conduck/Views/Workboard/WorkboardView.swift`
- `ConduckTests/ConversationWorkbenchToolbarDriftGuardTests.swift` (new)
- `ConduckTests/PhoneWorkbenchChromeDriftGuardTests.swift` (new)
- `ConduckTests/WorkbenchSectionToolbarItemBindingTests.swift` (new)
- `ConduckTests/WorkbenchShellDriftGuardTests.swift` (new)
- `ConduckTests/WorkboardLayoutModePersistenceTests.swift` (new)
- `ConduckTests/WorkboardToolbarDriftGuardTests.swift` (new)
- `ConduckTests/WorkboardDeskSurfaceDriftGuardTests.swift`

## QA script

One note before you start: in QA mode the red **QA MODE** banner is drawn over the top ~83 points of the screen, which covers the upper half of the navigation bar. The switch and the bar buttons sit *behind* it, not clipped by the bar. If you want a clean look at the bar, run without QA mode.

### 1 — iPad (any size, portrait)

1. Open the app in Chats with the sidebar showing and no conversation selected.
   - The amber **Chats | Work** switch is at the far right of the right-hand column's bar.
   - Nothing sits to the right of it.
   - The gateway name is centred in the right-hand column.
2. Tap the first conversation in the sidebar.
   - A **Copy conversation** button appears in the bar.
   - Copy sits to the **left** of the switch, and the switch has not moved a pixel.
   - *Failure to look for:* the switch jumping left as Copy appears, or Copy landing to the right of it.
3. Hide the sidebar with the system sidebar button, then repeat steps 1 and 2.
   - The switch stays in exactly the same place in all four combinations.
4. Type a few characters into the message box, then tap **Work**.
   - Work appears, filling the window.
   - The title reads **Work**, centred.
   - A view menu glyph sits immediately to the left of the switch.
   - The switch is in the same place it occupied in Chats — no sideways jump during the crossfade.
   - *Failure to look for:* the switch shifting position between the two sections.
5. Look at the top of the board area.
   - The first card (or the empty-board message) starts right under the bar.
   - There is no segmented **Board view** picker and no **Drag to reorder** line in the scrolling area.
   - *Failure to look for:* either of those still sitting above the cards.
6. Tap the view menu.
   - Exactly two entries: **Tiles** and **List**, with a checkmark on the current one.
   - Choose **List**. The board redraws as full-width rows.
7. Quit the app from the app switcher and reopen it, then go to Work.
   - The board is still in List, and the view menu shows the checkmark on **List**.
   - *Failure to look for:* the board reverting to Tiles.
8. Tap **Chats**.
   - The same conversation is still selected.
   - The characters you typed in step 4 are still in the message box.
   - *Failure to look for:* an empty message box, or the conversation selection cleared.
9. Look closely at the switch itself.
   - It is a single filled capsule with two segments — not a capsule inside another glass capsule.
   - It is not cut off at the top or bottom by the bar.

### 2 — iPhone

1. Open the app.
   - The tab bar reads **Chats** (left) then **Work** (right).
   - The selected tab's icon and label are amber, not blue.
   - *Failure to look for:* blue selection, or Work on the left.
2. Look at the top bar in Chats.
   - The left button is a sidebar-style glyph; it is **not** amber — it is the ordinary light label colour.
   - The gateway name is centred.
   - **New conversation** is top-right and also not amber.
   - *Failure to look for:* amber bleeding into either bar button.
3. Tap the left button.
   - The conversation list opens as a sheet with the seeded conversations in it.
4. Close the sheet and tap the **Work** tab.
   - The bar shows the title, a view menu top-right, and nothing top-left.
   - There is no Chats / Work switch anywhere on the phone.
   - *Failure to look for:* the switch appearing in the bar on top of the tab bar — two section switches at once.
5. Look at a coloured control **inside** a tab. The one to check is the **Retry** button on the "Your last recording couldn't be sent" card, which sits at the top of Chats whenever recordings are waiting to be sent — record something with the gateway unreachable if the card is not already there.
   - **Retry** is the ordinary iOS blue, not amber. Only the tab bar is amber.
   - Second control, if no recording is waiting: type a word in the message box and double-tap it. The selection highlight and its two round handles are blue.
   - *Failure to look for:* **Retry**, the selection highlight, or any other filled button, link or toggle inside a tab drawn in amber. The same controls are blue on iPad and on any sheet, so a side-by-side comparison settles it.

### 3 — iPhone Pro Max, landscape

1. With the app open, rotate to landscape.
   - The tab bar is still there, at the bottom.
   - There is no sidebar, no two-column split, and no Chats / Work switch.
   - *Failure to look for:* the iPad two-layer layout appearing on a phone.

### 4 — Mac

No change is expected. Confirm the window still opens with New chat and the sidebar toggle on the left, the gateway name in the middle, and the Chats | Work switch at the far right, and that Work still collapses the sidebar column.
