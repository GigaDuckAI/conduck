// Conduck
// SessionContinuationPolicyTests.swift
//
// Coverage for the session-continuation policy: the pure-enum `ttlSeconds`
// mapping + default + forward-compat fallback, and the policy-aware,
// clock-skew-safe `SettingsManager.resolveActiveConversationID(now:)` resolver.
//
// Test isolation: the resolver tests drive the live `SettingsManager.shared`
// actor (a `static let` singleton — can't construct a fresh instance per test),
// so every test wipes the pointer + policy slots in the same App Groups
// UserDefaults the actor uses, in setUp + tearDown. The resolver injects `now`
// for deterministic boundaries — no real clock dependency.
//
// These are pure-logic + UserDefaults round-trip assertions; none require a
// signed build (no Keychain writes), so no skip-guards are needed here.

import XCTest
@testable import Conduck

final class SessionContinuationPolicyTests: XCTestCase {

    /// App Groups UserDefaults — same suite the actor uses internally.
    private let defaults: UserDefaults = {
        UserDefaults(suiteName: Constants.appGroupID) ?? UserDefaults.standard
    }()

    override func setUp() async throws {
        try await super.setUp()
        wipePolicyAndPointer()
    }

    override func tearDown() async throws {
        wipePolicyAndPointer()
        try await super.tearDown()
    }

    private func wipePolicyAndPointer() {
        defaults.removeObject(forKey: Constants.sessionContinuationPolicyKey)
        defaults.removeObject(forKey: Constants.remoteAgentActiveConversationIDKey)
        defaults.removeObject(forKey: Constants.remoteAgentActiveConversationActivityKey)
    }

    // MARK: - Enum: ttlSeconds mapping

    func testTTLSecondsIsNilForExtremes() {
        XCTAssertNil(SessionContinuationPolicy.alwaysNew.ttlSeconds,
                     "alwaysNew is branch-handled, not arithmetic — ttlSeconds must be nil.")
        XCTAssertNil(SessionContinuationPolicy.alwaysContinue.ttlSeconds,
                     "alwaysContinue is branch-handled, not arithmetic — ttlSeconds must be nil.")
    }

    func testTTLSecondsForTimedCases() {
        XCTAssertEqual(SessionContinuationPolicy.minutes15.ttlSeconds, 900)
        XCTAssertEqual(SessionContinuationPolicy.minutes30.ttlSeconds, 1800)
        XCTAssertEqual(SessionContinuationPolicy.minutes60.ttlSeconds, 3600)
    }

    // MARK: - Enum: default + forward-compat fallback

    func testDefaultIsThirtyMinutes() {
        XCTAssertEqual(SessionContinuationPolicy.default, .minutes30)
    }

    func testCaseIterableCoversAllFive() {
        XCTAssertEqual(SessionContinuationPolicy.allCases,
                       [.alwaysNew, .minutes15, .minutes30, .minutes60, .alwaysContinue])
    }

    /// The getter's forward-compat path relies on `init?(rawValue:)` returning
    /// nil for an unknown value (it then falls back to `.default`, mirroring
    /// `getOnLaunchMode`). Assert that raw-init contract here; the live
    /// getter fallback is exercised in `testGetterReturnsDefaultForPoisonedRawValue`.
    func testUnknownRawValueDoesNotDecode() {
        XCTAssertNil(SessionContinuationPolicy(rawValue: "minutes90"),
                     "Unknown raw value must not decode — the getter then returns `.default`.")
    }

    func testGetterReturnsDefaultForPoisonedRawValue() async {
        defaults.set("not-a-real-policy", forKey: Constants.sessionContinuationPolicyKey)
        let resolved = await SettingsManager.shared.getSessionContinuationPolicy()
        XCTAssertEqual(resolved, .default,
                       "An unknown stored raw value must fall back to `.default` (forward-compat).")
    }

    // MARK: - Shared pure resolver (covers BOTH iOS + Watch surfaces)

    /// `resolvedConversationID(id:lastActivity:now:)` is the single source of
    /// truth both `SettingsManager` (iOS/macOS) and `WatchSettingsReader`
    /// (watchOS) delegate to — testing it directly proves the Watch resolver's
    /// continue-vs-fresh logic without standing up a watchOS test target (the
    /// Watch file lives in a separate, untestable target). No storage, no actor.

    func testPureResolver_alwaysNewIsAlwaysFresh() {
        let id = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertNil(SessionContinuationPolicy.alwaysNew
            .resolvedConversationID(id: id, lastActivity: 1_000_000, now: now),
            ".alwaysNew mints fresh even at 0 s elapsed.")
    }

    func testPureResolver_alwaysContinueNeverExpires() {
        let id = UUID()
        // 10 days idle — far past any finite window.
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000 + 864_000)
        XCTAssertEqual(SessionContinuationPolicy.alwaysContinue
            .resolvedConversationID(id: id, lastActivity: 1_000_000, now: now), id,
            ".alwaysContinue continues regardless of idle.")
    }

    func testPureResolver_finiteWindowBoundaries() {
        let id = UUID()
        let activity: TimeInterval = 1_000_000
        let inside = Date(timeIntervalSinceReferenceDate: activity + 29 * 60)
        let outside = Date(timeIntervalSinceReferenceDate: activity + 31 * 60)
        XCTAssertEqual(SessionContinuationPolicy.minutes30
            .resolvedConversationID(id: id, lastActivity: activity, now: inside), id,
            "29 min < 30 min window → continue.")
        XCTAssertNil(SessionContinuationPolicy.minutes30
            .resolvedConversationID(id: id, lastActivity: activity, now: outside),
            "31 min > 30 min window → fresh.")
    }

    func testPureResolver_clockSkewClampsToZero() {
        let id = UUID()
        let activity: TimeInterval = 5_000_000  // stamped "in the future"
        let now = Date(timeIntervalSinceReferenceDate: activity - 10 * 60)  // negative elapsed
        XCTAssertNil(SessionContinuationPolicy.alwaysNew
            .resolvedConversationID(id: id, lastActivity: activity, now: now),
            ".alwaysNew is branch-handled — negative elapsed must NOT flip it to continue.")
        XCTAssertEqual(SessionContinuationPolicy.minutes30
            .resolvedConversationID(id: id, lastActivity: activity, now: now), id,
            "Finite policy clamps negative elapsed to 0 → continue (not reset).")
    }

    // MARK: - Resolver: boundary behavior (injected `now`)

    /// Helper: stamp the pointer at `activityRef` (timeIntervalSinceReferenceDate)
    /// so `resolveActiveConversationID(now:)` has an id + timestamp to evaluate.
    private func stampPointer(id: UUID, activityRef: TimeInterval) {
        defaults.set(id.uuidString, forKey: Constants.remoteAgentActiveConversationIDKey)
        defaults.set(activityRef, forKey: Constants.remoteAgentActiveConversationActivityKey)
    }

    func testResolver_thirtyOneMinutesIdle() async {
        let id = UUID()
        let activity: TimeInterval = 1_000_000  // arbitrary reference instant
        stampPointer(id: id, activityRef: activity)
        let now = Date(timeIntervalSinceReferenceDate: activity + 31 * 60)  // 31 min later

        await SettingsManager.shared.setSessionContinuationPolicy(.minutes30)
        var resolved = await SettingsManager.shared.resolveActiveConversationID(now: now)
        XCTAssertNil(resolved, "31 min idle under .minutes30 (1800 s) → fresh (nil).")

        await SettingsManager.shared.setSessionContinuationPolicy(.minutes60)
        resolved = await SettingsManager.shared.resolveActiveConversationID(now: now)
        XCTAssertEqual(resolved, id, "31 min idle under .minutes60 (3600 s) → continue.")

        await SettingsManager.shared.setSessionContinuationPolicy(.alwaysContinue)
        resolved = await SettingsManager.shared.resolveActiveConversationID(now: now)
        XCTAssertEqual(resolved, id, ".alwaysContinue never auto-expires → continue regardless of idle.")
    }

    func testResolver_alwaysNewIsFreshEvenAtZeroElapsed() async {
        let id = UUID()
        let activity: TimeInterval = 2_000_000
        stampPointer(id: id, activityRef: activity)
        let now = Date(timeIntervalSinceReferenceDate: activity)  // 0 s elapsed

        await SettingsManager.shared.setSessionContinuationPolicy(.alwaysNew)
        let resolved = await SettingsManager.shared.resolveActiveConversationID(now: now)
        XCTAssertNil(resolved, ".alwaysNew mints fresh even at 0 s elapsed (every capture is new).")
    }

    func testResolver_continuesJustInsideWindow() async {
        let id = UUID()
        let activity: TimeInterval = 3_000_000
        stampPointer(id: id, activityRef: activity)
        // 29 min later — inside the 30-min window.
        let now = Date(timeIntervalSinceReferenceDate: activity + 29 * 60)

        await SettingsManager.shared.setSessionContinuationPolicy(.minutes30)
        let resolved = await SettingsManager.shared.resolveActiveConversationID(now: now)
        XCTAssertEqual(resolved, id, "29 min idle under .minutes30 → continue (just inside window).")
    }

    // MARK: - Resolver: clock-skew regression (the Gemini-driven case)

    /// `lastActivity` in the FUTURE (a backward clock jump → negative elapsed).
    /// `.alwaysNew` must still mint fresh (branch, not arithmetic — never sees a
    /// negative `elapsed < 0` that would flip it to "continue"); a finite policy
    /// clamps elapsed to 0 and continues.
    func testResolver_clockSkewFutureActivity() async {
        let id = UUID()
        let activity: TimeInterval = 5_000_000  // pointer stamped "in the future"
        stampPointer(id: id, activityRef: activity)
        // now is BEFORE the stamped activity → raw elapsed is negative.
        let now = Date(timeIntervalSinceReferenceDate: activity - 10 * 60)

        await SettingsManager.shared.setSessionContinuationPolicy(.alwaysNew)
        var resolved = await SettingsManager.shared.resolveActiveConversationID(now: now)
        XCTAssertNil(resolved, ".alwaysNew is skew-immune — negative elapsed must NOT flip it to continue.")

        await SettingsManager.shared.setSessionContinuationPolicy(.minutes30)
        resolved = await SettingsManager.shared.resolveActiveConversationID(now: now)
        XCTAssertEqual(resolved, id, "Finite policy clamps negative elapsed to 0 → continue (not reset).")

        await SettingsManager.shared.setSessionContinuationPolicy(.alwaysContinue)
        resolved = await SettingsManager.shared.resolveActiveConversationID(now: now)
        XCTAssertEqual(resolved, id, ".alwaysContinue continues regardless of skew.")
    }

    // MARK: - Resolver: guards above the policy branch still hold

    func testResolver_nilWhenNoStoredPointer() async {
        // No pointer stamped — wipe already ran in setUp.
        await SettingsManager.shared.setSessionContinuationPolicy(.alwaysContinue)
        let resolved = await SettingsManager.shared.resolveActiveConversationID(now: Date())
        XCTAssertNil(resolved, "No stored id → nil even under .alwaysContinue (guard above the branch).")
    }

    func testResolver_nilWhenActivityStampMissing() async {
        // Stamp an id but NO activity timestamp (double(forKey:) → 0).
        let id = UUID()
        defaults.set(id.uuidString, forKey: Constants.remoteAgentActiveConversationIDKey)
        await SettingsManager.shared.setSessionContinuationPolicy(.alwaysContinue)
        let resolved = await SettingsManager.shared.resolveActiveConversationID(now: Date())
        XCTAssertNil(resolved, "lastActivity <= 0 → nil even under .alwaysContinue (guard above the branch).")
    }

    // MARK: - currentActiveConversationID: CarPlay policy-bypass contract

    /// CarPlay's per-turn continuation reads the pointer via
    /// `currentActiveConversationID()`, which must IGNORE the policy/TTL so a live
    /// voice session keeps one thread across turns even under `.alwaysNew`
    /// (regression guard: the shared `resolveActiveConversationID` would return
    /// nil every turn under `.alwaysNew`, splitting the session into one-turn
    /// conversations).
    func testCurrentActiveConversationIgnoresPolicyAndTTL() async {
        let id = UUID()
        let activity: TimeInterval = 4_000_000
        stampPointer(id: id, activityRef: activity)

        // Even under .alwaysNew (resolveActiveConversationID → nil every call),
        // the policy-free read returns the stamped session conversation.
        await SettingsManager.shared.setSessionContinuationPolicy(.alwaysNew)
        var current = await SettingsManager.shared.currentActiveConversationID()
        XCTAssertEqual(current, id, ".alwaysNew must NOT affect CarPlay's policy-free pointer read.")

        // And even when far past any finite window (stale timestamp).
        await SettingsManager.shared.setSessionContinuationPolicy(.minutes15)
        current = await SettingsManager.shared.currentActiveConversationID()
        XCTAssertEqual(current, id, "currentActiveConversationID ignores TTL/expiry entirely.")
    }

    func testCurrentActiveConversationNilWhenNoPointer() async {
        // wipe ran in setUp → no stored id.
        let current = await SettingsManager.shared.currentActiveConversationID()
        XCTAssertNil(current, "No stored pointer → nil (CarPlay then mints a fresh conversation).")
    }

    // MARK: - SettingsManager policy round-trip (App Groups, per-device)

    func testPolicyRoundTripPersistsToAppGroups() async {
        await SettingsManager.shared.setSessionContinuationPolicy(.minutes15)
        let resolved = await SettingsManager.shared.getSessionContinuationPolicy()
        XCTAssertEqual(resolved, .minutes15, "Policy must round-trip through App Groups.")
        // App Groups is the ONLY store now (per-device); confirm the raw write landed.
        XCTAssertEqual(defaults.string(forKey: Constants.sessionContinuationPolicyKey),
                       SessionContinuationPolicy.minutes15.rawValue,
                       "Setter must write the raw value into App Groups for the synchronous getter.")
    }

    func testGetterReturnsDefaultWhenUnset() async {
        // wipe ran in setUp → no stored value.
        let resolved = await SettingsManager.shared.getSessionContinuationPolicy()
        XCTAssertEqual(resolved, .default, "Unset policy must resolve to `.default` (.minutes30).")
    }

    func testSetPolicyPostsNotification() async {
        let expectation = XCTNSNotificationExpectation(name: .settingsDidChangeRemotely)
        await SettingsManager.shared.setSessionContinuationPolicy(.minutes60)
        await fulfillment(of: [expectation], timeout: 1.0)
    }
}
