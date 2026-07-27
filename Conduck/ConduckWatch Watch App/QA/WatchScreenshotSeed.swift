// SPDX-License-Identifier: Apache-2.0

#if DEBUG

import Foundation

/// DEBUG-only screenshot seeder for the Conduck **Watch** app. Activated by the
/// `-ConduckWatchQAScreenshotMode` launch argument (added to the "ConduckWatch
/// Watch App" scheme's Run action).
///
/// **Why this exists (watch parity with the iOS `QAMode`):** the wrist reads its
/// gateway config from the paired iPhone (iCloud KVS + WCSession) and its
/// conversations from its OWN local `ConversationStore`, fed only by CloudKit
/// sync. On the simulator BOTH are empty/inert — KVS/CloudKit don't sync on an
/// unsigned sim, and the iOS `QAMode` rig seeds only the phone — so the watch
/// lands unconfigured with an empty conversation list, useless for a marketing
/// capture. This seeds, purely in memory + the wrist's local store:
///   1. Two **keyless** built-in gateways (OpenClaw + Hermes) injected into
///      `WatchSettingsReader` via a synthesized broadcast envelope, so the
///      launchpad "Ask" chooser + gateway picker render as configured. Keyless
///      (`.none`) sidesteps the unsigned-sim Keychain block — a static
///      screenshot never sends, so no real token is needed.
///   2. Three marketing conversations into the local `ConversationStore` — only
///      when the store is empty (idempotent across relaunches, mirroring the
///      iOS `QAMode.seedConversationsIfNeeded`).
///
/// **Production safety (two gates):** the whole file is `#if DEBUG`, so Release
/// contains zero symbols; and every behavior is additionally gated on
/// `isActive` (the launch flag). A Debug build launched WITHOUT the flag is
/// byte-identical to today: no seeding, no gateway injection.
enum WatchScreenshotSeed {
    private static let activationFlag = "-ConduckWatchQAScreenshotMode"

    /// True when launched with `-ConduckWatchQAScreenshotMode`.
    static let isActive: Bool = {
        ProcessInfo.processInfo.arguments.contains(activationFlag)
    }()

    /// Dummy but well-formed base URLs for the seeded keyless gateways. Never
    /// contacted — a static screenshot issues no request; they exist only so
    /// `WatchSettingsReader.remoteAgentConfig(for:)` returns non-nil (keyless =
    /// URL alone is enough) and each gateway reads as configured.
    private static let openClawURL = URL(string: "https://openclaw.local")!
    private static let hermesURL = URL(string: "https://hermes.local")!

    /// Inject gateways + seed conversations. Safe to call unconditionally — a
    /// no-op unless `isActive`. Called once from `ConduckWatchApp`'s root `.task`.
    @MainActor
    static func seedIfNeeded() async {
        guard isActive else { return }
        seedGateways()
        await seedConversationsIfNeeded()
    }

    /// Inject OpenClaw + Hermes as keyless (`.none`) configured gateways so the
    /// launchpad Ask chooser presents a 2-gateway picker ("Ask which gateway?")
    /// and each seeded thread's badge resolves. Uses the real
    /// `updateRemoteAgents(multi:)` path with a synthesized envelope; a `Date()`-
    /// now timestamp beats any stale stored high-water so it is always accepted.
    @MainActor
    private static func seedGateways() {
        let now = Date().timeIntervalSinceReferenceDate
        func sub(_ backend: RemoteAgentBackend, url: URL) -> RemoteAgentBroadcastEnvelope {
            RemoteAgentBroadcastEnvelope(
                backendRef: RemoteAgentRef.builtin(backend).rawString,
                url: url,
                name: nil,          // built-ins derive their name from `displayName`
                model: nil,
                colorID: nil,
                monogram: nil,
                token: nil,         // keyless — no token needed or stored
                authScheme: .none,  // keyless: config resolves on the URL alone
                certFingerprintHex: nil,
                activeSessionID: nil,
                timestamp: now
            )
        }
        let envelope = RemoteAgentMultiBroadcastEnvelope(
            backends: [sub(.openclaw, url: openClawURL), sub(.hermes, url: hermesURL)],
            defaultBackendRef: RemoteAgentRef.builtin(.openclaw).rawString,
            timestamp: now,
            sessionPolicy: nil
        )
        WatchSettingsReader.shared.updateRemoteAgents(multi: envelope)
    }

    /// One marketing thread: a backend + alternating user/agent turns. The first
    /// user turn becomes the list row's title snippet, so it reads well as a row.
    private typealias SeedTurn = (role: String, text: String, device: String)
    private typealias SeedThread = (backend: RemoteAgentBackend, turns: [SeedTurn])

    /// Marketing seeds mirroring the iOS screenshot copy, trimmed for the wrist.
    /// Device tags are production-format (`iphone-voice` / `iphone`) so the
    /// bubble footer chips render real, telling the cross-device story (a thread
    /// that travelled from iPhone to the wrist). Seed order matters: the LAST
    /// thread seeded is the most-recently-active, so it tops the list.
    private static func seedThreads() -> [SeedThread] {
        [
            (.hermes, [
                ("user", "What can you actually see about me?", "iphone-text"),
                ("agent", "Only what you send in this chat — there's no server in between. Your messages go straight to the AI you set up, with your own key.", "iphone")
            ]),
            (.openclaw, [
                ("user", "Turn my meeting notes into three action items.", "iphone-voice"),
                ("agent", "Done:\n\n1. Send Alba the revised quote\n2. Book the Q3 planning room\n3. Chase the missing invoice", "iphone")
            ]),
            (.openclaw, [
                ("user", "What's left before my 3pm call?", "iphone-voice"),
                ("agent", "Three things:\n\n1. Finish the budget draft\n2. Reply to Sam\n3. Review the two open PRs", "iphone")
            ])
        ]
    }

    /// Seed the marketing threads into the wrist's local `ConversationStore` —
    /// only when the store is empty (idempotent across relaunches, mirroring the
    /// iOS `QAMode.seedConversationsIfNeeded`). Uses the real store API so
    /// title-snippet denormalization + activity stamps match production. Errors
    /// are logged and swallowed — seeding must never crash a capture launch.
    static func seedConversationsIfNeeded() async {
        do {
            let existing = try await ConversationStore.shared.fetchConversations()
            guard existing.isEmpty else {
                WatchLog.note(.nav, "screenshot.seed.skip", ["have": existing.count])
                return
            }
            let threads = seedThreads()
            for thread in threads {
                let conversation = try await ConversationStore.shared.createConversation(
                    backend: RemoteAgentRef.builtin(thread.backend).rawString
                )
                for turn in thread.turns {
                    _ = try await ConversationStore.shared.appendMessage(
                        role: turn.role,
                        text: turn.text,
                        conversationID: conversation.id,
                        sourceDevice: turn.device,
                        status: "sent"
                    )
                }
            }
            WatchLog.note(.nav, "screenshot.seed.done", ["threads": threads.count])
        } catch {
            WatchLog.error(.nav, "screenshot.seed.failed", ["err": error.localizedDescription])
        }
    }
}

#endif
