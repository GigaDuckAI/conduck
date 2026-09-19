# Changelog

Notable changes to the Conduck app for iPhone, iPad, Mac, Apple Watch and
CarPlay. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
Each section is named for one tagged App Store build — the marketing version
and build number Apple shows — and matches `v<version>-<build>` in this
repository. Versions 1.3 and 1.4 shipped on macOS while iOS moved directly
from 1.2 to 1.5.

## [1.6.3-16] — iCloud sync reliability

Release build, tagged `v1.6.3-16` on 19 September 2026.

### Fixed

- An issue that could cause iOS to terminate Conduck when it moved into the
  background with content sync enabled. Sync coordination no longer holds a
  file lock while the app is suspended, and still waits for other Conduck
  sessions to stop before confirming sync is off
- iCloud storage warnings remain until the affected content successfully
  uploads. Returning to the app, temporary account interruptions and successful
  downloads no longer incorrectly clear an unresolved storage warning
- Unresolved iCloud storage warnings are restored from retained sync history

## [1.6.2-15] — the iPhone bar tidy-up

App Store build, tagged `v1.6.2-15` on 17 September 2026. 7 commits since 1.6.1.

### Changed

- iPhone: the chat bar keeps four glyphs — Conversations, New conversation, the
  gateway title (the bar's only dropdown) and one icon that flips between Chats and
  Work. The "Chats ⌄" section menu is gone. Copy conversation moves into each
  bubble's actions menu. iPad and Mac are unchanged
- Free plan: the "Choose active gateways" reminder in Settings shows only while a
  choice is still needed; an inactive gateway's editor keeps the link for revising
  a completed choice

### Fixed

- iPhone and iPad: the composer's trailing button no longer flickers send → mic →
  Stop on every send. The attachment-only send keeps its slot while attachments
  are staged, and the recording / transcribing status row has one fixed height, so
  the bar stops jumping
- Work opens to the same connect-your-AI screen as Chats when no gateway is
  configured, with a button into the guided setup (iPhone, iPad, Mac)

### Developer-facing

- README gains a two-minute quick start (Ollama on the LAN, OpenRouter, the
  adapter path)
- `docs/qa/qa-mode.md` names the CloudKit environment of Xcode-installed builds
  correctly (Development)

## [1.6.1-14] — the Mac sync fix

App Store build, tagged `v1.6.1-14` on 15 September 2026. 5 commits since 1.6.

### Fixed

- The Mac app now carries the push entitlement macOS needs for iCloud sync. In 1.6
  the Mac was signed without it, so a conversation or a Work capture made on iPhone,
  iPad or Apple Watch reached the Mac only at the next scheduled import or when the
  app was brought to the front. With the entitlement the Mac imports within about a
  second of a push arriving. Apple's push service can still hold a Mac's
  notifications for a while; that part is outside the app
- Mac → iPhone, iPad and Watch, and every direction between the iOS devices, were
  already immediate and are unchanged

### Developer-facing

- Debug builds log each iCloud import, export and setup event, and a
  `-ConduckInitializeCloudKitSchema` launch flag fills the CloudKit Development
  schema before a Production deploy (documented in `docs/qa/qa-mode.md`)
- Builds with Xcode 27: two protocols gained the isolation annotation the new
  compiler requires, and the Watch schemes drop an attribute Xcode 27 removes

## [1.6-13] — the Work release

App Store build, tagged `v1.6-13` on 14 September 2026. 125 commits since 1.5.

### Work — a private desk beside your chats

- Work is a new destination next to Chats on iPhone, iPad, Mac, Apple Watch and
  CarPlay. It is a board of cards — thoughts, files, screenshots, photos, links and
  spoken notes — that you collect first and brief your AI with later. Adding to Work
  sends nothing to your AI. Every capture surface says so on its receipt: "Added to
  Work. Nothing was sent."
- Captures arrive from the app's composer, drag and drop, paste, the share sheet,
  Shortcuts, a chat message's menu, the Mac menu bar, Apple Watch and CarPlay. A link
  card saves the address as text; Conduck never fetches the page in the background
- Cards open in place: images in a full-screen gallery with a counter, arrow keys and
  Share; files in Quick Look; links in the browser. Any card can be shared, with a
  note going out as text, a link as a URL, and an image or file as a disposable copy
- Three layouts — Tiles, List and a freeform Canvas that pans and zooms, with Fit and
  Reset zoom. Cards keep the order you leave them in, in every layout, and a capture
  that lands mid-drag slips in behind the card you are holding rather than
  interrupting you. VoiceOver gets Move Earlier / Move Later and the Canvas exposes
  Move up / down / left / right and Zoom in / out as accessible actions
- Search across the whole of Work — "Find an idea or file" — crosses project
  boundaries on purpose
- A screenshot and the voice note spoken with it appear as one card, "Screenshot with
  note", with a play control and per-part Open, Share and Reattach actions
- Every image card is normalised at the desk write, on every lane: a JPEG capped at
  1568 px on the long edge — the same size a chat turn sends inline — with EXIF, GPS,
  TIFF, IPTC and XMP metadata stripped. GIFs, multi-frame images and already-small
  clean JPEGs pass through untouched. This says nothing about images you send in a
  chat, which are unchanged
- A first visit to Work shows a four-page introduction — a home for your next idea,
  catch it where you find it, bring related ideas together, give your AI the right
  context. It appears once per device, only when you deliberately switch from Chats to
  Work, and steps aside for anything you are in the middle of

### Work — projects

- Hold one card over another to group them into a project. A project has a name, one
  of six colours, an optional brief (standing instructions for every conversation
  started from it), a preferred gateway, its own layout, its own composer draft and
  its own Canvas viewport. Projects can be pinned and previewed without leaving the
  board
- Home holds loose cards; All materials shows everything, including cards filed into
  projects. A card can live in more than one project — Add to another project, Move,
  Remove from this project, Move to Home — and a card's detail says "In N projects".
  Filing, moving and removing can be undone from a banner
- A capture made from inside an open project — composer, file picker, drop or
  microphone — lands in that project; the destination is frozen at the moment you
  submit, so a slow import does not follow you to wherever you navigated next. The
  share sheet, Shortcuts, the menu bar, Watch and CarPlay have no project context and
  still land on Home. The capture bar and drop overlays name where the material will
  go, and a batch that saved but could not be filed says so with a count
- Notes on any material — "Add notes…" — travel with it into a conversation. Text
  cards and voice transcripts are editable, with the original kept behind Preview
  original. A card shows "Used in N conversations" and opens the conversation it was
  used in
- Deleting a project is reviewed: keep its materials (those only in that project
  return to Home; those used elsewhere stay put; notes are kept) or delete the project
  and its materials everywhere. A project that changed underneath the review forces a
  re-review

### Work — briefing your AI

- New conversation from a project opens a full review: your task, a checklist of
  materials ("N of M included"), the gateway, and an exact preview of the outgoing
  message before Send. What the gateway can take is stated up front — text, images and
  attached files; text and images with file transfer not connected; or a hosted model
  with no file workspace
- Conversations started from a project stay nested under it in Work, and materials
  from elsewhere in Work can be pulled in without moving them. Drafts persist per
  project and survive an interrupted send, with explicit handling when another window
  changed the same draft
- With a self-hosted agent and file exchange set up, files your AI returns appear as
  Result cards in the project, each linking back to its source conversation. A file
  still on the gateway says so and tells you how to bring it in. On the hosted
  OpenRouter lane there is no file workspace, and the brief says so
- A conversation that belongs to a project is marked wherever it is listed: the
  project's folder and name on a Chats row and in search; a line under the thread's
  navigation bar with Show in Work; the project name on the Watch row's date line; and
  "2 hr ago · Q3 launch" on the CarPlay Recent row, capped at 24 characters with no
  colour and never any message content reaching the car screen
- A project that cannot take a new turn says why. When a project is archived, or a
  free-plan library holds more active projects than the allowance and no choice has
  been made yet, the reason appears above the composer with a button into Work, every
  send path refuses with the same sentence, and the draft, staged files and any capture
  in flight are kept

### Work — spoken notes

- A spoken Work note reaches the desk as its words alone. Every voice lane bound for
  Work — the in-app sheet, the Mac menu bar, a Shortcut, CarPlay, the Watch relay —
  parks the recording in a device-local retry lane, transcribes it, writes a
  words-only card and deletes the audio. Nothing reaches the desk or iCloud before the
  words exist; a failed transcription leaves the desk untouched and the recording
  waiting behind Try Again, with a confirmed Discard
- The audio goes only to the speech provider you chose, and only to be turned into
  words — never into a conversation, and never through a server of ours. Conduck has
  no intermediary servers
- Recordings are kept only when you add them yourself, through the attachment button
  in Work or a drop into the Work pane; those become playable cards with one-at-a-time
  playback. The share sheet, the Add Files Shortcut and Chat → Work refuse a recording
  and name the door

### Work — sync

- With content sync on, the desk syncs through your own private iCloud, bytes
  included, up to 30 MB per card. A larger file stays on the device that captured it;
  a confirmation says so at capture time, the card reads "Available on this device"
  elsewhere, and a Reattach action is offered. A card still arriving reads "Waiting for
  iCloud…" and stays inert until its bytes are proven present
- Card payloads live in a second store under their own iCloud container. The Watch
  mounts only the conversations store and holds no card bytes, by construction
- A named iCloud problem — signed out, storage full, restricted — gets its own banner
  instead of a silently unsynced desk

### Conduck Pro and the free plan

- Conduck introduces a free plan and an optional Conduck Pro auto-renewing monthly
  subscription, sold and managed entirely by Apple. There is no Conduck account and no
  licensing server; access is derived on-device from Apple-signed transactions
- The free plan is exactly two allowances: three active Work projects, and three
  configured gateways in total across OpenClaw, Hermes and custom connections.
  OpenRouter never uses a gateway slot and is always available. Pro removes both
  limits
- The gateway allowance changed shape. It used to cap custom gateways only; it now
  counts built-in and custom gateways together. If you already have more than three
  configured, Conduck asks you to choose which three stay active. The others are
  retained with their credentials — they simply cannot dispatch until you pick them or
  subscribe. Nothing is deleted
- Archiving a project frees a slot and changes nothing else: every material,
  conversation and byte stays. An archived project refuses new materials and new turns
  until restored. Going over the project allowance — when a subscription ends, for
  instance — opens a Choose projects sheet that archives only after you confirm
- The paywall is Apple's native subscription sheet, so the price, billing period and
  purchase button come from the App Store in your locale. It opens from a Conduck Pro
  row in Settings and from wherever a limit is met; the "Set up a custom server" row is
  no longer disabled at the cap, it opens the paywall with a Manage gateways escape.
  Purchasing returns you to the same, unchanged editor and never saves, probes or
  sends anything. Restore Purchases and Manage subscription sit on the sheet itself
- The allowance is enforced on every dispatching surface — the Watch, CarPlay and the
  Converse Shortcut all wait for the first verified entitlement read and refuse an
  inactive gateway by name. The Watch never asks you to choose; it points you at
  Work on iPhone, iPad or Mac. The Watch can be narrowed by the phone but never
  granted Pro by it
- AI and speech usage stay billed by your own providers, separately from the
  subscription. A Community build from this repository has no product configured,
  sells nothing, and says so on the paywall; the free-plan limits still apply unless
  you change the source

### Chats

- A gateway presence dot in the chat toolbar on iPhone, iPad and the Mac window
  answers "can this device reach the gateway I am about to talk to" before you type.
  It does no polling, and its verdict expires on its own clock — red after 30 seconds,
  green after five minutes — so a gateway you have since fixed stops reading red
  forever. The label is "Connection check failed", because the probe cannot tell a
  rejected key from an unreachable machine
- Each message carries a visible actions menu — Copy message and Save message to Work
  — kept off the message body so native text selection on long-press and right-click
  still works. Check for returned files and Search for files this reply mentions
  appear only beside a relevant file problem, not on every reply
- The full-screen attachment gallery gains a header: filename, position counter,
  Previous/Next, arrow keys and Share. On macOS it renders one page at a time instead
  of falling through to a strip of unlabeled segments
- On iPhone and iPad, tapping empty space or dragging a short list dismisses the
  keyboard, in a chat thread and on the Work board. A one-message thread used to hold
  the keyboard up with no way down
- Deleting all conversations names what it does and does not touch: with content sync
  on, the deletion reaches all devices; with it off, it can still propagate later, and
  usage history is cleared account-wide either way. Work is untouched

### Settings

- Sign in with OpenRouter. Guided Setup's hosted step can create an API key in your
  own OpenRouter account through the system web-auth sheet — nothing to copy. Pasting a
  key remains an equal alternative and every failure path points back to it. Every
  request to OpenRouter now identifies the app with attribution headers, sent to the
  OpenRouter host only — a self-hosted gateway, a lookalike host or a speech vendor
  never sees them, and they carry no content and no key material
- Content sync is an explicit setting — General → Sync → "Sync content with iCloud".
  It is on by default, the choice itself syncs across your devices, and both
  directions are confirmed with a dialog that says what turning it off does not do:
  it does not free iCloud storage, and it does not stop settings and keys from
  syncing. Live per-device status sits beneath the toggle, and a Work file that is not
  on this device says whether it is waiting for iCloud or content sync is off
- Usage explains how it counts. A "How usage is counted" row states that a turn is one
  message and a retry adds an attempt, that success rates use succeeded and failed
  attempts, that reply times cover successful replies only, that token reporting may
  be incomplete and is never a bill, and that removing a gateway or a conversation
  keeps its history. A removed gateway keeps its last known name — "Acme box
  (removed)", or "(unavailable)" when it merely vanished from a synced roster — and a
  rename shows up live. Breakdown rows carry attempts and share only; the rates moved
  into their detail cards
- Usage figures now stay tied to the date range on screen; a fetch error or a range
  change could previously leave figures from a different range in place
- Diagnostics lists permission, sync and recording checks directly, invalidates stale
  results instead of showing them, deduplicates repeated problems, adds a "Not tested"
  state, and deep-links connect failures to the matching recipe at
  conduck.com/setup/tls. Sync-history rows say plainly that history does not establish
  current sync health
- A quiet native App Store review request: after three separate days of use, during
  a calm foreground moment, Apple's own prompt is shown once, ever. Write a Review in
  About opens the store page directly and permanently retires the automatic prompt.
  Community builds show neither
- Gemini speech-to-text moves to the dedicated `gemini-3.5-transcribe` model on the
  Interactions endpoint, asking Google not to retain the request and pinning verbatim
  mode so a future default cannot silently tidy your disfluencies. Its errors say
  something useful: an auth failure reads as one, a rejected request points at the
  model name in Advanced settings, and rate-limiting is told apart from a billing
  quota — defaulting to transient, so a rate-limited user is not told to top up an
  account with money in it. Existing custom model overrides keep working untouched

### macOS

- Capture to Work from the menu bar, on ⌃⌘W: a region-capture overlay ("Drag to
  capture · Return to skip · Esc to cancel"), then a spoken note, with a Work HUD that
  mirrors the Ask HUD. A second hotkey press or a status-item click stops it, and a
  screen-recording refusal offers Continue Without Screenshot. Keyboard Shortcuts in
  Settings lists all three recorders
- The menu-bar composer names its destination — Add to Work beside Ask — and the
  popover gains Retry saved recording and Cancel transcription. Quitting with a
  capture that has not reached the desk is guarded: "Quitting now loses what was
  captured", with Keep the Capture
- Work fills the window: switching to Work collapses the sidebar column, switching
  back restores the column state you had. Work and Chats share the same full-height
  native sidebar, search and Settings controls, and switching between them keeps
  workspace state, capture focus and the menu-bar surface in step
- The Canvas zooms with a mouse wheel and pans with trackpad scrolling; the two are
  told apart by gesture phase, so a precise-scrolling mouse still zooms
- The Conduck Pro sheet is 620 pt wide, clamped to the visible screen height so it can
  never exceed a short display, with the close control overlaid instead of an empty
  action bar beneath the purchase controls

### iPhone / iPad

- iPhone moves Chats | Work into an expandable header control in the navigation bar,
  and iPad gains the Chats | Work switch in its toolbar. Before this, Work was
  unreachable from Chats on iPad, and an external capture that landed in Work stranded
  you there
- The Conduck Pro row sits below About in iPhone Settings, and the paywall's type and
  footer links scale and reflow with large accessibility text instead of clipping
- The Pro sheet mounts one StoreKit view for its whole life, keyed on the product
  identifier, so it no longer swaps layouts and jumps while the product loads

### Apple Watch

- Every Ask press opens a "Where to?" chooser listing your gateways first and Add to
  Work last, even with a single gateway configured. Add to Work has its own capture
  screen — Starting…, Tap to Stop, "1 min left", Saving to Work… — and ends with
  "Saved to Work." or "Saved on your watch. It reaches Work when your iPhone is
  nearby." Captures relay through the paired iPhone and queue durably on the wrist
  until it is in range; with content sync off, the Watch says where the note went and
  what to turn on to see it elsewhere
- The launchpad no longer flashes a greyed Ask button and a "Recording…" caption while
  the capture screen is being pushed

### CarPlay

- The gateway switcher in the navigation bar appears from the first configured
  gateway (it used to need two), and the Choose AI list it opens ends with Add to
  Work. The root list carries an Add to Work row only when no gateway exists at all
- Spoken receipts for Work: "Saved to Work.", or "Kept on your iPhone. Open Conduck to
  add it to Work." when the words have not landed yet
- CarPlay pre-flights a thread before listening and speaks a project refusal —
  "This project is archived. Restore it in Work on your iPhone to continue." —
  instead of collapsing it into "couldn't reach your AI", which blamed the gateway
  for a project fact

### Shortcuts and the share sheet

- Three Work intents: Add to Work (a thought), Add Files to Work, and Record a Note to
  Work. The Converse intent gains a Destination parameter, Chat or Work, and the
  bundled GigaAction shortcut gains a Send to Work branch that takes a screenshot,
  records audio and lands both on the desk with no gateway step
- The share sheet is rebuilt around one "Where to?" list of gateways and recent chats
  with search, on iPhone, iPad and Mac. Add to Work sits on the floor beside Send,
  captioned "Nothing is sent to AI"; Send names its target — "Send to <gateway>" or
  "Send to <chat>" — and your default gateway opens highlighted, so nothing leaves
  until you press the button that says where it goes. Recordings, folders and package
  documents are refused with the reason

### Files

- The file lane speaks only when a file was in play. A plain text turn under a
  stopped file server no longer draws a paragraph about lost files, opening a thread
  with no network signal no longer paints "Couldn't read your file server" under the
  replies or opens a backoff against a healthy server, and a reply that merely echoes
  a filename you uploaded stays silent

### Fixes

- The app could deadlock permanently and silently. Three observers of the
  conversations-changed notification each spawned a task per notification, all
  reaching a fetch whose fault fulfilment parks a dispatch worker; a burst hit
  libdispatch's 512-thread limit and the process could schedule nothing again — no
  crash, no report. Each surface now coalesces to one in-flight refresh plus one
  trailing pass, which also fixes an older share-targets snapshot committing over a
  newer one
- A signed macOS build could fail to open Chats and Work at all when a failed defaults
  flush left the content-sync preference unreadable. The preference now has its own
  store and an unreadable policy never blocks local database access
- The first signed launch crashed once the payload store was added, because Core Data
  refuses two stores mirroring one iCloud container. The payload store mirrors through
  its own container and mounts local-only, with a log line, when that container is not
  entitled
- A released drag in Tiles or List shows its intended order immediately while the save
  runs, instead of snapping back; a pane-wide drop receiver no longer outlines the
  whole window and steals precise drops in populated layouts
- The drop overlay drawn over an open project named the wrong destination, and its two
  catalog rows were stuck in state `new` so they never compiled into the English
  resources
- A replay after Reattach could retire the replacement payload you had just attached;
  a stale re-drain could revert a file attached afterwards
- Usage hid the device and gateway sections entirely when every attempt was
  unattributed, so the missing mass was invisible rather than explained
- A note card could repeat its first line as its own body, and a share-sheet note
  could show the wrong title

### Project

- The architecture document states the Work desk's boundaries as decisions: captures
  never dispatch themselves, a spoken note is its words, the 30 MB sync ceiling, the
  free-plan allowances and what archiving does, and the content-sync policy and its
  limits — offline devices, older builds and fresh installs cannot be remotely
  prevented from syncing
- The Conversations data model advances seven versions; migration is additive
  throughout and both parallel-branch lineages are kept so a TestFlight store from
  either migrates forward
- QA runbooks for content sync and for project threads record the device-level checks
  the simulator suites do not cover: real CloudKit stop and resume, WatchConnectivity
  delivery on hardware, and native StoreKit transactions
- The pairing importer is tested against conduck-connect's frozen pairing vectors

Verified: iOS 6722 tests / 0 failures · watchOS 318 / 0 · Release builds green on iOS and macOS · macOS test bundle compiles · six CI source guards clean

## [1.5-11] — the measurement release

App Store release, 28 August 2026. Tagged `v1.5-11`.

### Usage — measuring your own setup, on your own devices

- Settings gains a Usage screen on iPhone, iPad and Mac: how many turns you sent,
  how many landed, how long a complete answer took, and whatever your gateway was
  willing to say about tokens. It answers a question the app previously could not —
  is this setup actually working, and which of my gateways is the slow one
- The measurement never leaves your devices. A record is written beside the
  conversation it describes, in the same local database and the same private iCloud
  mirror that already holds your threads, and there is nowhere else for it to go:
  Conduck has no server, so a dashboard that reported home would have had to invent
  one. Nothing in this release changes what leaves the device
- The records are content-free, and that is a release-blocking constraint rather
  than a preference: no prompt or reply text, no gateway address or host, no token,
  no gateway name, no provider error string, no HTTP status. What is kept is
  timings, an outcome, a stable local error code, and the handful of fields the
  gateway itself reported. The gateway is stored as the same opaque reference a
  conversation already binds to, and the name you read is resolved when the screen
  is drawn. "There is nothing to disclose because there is no server" holds only
  while what is stored could not embarrass you if it were disclosed anyway, and
  usage data is exactly where that erodes — one convenient field at a time
- The few strings that do arrive from the wire are length-bounded and refused
  outright when they carry control or bidirectional-control characters. A ledger is
  read back into an interface, and text from someone else's server is untrusted input
- Writing a record is best-effort and can never block, lose or duplicate a reply.
  That is carried into the copy: these are recorded attempts, never "totals" —
  claiming a completeness the design deliberately declines to provide would be the
  wrong kind of accurate
- An activity chart with five measures — Turns stacked by outcome, Tokens, Models,
  Devices, Gateways — over 7, 30 or 90 days or all time, folding to weekly or
  monthly buckets on the wider ranges. Selecting a period says what happened in it,
  and the chart carries a per-period VoiceOver audio graph
- Reliability leads with the share of resolved attempts that succeeded — cancelled
  and unconfirmed attempts stay out of that rate — and opens onto delivered-first-try,
  recovered-by-retry, retry rate, attempts per completed turn, and replies cut short
- Failure reasons are grouped, and a reason opens the individual turns behind it
  with a link into each conversation. A rate tells you something is wrong; the
  incident list tells you which morning it happened
- Full-response time reports the average and the 90th percentile, and states what it
  includes: the network and any tools your agent ran, not model latency
- Reported tokens leads with the total your gateway reported and the share of
  attempts it reported on. Input, output, cached input, cache writes and reasoning
  output sit behind Details and read "Not reported" where the gateway stayed silent
  rather than taking no row — a gateway reporting nothing must never read as a
  gateway that used nothing. Each gateway counts tokens its own way, and the card
  says so instead of implying the figures were counted alike
- No cost figure anywhere, deliberately. The app does not hold your billing
  relationship with your provider, so there is no truthful source for one, and a
  number that looks like money is believed in a way a token count is not
- By device, by gateway and by model, with every ranked row carrying its share of
  that scope's attempts (honest rounding: under 1 %, over 99 %, an exact 100 % only
  for the whole) and a footer naming any mass that could not be attributed, so
  visible shares summing short is never unexplained
- Heaviest threads, with the full ranked list behind See all. A ranking picks one
  basis — the gateway's own reported totals, or input plus output added up — applies
  it to every row, names it on screen, and says plainly that threads without that
  measurement are not ranked. Silently mixing the two would rank threads against
  each other on numbers that were never comparable
- Drill-downs per gateway and per device, each with its own range picker, its own
  largest-turns section, and an Image history card that separates the turns you
  attached images to from the earlier images re-sent along with them — which is the
  only honest way to show why an image-carrying thread costs what it does
- A thread whose conversation is not present reads as unavailable, never as deleted:
  the ledger cannot tell a deletion from an import that has not arrived yet, and the
  row becomes navigable on its own if the conversation later appears
- Usage records outlive the conversations they describe, so tidying up your threads
  no longer puts a hole in the trend. Where that is disclosed is a decision rather
  than an oversight — it is said in the two places the claim can be tested: beside
  the retained figures themselves, and in the erase-everything confirmation, which
  is the one deletion that does take the records with it
- Clear usage history is account-wide and is the only thing that removes a record.
  It advances a shared cutoff first, so every device excludes everything at or before
  it the moment the setting lands, and deletes the rows locally afterwards in
  bounded, resumable passes. That ordering is what holds the guarantee for a device
  that was offline during the clear: no amount of late syncing resurrects cleared
  history, and an interrupted purge finishes on the next load rather than stranding a
  half-cleared ledger
- Which device a record belongs to is derived in a fixed order — the surface the
  dispatch originated from, then the device class stamped on the record, then the
  source device on the turn — so a car session and a wrist capture are not folded
  into the phone that carried the request. An attempt the ledger could not place
  leaves the breakdown it cannot be placed in and stays inside every total and rate,
  because a row standing for "not measured" reads as one more of the things beside it
- Every dispatching surface writes to the ledger — CarPlay, the Watch, the Converse
  intent, the shared inbox and the background uploader. A build that measured some
  routes and not others would not under-report evenly; it would make whichever
  surfaces were instrumented look like the whole of how the app is used, and no later
  release can repair a period recorded that way
- Two send-path properties hardened to support this, and worth more than the
  dashboard: the agent's reply is written under an identifier minted at dispatch, so
  the same reply landing twice cannot produce a second copy of it; and a cancellation
  now names the exact turn rather than the conversation holding it, so stopping one
  turn leaves a sibling running beside it alone

### macOS — deleting a conversation

- macOS had no delete path at all: the iOS swipe renders nothing there and the host
  suppresses the toolbar actions. Right-click a sidebar row for Delete (no
  confirmation, matching the iOS swipe), and Delete All sits in the window toolbar's
  sidebar band
- The trash sits on the leading side of that band, apart from compose and the sidebar
  toggle, and is hidden whenever the sidebar is collapsed — a collapsed bar should
  carry no bulk-destructive action
- Deleting the open thread resets the window to the new-chat state by the same path
  ⌘N takes; the composer no longer stays mounted against a dead conversation

### CarPlay

- A session that died while its audio engine was still starting could commit a
  running engine and a live input tap onto a dead session, which held the car's
  hands-free microphone until the device was rebooted — every later start refused.
  The commit re-checks the session and discards the engine instead, and the service's
  observers, a hard disconnect and an abrupt scene teardown are all covered
- A voice session that timed out on silence simply vanished, which on a car screen
  reads as a crash. Both silence windows now end by speaking: the ordinary sign-off
  when the capture pipeline is healthy, including on the cold-connect window, and one
  line about the microphone when the pipeline is genuinely dead. Which layer failed is
  a question for the logs, not for the driver
- Three constraints keep that verdict honest. Counters are scoped to the current tap
  and reset when an engine reconfiguration reinstalls it, so one healthy conversion
  from before cannot mask a pipeline that has since died; a tap too young to have seen
  anything convicts nobody; and an all-zero but finite probability stream is read as a
  quiet cabin rather than a fault, because telling a silent driver their microphone is
  broken is the worse error
- Speech is corroborated before it counts: two consecutive chunks at or above the
  threshold, judged on raw per-chunk probabilities rather than the detector's own
  in-speech state, whose hysteresis keeps reporting speech across several quiet frames.
  One loud 256 ms chunk of road noise used to be enough to declare speech. The accepted
  cost is a genuinely short answer that yields only one qualifying chunk — it is
  dropped, with the microphone still live
- The silence windows are named and long on purpose (15 s before the first word, 20 s
  after a reply): killing a live conversation is worse than holding the audio route
  while a driver thinks or attends to the road. A muted session is never signed off
  for not talking, and endpointing is quantized in 256 ms frames, so the tuning dial's
  dead zones are computed rather than guessed at
- An empty transcript and a speech provider's own no-speech verdict mean the same
  thing to a driver: both say so and listen again, and the second in a row signs off
- A microphone that fails to start now shows a "Mic couldn't start" row instead of
  vanishing silently — gated on the voice modal still being up, so a driver who
  already dismissed it is never falsely told the mic failed
- A reply heard in the car no longer stays marked unread. Unread is derived from
  whether a conversation's tail is newer than what you last viewed, and CarPlay was
  the one reply surface that never wrote that marker, because the car has no thread
  view. It writes it now, gated on proof the reply was actually heard: audio began for
  that turn and the turn settled finished. Ending mid-speech, a system interruption
  and a never-spoken reply all stay unread, and so does a newer reply that arrives
  while an older one is still being read out

### Watch

- The launchpad no longer flashes a greyed-out Ask button and a "Recording…" caption
  while the capture screen is being pushed. Choosing a gateway arms the recorder and
  pushes the route in one transaction, so the still-visible root re-rendered busy
  underneath the animation. "Still answering your last question." still shows, because
  that case really is about the root

### Sync — a peer's delete lands on quiet devices

- Forgetting a custom gateway on one device left a stale row on the others. The live
  change notification only reaches a running process — the system applies the
  key-value delta silently while the app is quit and replays nothing at the next
  launch — and the one cold-launch catch-up was gated on an iCloud check that reads
  the ubiquity identity token, which tracks iCloud Drive rather than the key-value
  store. A Mac with iCloud Drive off, or one that simply was not running, kept the
  deleted row forever. Every device now reconciles the synced roster from the local
  key-value cache at launch and on foreground activation, ungated
- That reconcile only ever adopts. It acts on a roster the store actually holds, never
  reads an absent key as a delete — a signed-out device reads exactly the same thing —
  and never publishes the local roster upward
- The custom voice-endpoint roster reconciles by the same rule, and it carried an
  extra fault the gateway path did not: its launch pass was iCloud-wins-then-push-up,
  so a device whose cache had not downloaded yet republished its stale roster and
  brought back endpoints a peer had deleted
- A deleted voice endpoint that was the active speech or speech-synthesis provider
  now falls both pointers back to Apple. Unlike a dangling gateway pointer, that one
  still resolved: the transcription path reads the endpoint's address without
  consulting the roster, so recorded audio and a bearer token would keep going to a
  server the user had deleted. Only a confirmed delete does this — a launch or
  activation reconcile still leaves pointers alone, because a roster older than an
  endpoint this device just created is indistinguishable from a delete

### Files

- A send from a dead spot charged the pre-dispatch folder check as "file server
  unreachable" — one strike, cooldown open — so the retry sent once the connection
  came back was suppressed, went out folder-less, and drew "No folder for this reply"
  underneath a perfectly healthy server's answer. An attempt that never left the
  device now charges nothing: no network path, or a cancellation that is genuinely
  ours, is evidence about the device rather than about the lane. The two lane-authored
  failures that look the same on the wire — a certificate-pin refusal and a peer
  stream reset — keep the old one-strike patience

### Project

- The architecture document gains the usage ledger's constraints, the CarPlay silence,
  endpointing and corroboration rules, and the roster-reconcile rule — stated as
  decisions rather than as description of the code beneath them
- A CarPlay Simulator QA runbook records the rig setup, the reboot-first rule, and how
  to tell a Simulator that dropped a button tap from app code that ignored one

Verified: iOS 4506 tests / 0 failures · watchOS 226 / 0 · Release builds green on iOS and macOS · macOS test bundle compiles · storage-seam and folder-map guards clean

## [1.4-10] — the local-server release

macOS App Store release, 22 August 2026. Tagged `v1.4-10`.

### Local servers — plain HTTP where Apple permits it, and nowhere else

- A gateway, a custom speech endpoint or a file lane may now be `http://` when the
  host is one only the local network can reach: a private-range IPv4 literal
  (`10/8`, `172.16/12`, `192.168/16`), loopback, link-local, an IPv6 unique-local
  address, or a `.local` name. Every other address still requires `https://`.
  This is what lets a bare Ollama on `:11434`, or a home Open WebUI box, work
  without putting a certificate in front of it first
- The boundary is Apple's and it was measured, not assumed: App Transport Security
  permits exactly those hosts with no `Info.plist` exception, and refuses every
  DNS hostname over plain HTTP even when that name resolves to a LAN address.
  Widening it further would mean disabling ATS for the whole app, which would
  weaken the OpenRouter, cloud-speech and file connections too — so it is not done
- Where the platform behaviour was not measured, the classifier refuses unless the
  kernel confines the traffic anyway. Single-label names, `0.0.0.0/8`, `::` and
  `fec0::/10` all take the strict lane, because an unencrypted request carries the
  gateway token with it and the public DNS root can answer a bare label
- The address field states the trade plainly: the connection is unencrypted on that
  network, and it works only from that network — not in the car, and not from a
  Watch on cellular
- A certificate pin configured against a plain-HTTP endpoint is refused, never
  silently ignored
- A refused address names the remedy rather than the rule — use the server's IP
  address or its `.local` name, or put it behind `https://`
- conduck-connect classifies host addresses by the same rule, so the wizard cannot
  mint a setup code the app will then reject on import

### Watch — a draft adopts the conversation its own capture minted

- A draft thread pushed before its conversation exists could observe the live
  conversation pin only outside the window where it is non-nil, and wait forever;
  and any mint at all satisfied its guard, so a deferred drain replaying an older
  capture could hand a draft a conversation the user never asked for. Mints are
  stamped with the capture request that owns them, and a draft adopts only its own
- The in-app Ask refuses at the trigger on exactly the state the headless path
  refuses on, closing the gap where a deferred drain could take the machine between
  the check and the start
- Three adjacent ways to strand a draft are closed: restore no longer stomps a
  capture the user began meanwhile, a superseded claim leaves a discard echo, and a
  denied microphone surfaces instead of hiding behind a silent retry

### Gateways

- The custom-gateway roster is capped at three. The cap is enforced when adding, so
  a roster already above it stays intact and fully editable

### Project

- The changelog ships in the repository, so someone holding a release tag can read
  what that release contained
- Architecture documents state the decisions rather than restating the code beneath
  them; the security disclosure link resolves without a redirect

Verified: iOS 3987 tests / 0 failures · watchOS 217 / 0 · connector 242 checks / 0 · Release builds green on iOS and macOS · macOS test bundle compiles

## [1.3-9] — the file lane, attention and trust release

macOS App Store release, 19 August 2026. Tagged `v1.3-9`.

Roughly 240 commits since 1.2 (21 July 2026). This repository's history opens
partway through that cycle — the app's source moved here on 22 July 2026 — so
the earlier 1.3 commits are not in this log's history, and there is no `v1.2`
tag here to compare against.

This is the engineering long form. The macOS App Store "What's New" for 1.3 is the
short, user-facing version of the same release.

### Files — the agent-file return lane rebuilt

- Per-conversation output folders; every dispatch names its own folder and creates nothing
- A reply's files come from the folder it was given, never parsed from its prose (an agent's refusal could previously mint four downloads, one from another conversation)
- Nothing downloads before a tap — up to 8 MB used to move on its own into a store that syncs to iCloud and the Watch
- Returned files keep their real name; Quick Look preview for file chips both roles; a file Conduck won't open can still be saved
- File-delivery capability is a property of each gateway; an upload-only server keeps the uploads it can do
- The folder check reads the server's answer, not just its envelope; a hand-back is believed only when the server can also say no
- Clone carries its attachments and offers to resend the unanswered turn
- Existence used to be decided from a status code, so an SSO login page or an nginx `try_files` fallback minted a convincing chip for a file that was never written (a textbook 206 with a valid Content-Range included). Probes read the BODY now, and no "exists" verdict survives without a universal negative control: a key that cannot exist must come back missing on the same lane first
- A miss used to be permanent — one 404 stamped the turn scanned forever, so an agent whose file landed a second after its sentence lost the delivery. A miss now leaves the turn eligible, the retro scan retries, and only a probe past the grace horizon closes it; auth/certificate/5xx failures are separated from failures that actually say something about the file
- FileLaneScanBreaker measures a lane with a key that cannot exist rather than counting stalls, and backs off 5/15/30/60 min rather than latching
- The AGENT creates the output folder, not the client — measured across nine agent frameworks, a client-created folder belongs to whoever runs the file server and locks the agent out on the two gateways most people use. The old instruction block is gone: it read as an injected command to a well-aligned model, one of which refused file transfer outright and stayed hostile for the rest of the thread
- A conversation's identifier is minted when the composer opens, so the first attachment lands in its own chat's folder instead of pooling in a shared root every conversation could read; images keep the filename they arrived with instead of being renamed by position
- The inbound name gate was `[A-Za-z0-9._-]`, so `the blue whale.MD`, `Übersicht.md`, `café.pdf` and every CJK name were listed, seen and discarded in silence. Now a positive Unicode policy, with every separator/prefix/component read on UTF-8 BYTES — grapheme-level comparison meant a `/` fused with a combining mark was not `/` while Foundation and the filesystem still saw U+002F. Refusals are reported as a census rather than dropped
- The output allowlist is a what-Conduck-opens policy, not a safety boundary, and behaves like one: refusals are classified, shown without a tap, and offer Save anyway. heic/mp4/mov join; webm stays out (no system decoder)
- Only a structural refusal of the listing method (405/501 against a folder that certainly exists) proves a server cannot list — a timeout, 401, 429, 5xx, redirect or non-multistatus body proves nothing and disables nothing. Test Connection also stops leaving a probe folder behind in the agent's working directory
- A turn that got no output folder says so ONLY when that is news — a wrist turn, a gateway with no file server and a lane already known incapable stay silent; a configured, tested server that has now stopped answering gets one row
- Watch shows a returned file while you're looking at it — the phone hands its name, size and stored key straight over the WatchConnectivity link (a live test measured seven minutes for the iCloud mirror path); no bytes and no credential travel, pinned by a test on the exact allowed key set
- The wrist stops naming output folders on a lane that cannot read them; a missing capability value means capable, so an older paired phone keeps working
- A pairing code carries the file server's measured capabilities, so a new device does not rediscover them; old codes import as not-yet-measured rather than capable
- A 16 MiB reply of newlines produced ~16.8M Substrings and half a gigabyte of live allocation inside claim ordering, while persisting a message — a crash CloudKit would have synced to every device. Ordering is bounded, off the main actor, and measures its own ceiling
- Long filenames no longer break attachments in three separate places: a storage key too long for the file server (upload refused outright), a staging copy with a fixed 53-byte prefix (attachment dropped with no chip, no error and no upload on one route, silently degraded to inline text on the other), and a 200-CHARACTER download bound that a 200-character CJK name blew past (Quick Look failed to open). All three are bounded in BYTES on a character boundary, extension preserved; a no-op for names that already fit
- macOS: drop a file anywhere on the conversation, not only on the composer

### Attention — the conversation list

- Rows resolve to working / answered-unseen / failed / idle; sort direction is legible with several agents dispatched
- Unread + failure acknowledgement are account facts, mirrored across devices and reaching the Watch (acknowledgement keyed by delivery-attempt identity, so a retry re-arms it)
- A failure is reported only while it is still the conversation's last activity
- A new chat starts on the gateway the last one used, not on the Settings default
- macOS gains a reply notification, a quit-mid-turn confirmation, and burst coalescing
- Watch writes its own sending status
- Per-row gateway badges follow what the HISTORY spans (configured set UNION the gateways the listed conversations were created with), not what is configured right now — down to one configured gateway a history spanning four rendered as identical rows on iPhone, iPad, Mac and CarPlay while the wrist still showed all four
- A forgotten CUSTOM gateway keeps two characters and a palette colour so its archive does not go blank; retirement is DERIVED, never replicated, because a monogram can carry organization identity and syncing tombstones would follow the user into their next iCloud account
- The Stop morph moved to the dispatch gate — during macOS's pre-dispatch window `inFlightTask` was nil and a tapped Stop did nothing; that window is a disabled Send now. The menu-bar popover gains Transcribing… → Sending… → "{gateway} is answering…", its ✕ live only in the last phase
- The elapsed clock is hidden from VoiceOver — text that rewrites itself every second announces itself every second

### Trust and security

- A publicly-trusted (ATS-admissible) certificate is now REQUIRED; a pin is an optional additional restriction on a chain the system already trusts. TOFU, the certificate-consent UI and every pin-as-authorisation path are deleted; certFP is gone from conduck-setup:v1
- Three certificate outcomes separated with their own codes, copy and remedy: untrusted chain / pin mismatch / key outside the SPKI prefix table
- A scanned setup code says where it points and has its certificate claim checked before anything is persisted
- Setup codes masked at rest; per-platform import sheet
- A deleted voice endpoint takes its key with it; remote text renders as nothing more than text
- Cross-host / scheme-downgrading redirects are REFUSED rather than replayed — a redirect no longer resends conversation history, images, audio, file bytes and the auth token to an address the user never configured; same rule on the file-transfer lane
- Markdown image and emoji loading in agent replies is blocked outright, so a reply cannot cause a fetch to a third-party address; links go through an explicit tap policy
- Persisted gateway / file-server URLs must be https, with a real host and no embedded user:password@ credentials — enforced on READ as well as write, so a bad address arriving from an older build or another device via iCloud sync is refused rather than used
- macOS conversation sends ran on a session that structurally could not carry a pin, silently dropping a configured pin on the send path while Settings' Test Connection did pin — all Mac send paths now share one correctly-configured recipe
- Agent-supplied filenames render quoted and single-line, so a crafted name cannot disguise itself in the UI
- A third of temp writes (raw microphone audio, full-fidelity images, request bodies carrying conversation history) were unreclaimable if the app was killed mid-operation; every temp write is now claimable and swept, the sweeper runs on watchOS for the first time, and it is off the main thread
- Stored-key path components and staged attachment leaves are bounded
- Forgetting the LAST gateway now reaches the Watch — `currentRemoteAgentMultiEnvelope()` returned nil for an empty configured set, so the wrist kept a live route (URL, auth scheme, roster, Keychain token) to a gateway the user believed disconnected, across reboots. Teardown is authorized by RECORDED USER INTENT via a latch armed at the Forget site, never inferred from a read (an empty set is equally a restored device before iCloud downloads, or a locked Keychain before first unlock)
- Migrating the single custom voice endpoint into the roster COPIED rather than moved, and nothing retired the copy: voice recovery walked Keychain accounts rather than the roster, so a recording plus its bearer token could reach a server the user had deleted. Legacy slots and the synchronizable item are retired on explicit deletion, keyed by the migration's uuid
- Untrusted text — an agent reply, a transcript from a configured endpoint — is projected before it reaches a notification body, a conversation headline, a CarPlay row or a VoiceOver label: formatting controls out, right-to-left script untouched, cap applied AFTER the projection so truncation cannot strand a control. Stored content and what replays on the wire stay byte-exact
- A synced gateway name that runs long is truncated rather than replaced, so editing one gateway can no longer rename another
- Cancelling dictation or speech preserves cancellation instead of burning retry attempts
- A certificate refusal in a background transfer lane shows as a certificate error rather than an unexplained cancel
- ErrorSurfaceDriftGuardTests: fails the suite when a surface renders a cause without its remedy, or draws Retry without consulting isRetryable

### Sync and multi-device correctness

- The XCTest suite had been writing into the REAL App-Group container, iCloud KVS and synchronizable Keychain, leaving fixture gateways (`https://gateway.example.test`) synced to every paired device and emptying the real custom-gateway roster — Diagnostics reported "2 gateways synced to this device are missing their key or model here" for gateways the user had removed. A storage seam (`Services/Storage/`, `SettingsDependencies`, a `Debug-Testing` configuration defining `CONDUCK_TESTING`, a `precondition` trap and `scripts/check-storage-seam.sh` in CI) closes it
- `performInitialSync` pushed local gateway URLs UP into KVS, so a device offline during a peer's Forget resurrected the gateway for everyone; gateway URL/model sync is hydrate-only now, and deliberately does NOT delete on absence (silence at launch is not evidence of a remote delete)
- `remoteAgent.model.*` had no inbound mirror, so a peer's Forget left every other device holding a stale model forever — permanently amber for OpenRouter, whose URL is app-fixed
- Built-in `remoteAgent.authScheme.*` had no inbound mirror and no launch hydration, so flipping a built-in to keyless on one device left every peer demanding a token that no longer existed
- A BUILT-IN default pointer is now always honoured: healing the fresh fallback sent the adopt-first bootstrap straight to the surviving custom, silently moving every message to another server
- `defaultRemoteAgentRef()` could point at a gateway that no longer existed; it self-heals on stored evidence, which fails safe on an unreadable Keychain rather than deleting the user's default during a locked-device read
- A peer's Forget arrives as bare key removals, so the inbound mirror now drops a default pointer whose sync-owned definition was present before the change and absent after, and lets the bootstrap choose — dropping rather than re-pointing, so it is safe to run unattended
- `LiveKVSChangeSource` required `NSUbiquitousKeyValueStoreChangedKeysKey`, which Foundation supplies only for server and initial-sync changes, so account-change and quota notifications were dropped and the Watch settings reader went stale for the rest of the process on an iCloud account switch
- Forget was gated on CONFIGURED, so a half-configured built-in had no Forget button and its row's advice led nowhere; `deleteCustomGateway` now purges the whole per-uuid key family from both stores
- The versioned orphan sweep was DELETED rather than repaired — both roster readers are fail-open, so one malformed record could have erased every gateway's URL, model, auth scheme and file-server config from every device with no journal and no undo. Out-of-band collection moved to `scripts/cleanup-orphan-slots.sh` (dry-run default, typed confirmation, never touches KVS)
- A signed test host was rewriting every title snippet in the real App-Group sqlite and exporting it to the developer's private CloudKit zone; the one-shot flag is gated on the STORE now

### Performance

- Reply rendering scans that were quadratic in reply length are single passes now, and display scanning stopped materializing the whole string — a 4 MB reply went from 16.4 MiB to 48 KiB of transient allocation
- The filename-detection pattern that took ~8 s on a 32 KB unbroken token run is bounded; deeply nested math falls back to a plain code block past a complexity budget rather than locking the UI

### Setup and pairing

- Copy conversation — one-tap whole-thread copy as plain text (iPhone/iPad/Mac); attachments as bracket placeholders, never bytes or extracted text
- File-transfer editor gains Test Connection (draft probe) + top-right Save + discard guard, killing the Save&Test flicker
- Quick connect deep-link honored on the FIRST tap, with no chooser detour
- Per-turn file-delivery instruction defeats gateway MEDIA:-stripping on any gateway; MKCOL before nested PUT; 409 create-parent handshake; iCloud sync mirror + silent folder re-probe
- macOS menu-bar dots suppressed for the thread visible in the active window
- Setup-code review screen redesigned; readiness step no longer an entry step on any path
- "I already have a code" reaches the import sheet in one tap; quick connect on a never-configured custom gateway opens the lane, not a bare command
- A setup code declares what the file server can actually do
- File-transfer settings screen redesigned; Advanced disclosure flattened
- Honest gateway commits and Back-not-Cancel in buffered editors
- An unconnected gateway is an offer, not an unfinished task
- The readiness step stopped gating on something the next step supplies: it asked "Can Conduck reach your AI?" while the helper step one screen later is what sets up reach, so an Ollama-on-localhost owner could not honestly claim reach and was routed to the adapter brief for a problem they did not have. It asks "Is your AI running as a server?" now, and says out loud that it need not be reachable yet
- The command step's iOS handoff line told a quick-connect user to "come back here", presuming a trip to a computer that only the guided path takes
- The Mac window asked whether the DEFAULT gateway could send and rendered the beginner "bring your own AI" screen on the answer — on a Mac holding five verified gateways whose default pointed at a built-in another device had forgotten, that screen was false and took the toolbar with it. `GatewayGate` holds both questions as pure functions both platforms call. The menu bar keeps the stricter question but refuses a capture BEFORE the recorder starts, rather than after a paid transcription is spent and a conversation permanently sealed to a gateway that must refuse it
- The macOS sidebar was laid out 1399pt tall inside a 949pt window and centred, spilling 225pt off each end — each split-view column is hosted in its own `NSHostingView`, which probes minimum size by proposing ZERO width, and a `.fixedSize` Text answers with its string set one character per line. Declaring each column's real width makes the probe measure what the user sees
- Starting a new conversation from iPad stops a capture that is still running, the way the Mac window already did — otherwise the outgoing thread's mic kept going and its transcript landed in the new chat's composer
- The About screen, README and issue templates carried a raw discord.gg invite code that had expired; a lapsed code is not merely a dead link, it becomes claimable by anyone as their own vanity URL, and a code baked into a shipped binary can only be corrected through a full App Review cycle. All surfaces point at conduck.com/discord now, so rotating it is a deploy
- Esc inside a pushed macOS Settings editor raised the CONTAINER's discard confirm, whose Discard tore down all of Settings and landed the user on the chat UI; Esc now targets the innermost editor only, the two dialogs read differently, and Esc no longer closes Settings from any depth with nothing unsaved
- Pairing a gateway from inside its own editor left the editor stuck (Save greyed, "Discard changes?" on exit, empty Name under a populated title) — fixed via a commit receipt the editor checks on dismissal
- A refused gateway save (address rejected, roster at cap) used to return silently as if it had worked; partial commits roll back, and a pairing test no longer falls back to the setup-code payload when storage comes up empty and paints a false green "Connected"
- Save is enabled only on a real change to a valid form, is inert during an in-flight save, and an untouched form announces "No changes to save." to VoiceOver rather than downgrading "Connected" to "Saved"
- The three pushed editors say "Back" rather than "Cancel"; iOS swipe-back is suppressed there because it was a silent discard
- The tailnet callout names iCloud Private Relay, gives the Settings path to turn it off, and suggests the Safari check that separates a name-resolution problem from an app problem
- Onboarding and Personal AI copy stop selling gateway-side memory — Conduck sends the whole conversation every message, so a gateway keeping its own history bills the context twice (measured 13.3k prompt tokens vs 540 on the same turn); the footer now states the send-context-every-message fact plainly
- Pairing sheet has exactly one paste path — the stacked "Use copied code" clipboard button is gone (QR scan unchanged on iOS); guided-cover deep-link made race-free (item-based presentation)
- Community/official build-identity split (Identity.xcconfig + private Identity-Override.xcconfig)

### Errors and diagnostics

- WS-D declined-turn UX: the adapter contract's 1.3 error vocabulary is consumed and PERSISTED (Core Data v4, additive) — a failed turn keeps WHY across a relaunch instead of a transient banner; a photo-related refusal no longer poisons every later turn, and offers resend-without-photo
- Out of credits and rate-limited keep their Try again; a 403 no longer asserts the bearer token is wrong
- Every error names the AI the user actually configured
- Diagnostics report what the wire did: persisted failure codes, per-gateway chat-proof records, scoped recheck, four-lane error parity
- Transport failures split by whether the request could have reached the server: an unmapped HTTP status keeps its code instead of collapsing to a generic retry; gateway/tunnel outages (502/503/504/530, Cloudflare 521-526) are separated from a server that errored; connection-never-opened (refused/DNS) is separated from may-have-arrived-then-dropped. Test Connection and a failed send finally agree
- Per-gateway recheck — a free, non-mutating check scoped to one gateway, on the focused card and every gateway row, instead of only the billable "Test everything"
- Copy Diagnostics carries `Recent failed sends:` (up to five, deduped per gateway/code/device) and `Chat proven:`; a green gateway row states its own scope (it checked the model list; only sending proves chat)
- Chat-proven recorded against the wrong config in two cases (a custom gateway always recorded a nil model; a gateway edit landing mid-send could store one gateway's success as proof for another) — both now read the config the request actually used
- Cancelled messages are no longer reported as gateway send failures in the support report
- CarPlay routed every non-certificate transport failure to a blanket "gateway unreachable", telling a driver to investigate a gateway that was never contacted — it now uses the same mapping as the other three lanes
- Watch surfaces coded failures (image not supported, model not found, context overflow) with their specific message instead of a generic status error; send-error banners name the gateway and the device
- Long errors are fully reachable: the Watch banner is a two-line summary with a chevron to a scrollable detail sheet at any Dynamic Type size, and both macOS dictation popover footers wrap instead of capping at three lines
- A trycloudflare.com gateway address warns at setup that it is disposable
- A leftover gateway is named, marked and counted ONCE — readiness ("can this gateway send?") and removability ("would Forget erase anything?") are separate axes from one classification pass, so the header count and the rows cannot disagree; each incomplete gateway gets its own row, named on screen but carrying only its KIND into the copyable report
- A turn that failed carrying a file and not one word says so, as a quiet footnote under the verdict — some agents produce no reply when there is nothing to answer, and where a tunnel replaces the body the explanation never arrives. Gated to the generic arm, a genuinely wordless turn, and only the four classes meaning the gateway's own program answered and failed
- On iOS the converse hop runs on a background URLSession that waits for connectivity out of process; the row claimed "{Gateway} is answering…" with an elapsed clock the whole time — measured as two and a half minutes of airplane mode, and as a refused connection that never surfaced. The wait stays; the false assertion does not
- The Watch's out-of-credits error rendered its remedy twice ("…then try again. Add credits with your provider, then try again.") and mirrored that to the paired iPhone's lock screen — the split into cause + recovery updated the iOS catalog and left the Watch one holding the pre-split value
- A passing row states its news once; the file-server row says whether uploads are on, not what a test once found
- The unavailable-default row offers a switch rather than ordering one

### macOS and iPad

- MacPointerTargets: every mouse-reachable custom-drawn control is properly clickable
- One settings rail, full-bleed sub-screen rows, persistent back chrome, live Guided Setup row
- Sidebar fits the window it is in; compose moves inside the sidebar and sizes to its own glyph
- The Mac window asks whether ANY gateway can send, not whether the default one can
- iPad: compose lives on whichever column's bar is on screen; sidebar separates its rows and squares its search field
- macOS 26 stale titlebar-glass band repaired at root cause; "Personal AI" header flicker killed on conversation switch (memo warmed at launch); transcript + sidebar opt out of the top scroll-edge effect

### Voice and Watch

- Typed TTS playback outcomes — undecodable bytes, refused starts, didFinish(false) and mid-clip decode errors are FAILURES routed to the Apple fallback with transparency, where they previously terminated the turn in silence; delegate-identity guards + per-turn generation in ReplyVoice
- TTS key-sync convergence UX — device-local key readiness banner (missing vs unreadable), TTSKeyArrivalMonitor (bounded 5s→160s foreground re-check, iCloud Keychain has no arrival event), explicit "Send Settings to Apple Watch" recovery
- Quick Look for inline text attachments (zero network); Watch text-attachment viewer; retroactive output-file detection for CarPlay/Watch turns
- An unreadable STT key is not an absent one — the recording outlives the refusal
- CarPlay hears the truth about STT; a route yields to what the user asked for next
- A queued Watch capture the iPhone could not read is kept, not thrown away
- Watch: say the out-of-credits remedy once, not twice
- Composer stops decoding full camera files on the main actor

### Project

- Apache-2.0 licensing, SPDX headers on every tracked source file, THIRD_PARTY_NOTICES, in-app Open Source Licenses screen
- DCO sign-off hook; issue forms built around the in-app diagnostics report
- CI source guards on Linux; macOS TLS test bundle compiled unconditionally

### Release-gating fixes made in this build

- ConverseIntent referenced DEBUG-only RemoteAgentDiagnostics in a line meant to ship — Release failed to compile on both platforms; it now uses an always-compiled os.Logger
- Two test files referenced iOS-only symbols ungated (AppleSpeechRelayCoordinator, CarPlaySceneDelegate), breaking the macOS test-bundle compile and with it the live TLS trust suite

Verified: iOS 3925 tests / 0 failures · watchOS 206 / 0 · live TLS 16 / 0 · Release builds green on iOS and macOS · SBOM notices gate clean
