// SPDX-License-Identifier: Apache-2.0

// Counts distinct UTC days on which the main app becomes active. Three days
// earn one native review request; a claim or manual review handoff suppresses
// future requests permanently. This local state is separate from Usage history.

import Foundation

@MainActor
final class AppReviewUsage {
    static let shared = AppReviewUsage()
    private static let storageKey = "appReview.usage.v1"
    private static let requiredDays = 3
    private let defaults: any DefaultsStore

    private nonisolated struct State: Codable {
        var lastActiveDay: Int?
        var activeDayCount = 0
        var hasRequested = false
    }

    init(dependencies: SettingsDependencies = .processDefault) {
        defaults = dependencies.defaults
    }

    var isEligible: Bool {
        let state = readState()
        return !state.hasRequested && state.activeDayCount == Self.requiredDays
    }

    func recordActiveDay(now: Date = Date()) {
        let rawDay = floor(now.timeIntervalSince1970 / 86_400)
        guard rawDay.isFinite, rawDay >= 0, rawDay < Double(Int.max) else { return }
        let day = Int(rawDay)
        var state = readState()
        // An earlier clock/date must not manufacture another active day.
        guard !state.hasRequested, state.lastActiveDay.map({ day > $0 }) ?? true else { return }
        state.lastActiveDay = day
        state.activeDayCount = min(state.activeDayCount + 1, Self.requiredDays)
        persist(state)
    }

    /// Call immediately before StoreKit. A native request has no observable
    /// result, so the single attempt is consumed even when Apple shows nothing.
    func claimRequest() -> Bool {
        var state = readState()
        guard !state.hasRequested, state.activeDayCount == Self.requiredDays else { return false }
        state.hasRequested = true
        return persist(state)
    }

    func suppressRequests() {
        var state = readState()
        guard !state.hasRequested else { return }
        state.hasRequested = true
        persist(state)
    }

    private func readState() -> State {
        guard let raw = defaults.object(forKey: Self.storageKey) else { return State() }
        guard let data = raw as? Data,
              let state = try? JSONDecoder().decode(State.self, from: data),
              (0...Self.requiredDays).contains(state.activeDayCount),
              state.lastActiveDay.map({ $0 >= 0 && $0 < Int.max }) ?? true,
              (state.lastActiveDay == nil) == (state.activeDayCount == 0) else {
            // Unknown history must not reset the once-ever request budget.
            return State(hasRequested: true)
        }
        return state
    }

    @discardableResult
    private func persist(_ state: State) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        return defaults.synchronize()
    }
}
