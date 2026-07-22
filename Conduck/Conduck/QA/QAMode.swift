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
                for thread in threads {
                    try await seedThread(backend: thread.backend, turns: thread.turns)
                }
                threadCount = threads.count
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
    /// behaviour match production).
    private static func seedThread(backend: String, turns: [AttachedSeedTurn]) async throws {
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
    }
}

#endif
