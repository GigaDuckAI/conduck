# Conduck — Repository Structure

*This file changes only when a folder is added or removed, or when the Xcode target topology changes. It is a map, not an inventory: it never lists individual files, because the filesystem already does that better and never goes stale.*

If you want to know what a particular file does, open it. Every source file carries a header comment explaining its job and, where the design is not obvious, why it works the way it does — `CONTRIBUTING.md` requires it. This document exists to tell you *which* file to open.

---

## Top of the repository

| Path | What it is |
|---|---|
| `README.md` | What Conduck is, how data flows, how to build it, and the glossary settling the words this project uses in a narrower sense than the industry does. Read this first. |
| `CONTRIBUTING.md` | Building under your own Apple identity, coding conventions, DCO sign-off. |
| `SECURITY.md` | How to report a vulnerability privately. |
| `LICENSE` · `NOTICE` · `THIRD_PARTY_NOTICES.md` | Apache-2.0 and the licences of bundled dependencies. |
| `TRADEMARKS.md` | The brand carve-out: the name and the duck artwork are not covered by the code licence. |
| `docs/ai-context/` | This file and `spec.md`, the architecture document. Written to be read by both people and AI coding agents. |
| `docs/qa/` | The in-app QA harness and the manual test scenarios that go with it. |
| `branding/` | Neutral placeholder artwork for community builds, and a README explaining how it is regenerated. |
| `scripts/` | The checks CI runs, plus a few maintenance tools. `spec.md` says which rules are upheld by one of these rather than by review. |
| `.github/workflows/` | Continuous integration. A cheap Linux job runs the source guards — the `scripts/` checks that keep this repository's own rules true, including the one that enforces this document — and the simulator test suites are gated on it, so a one-line violation is never discovered by an expensive macOS matrix. |
| `.githooks/` | Optional local hooks. Enable with `git config core.hooksPath .githooks`. |
| `Conduck/` | The Xcode project and all Swift source. Everything below is inside it. |

---

## The Xcode project

| Path | What it is |
|---|---|
| `Conduck/Conduck.xcodeproj/` | The project file, the schemes, and the pinned versions of the three Swift package dependencies. |
| `Conduck/Configs/` | `Identity.xcconfig` — bundle identifiers, App Group, Keychain group and iCloud container, expressed as build variables rather than hardcoded strings. Ships with community defaults; a private, gitignored override file alongside it substitutes another identity without touching source. |

---

## The main app — `Conduck/Conduck/`

One target covers iPhone, iPad and Mac. The Mac build is a full Dock application *and* a menu-bar agent; both live here. The target's platform settings also list visionOS, which nothing else in the repository acts on: no source file branches on it, no scheme or workflow names a visionOS destination, and no continuous-integration job builds one. Read the supported set as the three platforms above until that setting is either removed or backed by a build.

| Folder | What lives there |
|---|---|
| *(top level)* | The app entry point and the top-level window and scene wiring shared by all three platforms. |
| `Models/` | The data types the whole app agrees on — conversation and message records, the error type, the user-preference enumerations, request and reply shapes. Those are structure without behaviour, and many of them are compiled into the Watch app as well. One thing here is not a type at all: `Models/Conversations.xcdatamodeld`, the versioned Core Data model behind the conversation store; `.xccurrentversion` names the model the app opens. Work organization uses additive, relationship-free metadata entities beside the existing capture records. Each version of it is additive-only, and every earlier version is still a live upgrade path on a device that has not opened the app in a long time, which makes it the highest-risk edit in the repository. |
| `Models/Diagnostics/` | The data behind the in-app diagnostics screen, including the plain-English explanations shown for each check. |
| `Services/` | App services: recording, conversation and usage persistence, settings, capture and retry queues, content-sync lifecycle and monitoring, and phone-side Watch transport. Work-specific capture processing lives in `Services/Workboard/`. |
| `Services/KeyArrival/` | iCloud Keychain delivers a synced secret opportunistically and posts no arrival event, so a device still waiting on one has nothing to converge on and stays quietly degraded. This holds the shared, bounded, foreground-only poller that each waiting subject takes its own instance of, instead of a hand-rolled wait per subject — the bounds are settled in one place rather than in every place that can be waiting. |
| `Services/RemoteAgent/` | Everything that talks to the user's AI. One network client serves every gateway kind; what differs between kinds is a capability descriptor, not a code path. Also holds pairing-payload import and export, certificate-trust evaluation, background upload and download, and the file-server client. |
| `Services/STT/` | Speech to text: the provider protocol, the shared request-building and response-decoding machinery, connection testing, and the on-device Apple engine. |
| `Services/STT/Providers/` | A file here only when a vendor cannot use the shared request and decode machinery — a bespoke probe or body factory for the ones that deviate. Vendors that fit the standard shape have no file at all. Adding a vendor means registering it in `Services/STT/STTProvider.swift` and the metadata lists beside it; a file here is the exception, not the step. |
| `Services/TTS/` | Read-aloud: sentence segmentation, chunk queueing, playback, exclusivity between surfaces, and the speak engine every spoken reply on this target passes through. The Watch has its own engine behind the same protocol. The one definition of the iOS spoken-audio session lives here too, because a played audio file on the desk is the same kind of output as a spoken reply and two copies of that posture would drift. |
| `Services/Storage/` | Storage interfaces and live/test adapters for App Group defaults, iCloud settings, Keychain and durable content-sync preferences. `scripts/check-storage-seam.sh` guards access to the underlying platform stores. |
| `Services/Workboard/` | Work services: capture import, voice-transcript publication and recovery, material storage and export, project-context preparation and reviewed handoff, and the repository that projects stored materials for the views. |
| `ViewModels/` | The state between views and services: conversation list and detail, Work capture and project organization, settings, diagnostics, and pairing import. |
| `Views/` | SwiftUI, split by area below. |
| `Views/Conversation/` | The message thread, the composer, and attachment handling — staging, previews, full-screen viewing. |
| `Views/Workboard/` | The Work/Chats shell and Work surfaces: All materials and projects, spatial canvas, tile and list layouts, capture composer, material editing, previews and sharing, project briefs and conversations, deletion review, and the tutorial. |
| `Views/Settings/` | The largest folder in the app. Every settings screen for every platform, plus the guided gateway-setup flow. iPhone/iPad and Mac have deliberately separate screen hierarchies here rather than one adaptive layout. |
| `Views/Onboarding/` | The first-run flow, including the choice between a self-hosted gateway and a hosted model. |
| `Views/Components/` | Small pieces shared across more than one screen, including the Quick Look presenter that Chat and the Work desk both drive — it owns the claim token that keeps a slow load from stealing a later tap's panel, and the platform rule about when a preview copy may be reclaimed; and the anchor registry that tells a share sheet which attached view to pop out of, newest surface first; and the one keyboard-dismissal modifier Chat's thread and the Work desk share, which lets a short list be dragged to dismiss and a tap on empty space put the keyboard away without outranking the cards, links and buttons underneath. |
| `Intents/` | App Intents: voice capture, network readiness, inert capture onto the Work desk, adding a chosen set of files to it, opening its recorder, plus shortcut registration. The file action publishes an envelope for the app to drain rather than writing cards itself, and the record action only launches the in-app recorder, because an intent cannot hold a Shortcut open while a person speaks. GigaAction has an additive Chat/Work destination; Chat remains the migration-safe default, and the Work leg reaches no gateway. |
| `MenuBar/` | The Mac menu-bar agent, its popover, and the user-configurable global hotkeys — one of which captures straight to the Work desk, taking its screenshot before it records, behind the one capture panel all three hotkeys share and a Work-only state of the compose surface; that panel outranks the popover's other content, except while the chat lane holds the microphone — whichever lane is recording is the one that has to be visible and stoppable. That state keeps its own composition: one surface may host both aims, but a composition aimed at the desk is never offered to a Return that reaches a gateway. |
| `ScreenCapture/` | The Mac drag-to-select region capture, serving both Screenshot & Ask and Capture to Work; on the Work lane Return skips the picture and every Screen Recording permission stop offers to continue without one. |
| `CarPlay/` | The CarPlay scene. It has its own recorder, its own audio session handling and its own end-of-speech detection rather than reusing the phone's, because the car is a hands-free multi-turn surface with different interruption rules. The gateway pill is drawn whenever a gateway exists and opens a chooser that lists every gateway and then a one-shot Add to Work row, an action that stores no destination and records a note onto the Work desk; only where no gateway exists does that row stand first on the root. That lane preserves its compressed bytes for retry before it transcribes, offers End and no Mute, and never draws a card on the car screen. |
| `QA/` | The QA harness — debug flags, an accessibility hierarchy dump, an on-screen banner. Compiled only into Debug builds. |
| `Utilities/` | Cross-cutting helpers, and `Constants.swift`, which owns the app's tunable limits, its storage keys and its identity namespace. When a document needs to refer to a number, it names the constant here rather than writing the number down. |
| `Resources/` | The bundled Shortcut, the voice-activity-detection model, speech-probe fixtures, and legal text. |
| `Assets.xcassets` | Icons and colours. Community builds carry the placeholder art from `branding/`. |

---

## The other targets

| Path | What it is |
|---|---|
| `Conduck/ConduckShareExtension/` | The iOS share-sheet extension. One destination list of gateways and recent chats opens with a new conversation on the app's default gateway highlighted — or the first gateway it can send on, or nothing at all where the app has published no roster — the button that sends names whatever is highlighted, and Add to Work stands beside it on the floor as its own action, outside the list entirely. A send writes the picked gateway into the manifest explicitly, so a default that moves between the share and the drain cannot reroute it, and Add to Work writes an inert envelope for the desk; both land in shared App-Group inboxes the app drains when active. |
| `Conduck/ConduckShareExtensionMac/` | The macOS share extension. Same inbox, same idea. Its files carry the same names as the iOS ones, but only some are copies: the view, the controller, the target filter and the web-page capture genuinely diverge because the two platforms' share hosts behave differently, while the snapshot, manifest and capture-envelope types, and the one publication transaction every inert Work capture is written through, are deliberate verbatim mirrors of the main app's, each held byte-identical by a test. |
| `Conduck/ConduckWatch Watch App/` | The watchOS app. It reuses the phone's models and service layer (see the shared-source rules below) but none of its views. |
| `Conduck/ConduckWatch Watch App/Services/` | The wrist's own recorder, audio session handling, network client, relay coordinator and its pending queue — whose Work entries neither age out nor are evicted, because the wrist holds the only copy until the phone confirms the desk has it, so a capture offered at capacity is refused instead — the holding area for agent-file descriptions the phone couriers ahead of sync, deep-link routing back into the app, and logging with hostname redaction. |
| `Conduck/ConduckWatch Watch App/Views/` | The wrist screens — conversation list, thread, composer, the Add-to-Work capture screen, reached from Ask's destination chooser and its own route rather than a mode on it, first-run welcome and setup. |
| `Conduck/ConduckWatch Watch App/Models/` | The Watch conversation view model and its request type. |
| `Conduck/ConduckWatch Watch App/QA/` | Seeding for App Store screenshot capture. |
| `Conduck/ConduckWatch/` | The Watch widget extension — the control that appears in Control Center, the Smart Stack and on the Action Button. It is a separate binary, so it carries its own copy of the recording coordinator and its own variant of the capture intent. |
| `Conduck/ConduckTests/` | The main test suite. Includes several named drift-guard and contract tests, each naming in its own header the rule it protects; `spec.md` says why those rules are held by a test rather than by review. |
| `Conduck/ConduckTests/RemoteAgent/` | Gateway tests, including the converse wire-contract test. The named drift guards live one level up, in `Conduck/ConduckTests/` itself. |
| `Conduck/ConduckTests/Providers/` | Per-vendor speech provider tests. |
| `Conduck/ConduckTests/Fixtures/` · `Conduck/ConduckTests/Resources/` | Test data with no Swift in it — a captured gateway reply, and DER-encoded certificates the trust-evaluation tests parse. `scripts/check-folder-map.sh` finds folders by the Swift source inside them, so it structurally cannot notice a resource-only folder. These two are mapped only because this row exists; delete it and nothing will ever report them missing. |
| `Conduck/ConduckWatchTests/` | Watch-only logic that the main suite cannot see, hosted by the Watch app. **See the footgun below before adding a file here.** |

---

## How source reaches a target

Seven targets: the app, two share extensions, the Watch app, the Watch widget extension, and two test bundles.

Six of the seven use **filesystem-synchronized groups** — Xcode compiles whatever is on disk in that folder, so a new Swift file joins its target automatically and the project file does not change. This is why adding a file almost never produces a merge conflict here.

Three consequences worth knowing:

**Shared code is a hand-maintained list in the project file, not a framework.** The Watch app does not include the main app's folder as a synchronized group. Instead the project file names an explicit subset of main-app files — the models, the storage seam, the gateway client, the speech and read-aloud services — as also belonging to the Watch target. Only those reach the Watch; roughly a fifth of the app folder.

That has a footgun in the opposite direction to the one you would guess. **A new file under `Conduck/Conduck/` does *not* reach the Watch.** If Watch code needs it, you have to add it to that list in the project file — which is the one case where adding a file does edit the project file, and therefore the one case that can produce a merge conflict. Conversely, a file the Watch never sees needs no platform gating at all: it is free to use frameworks watchOS lacks.

Where a file *is* shared but only partly applies, the gating happens inside it with `#if !os(watchOS)`, which is why a handful of shared files compile to almost nothing on the wrist.

**The Watch has its own copy of anything it cannot share.** Where a type genuinely cannot be common — the Watch-side half of the phone relay is the main case — the two sides hold literal duplicates of the same wire constants, because neither target can see the other's symbols. A one-character rename on one side breaks the relay at runtime with no compile error, which is why a drift-guard test compares the two files' text directly.

**`ConduckWatchTests` is the one target with no synchronized group at all**, so every test file in it is referenced explicitly in the project file. (It is not the only place explicit references appear — the main app also compiles two files from the macOS share extension's folder that way, so its helpers can be unit-tested.) **A new file dropped into that folder will not compile and its tests will not run — silently.** You have to add it to the target in Xcode. Nothing warns you, which is exactly what makes it dangerous: the suite still passes, having quietly skipped your test.

Three build configurations exist: `Debug`, `Release`, and `Debug-Testing`. All three read their identity variables from `Conduck/Configs/Identity.xcconfig`.

Several things in the project file fail silently if you touch them. The macOS share extension's embed step and its target dependency must both carry the platform filter as a **plural array** — Xcode ignores the singular macOS token, and the macOS extension then embeds into the iOS build. No identity-bearing value may be written directly into a build setting: those come from the xcconfig, and hardcoding one defeats the community/official split without breaking anything visibly.

The same split also runs through the app's entitlements, which are two files rather than one — `Conduck/Conduck/Conduck-Community.entitlements` and `Conduck/Conduck/Conduck-Official.entitlements`, selected by a build variable. Xcode's capability editor writes only to whichever variant the active configuration selects and never touches the other, so a capability added through the capabilities UI lands in one build and is silently missing from the other. Edit both files by hand, and check the variant you are not building.

---

## Where to start

| If you are changing… | Start in |
|---|---|
| How a turn reaches the user's AI, or adding a gateway kind | `Conduck/Conduck/Services/RemoteAgent/` |
| Speech recognition, or adding a speech vendor | `Conduck/Conduck/Services/STT/` |
| Spoken replies | `Conduck/Conduck/Services/TTS/` |
| Conversation, Work or usage storage, or content sync | `Conduck/Conduck/Services/` and `Conduck/Conduck/Services/Storage/` |
| The conversation database schema | `Conduck/Conduck/Models/Conversations.xcdatamodeld` — add a version rather than editing a shipped one. The mirrored CloudKit schema is additive-only and permanent, so a field cannot be withdrawn once it exists, and every version still on disk somewhere is a migration a real device will run. The model carries two named configurations and a new entity belongs to exactly one of them: `Core` backs the shipped conversation store, and `Blobs` backs a sibling payload store the Watch deliberately never mounts, which is what keeps Work's bytes off the wrist |
| Anything persisted, synced, or kept secret | `Conduck/Conduck/Services/Storage/` — go through the seam |
| The message thread or the composer | `Conduck/Conduck/Views/Conversation/` |
| The Work workspace, project organization, or a card | `Conduck/Conduck/Views/Workboard/` and `Conduck/Conduck/ViewModels/` |
| Landing something on Work from a new surface | `Conduck/Conduck/Services/Workboard/` for capture processing and `Conduck/Conduck/Services/` for the store and inbox. Entry points live in their platform folders; check the Watch shared-source rules before assuming app-side Work code is available there. |
| A settings screen | `Conduck/Conduck/Views/Settings/` — check whether the Mac hierarchy needs the same change |
| Watch behaviour | `Conduck/ConduckWatch Watch App/` |
| CarPlay behaviour | `Conduck/Conduck/CarPlay/` |
| Share-sheet behaviour | Both extension folders, and the inbox drainer in `Conduck/Conduck/Services/` |
| Voice capture | `Conduck/Conduck/Services/AudioRecorder.swift`, with `InAppAudioRecorder.swift` beside it wrapping the in-app thread flow — then check the surfaces you are *not* changing. `Conduck/Conduck/CarPlay/`, `Conduck/ConduckWatch Watch App/Services/` and `Conduck/ConduckWatch/` each own a separate recorder on purpose, so none of them inherits a fix made here |
| A user-visible string | `Conduck/Conduck/Localizable.xcstrings`, and `Conduck/ConduckWatch Watch App/Localizable.xcstrings` if the wrist shows it too. They are two independent catalogues, so a string both sides display is written in both — including a string that lives in a file the Watch compiles from the app target, because the lookup still resolves against the Watch's own bundle |
| A tunable limit | `Conduck/Conduck/Utilities/Constants.swift` |

Before changing a subsystem, read the corresponding part of [`spec.md`](spec.md) — it records decisions that the code cannot tell you, including several designs that were deliberately rejected.
