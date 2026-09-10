// SPDX-License-Identifier: Apache-2.0

// The main app counts local active days and offers Apple's native review UI
// once, from day three onward. A quiet foreground interval is required; normal
// loading/interaction restarts the delay. Busy readings come from the existing
// visible views through one Boolean preference, never from a second audio
// state machine. Watch, CarPlay and the menu-bar popover never mount this host.

import SwiftUI
import StoreKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct AppReviewBusyPreference: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Combine with descendants instead of replacing their busy reading.
    func appReviewBusy(_ busy: Bool) -> some View {
        transformPreference(AppReviewBusyPreference.self) { $0 = $0 || busy }
    }

    func requestAppReviewAfterActiveDays(anchor: SharePresentationAnchor) -> some View {
        modifier(AppReviewRequestModifier(anchor: anchor))
    }
}

@MainActor
private struct AppReviewRequestModifier: ViewModifier {
    let anchor: SharePresentationAnchor
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appearsActive) private var appearsActive
    @State private var busy = false
    @State private var pending: Task<Void, Never>?
    @State private var attemptedThisVisit = false
    @State private var requestID = UUID()
    #if os(macOS)
    @State private var scrollMonitor: Any?
    #endif

    private var foreground: Bool { scenePhase == .active && appearsActive }

    private var enabled: Bool {
        #if DEBUG || CONDUCK_TESTING
        false
        #else
        Constants.appStoreID != nil
        #endif
    }

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(AppReviewBusyPreference.self) { value in
                busy = value
                cancelDelay()
                scheduleIfQuiet()
            }
            .onAppear {
                beginForegroundVisit()
                installScrollMonitor()
            }
            .onChange(of: foreground) { _, active in
                if active {
                    beginForegroundVisit()
                    installScrollMonitor()
                } else {
                    cancelDelay()
                    removeScrollMonitor()
                }
            }
            .onDisappear {
                cancelDelay()
                removeScrollMonitor()
            }
            // A person reading/scrolling or operating a control gets a fresh
            // quiet interval after that interaction ends.
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in cancelDelay() }
                .onEnded { _ in scheduleIfQuiet() })
            .onKeyPress { _ in
                cancelDelay()
                scheduleIfQuiet()
                return .ignored
            }
    }

    private func beginForegroundVisit() {
        cancelDelay()
        guard enabled, foreground else { return }
        attemptedThisVisit = false
        AppReviewUsage.shared.recordActiveDay()
        scheduleIfQuiet()
    }

    private func scheduleIfQuiet() {
        guard enabled, foreground, !busy, !attemptedThisVisit,
              pending == nil, AppReviewUsage.shared.isEligible else { return }
        let id = UUID()
        requestID = id
        pending = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard !Task.isCancelled, requestID == id else { return }
            guard canPresent else {
                pending = nil
                return
            }
            // TestFlight/local installs do not spend the local once-only flag.
            // Read the store only after local eligibility and a quiet interval.
            let production = await AppReviewDistribution.isProduction()
            guard !Task.isCancelled, requestID == id else { return }
            guard production else {
                attemptedThisVisit = true
                pending = nil
                return
            }
            guard canPresent else {
                pending = nil
                return
            }
            attemptedThisVisit = true
            pending = nil
            guard AppReviewUsage.shared.claimRequest() else { return }
            requestReview()
        }
    }

    @Environment(\.requestReview) private var requestReview

    private var canPresent: Bool {
        foreground && !busy && AppReviewPresentation.isClear(anchor: anchor)
            && InFlightTurnRegistry.shared.liveCount == 0
            && !SpeechExclusivity.shared.isRecordingActive
    }

    private func cancelDelay() {
        guard pending != nil else { return }
        requestID = UUID()
        pending?.cancel()
        pending = nil
    }

    private func installScrollMonitor() {
        #if os(macOS)
        guard enabled, foreground, scrollMonitor == nil else { return }
        // Mouse wheels and trackpad momentum are NSEvent scrollWheel events,
        // not SwiftUI drags. Observe only this host's existing anchored window,
        // pass every event through unchanged, and remove the monitor on exit.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = anchor.presentationView?.window,
                  event.window === window else { return event }
            cancelDelay()
            scheduleIfQuiet()
            return event
        }
        #endif
    }

    private func removeScrollMonitor() {
        #if os(macOS)
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        #endif
    }
}

@MainActor
private enum AppReviewDistribution {
    private static var production: Bool?

    static func isProduction() async -> Bool {
        if let production { return production }
        do {
            // Never refresh(): prompting for App Store authentication would
            // turn an optional rating request into a second interruption.
            let result = try await AppTransaction.shared
            guard !Task.isCancelled else { return false }
            if case .verified(let transaction) = result {
                production = transaction.environment == .production
            } else {
                production = false
            }
        } catch {
            // Cancellation belongs to this timer, not this installation. An
            // old cancelled read must not poison the cache for the next visit.
            guard !Task.isCancelled, !(error is CancellationError) else { return false }
            production = false
        }
        return production == true
    }
}

@MainActor
private enum AppReviewPresentation {
    static func isClear(anchor: SharePresentationAnchor) -> Bool {
        #if os(iOS)
        guard !CarPlayRecordingService.anySessionActive,
              UIApplication.shared.applicationState == .active,
              let hostWindow = anchor.presentationView?.window,
              hostWindow.isKeyWindow,
              hostWindow.windowScene?.activationState == .foregroundActive else { return false }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .filter { $0.windowLevel == .normal && !$0.isHidden }
        guard !windows.isEmpty else { return false }
        return windows.allSatisfy { window in
            guard let root = window.rootViewController else { return false }
            return !presentsAnything(root) && !hasTextInputResponder(window)
        }
        #elseif os(macOS)
        guard NSApplication.shared.isActive,
              let window = anchor.presentationView?.window,
              window === NSApplication.shared.keyWindow,
              window.isKeyWindow else { return false }
        return window.isVisible && window.attachedSheet == nil && window.sheetParent == nil
        #endif
    }

    #if os(iOS)
    private static func presentsAnything(_ controller: UIViewController) -> Bool {
        if controller.presentedViewController != nil { return true }
        return controller.children.contains { presentsAnything($0) }
    }

    private static func hasTextInputResponder(_ view: UIView) -> Bool {
        if view.isFirstResponder, view is any UITextInput { return true }
        return view.subviews.contains { hasTextInputResponder($0) }
    }
    #endif
}
