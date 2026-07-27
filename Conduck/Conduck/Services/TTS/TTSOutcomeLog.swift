// SPDX-License-Identifier: Apache-2.0

// Conduck
// TTSOutcomeLog.swift
//
// DEVICE-LOCAL forensic ring of recent TTS outcome decisions (iOS / macOS
// target; the wrist's equivalent forensic layer is `WatchLog`). Exists because
// the chat path's silent Apple fallback is deliberate (a spoken reply must
// never go silent — CarPlay hands-free), which used to mean a fallback left NO
// reconstructable trace: "why did my phone speak the built-in voice at 20:39"
// had no answer. The ring answers it from Diagnostics without violating privacy.
//
// WHAT IS RECORDED (one event per turn/test at the surface's terminal
// decision — never per internal retry):
//   - a chat/CarPlay turn's Apple-FALLBACK start (recorded when the fallback
//     audio actually STARTS, not when it is merely attempted),
//   - a turn the engine had to give up on (`gaveUp` — the Apple leg never
//     produced audio and the inactivity watchdog settled the turn),
//   - preview / diagnostics failures (loud) and USER-INITIATED successes
//     (`cloudOK` / `appleOK`).
// Routine successful chat playback is NOT recorded (noise, and privacy posture:
// the log must never become a usage journal).
//
// PRIVACY (hard rules): events carry NO message/conversation IDs, no
// text, no keys or key tails, no URLs, no raw voice/model strings, no provider
// bodies, no `localizedDescription`. Safe fields only: timestamp, surface,
// typed stage, outcome, `AppError.errorCode`, typed key state, and an OPAQUE
// configuration signature (a truncated hash over non-secret config fields —
// deliberately EXCLUDING the custom endpoint URL; only its presence + auth
// scheme feed the hash). Storage is the DEVICE-LOCAL App Group defaults suite
// only — never iCloud KVS, Core Data, CloudKit, or any outbound service
// (imitates the `screenshotAskTipSeenKey` device-local pattern; the key lives
// under the `diag.` namespace, outside every KVS-mirrored prefix).

import Foundation
import CryptoKit

/// One recorded TTS outcome decision. All fields privacy-safe (see file header).
struct TTSOutcomeEvent: Codable, Equatable, Sendable {
    /// Which speak surface made the terminal decision.
    enum Surface: String, Codable, Sendable {
        case chat, carplay, preview, diagnostics
    }

    /// Where in the pipeline the decision was made.
    enum Stage: String, Codable, Sendable {
        /// Key resolution (missing / unreadable key at snapshot time).
        case key
        /// The cloud synthesis fetch (throw from `TTSClient`).
        case fetch
        /// Fetched bytes were undecodable.
        case decode
        /// `play()` refused to start.
        case playStart
        /// Playback began but died mid-clip (`successfully: false` / decode error).
        case playback
        /// A chunked turn's chunk was unplayable.
        case chunk
        /// The first-audio watchdog expired (hung pipeline).
        case stall
        /// The Apple leg itself (its start, or its inactivity settlement).
        case apple
    }

    /// The terminal decision.
    enum Outcome: String, Codable, Sendable {
        /// A user-initiated cloud sample/preview actually played.
        case cloudOK
        /// A user-initiated INTENDED-Apple sample played (Apple sentinel —
        /// neither a cloud success nor a fallback).
        case appleOK
        /// The Apple FALLBACK leg's audio actually started for a cloud turn.
        case appleFallback
        /// A preview/diagnostics run failed loud (no substitution).
        case failedLoud
        /// The turn could not be spoken at all — the Apple leg never produced
        /// audio and the inactivity watchdog settled the completion.
        case gaveUp
    }

    let timestamp: Date
    let surface: Surface
    let stage: Stage
    let outcome: Outcome
    /// `AppError.errorCode` when a typed error drove the decision; nil
    /// otherwise. Raw HTTP statuses never cross `TTSClient`'s typed-error
    /// boundary, so the bucketed code is the finest privacy-safe grain available.
    let errorCode: Int?
    /// `APIKeyState.rawValue` at decision time.
    let keyState: String
    /// Opaque config signature — same/different across events is the signal
    /// (distinguishes "late voice/model hydration" from "provider transient");
    /// the value itself reveals nothing.
    let configSignature: String
}

/// The ring itself. `@MainActor` — every recorder (ReplyVoice, the Settings
/// VM, DiagnosticsRunner) already lives there. Injectable suite/clock/capacity
/// for tests; production uses the App Group suite so Diagnostics and the app
/// share one ring.
@MainActor
final class TTSOutcomeLog {

    static let shared = TTSOutcomeLog()

    /// Device-local storage key. `diag.` namespace — OUTSIDE every
    /// KVS-mirrored prefix (`tts.*` mirrors travel through explicit dual-write
    /// setters; this key is never handed to `NSUbiquitousKeyValueStore`).
    static let defaultsKey = "diag.tts.outcomes.v1"

    private let defaults: UserDefaults
    private let capacity: Int
    private let now: () -> Date

    /// - Parameters:
    ///   - defaults: storage suite (default: the App Group; tests inject a
    ///     throwaway suite).
    ///   - capacity: ring size (default 16 — enough to span a multi-day
    ///     incident without becoming a usage journal).
    ///   - now: injectable clock for deterministic tests.
    init(
        defaults: UserDefaults? = nil,
        capacity: Int = 16,
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults ?? UserDefaults(suiteName: Constants.appGroupID) ?? .standard
        self.capacity = capacity
        self.now = now
    }

    /// Append one event, pruning to `capacity` (oldest dropped).
    func record(
        surface: TTSOutcomeEvent.Surface,
        stage: TTSOutcomeEvent.Stage,
        outcome: TTSOutcomeEvent.Outcome,
        errorCode: Int? = nil,
        keyState: APIKeyState,
        configSignature: String
    ) {
        var all = events()
        all.append(TTSOutcomeEvent(
            timestamp: now(),
            surface: surface,
            stage: stage,
            outcome: outcome,
            errorCode: errorCode,
            keyState: keyState.rawValue,
            configSignature: configSignature
        ))
        if all.count > capacity {
            all.removeFirst(all.count - capacity)
        }
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// All stored events, oldest → newest. Empty on decode failure (a corrupt
    /// blob is silently superseded by the next `record`).
    func events() -> [TTSOutcomeEvent] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([TTSOutcomeEvent].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Drop the ring (tests / a future explicit user reset).
    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    // MARK: - Config signature

    /// Opaque signature over the NON-SECRET config fields that determine a
    /// synthesis request: provider id, voice override, per-provider model
    /// override, custom-endpoint model, and — for the BYO endpoint — only its
    /// PRESENCE and auth scheme (the URL itself never feeds the hash; a
    /// truncated unsalted digest over a low-entropy URL would be
    /// dictionary-testable, conflicting with the never-log-URLs rule).
    /// 8 hex chars: enough to answer "same config or different?" across ring
    /// events, which is the only question it exists for.
    static func configSignature(
        providerID: String,
        voice: String?,
        customModel: String?,
        customConfig: CustomTTSConfig?
    ) -> String {
        let parts = [
            providerID,
            voice ?? "",
            customModel ?? "",
            customConfig?.model ?? "",
            // Presence + auth scheme only — never the endpoint URL (see doc).
            customConfig.map { "custom:\(String(describing: $0.auth))" } ?? ""
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Snapshot convenience — signature from an atomic `TTSSnapshot`.
    static func configSignature(for snapshot: TTSSnapshot) -> String {
        configSignature(
            providerID: snapshot.providerID,
            voice: snapshot.voice,
            customModel: snapshot.customModel,
            customConfig: snapshot.customConfig
        )
    }
}
