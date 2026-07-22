// Conduck
// WatchSettingsView.swift
//
// iOS-hosted Apple Watch settings (the Watch keeps NO settings UI of its own —
// it's a thin headless surface, so everything it needs is configured from the
// paired iPhone). Two things live here:
//
//   - Default gateway — a selector row → a chooser that PREPENDS a "Follow
//     iPhone" option above the configured gateways. "Follow iPhone" (the
//     default) makes the wrist inherit the iPhone's device-local default;
//     picking a specific gateway pins the wrist to it regardless of the phone.
//     Mirrors `PersonalAISettingsView`'s default-selector pattern, reusing
//     `DefaultGatewaySelectorRow` + `DefaultGatewayPicker`.
//   - Spoken Replies — a single "Speak replies aloud" toggle: whether replies to
//     questions asked ON the wrist are spoken there. Moved here from the Voice
//     screen (it's a wrist-only behavior); the value stays iCloud-synced (KVS) +
//     WCSession-couriered by `setWatchReadRepliesAloud`.
//   - Set up Apple Watch — opens the existing `WatchSetupGuideView` full-screen
//     (install + Control Center / Action Button binding walkthrough).
//
// iPhone-only surface (a Watch pairs with an iPhone, not an iPad) — `SettingsView`
// gates the entry to `.phone`. Because this whole screen is iPhone-only, the
// read-aloud toggle needs no `isiPad` guard (it carried one on the Voice screen).

#if os(iOS)
import Combine
import SwiftUI

struct WatchSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    /// Drives the pushed default-gateway chooser.
    @State private var route: WatchSettingsRoute?

    /// Drives the existing Watch setup walkthrough (full-screen).
    @State private var showWatchSetupGuide = false

    /// Mirror of the Watch read-replies-aloud preference, seeded from the
    /// `SettingsManager` actor in `.task` (defaults OFF until the stored value
    /// lands).
    @State private var watchReadRepliesAloud = false

    /// True while a re-send is in flight — disables the button so a tap can't
    /// double-enqueue.
    @State private var isResending = false

    /// The most recent re-send outcome, shown transiently below the button and
    /// auto-cleared by `resultClearTask`. Nil = no line shown.
    @State private var resendResult: PhoneSessionManager.WatchResendOutcome?

    /// Stored auto-clear task for `resendResult`: cancelled + replaced on each
    /// tap, cancelled on disappear, so a stale timer can't wipe a fresh line.
    @State private var resultClearTask: Task<Void, Never>?

    /// Last completed settings-transfer stamp (`timeIntervalSinceReferenceDate`)
    /// mirrored from App-Group UserDefaults. 0 / absent = none recorded yet.
    /// Kept live via `UserDefaults.didChangeNotification` (the delivery delegate
    /// writes it in-process on a background thread).
    @State private var lastTransferStamp: Double = 0

    var body: some View {
        Form {
            defaultSelectorSection
            sessionPolicySection
            spokenRepliesSection
            setupSection
            syncSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(Text(LocalizedStringResource(
            "settings.watch.section.title",
            defaultValue: "Apple Watch"
        )))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            watchReadRepliesAloud = await SettingsManager.shared.getWatchReadRepliesAloud()
            lastTransferStamp = readLastTransferStamp()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            lastTransferStamp = readLastTransferStamp()
        }
        .onDisappear {
            resultClearTask?.cancel()
        }
        .navigationDestination(item: $route) { route in
            switch route {
            case .defaultChooser:
                DefaultGatewayPicker(
                    rows: watchChooserRows,
                    onActivate: { ref in
                        Task {
                            await viewModel.setWatchDefaultOverrideRef(ref)
                            self.route = nil
                        }
                    },
                    onSetUp: { ref in self.route = .configure(ref) },
                    onFollowPhone: {
                        Task {
                            await viewModel.setWatchDefaultOverrideRef(nil)
                            self.route = nil
                        }
                    },
                    followPhoneSelected: viewModel.watchDefaultOverrideRef == nil
                )
            case .configure(let ref):
                RemoteAgentDetailView(viewModel: viewModel, ref: ref)
            }
        }
        .fullScreenCover(isPresented: $showWatchSetupGuide) {
            WatchSetupGuideView()
        }
    }

    // MARK: - Default selector

    /// The top "Default gateway → <name>" selector. Tapping opens the chooser.
    /// The trailing name is "Follow iPhone" until the user pins a gateway.
    private var defaultSelectorSection: some View {
        Section {
            Button {
                route = .defaultChooser
            } label: {
                DefaultGatewaySelectorRow(defaultName: viewModel.watchDefaultDisplayName)
            }
            .buttonStyle(.plain)
        } header: {
            Text(LocalizedStringResource("settings.voice.summary.header", defaultValue: "Active"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.watch.default.footer",
                defaultValue: "Your Apple Watch follows the iPhone's default gateway unless you pick a specific one here."
            ))
        }
    }

    /// The gateway rows for the Watch chooser. Same set as `personalAIRows`, but
    /// `isDefault` reflects the WATCH override (not the iPhone default) so the
    /// amber check tracks the wrist's pinned gateway.
    private var watchChooserRows: [PersonalAIRow] {
        viewModel.personalAIRows.map { row in
            PersonalAIRow(
                ref: row.ref,
                displayName: row.displayName,
                configured: row.configured,
                isDefault: viewModel.watchDefaultOverrideRef == row.ref
            )
        }
    }

    // MARK: - Quick-capture continuation policy (Watch)

    /// "Add to last conversation" for wrist asks (Action Button / Control Center).
    /// An inline menu Picker that PREPENDS a "Follow iPhone" option (= a `nil`
    /// override) above the TTL values, mirroring the default-gateway "Follow
    /// iPhone" pattern. `nil` (the default) makes the wrist inherit the iPhone's
    /// per-device policy; picking a value pins the wrist regardless of the phone.
    /// `SettingsManager` couriers the Watch-effective policy in the broadcast
    /// envelope's `sessionPolicy` slot.
    private var sessionPolicySection: some View {
        Section {
            let selection = Binding<SessionContinuationPolicy?>(
                get: { viewModel.watchSessionPolicyOverride },
                set: { newValue in Task { await viewModel.setWatchSessionPolicyOverride(newValue) } }
            )
            Picker(selection: selection) {
                Text(LocalizedStringResource("settings.watch.sessionPolicy.followPhone", defaultValue: "Follow iPhone"))
                    .tag(SessionContinuationPolicy?.none)
                ForEach(SessionContinuationPolicy.allCases.reversed()) { policy in
                    Text(policy.label).tag(SessionContinuationPolicy?.some(policy))
                }
            } label: {
                Text(LocalizedStringResource("settings.watch.sessionPolicy.label", defaultValue: "Add to last conversation"))
                    .foregroundStyle(AppColors.textPrimary)
            }
            .pickerStyle(.menu)
            .tint(AppColors.brandAmber)
        } header: {
            Text(LocalizedStringResource("settings.watch.sessionPolicy.header", defaultValue: "Action Button & Control Center"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.watch.sessionPolicy.footer",
                defaultValue: "Applies to asks from the Action Button or Control Center on this Apple Watch. Follow iPhone uses your iPhone's setting."
            ))
        }
    }

    // MARK: - Spoken Replies

    /// "Speak replies aloud" — whether replies to questions asked ON the Watch are
    /// spoken there. Moved here from the Voice screen's "Spoken Replies" section
    /// (it's a wrist-only behavior, so it belongs in the Apple Watch screen). The
    /// value stays iCloud-synced (KVS) + WCSession-couriered by
    /// `setWatchReadRepliesAloud`. No `isiPad` guard — this whole screen is
    /// iPhone-only.
    private var spokenRepliesSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { watchReadRepliesAloud },
                set: { newValue in
                    watchReadRepliesAloud = newValue
                    Task { await SettingsManager.shared.setWatchReadRepliesAloud(newValue) }
                }
            )) {
                Text(LocalizedStringResource(
                    "settings.watch.readAloud.toggle",
                    defaultValue: "Speak replies aloud"
                ))
                .foregroundStyle(AppColors.textPrimary)
            }
            .tint(AppColors.brandAmber)
        } header: {
            Text(LocalizedStringResource(
                "settings.watch.readAloud.header",
                defaultValue: "Spoken Replies"
            ))
        } footer: {
            Text(LocalizedStringResource(
                "settings.watch.readAloud.footer",
                defaultValue: "Replies to anything you ask on Apple Watch — using the Action Button, Control Center, or the Ask button — are spoken aloud on your wrist."
            ))
        }
    }

    // MARK: - Setup walkthrough

    /// "Set up Apple Watch" — opens the existing full-screen walkthrough
    /// (install + Control Center / Action Button binding).
    private var setupSection: some View {
        Section {
            Button {
                showWatchSetupGuide = true
            } label: {
                HStack {
                    Image(systemName: "applewatch")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 32)
                    Text(LocalizedStringResource(
                        "settings.watch.setup.title",
                        defaultValue: "Set up Apple Watch"
                    ))
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(.tint)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(LocalizedStringResource("settings.watch.setup.header", defaultValue: "Setup"))
        }
    }

    // MARK: - Re-send settings (recovery control)

    /// "Send Settings to Apple Watch" — an explicit, honest re-send of the
    /// current provider/key/gateway envelope over the queued `transferUserInfo`
    /// channel. Placed LAST (after setup) because it's a recovery control, not a
    /// primary setting. The result line and last-transfer caption speak only to
    /// the DELIVERY layer — never "applied"/"updated" — because the Watch sends
    /// no ack that the settings took effect.
    private var syncSection: some View {
        Section {
            Button {
                resend()
            } label: {
                Text(LocalizedStringResource(
                    "settings.watch.sync.button",
                    defaultValue: "Send Settings to Apple Watch"
                ))
                .foregroundStyle(AppColors.textPrimary)
            }
            .buttonStyle(.plain)
            .disabled(isResending)

            if let resendResult {
                Text(syncResultCopy(resendResult))
                    .font(.callout)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Text(lastTransferCopy)
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
        } header: {
            Text(LocalizedStringResource("settings.watch.sync.header", defaultValue: "Sync"))
        } footer: {
            Text(LocalizedStringResource(
                "settings.watch.sync.footer",
                defaultValue: "Queues your current provider, key, and gateway settings for delivery. Delivery happens in the background, even when the Watch is out of reach — it completes the next time your Apple Watch is available."
            ))
        }
    }

    /// Transient result copy for each re-send outcome. Delivery-layer language
    /// only — no case claims the Watch applied anything.
    private func syncResultCopy(_ outcome: PhoneSessionManager.WatchResendOutcome) -> LocalizedStringResource {
        switch outcome {
        case .queued:
            LocalizedStringResource(
                "settings.watch.sync.result.queued",
                defaultValue: "Settings queued for delivery to your Apple Watch."
            )
        case .activationPending:
            LocalizedStringResource(
                "settings.watch.sync.result.activationPending",
                defaultValue: "The Apple Watch connection is still starting up — try again in a moment."
            )
        case .notPaired:
            LocalizedStringResource(
                "settings.watch.sync.result.notPaired",
                defaultValue: "No Apple Watch is paired with this iPhone."
            )
        case .watchAppNotInstalled:
            LocalizedStringResource(
                "settings.watch.sync.result.notInstalled",
                defaultValue: "Conduck isn't installed on your Apple Watch."
            )
        }
    }

    /// Quiet caption reporting the last COMPLETED settings transfer as a
    /// delivery-layer fact. A future-dated stamp renders relative without any
    /// assertion. Absent/`<= 0` → the "none yet" line.
    private var lastTransferCopy: LocalizedStringResource {
        guard lastTransferStamp > 0 else {
            return LocalizedStringResource(
                "settings.watch.sync.lastTransfer.none",
                defaultValue: "No completed settings transfer recorded yet."
            )
        }
        let when = Date(timeIntervalSinceReferenceDate: lastTransferStamp)
            .formatted(.relative(presentation: .named))
        return LocalizedStringResource(
            "settings.watch.sync.lastTransfer",
            defaultValue: "Last settings transfer completed \(when)."
        )
    }

    /// Read the last-success stamp from the App-Group suite. 0 when absent.
    private func readLastTransferStamp() -> Double {
        UserDefaults(suiteName: Constants.appGroupID)?
            .double(forKey: Constants.watchBroadcastLastSuccessAtKey) ?? 0
    }

    /// Kick off a re-send: disable the button, run the async request, then show
    /// the outcome, re-read the transfer stamp, and (re)arm the auto-clear.
    private func resend() {
        resultClearTask?.cancel()
        isResending = true
        Task {
            let outcome = await PhoneSessionManager.shared.resendSettingsToWatch()
            await MainActor.run {
                isResending = false
                resendResult = outcome
                lastTransferStamp = readLastTransferStamp()
                scheduleResultClear()
            }
        }
    }

    /// Cancel + replace the stored auto-clear task so the result line fades
    /// ~6s after the latest tap.
    private func scheduleResultClear() {
        resultClearTask?.cancel()
        resultClearTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { resendResult = nil }
        }
    }
}

/// Typed navigation route for the Apple Watch settings screen: the default-
/// gateway chooser, or a per-gateway config detail (reached via "Set up…" on an
/// unconfigured gateway in the chooser — mirrors `PersonalAIRoute`).
private enum WatchSettingsRoute: Hashable {
    case defaultChooser
    case configure(RemoteAgentRef)
}
#endif
