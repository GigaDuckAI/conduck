// SPDX-License-Identifier: Apache-2.0

#if DEBUG

import Foundation
import OSLog
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Compile-and-runtime gate for Conduck's QA mode. Activated by the
/// `-ConduckQAMode` launch argument.
///
/// **Why this exists:** the unsigned QA simulator can't persist a gateway
/// bearer token to Keychain (no signed Keychain access), so a real gateway
/// can't be configured and no conversations/messages can be created — which
/// blocks every gateway-dependent QA scenario. QA mode seeds the gateway
/// config into an in-memory override (read by `SettingsManager` BEFORE it
/// touches Keychain) and pre-seeds sample conversations, so the QA agent
/// lands in a populated, configured app. Sends still hit the REAL gateway
/// over the tailnet — there is no mock.
///
/// **Production safety (two gates):**
/// 1. The entire namespace is wrapped `#if DEBUG`, so Release builds contain
///    zero `QAMode` symbols.
/// 2. Every behavior is additionally gated on `QAMode.isActive` (true only
///    when `-ConduckQAMode` is present). A Debug build launched WITHOUT the
///    flag behaves byte-identically to today: no banner, no seeding, the real
///    Keychain read-path untouched. Any caller referencing `QAMode` from
///    outside a DEBUG-only branch must be behind its own `#if DEBUG`.
enum QAMode {
    private static let activationFlag = "-ConduckQAMode"
    private static let screenshotFlag = "-ConduckQAScreenshotMode"
    private static let openClawURLFlag = "-ConduckQAOpenClawURL"
    private static let openClawTokenFlag = "-ConduckQAOpenClawToken"
    private static let hermesURLFlag = "-ConduckQAHermesURL"
    private static let hermesTokenFlag = "-ConduckQAHermesToken"
    private static let defaultBackendFlag = "-ConduckQADefaultBackend"
    private static let customURLFlag = "-ConduckQACustomURL"
    private static let customTokenFlag = "-ConduckQACustomToken"
    private static let customNameFlag = "-ConduckQACustomName"
    private static let customModelFlag = "-ConduckQACustomModel"
    private static let forceICloudUnavailableFlag = "-ConduckQAForceICloudUnavailable"
    private static let seedImagePathFlag = "-ConduckQASeedImagePath"

    private static let logger = Logger(
        subsystem: Constants.identityNamespace,
        category: "QAMode"
    )

    /// True when the app was launched with `-ConduckQAMode` OR
    /// `-ConduckQAScreenshotMode`. Screenshot mode is a SUPERSET of QA mode: it
    /// reuses the same in-memory gateway override + conversation seeding so the
    /// app lands configured + populated, just with the red banner suppressed and
    /// marketing-grade seed copy (see `isScreenshotMode` / `showsBanner`).
    static let isActive: Bool = {
        let args = ProcessInfo.processInfo.arguments
        return args.contains(activationFlag) || args.contains(screenshotFlag)
    }()

    /// True when launched with `-ConduckQAScreenshotMode` (App Store capture).
    /// Implies `isActive`. Drives two deltas from plain QA mode: no QA banner,
    /// and curated marketing conversations instead of the dev-flavored seeds.
    static let isScreenshotMode: Bool = {
        ProcessInfo.processInfo.arguments.contains(screenshotFlag)
    }()

    /// The red "QA MODE" banner shows for plain QA mode but NEVER in screenshot
    /// mode — it would ruin a marketing capture. Banner call-sites gate on this.
    static var showsBanner: Bool { isActive && !isScreenshotMode }

    /// `-ConduckQAForceICloudUnavailable` — force `CloudSyncMonitor` to report
    /// iCloud as signed-out so the "iCloud unavailable" banner + Settings row can
    /// be exercised on the simulator (which can't actually sign out of iCloud and
    /// where the real CloudKit path is inert). Gated on `isActive` so it is inert
    /// without QA mode; the monitor reads it only under `#if DEBUG`.
    static var forceICloudUnavailable: Bool {
        isActive && ProcessInfo.processInfo.arguments.contains(forceICloudUnavailableFlag)
    }

    /// In-memory gateway overrides keyed by backend. Built from the paired
    /// url/token launch flags. A backend is included ONLY when BOTH its URL
    /// (parseable as a `URL`) and its token are present and non-empty — this
    /// mirrors `SettingsManager.configuredRemoteAgentBackends()`'s
    /// url-AND-token requirement so the override set never claims a
    /// half-configured backend. Empty when QA mode is off.
    static let gatewayOverrides: [RemoteAgentBackend: (url: URL, token: String)] = {
        guard isActive else { return [:] }
        var result: [RemoteAgentBackend: (url: URL, token: String)] = [:]
        if let override = override(urlFlag: openClawURLFlag, tokenFlag: openClawTokenFlag) {
            result[.openclaw] = override
        }
        if let override = override(urlFlag: hermesURLFlag, tokenFlag: hermesTokenFlag) {
            result[.hermes] = override
        }
        return result
    }()

    /// Stable UUID for the QA-seeded custom gateway — deterministic across
    /// relaunches so the in-memory roster record + any conversation bound to
    /// `custom_<uuid>` stay consistent run-to-run.
    static let customGatewayID = UUID(uuidString: "C0FFEE00-0000-4000-A000-000000000001")!

    /// In-memory CUSTOM-gateway override: a roster record (`{id,name,model}`)
    /// + its url + token. Present only when BOTH `-ConduckQACustomURL` and
    /// `-ConduckQACustomToken` parse (same url-AND-token rule as the built-ins).
    /// Purely in-memory — like `gatewayOverrides`, it is NEVER written to the
    /// real registry/Keychain (the unsigned sim can't persist the token, and we
    /// keep zero storage pollution); `SettingsManager` injects the roster record
    /// into its READ paths in QA mode so the gateway list/picker/badge render.
    /// `model` (from `-ConduckQACustomModel`) lets QA exercise the model-on-wire
    /// path against a model-requiring server; nil → omitted (gateway default).
    static let customGatewayOverride: (gateway: CustomGateway, url: URL, token: String)? = {
        guard isActive, let override = override(urlFlag: customURLFlag, tokenFlag: customTokenFlag) else {
            return nil
        }
        let name = stringValue(for: customNameFlag) ?? "QA Custom Gateway"
        let model = stringValue(for: customModelFlag)
        let gateway = CustomGateway(id: customGatewayID, name: name, model: model)
        return (gateway, override.url, override.token)
    }()

    /// Default backend a freshly-minted conversation binds to. Sourced from
    /// `-ConduckQADefaultBackend <rawValue>`; falls back to `.openclaw` when
    /// the flag is absent or the value isn't a known `RemoteAgentBackend`.
    static let defaultBackend: RemoteAgentBackend = {
        guard isActive else { return .openclaw }
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: defaultBackendFlag), idx + 1 < args.count,
           let backend = RemoteAgentBackend(rawValue: args[idx + 1]) {
            return backend
        }
        return .openclaw
    }()

    /// Parse a paired url/token flag set into an override tuple. Returns nil
    /// unless BOTH are present, the token is non-empty, and the URL parses.
    private static func override(urlFlag: String, tokenFlag: String) -> (url: URL, token: String)? {
        let args = ProcessInfo.processInfo.arguments
        guard let urlIdx = args.firstIndex(of: urlFlag), urlIdx + 1 < args.count,
              let tokenIdx = args.firstIndex(of: tokenFlag), tokenIdx + 1 < args.count else {
            return nil
        }
        let urlString = args[urlIdx + 1]
        let token = args[tokenIdx + 1]
        // Reject a value slot that's actually the next QA flag (e.g. a missing
        // URL value: `-ConduckQAOpenClawURL -ConduckQAOpenClawToken …`). Without
        // this, `URL(string:)` would accept the flag as a relative URL and the
        // override would surface as a confusing network failure rather than nil.
        guard !urlString.hasPrefix("-ConduckQA"), !token.hasPrefix("-ConduckQA") else {
            return nil
        }
        guard !token.isEmpty, let url = URL(string: urlString) else {
            return nil
        }
        return (url, token)
    }

    /// Read a single string value following a launch flag. Rejects an empty
    /// value or one that's actually the next QA flag (a missing value slot).
    /// nil when the flag is absent.
    private static func stringValue(for flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        let value = args[idx + 1]
        guard !value.isEmpty, !value.hasPrefix("-ConduckQA") else { return nil }
        return value
    }

    /// Idempotent conversation seed. No-op when QA mode is off OR the store
    /// already holds conversations (so re-launches don't pile up duplicates).
    /// Inserts 2–3 threads (`openclaw` + `hermes`, plus a custom thread when a
    /// custom override is supplied) — each with four alternating user/agent
    /// turns via the real `ConversationStore` API, so the list shows meaningful
    /// titles (each thread's first user turn → `titleSnippet`). Content is
    /// dev-flavored for plain QA mode and marketing-grade for screenshot mode
    /// (see `qaSeedThreads` / `screenshotSeedThreads`). Errors are logged and
    /// swallowed — seeding must never crash a QA launch.
    static func seedConversationsIfNeeded() async {
        guard isActive else { return }
        do {
            let existing = try await ConversationStore.shared.fetchConversations()
            guard existing.isEmpty else {
                logger.notice("QAMode seed skipped — \(existing.count, privacy: .public) conversation(s) already present")
                return
            }

            // Screenshot threads may carry attachments; the dev-flavored QA
            // threads never do (mapped up to attachment-less turns). Split the
            // branches because the two seed builders return distinct turn types.
            let threadCount: Int
            if isScreenshotMode {
                let threads = screenshotSeedThreads()
                var seededIDs: [UUID] = []
                for thread in threads {
                    seededIDs.append(
                        try await seedThread(backend: thread.backend, turns: thread.turns))
                }
                threadCount = threads.count
                // Conversations alone leave Settings ▸ Usage empty — the
                // dashboard reads the ATTEMPT ledger, which no seeded message
                // writes. Seeded last so it can hang history off the threads
                // above.
                await seedUsageHistory(conversationIDs: seededIDs)
            } else {
                let threads = qaSeedThreads()
                for thread in threads {
                    try await seedThread(backend: thread.backend, turns: attachless(thread.turns))
                }
                threadCount = threads.count
            }
            logger.notice("QAMode seeded \(threadCount, privacy: .public) conversation(s) (screenshot=\(isScreenshotMode, privacy: .public))")
        } catch {
            logger.error("QAMode conversation seed failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One seeded turn. `device` is a production-format `Message.sourceDevice`
    /// tag (`iphone-text`, `mac-voice`, …) so the bubble-footer chip renders
    /// exactly as real usage would — a bare made-up tag (e.g. "phone") falls
    /// through `MessageRowFormatters` to a literal-string chip the shipping app
    /// never shows.
    private typealias SeedTurn = (role: String, text: String, device: String)
    private typealias SeedThread = (backend: String, turns: [SeedTurn])

    /// A seed turn that additionally carries persisted attachments (drives the
    /// bubble image grid / file chips). The dev-flavored QA seeds never attach,
    /// so they stay bare `SeedTurn`s and lift into this via `attachless`; only
    /// screenshot marketing threads populate the attachments.
    private typealias AttachedSeedTurn = (role: String, text: String, device: String, attachments: [AttachmentDraft])
    private typealias AttachedSeedThread = (backend: String, turns: [AttachedSeedTurn])

    /// Lift bare `SeedTurn`s to attachment-less `AttachedSeedTurn`s so a single
    /// `seedThread` overload feeds both seed sources.
    private static func attachless(_ turns: [SeedTurn]) -> [AttachedSeedTurn] {
        turns.map { (role: $0.role, text: $0.text, device: $0.device, attachments: []) }
    }

    /// Dev-flavored QA seeds — meaningful for an engineer driving QA scenarios,
    /// but not marketing copy. Two built-in threads + a custom thread when a
    /// custom override is present (so QA can verify CUSTOM-ref routing + badge).
    private static func qaSeedThreads() -> [SeedThread] {
        var threads: [SeedThread] = [
            ("openclaw", [
                ("user", "What's a good way to structure a Swift actor for thread-safe state?", "iphone-text"),
                ("agent", "Keep mutable state private to the actor and expose async methods; never hand out references to internal classes.", "iphone"),
                ("user", "Does that mean every read also has to be async?", "iphone-text"),
                ("agent", "Yes — any cross-actor access hops the executor, so callers await reads as well as writes.", "iphone")
            ]),
            ("hermes", [
                ("user", "Summarize the tradeoffs between Core Data and SQLite for a local-first app.", "iphone-text"),
                ("agent", "Core Data gives you object graph management and CloudKit sync; raw SQLite gives you control and portability at the cost of boilerplate.", "iphone"),
                ("user", "Which would you pick for offline sync across Apple devices?", "iphone-text"),
                ("agent", "Core Data with NSPersistentCloudKitContainer — it's the lowest-friction path to multi-device sync on Apple platforms.", "iphone")
            ]),
            // Long markdown-rich thread — forces the LazyVStack to lazily create &
            // measure many `StructuredText` bubbles on scroll, the trigger for the
            // intrinsic-size/first-layout class of bug (Textual #52). Used to
            // scroll-stress agent-bubble rendering & cross-block selection.
            ("openclaw", longMarkdownSeedTurns())
        ]
        if let override = customGatewayOverride {
            threads.append((override.gateway.ref.rawString, [
                ("user", "Test my self-hosted gateway — what model are you?", "iphone-text"),
                ("agent", "I'm the model your custom gateway routes to; this thread is bound to your custom endpoint.", "iphone"),
                ("user", "Good. Does this thread stay on the custom gateway?", "iphone-text"),
                ("agent", "Yes — a conversation is locked to the gateway it was created on; start a new chat to switch.", "iphone")
            ]))
        }
        return threads
    }

    /// A long, markdown-heavy thread (16 turns) of varying bubble heights — short
    /// prose, nested lists, headings, inline code, and fenced code blocks — so
    /// scrolling exercises lazy first-layout measurement of many `StructuredText`
    /// bubbles at once (Textual #52 repro surface).
    private static func longMarkdownSeedTurns() -> [SeedTurn] {
        var turns: [SeedTurn] = []
        let topics = [
            ("How do I make a value type thread-safe?",
             "## Value types & concurrency\nA `struct` is **copied**, so each task gets its own copy — no shared mutable state to race on. Push shared state behind an `actor` instead.\n\n1. Prefer `let` over `var`\n2. Wrap shared mutable state in an `actor`\n   - reads and writes both `await`\n   - never expose internal reference types\n3. Mark cross-task models `Sendable`"),
            ("Show me a tiny actor example.",
             "Here's a counter that's safe under concurrency:\n\n```swift\nactor Counter {\n    private var value = 0\n    func increment() { value += 1 }\n    func current() -> Int { value }\n}\n```\n\nCallers `await counter.increment()` — the actor serializes access."),
            ("What's the difference between `Task` and `Task.detached`?",
             "**`Task { }`** inherits the current actor context and priority. **`Task.detached { }`** does **not** — it starts fresh with no actor isolation. Reach for `detached` only when you explicitly want to escape the current context; it's easy to misuse."),
            ("How should I handle errors in async code?",
             "### Three patterns\n- `try await` for propagation\n- `Result` when you want to *store* the outcome\n- `async`-`throws` boundaries at the edges, mapped to a UI-friendly `enum`\n\nKeep raw provider errors out of the view layer — translate them once at the boundary."),
            ("Give me a checklist for reviewing a PR.",
             "**Review checklist**\n1. Does it do what the description says?\n2. Tests: new behavior covered, suite green\n3. Edge cases\n   - empty input\n   - cancellation mid-flight\n   - the slow-network path\n4. No secrets / tokens logged\n5. Naming reads like the surrounding code"),
            ("How do I debounce a search field?",
             "Use a structured-concurrency debounce:\n\n```swift\n.task(id: query) {\n    try? await Task.sleep(for: .milliseconds(300))\n    guard !Task.isCancelled else { return }\n    await runSearch(query)\n}\n```\n\nChanging `query` cancels the prior task, so only the last keystroke survives the delay."),
            ("Explain `@MainActor` in one paragraph.",
             "`@MainActor` pins a type or function to the main thread's executor. Anything UI-touching should be main-actor isolated so SwiftUI sees mutations on the main thread. Calls *into* it from a background context `await`; calls already on the main actor are synchronous."),
            ("Any quick tips for keeping a chat thread smooth while scrolling?",
             "A few that matter:\n- Use a `LazyVStack` so off-screen bubbles aren't built\n- Give each row a **stable identity** so SwiftUI can diff cheaply\n- Avoid per-frame work in `body` (no timers beside a `ScrollView`)\n- Measure once and cache — re-parsing markdown on every scroll tick is the classic stutter source")
        ]
        for (q, a) in topics {
            turns.append(("user", q, "iphone-text"))
            turns.append(("agent", a, "iphone"))
        }
        return turns
    }

    /// Marketing-grade seeds for App Store capture: warm, useful, and aligned
    /// with the listing's story (every Apple device · bring your own AI · no
    /// middleman). The first user turn of each becomes its list `titleSnippet`,
    /// so they read well as conversation-list rows too. Device tags are
    /// production-format so chips render real (`iphone-voice` shows the
    /// waveform glyph, `mac-text` the keyboard); the continuity thread mixes
    /// `mac-*` and `iphone-*` turns so a single capture shows one conversation
    /// travelling across devices. The custom thread (a named BYO gateway) is
    /// included only when a custom override is supplied. Seed order matters:
    /// the LAST thread seeded is the most recently active, so it tops the list.
    private static func screenshotSeedThreads() -> [AttachedSeedThread] {
        var threads: [AttachedSeedThread] = [
            ("openclaw", attachmentShowcaseTurns()),
            ("hermes", attachless([
                ("user", "What can you actually see about me?", "iphone-text"),
                ("agent", "Only what you send in this chat. There's no intermediary server in between — your messages go straight from your device to the model you set up, with your own key.", "iphone"),
                ("user", "And when I talk instead of type?", "iphone-text"),
                ("agent", "By default your speech becomes text right on your iPhone, on-device. Your voice never leaves the phone.", "iphone")
            ])),
            ("openclaw", attachless([
                ("user", "Turn my meeting notes into three action items.", "mac-text"),
                ("agent", "Done:\n\n1. Send the revised quote to Alba by Thursday\n2. Book the room for Q3 planning\n3. Chase the printer's missing invoice\n\nWant these as reminders?", "mac"),
                ("user", "Which one was due Thursday again?", "iphone-text"),
                ("agent", "The revised quote for Alba — the other two have no deadline yet.", "iphone")
            ]))
        ]
        if let override = customGatewayOverride {
            threads.append((override.gateway.ref.rawString, attachless([
                ("user", "What's left on my plate before the 3pm call?", "iphone-voice"),
                ("agent", "Three things:\n\n1. Finish the budget draft\n2. Reply to Sam\n3. Review the two open PRs\n\nWant me to block time for each?", "iphone"),
                ("user", "Just the first two.", "iphone-text"),
                ("agent", "Done — 30 min for the budget draft, 10 for Sam's reply. The PRs can wait till after the call.", "iphone")
            ])))
        }
        return threads
    }

    /// The lead screenshot thread — an attachment showcase. The user turn sends
    /// the duck mascot IMAGE (from `-ConduckQASeedImagePath`, rendered in the
    /// bubble image grid) + a server-reference PDF chip; the agent replies with
    /// an edited-file DOWNLOAD chip (a server-reference `image/png`). The image
    /// is omitted (chip-only turn) when the flag is absent or the read fails —
    /// the PDF/download chips still render, so the thread never no-ops.
    private static func attachmentShowcaseTurns() -> [AttachedSeedTurn] {
        var userAttachments: [AttachmentDraft] = []
        if let image = seedImageDraft(sequence: 0) {
            userAttachments.append(image)
        }
        var checklist = AttachmentDraft(
            mimeType: "application/pdf",
            filename: "launch-checklist.pdf",
            data: Data(),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: 186_000,
            sequence: 1
        )
        checklist.isServerReference = true
        checklist.storedKey = "qa02__launch-checklist.pdf"
        userAttachments.append(checklist)

        var editedImage = AttachmentDraft(
            mimeType: "image/png",
            filename: "duck-astronaut.png",
            data: Data(),
            thumbnailData: nil,
            width: 0,
            height: 0,
            byteSize: 412_000,
            sequence: 0
        )
        editedImage.isServerReference = true
        editedImage.storedKey = "qa01__duck-astronaut.png"

        return [
            (role: "user",
             text: "Help me with the launch post: put this duck in a space suit, and flag anything missing in the checklist.",
             device: "iphone-text",
             attachments: userAttachments),
            (role: "agent",
             text: "Space suit on, visor up — saved next to the original.\n\nThe checklist has two gaps: the press-kit link is still a placeholder, and day-one support has no owner. Everything else is ready.",
             device: "iphone",
             attachments: [editedImage])
        ]
    }

    /// Build the user-image attachment from the file at `-ConduckQASeedImagePath`
    /// (a HOST path readable from the sim process). Returns nil — logged, never
    /// throwing — when the flag is absent or the bytes don't read / decode, so a
    /// missing seed image degrades to a chip-only turn rather than crashing.
    /// `thumbnailData` is a ~600px PNG preview (alpha preserved for a clean dark
    /// bubble); `data` is the full original bytes.
    private static func seedImageDraft(sequence: Int) -> AttachmentDraft? {
        guard isActive, let path = stringValue(for: seedImagePathFlag) else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            logger.error("QAMode seed image unreadable at supplied path")
            return nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            logger.error("QAMode seed image failed to decode")
            return nil
        }
        let thumbnail = downsizedPNG(from: source, maxPixel: 600) ?? data
        return AttachmentDraft(
            mimeType: mimeType(forPath: path),
            filename: nil,
            data: data,
            thumbnailData: thumbnail,
            width: width,
            height: height,
            byteSize: data.count,
            sequence: sequence
        )
    }

    /// Decode-and-downsize in one pass to a PNG (alpha preserved — the mascot art
    /// is transparent). Nil on any ImageIO failure; the caller falls back to the
    /// full bytes.
    private static func downsizedPNG(from source: CGImageSource, maxPixel: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// Real MIME from the file extension (`image/png` for PNG); defaults to
    /// `image/png` for an unrecognized extension.
    private static func mimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return "image/png"
    }

    /// Create one conversation and append its turns through the real store API
    /// (so `titleSnippet` denormalization, activity-stamp bumps, and CloudKit
    /// behaviour match production). Returns the conversation's id so the
    /// screenshot usage seed can hang a month of attempt history off threads
    /// that really exist on this device — a ranked thread whose conversation is
    /// absent renders as unavailable rather than as a row worth capturing.
    @discardableResult
    private static func seedThread(backend: String, turns: [AttachedSeedTurn]) async throws -> UUID {
        let conversation = try await ConversationStore.shared.createConversation(backend: backend)
        for turn in turns {
            _ = try await ConversationStore.shared.appendMessage(
                role: turn.role,
                text: turn.text,
                conversationID: conversation.id,
                sourceDevice: turn.device,
                status: "sent",
                attachments: turn.attachments
            )
        }
        return conversation.id
    }

    // MARK: - Usage-history seed (screenshot mode only)

    /// Days of history the usage seed lays down. Matches the dashboard's default
    /// 30-day range, so the capture opens on a full chart rather than on a
    /// window that is mostly empty.
    private static let usageSeedDays = 30

    /// Turns per day, OLDEST first, one entry per `usageSeedDays`. Hand-written
    /// rather than generated: an activity chart is the one thing on the screen a
    /// reader judges by SHAPE, and a uniform random walk reads as noise while a
    /// smooth curve reads as fake. This is a working month — busy midweeks, thin
    /// weekends, one near-idle day, and a today that is still running.
    private static let usageSeedDailyTurns = [
        6, 9, 11, 7, 3, 2, 8, 12, 10, 14,
        9, 4, 1, 7, 11, 13, 8, 6, 3, 9,
        15, 12, 10, 5, 2, 8, 14, 11, 9, 4
    ]

    /// The turns that did not simply succeed, named by their index in the month.
    /// EXPLICIT RATHER THAN ROLLED: reliability is a headline figure on the
    /// captured card, and a coin flip cannot be asked to land on a believable
    /// rate with a non-zero incident count on every rebuild. Together these put
    /// the resolved success rate just under 98 % — high enough to be a working
    /// setup, never the 100 % that would read as a screen with no data behind
    /// it. Chosen for `usageSeedDailyTurns`' 243 turns; re-pick them if that
    /// month changes.
    ///
    /// A transport failure the retry then landed. Drives "recovered by retry".
    private static let usageSeedRecoveredTurns: Set<Int> = [30, 111, 192]
    /// Retried, and the retry failed too — so recovery is not a flat 100 %.
    private static let usageSeedUnrecoveredTurns: Set<Int> = [140]
    /// Failed on its only attempt.
    private static let usageSeedFailedTurns: Set<Int> = [77]
    /// The user stopped waiting. Outside every rate on the card, which is
    /// exactly why one belongs in the mix.
    private static let usageSeedCancelledTurns: Set<Int> = [44, 153]

    /// One planned attempt, fully decided before anything is written. Building
    /// the whole month first keeps the store calls a dumb replay loop and keeps
    /// every derived figure — reliability, retry recovery, token coverage —
    /// decided in one place where it can be reasoned about.
    private struct SeedUsageAttempt {
        let attemptID = UUID()
        let conversationID: UUID
        let userMessageID: UUID
        let gatewayRef: String
        let origin: GatewayAttemptOrigin
        let inputMode: GatewayInputMode
        let requestedModel: String?
        let deviceClass: String?
        let startedAt: Date
        let completedAt: Date
        let outcome: GatewayAttemptOutcome
        let appErrorCode: Int?
        let metadata: GatewayResponseMetadata?
        let currentImages: Int
        let priorImages: Int
        let currentTextFiles: Int
        let priorTextFiles: Int
    }

    /// One gateway slot's habits. Gateways do not report alike — that is a
    /// premise of the dashboard's own copy — so the seed gives each slot its own
    /// reporting completeness, latency band and model list rather than sprinkling
    /// one distribution across all of them.
    private struct SeedUsageLane {
        let ref: String
        /// Relative share of the month's turns.
        let weight: Int
        /// Requested-model values this slot sends. `nil` is a real value: an
        /// agent gateway picks its own model, and the dashboard names that
        /// "Gateway default".
        var models: [String?]
        /// Percent of landings whose body carried usage this slot could keep.
        let reportsTokensPercent: Int
        /// Whether this slot ever reports prompt-cache detail.
        let reportsCacheDetail: Bool
        /// Whether this slot ever reports reasoning-token detail.
        let reportsReasoningDetail: Bool
        /// Full-response time band in milliseconds.
        let latencyMS: ClosedRange<Int>
    }

    /// A deterministic value source. NOT `SystemRandomNumberGenerator`: the same
    /// build has to produce the same dashboard every launch, or a recapture
    /// after a copy tweak silently changes every figure in the shot. SplitMix64
    /// over a fixed seed — a few lines, and good enough to look organic.
    private struct SeedRandom {
        private var state: UInt64

        init(seed: UInt64) { self.state = seed }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func int(_ range: ClosedRange<Int>) -> Int {
            let span = UInt64(range.upperBound - range.lowerBound + 1)
            return range.lowerBound + Int(next() % span)
        }

        /// True `percent` of the time, in tenths of a percent so the rare
        /// outcomes (a cancel, a truncated reply) can be tuned below 1 %.
        mutating func chance(perMille: Int) -> Bool { int(1...1000) <= perMille }

        mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
    }

    /// Lay down a month of gateway attempts behind the seeded conversations, so
    /// Settings ▸ Usage renders a populated dashboard instead of its empty state.
    ///
    /// EVERY ROW GOES IN THROUGH THE REAL LEDGER API — `beginGatewayAttempt`
    /// opens it and a `TerminalAttemptObservation` closes it, exactly as a
    /// dispatch and its landing would — so the seeded rows carry the same
    /// columns, the same one terminal transition and the same fail-open
    /// behaviour as production ones. The ONE thing no real API can do is date a
    /// row in the past (begin stamps `startedAt` inside its own transaction, and
    /// must), which is what the DEBUG-only backdate at the end is for.
    ///
    /// Best-effort throughout: a begin that returns nil is skipped and the rest
    /// of the month still lands, matching the ledger's own posture that
    /// measurement never outranks anything.
    private static func seedUsageHistory(conversationIDs: [UUID]) async {
        guard isScreenshotMode, !conversationIDs.isEmpty else { return }
        let plans = usageHistoryPlan(conversationIDs: conversationIDs)
        var starts: [UUID: Date] = [:]
        for plan in plans {
            let draft = GatewayAttemptDraft(
                attemptID: plan.attemptID,
                conversationID: plan.conversationID,
                userMessageID: plan.userMessageID,
                gatewayRef: plan.gatewayRef,
                origin: plan.origin,
                inputMode: plan.inputMode,
                requestedModel: plan.requestedModel,
                deviceClass: plan.deviceClass,
                currentTurnInlineImageCount: plan.currentImages,
                priorTurnInlineImageCount: plan.priorImages,
                currentTurnInlineTextFileCount: plan.currentTextFiles,
                priorTurnInlineTextFileCount: plan.priorTextFiles
            )
            guard await ConversationStore.shared.beginGatewayAttempt(draft: draft) != nil else {
                continue
            }
            await ConversationStore.shared.terminalizeGatewayAttempt(
                TerminalAttemptObservation(
                    attemptID: plan.attemptID,
                    completedAt: plan.completedAt,
                    outcome: plan.outcome,
                    appErrorCode: plan.appErrorCode,
                    metadata: plan.metadata
                )
            )
            starts[plan.attemptID] = plan.startedAt
        }
        await ConversationStore.shared.debugBackdateGatewayAttemptStarts(starts)
        logger.notice("QAMode seeded \(starts.count, privacy: .public) usage attempt(s)")
    }

    /// Decide the whole month. Pure — no store, no clock beyond one `Date()` at
    /// the top — so the shape of the data is auditable in one read.
    private static func usageHistoryPlan(conversationIDs: [UUID]) -> [SeedUsageAttempt] {
        var rng = SeedRandom(seed: 0xC0FF_EE00_D0CC_0001)
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        let lanes = usageSeedLanes()
        // Weighted slot list, drawn from directly — the alternative is a running
        // cumulative sum at every draw for a table that never changes.
        var lanePool: [SeedUsageLane] = []
        for lane in lanes {
            for _ in 0..<lane.weight { lanePool.append(lane) }
        }

        // Threads the ledger can still point at, plus threads it outlived. Usage
        // history is first-class and survives its conversations, so a month that
        // maps one-to-one onto four live threads would misrepresent the feature
        // AND read as a suspiciously tidy account. The live ones carry the
        // heavier traffic, which is what keeps them at the top of the ranked
        // list where the rows are navigable.
        var threadPool: [(id: UUID, tokenScale: Double)] = []
        for id in conversationIDs {
            for _ in 0..<5 { threadPool.append((id, 1.0)) }
        }
        for index in 1...10 {
            guard let id = UUID(
                uuidString: String(format: "C0FFEE00-0000-4000-B000-%012X", index)
            ) else { continue }
            threadPool.append((id, 0.5))
        }

        var plans: [SeedUsageAttempt] = []
        var turnIndex = 0
        for (index, turnCount) in usageSeedDailyTurns.enumerated() {
            let daysAgo = usageSeedDays - 1 - index
            guard let dayStart = calendar.date(byAdding: .day, value: -daysAgo, to: today) else {
                continue
            }
            // Today is still running: keep its turns safely behind the pinned
            // 9:41 status bar rather than dropping attempts into the future.
            let hours = daysAgo == 0 ? 5...7 : 8...21
            for _ in 0..<turnCount {
                let startedAt = dayStart.addingTimeInterval(
                    TimeInterval(rng.int(hours) * 3600 + rng.int(0...59) * 60 + rng.int(0...59))
                )
                plans.append(contentsOf: turnAttempts(
                    turnIndex: turnIndex,
                    startedAt: startedAt,
                    lane: rng.pick(lanePool),
                    thread: rng.pick(threadPool),
                    rng: &rng
                ))
                turnIndex += 1
            }
        }
        return plans
    }

    /// The gateway slots the seed spreads its month across — the built-ins the
    /// screenshot rig configures, plus the named custom slot when one was
    /// supplied. When there is no custom slot the model names move onto Hermes,
    /// so the By-model card still has a mix to describe instead of vanishing.
    private static func usageSeedLanes() -> [SeedUsageLane] {
        var lanes = [
            SeedUsageLane(
                ref: RemoteAgentBackend.openclaw.rawValue,
                weight: 5,
                models: [nil],
                reportsTokensPercent: 100,
                reportsCacheDetail: true,
                reportsReasoningDetail: true,
                latencyMS: 2_200...14_000
            ),
            SeedUsageLane(
                ref: RemoteAgentBackend.hermes.rawValue,
                weight: 3,
                models: [nil],
                reportsTokensPercent: 78,
                reportsCacheDetail: false,
                reportsReasoningDetail: true,
                latencyMS: 1_800...9_000
            )
        ]
        // Open-weight names on purpose: the custom slot IS someone's own box, and
        // a self-hosted model list is what that box actually runs.
        let selfHosted: [String?] = ["llama-3.3-70b", "qwen3-30b"]
        if let override = customGatewayOverride {
            lanes.append(SeedUsageLane(
                ref: override.gateway.ref.rawString,
                weight: 2,
                models: selfHosted,
                reportsTokensPercent: 100,
                reportsCacheDetail: true,
                reportsReasoningDetail: false,
                latencyMS: 3_200...19_000
            ))
        } else {
            lanes[1].models = selfHosted
        }
        return lanes
    }

    /// One user turn's attempts. Almost always exactly one that succeeded; the
    /// handful of turns named in the incident sets above instead fail, get
    /// retried, or are cancelled — which is what puts a real incident count and
    /// a real "recovered by retry" figure on the screen.
    private static func turnAttempts(
        turnIndex: Int,
        startedAt: Date,
        lane: SeedUsageLane,
        thread: (id: UUID, tokenScale: Double),
        rng: inout SeedRandom
    ) -> [SeedUsageAttempt] {
        let turnID = UUID()
        let surface = usageSeedSurface(&rng)
        let model = rng.pick(lane.models)

        func attempt(
            at start: Date,
            outcome: GatewayAttemptOutcome,
            appErrorCode: Int?,
            elapsed: TimeInterval,
            metadata: GatewayResponseMetadata?
        ) -> SeedUsageAttempt {
            SeedUsageAttempt(
                conversationID: thread.id,
                userMessageID: turnID,
                gatewayRef: lane.ref,
                origin: surface.origin,
                inputMode: surface.inputMode,
                requestedModel: model,
                deviceClass: surface.deviceClass,
                startedAt: start,
                completedAt: start.addingTimeInterval(elapsed),
                outcome: outcome,
                appErrorCode: appErrorCode,
                metadata: metadata,
                currentImages: surface.currentImages,
                priorImages: surface.priorImages,
                currentTextFiles: surface.currentTextFiles,
                priorTextFiles: surface.priorTextFiles
            )
        }

        func succeeded(at start: Date) -> SeedUsageAttempt {
            attempt(
                at: start,
                outcome: .succeeded,
                appErrorCode: nil,
                elapsed: usageSeedElapsed(lane: lane, rng: &rng),
                metadata: usageSeedMetadata(
                    lane: lane, model: model, scale: thread.tokenScale, rng: &rng)
            )
        }

        func failed(at start: Date) -> SeedUsageAttempt {
            attempt(
                at: start,
                outcome: .failed,
                appErrorCode: usageSeedFailureCode(&rng),
                elapsed: TimeInterval(rng.int(6...50)),
                metadata: nil
            )
        }

        /// Where a retry starts: after the first attempt gave up, plus the beat
        /// it takes to notice and tap.
        func retryStart(after first: SeedUsageAttempt) -> Date {
            first.completedAt.addingTimeInterval(TimeInterval(rng.int(5...90)))
        }

        if usageSeedCancelledTurns.contains(turnIndex) {
            return [attempt(
                at: startedAt,
                outcome: .cancelled,
                appErrorCode: nil,
                elapsed: TimeInterval(rng.int(4...40)),
                metadata: nil
            )]
        }
        if usageSeedFailedTurns.contains(turnIndex) {
            return [failed(at: startedAt)]
        }
        if usageSeedRecoveredTurns.contains(turnIndex) {
            let first = failed(at: startedAt)
            return [first, succeeded(at: retryStart(after: first))]
        }
        if usageSeedUnrecoveredTurns.contains(turnIndex) {
            let first = failed(at: startedAt)
            return [first, failed(at: retryStart(after: first))]
        }
        return [succeeded(at: startedAt)]
    }

    /// Which surface sent the turn, and what rode along with it. Device, origin
    /// and input mode are decided TOGETHER because they are not independent: the
    /// wrist is voice, a head unit is voice on iPhone hardware, and a Mac is
    /// overwhelmingly typed.
    private static func usageSeedSurface(
        _ rng: inout SeedRandom
    ) -> (
        origin: GatewayAttemptOrigin,
        inputMode: GatewayInputMode,
        deviceClass: String?,
        currentImages: Int,
        priorImages: Int,
        currentTextFiles: Int,
        priorTextFiles: Int
    ) {
        let roll = rng.int(1...100)
        let origin: GatewayAttemptOrigin
        let inputMode: GatewayInputMode
        let deviceClass: String
        switch roll {
        case 1...8:
            // The wrist. `origin` alone puts it in the watch bucket.
            origin = .watch
            inputMode = rng.chance(perMille: 920) ? .voice : .text
            deviceClass = GatewayAttemptDeviceClass.watch.rawValue
        case 9...15:
            // A head unit — the dispatch runs on the iPhone, so the class is
            // `iphone` and `origin` is what makes it CarPlay.
            origin = .carPlay
            inputMode = .voice
            deviceClass = GatewayAttemptDeviceClass.iphone.rawValue
        case 16...37:
            origin = rng.chance(perMille: 350) ? .menuBar : .app
            inputMode = rng.chance(perMille: 880) ? .text : .voice
            deviceClass = GatewayAttemptDeviceClass.mac.rawValue
        default:
            if rng.chance(perMille: 100) {
                origin = .quickCapture
                inputMode = .voice
            } else if rng.chance(perMille: 35) {
                origin = .share
                inputMode = .shared
            } else {
                origin = .app
                inputMode = rng.chance(perMille: 610) ? .text : .voice
            }
            deviceClass = GatewayAttemptDeviceClass.iphone.rawValue
        }

        let currentImages = inputMode == .shared
            ? rng.int(1...2)
            : (rng.chance(perMille: 60) ? rng.int(1...2) : 0)
        let currentTextFiles = rng.chance(perMille: 45) ? 1 : 0
        return (
            origin: origin,
            inputMode: inputMode,
            deviceClass: deviceClass,
            currentImages: currentImages,
            // History replayed on this request — the same image riding along on
            // the follow-up turns of a thread that has one.
            priorImages: rng.chance(perMille: 120) ? rng.int(1...3) : 0,
            currentTextFiles: currentTextFiles,
            priorTextFiles: rng.chance(perMille: 70) ? 1 : 0
        )
    }

    /// Full-response time, with the long tail an agent gateway really has: most
    /// answers inside the lane's band, a handful several times slower because a
    /// tool ran.
    private static func usageSeedElapsed(lane: SeedUsageLane, rng: inout SeedRandom) -> TimeInterval {
        let base = Double(rng.int(lane.latencyMS)) / 1_000
        return rng.chance(perMille: 90) ? base * Double(rng.int(2...4)) : base
    }

    /// What the gateway reported about the turn. The three DETAIL figures are
    /// SUBSETS of the two above them — cached and cache-write of the input,
    /// reasoning of the output — and are derived that way here so the seeded
    /// rows honour the containment the ledger documents.
    private static func usageSeedMetadata(
        lane: SeedUsageLane,
        model: String?,
        scale: Double,
        rng: inout SeedRandom
    ) -> GatewayResponseMetadata? {
        guard rng.int(1...100) <= lane.reportsTokensPercent else { return nil }
        let input = Int64(Double(rng.int(1_500...12_000)) * scale)
        let output = Int64(Double(rng.int(120...1_800)) * scale)
        let cached: Int64? = lane.reportsCacheDetail && rng.chance(perMille: 380)
            ? Int64(Double(input) * Double(rng.int(30...70)) / 100)
            : nil
        let cacheWrite: Int64? = lane.reportsCacheDetail && rng.chance(perMille: 150)
            ? Int64(Double(input) * Double(rng.int(5...20)) / 100)
            : nil
        let reasoning: Int64? = lane.reportsReasoningDetail && rng.chance(perMille: 300)
            ? Int64(Double(output) * Double(rng.int(20...60)) / 100)
            : nil
        return GatewayResponseMetadata(
            reportedModel: model,
            reportedResponseID: nil,
            // `length` is the one finish reason with a user-visible consequence
            // — it is what puts a "Replies cut short" row on the card.
            finishReason: rng.chance(perMille: 15) ? "length" : "stop",
            reportedInputTokens: input,
            reportedOutputTokens: output,
            reportedTotalTokens: input + output,
            reportedCachedInputTokens: cached,
            reportedCacheWriteInputTokens: cacheWrite,
            reportedReasoningOutputTokens: reasoning
        )
    }

    /// Conduck's OWN error codes, never a server code or status. Transport
    /// trouble reaching someone else's always-on box is what actually fails for
    /// a self-hosted gateway.
    private static func usageSeedFailureCode(_ rng: inout SeedRandom) -> Int {
        rng.pick([
            AppError.remoteAgentTimeout.errorCode,
            AppError.remoteAgentTimeout.errorCode,
            AppError.noInternetConnection.errorCode,
            AppError.remoteAgentUnreachable.errorCode
        ])
    }
}

#endif
