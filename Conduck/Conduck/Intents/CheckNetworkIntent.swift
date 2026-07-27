// SPDX-License-Identifier: Apache-2.0

// Conduck
// CheckNetworkIntent.swift
//
// NWPathMonitor one-shot probe. FIRST action in the bundled shortcut,
// short-circuits on no-connectivity so users don't waste a recording when the
// upload would fail anyway.

import AppIntents
import Foundation
import Network

/// Pre-recording network connectivity check. Throws when offline so the
/// bundled Shortcut bails before `Record Audio` opens the mic UI.
struct CheckNetworkIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Network"      // xcstrings

    static var description: IntentDescription = IntentDescription(
        LocalizedStringResource("Verifies internet connection before recording so the upload doesn't fail later.")  // xcstrings
    )

    // MARK: - Perform

    func perform() async throws -> some IntentResult {
        let isConnected = await checkNetworkConnectivity()

        if isConnected {
            // Network available — shortcut continues to next action.
            return .result()
        } else {
            // No network — throw to stop the shortcut before recording.
            throw AppError.noInternetConnection
        }
    }

    // MARK: - Private Methods

    /// Check current network connectivity using NWPathMonitor.
    /// Returns immediately with current status (doesn't wait for changes).
    private func checkNetworkConnectivity() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: Constants.identityNamespace + ".networkcheck")
            // Single-fire latch, claimed BEFORE `cancel()` — `cancel()` stops
            // FUTURE deliveries but cannot un-enqueue a handler block already
            // dispatched onto the monitor's queue, and a second
            // `continuation.resume` is a hard `fatalError` in every build
            // configuration. Same primitive and same shape as
            // `DiagnosticsRunner.probeNetworkPath()`, the codebase's other
            // `NWPathMonitor` probe.
            let resumeOnce = LockedOnce()
            monitor.pathUpdateHandler = { [monitor] path in
                guard resumeOnce.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }

            monitor.start(queue: queue)
        }
    }
}
