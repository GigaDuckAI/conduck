# Changelog

Notable changes to the Conduck app for iPhone, iPad, Mac, Apple Watch and
CarPlay. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
Each section is named for one App Store release — the marketing version and the
build number Apple shows — and matches the tag that release carries in this
repository, `v<version>-<build>`.

## [1.5-11] — the measurement release

App Store release, 25 August 2026. Tagged `v1.5-11`.

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

App Store release, 22 August 2026. Tagged `v1.4-10`.

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

App Store release, 19 August 2026. Tagged `v1.3-9`.

Roughly 240 commits since 1.2 (16 July 2026). This repository's history opens
partway through that cycle — the app's source moved here on 22 July 2026 — so
the earlier 1.3 commits are not in this log's history, and there is no `v1.2`
tag here to compare against.

This is the engineering long form. The App Store "What's New" for 1.3 is the
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
