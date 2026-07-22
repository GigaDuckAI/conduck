// Conduck
// TTSTestSupport.swift
//
// Shared helpers for the TTS/ReplyVoice test suites. The one thing every
// `ReplyVoice` construction in tests needs: an outcome ring that writes into a
// THROWAWAY UserDefaults suite, never the real App Group `diag.tts.outcomes.v1`
// key. Each call gets a unique suite so ring assertions never see cross-test
// state. iOS/macOS only (ReplyVoice + TTSOutcomeLog are not in the Watch target).

#if !os(watchOS)
import Foundation
@testable import Conduck

/// A `TTSOutcomeLog` backed by a fresh, uniquely-named UserDefaults suite so the
/// real device-local ring is never touched and each test owns an isolated ring.
/// Capacity defaults to the production 16 (override for pruning tests).
@MainActor
func makeThrowawayOutcomeLog(
    _ id: String = UUID().uuidString,
    capacity: Int = 16,
    now: @escaping () -> Date = { Date() }
) -> TTSOutcomeLog {
    let suite = UserDefaults(suiteName: "test.ring.\(id)")!
    suite.removePersistentDomain(forName: "test.ring.\(id)")
    return TTSOutcomeLog(defaults: suite, capacity: capacity, now: now)
}
#endif
