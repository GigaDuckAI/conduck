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
| `scripts/` | The checks CI runs, plus a few maintenance tools. See the verification table in `spec.md`. |
| `.github/workflows/` | Continuous integration: the header and storage-seam checks, then the test suites. |
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

One target covers iPhone, iPad and Mac. The Mac build is a full Dock application *and* a menu-bar agent; both live here.

| Folder | What lives there |
|---|---|
| *(top level)* | The app entry point and the top-level window and scene wiring shared by all three platforms. |
| `Models/` | The plain data types the whole app agrees on — conversation and message records, the error type, the user-preference enumerations, request and reply shapes. No behaviour, only structure. Many of these are compiled into the Watch app as well. |
| `Models/Diagnostics/` | The data behind the in-app diagnostics screen, including the plain-English explanations shown for each check. |
| `Services/` | Everything that does work rather than draws: audio recording, the conversation store, settings, the share-sheet inbox and its drainer, permissions, iCloud sync monitoring, retry bookkeeping. |
| `Services/RemoteAgent/` | Everything that talks to the user's AI. One network client serves every gateway kind; what differs between kinds is a capability descriptor, not a code path. Also holds pairing-payload import and export, certificate-trust evaluation, background upload and download, and the file-server client. |
| `Services/STT/` | Speech to text: the provider protocol, the shared request-building and response-decoding machinery, connection testing, and the on-device Apple engine. |
| `Services/STT/Providers/` | A file here only when a vendor cannot use the shared request and decode machinery — a bespoke probe or body factory for the ones that deviate. Vendors that fit the standard shape have no file at all. Adding a vendor means registering it in `Services/STT/STTProvider.swift` and the metadata lists beside it; a file here is the exception, not the step. |
| `Services/TTS/` | Read-aloud: sentence segmentation, chunk queueing, playback, exclusivity between surfaces, and the speak engine every spoken reply on this target passes through. The Watch has its own engine behind the same protocol. |
| `Services/Storage/` | The storage seam. Three shared, syncing stores reach the app only through the protocols here, so tests can substitute in-memory doubles instead of writing to a developer's real iCloud account. `scripts/check-storage-seam.sh` fails the build if anything bypasses it. |
| `ViewModels/` | The state that sits between views and services — conversation list and detail, settings (split across several files by area), the diagnostics runner, the pairing import flow. |
| `Views/` | SwiftUI, split by area below. |
| `Views/Conversation/` | The message thread, the composer, and attachment handling — staging, previews, full-screen viewing. |
| `Views/Settings/` | The largest folder in the app. Every settings screen for every platform, plus the guided gateway-setup flow. iPhone/iPad and Mac have deliberately separate screen hierarchies here rather than one adaptive layout. |
| `Views/Onboarding/` | The first-run flow, including the choice between a self-hosted gateway and a hosted model. |
| `Views/Components/` | Small pieces shared across more than one screen. |
| `Intents/` | App Intents: the voice-capture intent behind the Action Button and Shortcuts, the network check, and the shortcut registration that makes both discoverable to Siri and Spotlight. |
| `MenuBar/` | The Mac menu-bar agent, its popover, and the user-configurable global hotkeys. |
| `ScreenCapture/` | Mac screenshot-and-ask: the drag-to-select region capture. |
| `CarPlay/` | The CarPlay scene. It has its own recorder, its own audio session handling and its own end-of-speech detection rather than reusing the phone's, because the car is a hands-free multi-turn surface with different interruption rules. |
| `QA/` | The QA harness — debug flags, an accessibility hierarchy dump, an on-screen banner. Compiled only into Debug builds. |
| `Utilities/` | Cross-cutting helpers, and `Constants.swift`, which owns the app's tunable limits, its storage keys and its identity namespace. When a document needs to refer to a number, it names the constant here rather than writing the number down. |
| `Resources/` | The bundled Shortcut, the voice-activity-detection model, speech-probe fixtures, and legal text. |
| `Assets.xcassets` | Icons and colours. Community builds carry the placeholder art from `branding/`. |

---

## The other targets

| Path | What it is |
|---|---|
| `Conduck/ConduckShareExtension/` | The iOS share-sheet extension. It writes into a shared App-Group inbox; the main app drains it when it next becomes active. |
| `Conduck/ConduckShareExtensionMac/` | The macOS share extension. Same inbox, same idea. Its files carry the same names as the iOS ones, but only some are copies: the view, the controller, the target filter and the web-page capture genuinely diverge because the two platforms' share hosts behave differently, while the snapshot and manifest types are deliberate verbatim mirrors of the main app's, held byte-identical by a test. |
| `Conduck/ConduckWatch Watch App/` | The watchOS app. It reuses the phone's models and service layer (see the target table below) but none of its views. |
| `Conduck/ConduckWatch Watch App/Services/` | The wrist's own recorder, audio session handling, network client, relay coordinator and its pending queue, the holding area for agent-file descriptions the phone couriers ahead of sync, deep-link routing back into the app, and logging with hostname redaction. |
| `Conduck/ConduckWatch Watch App/Views/` | The wrist screens — conversation list, thread, composer, first-run welcome and setup. |
| `Conduck/ConduckWatch Watch App/Models/` | The Watch conversation view model and its request type. |
| `Conduck/ConduckWatch Watch App/QA/` | Seeding for App Store screenshot capture. |
| `Conduck/ConduckWatch/` | The Watch widget extension — the control that appears in Control Center, the Smart Stack and on the Action Button. It is a separate binary, so it carries its own copy of the recording coordinator and its own variant of the capture intent. |
| `Conduck/ConduckTests/` | The main test suite. Includes several named drift-guard and contract tests; the verification table in `spec.md` says what each one protects. |
| `Conduck/ConduckTests/RemoteAgent/` | Gateway tests, including the converse wire-contract test. The named drift guards live one level up, in `Conduck/ConduckTests/` itself. |
| `Conduck/ConduckTests/Providers/` | Per-vendor speech provider tests. |
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

Two things in the project file fail silently if you touch them. The macOS share extension's embed step and its target dependency must both carry the platform filter as a **plural array** — Xcode ignores the singular macOS token, and the macOS extension then embeds into the iOS build. And no identity-bearing value may be written directly into a build setting: those come from the xcconfig, and hardcoding one defeats the community/official split without breaking anything visibly.

---

## Where to start

| If you are changing… | Start in |
|---|---|
| How a turn reaches the user's AI, or adding a gateway kind | `Conduck/Conduck/Services/RemoteAgent/` |
| Speech recognition, or adding a speech vendor | `Conduck/Conduck/Services/STT/` |
| Spoken replies | `Conduck/Conduck/Services/TTS/` |
| Conversation storage or iCloud sync | `Conduck/Conduck/Services/ConversationStore.swift` and `Services/Storage/` |
| Anything persisted, synced, or kept secret | `Conduck/Conduck/Services/Storage/` — go through the seam |
| The message thread or the composer | `Conduck/Conduck/Views/Conversation/` |
| A settings screen | `Conduck/Conduck/Views/Settings/` — check whether the Mac hierarchy needs the same change |
| Watch behaviour | `Conduck/ConduckWatch Watch App/` |
| CarPlay behaviour | `Conduck/Conduck/CarPlay/` |
| Share-sheet behaviour | Both extension folders, and the inbox drainer in `Conduck/Conduck/Services/` |
| A tunable limit | `Conduck/Conduck/Utilities/Constants.swift` |

Before changing a subsystem, read the corresponding part of [`spec.md`](spec.md) — it records decisions that the code cannot tell you, including several designs that were deliberately rejected.
