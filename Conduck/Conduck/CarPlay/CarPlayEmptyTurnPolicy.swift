// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlayEmptyTurnPolicy.swift
//
// What a CarPlay voice session does when a turn comes back with nothing in it —
// an empty transcript from the speech provider, or the provider's own
// "no speech detected" verdict. Both mean the same thing to the driver: they
// spoke, and the car heard nothing usable.
//
// Ending the session there is the wrong answer once. Somebody clearing their
// throat, a truck passing, a provider that trimmed a short answer to nothing —
// each of those killed the conversation outright and dropped the driver back to
// the picker. The right answer is to say so and listen again, and to stop after
// the second one in a row, because a cabin producing nothing but noise would
// otherwise loop for as long as the drive lasts.
//
// Pure and platform-free so the rule can be tested without an audio session:
// a count in, a decision out.

import Foundation

/// Retry-once-then-end policy for consecutive empty voice turns.
enum CarPlayEmptyTurnPolicy {

    /// What to do about the empty turn that just landed.
    enum Outcome: Equatable {
        /// Speak the "didn't catch that" prompt and re-arm the microphone.
        case retryListening
        /// Speak the same prompt and end the session.
        case endSession
    }

    /// How many empty turns IN A ROW end the session. Two: the first is a
    /// retry, the second is the sign-off. Raising this lets a noisy cabin hold
    /// the audio route — and the car's radio — for another full listening
    /// window per extra attempt.
    static let maxConsecutiveEmptyTurns = 2

    /// Decide, given how many empty turns preceded this one in the same
    /// session. Pass the count BEFORE this turn is folded in; use
    /// `nextCount(after:)` for the value to store.
    static func outcome(after priorConsecutiveEmptyTurns: Int) -> Outcome {
        nextCount(after: priorConsecutiveEmptyTurns) >= maxConsecutiveEmptyTurns
            ? .endSession
            : .retryListening
    }

    /// The running count to store once this empty turn is folded in. Clamped at
    /// zero so a caller that reset mid-flight cannot drive it negative.
    static func nextCount(after priorConsecutiveEmptyTurns: Int) -> Int {
        max(0, priorConsecutiveEmptyTurns) + 1
    }
}
