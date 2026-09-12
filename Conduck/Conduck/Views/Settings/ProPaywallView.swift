// SPDX-License-Identifier: Apache-2.0

// One offer with three entry contexts. Each presenting editor keeps ownership
// of its draft; this sheet carries no project contents or gateway credentials.
// StoreKit supplies the real localized price, billing period and purchase UI.
// A verified purchase closes only this sheet, never saves or sends the draft.
// A configured offer keeps one StoreKit view mounted through loading, errors
// and entitlement changes. StoreKit owns scrolling, product loading and controls;
// no product result swaps in a competing ScrollView during sheet layout.
// Mac uses a wide introduction and an overlaid close control so NavigationStack
// does not allocate a second bottom action bar beneath the purchase controls.

import SwiftUI
import StoreKit
#if os(macOS)
import AppKit
#endif

enum ProPaywallContext: Identifiable {
    case manual, projectLimit, gatewayLimit
    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .manual: LocalizedStringResource("pro.title.manual", defaultValue: "More room for your work.")
        case .projectLimit: LocalizedStringResource("pro.title.project", defaultValue: "Make room for another project.")
        case .gatewayLimit: LocalizedStringResource("pro.title.gateway", defaultValue: "Connect another gateway.")
        }
    }

    var explanation: LocalizedStringResource {
        switch self {
        case .manual: LocalizedStringResource("pro.body.manual", defaultValue: "The free plan includes three active projects and three configured gateways. Go further with Pro.")
        case .projectLimit: LocalizedStringResource("pro.body.project", defaultValue: "You have three active projects. Keep every project moving with Pro, or archive a project to free a slot.")
        case .gatewayLimit: LocalizedStringResource("pro.body.gateway", defaultValue: "Your three configured gateway slots are in use. OpenRouter is always available.")
        }
    }

    var managementTitle: LocalizedStringResource {
        switch self {
        case .gatewayLimit: LocalizedStringResource("pro.manage.gateways", defaultValue: "Manage gateways")
        case .manual, .projectLimit: LocalizedStringResource("pro.manage.projects", defaultValue: "Manage projects")
        }
    }
}

struct ProPaywallView: View {
    var context: ProPaywallContext = .manual
    var onManage: (() -> Void)? = nil
    @State private var store = ProSubscriptionStore.shared
    @State private var showingManagement = false
    @State private var didBeginPurchase = false
    @State private var hasPreparedSession = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .title) private var titleSize = 30.0
    @ScaledMetric(relativeTo: .body) private var bodySize = 16.0
    @ScaledMetric(relativeTo: .footnote) private var footnoteSize = 13.0

    var body: some View {
        presentation
        .background(AppColors.cardBackground)
        .foregroundStyle(AppColors.textPrimary)
        .tint(AppColors.brandAmber)
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(width: 620, height: min(740, (NSScreen.main?.visibleFrame.height ?? 820) - 80))
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .manageSubscriptionsSheet(isPresented: $showingManagement)
        #endif
        .task {
            store.start()
            store.message = nil
            hasPreparedSession = true
            await store.refreshAndWaitUntilApplied()
            guard !Task.isCancelled else { return }
            if store.hasProAccess && context != .manual { dismiss() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
        }
        .onChange(of: store.hasProAccess) { _, active in
            if active && (context != .manual || didBeginPurchase) { dismiss() }
        }
    }

    @ViewBuilder
    private var presentation: some View {
        #if os(macOS)
        content
            .overlay(alignment: .topTrailing) {
                closeButton
                    .pointerIconButton(size: 36, shape: .circle)
                    .background(AppColors.cardBackgroundElevated, in: Circle())
                    .padding(16)
            }
        #else
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { closeButton }
                }
        }
        #endif
    }

    private var content: some View {
        offer
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer
                    .frame(maxWidth: .infinity)
                    .background(AppColors.cardBackground)
            }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Label(LocalizedStringResource("pro.close", defaultValue: "Close Conduck Pro"), systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
        .keyboardShortcut(.cancelAction)
    }

    @ViewBuilder
    private var offer: some View {
        if let productID = store.configuration.productID {
            // Identity depends only on the build's product ID, never on a
            // transient product fetch or access result. Native controls handle
            // loading, unavailable products and existing subscriptions in place.
            SubscriptionStoreView(productIDs: [productID]) {
                marketingHeader
            }
            .subscriptionStoreControlStyle(.automatic)
            .subscriptionStoreButtonLabel(.multiline)
            .subscriptionStoreControlBackground(AppColors.cardBackgroundElevated)
            .containerBackground(AppColors.cardBackground, for: .subscriptionStoreFullHeight)
            .storeButton(.hidden, for: .cancellation, .restorePurchases)
            .subscriptionStorePolicyDestination(url: URL(string: Constants.termsOfServiceURL)!, for: .termsOfService)
            .subscriptionStorePolicyDestination(url: URL(string: Constants.privacyPolicyURL)!, for: .privacyPolicy)
            .onInAppPurchaseStart { _ in didBeginPurchase = true }
            .onInAppPurchaseCompletion { product, result in
                await store.purchaseCompleted(product: product, result: result)
                if store.hasProAccess { dismiss() }
            }
        } else {
            ScrollView {
                marketingHeader
                Text(LocalizedStringResource("pro.store.community", defaultValue: "Subscriptions are not available in this build."))
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }

    private var marketingHeader: some View {
        VStack(spacing: 28) {
            #if os(macOS)
            HStack(alignment: .center, spacing: 28) {
                introduction(alignment: .leading)
                artwork(width: 224)
            }
            #else
            VStack(spacing: 20) {
                artwork(width: 240)
                introduction(alignment: .center)
            }
            #endif

            VStack(alignment: .leading, spacing: 20) {
                benefit(LocalizedStringResource("pro.benefit.projects", defaultValue: "Unlimited active projects"), systemImage: "folder")
                benefit(LocalizedStringResource("pro.benefit.gateways", defaultValue: "Unlimited configured gateways"), systemImage: "server.rack")
                benefit(LocalizedStringResource("pro.benefit.advanced", defaultValue: "Advanced features as they arrive"), systemImage: "sparkles")
                benefit(LocalizedStringResource("pro.benefit.support", defaultValue: "Support this project"), systemImage: "heart")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
            .overlay(alignment: .top) { Divider().overlay(AppColors.border) }
            .overlay(alignment: .bottom) { Divider().overlay(AppColors.border) }
            if store.hasProAccess {
                VStack(spacing: 12) {
                    Text(LocalizedStringResource("pro.active", defaultValue: "Conduck Pro is active"))
                        .font(.headline)
                    Button(LocalizedStringResource("pro.subscription.manage", defaultValue: "Manage subscription")) {
                        #if os(macOS)
                        openURL(URL(string: "https://apps.apple.com/account/subscriptions")!)
                        #else
                        showingManagement = true
                        #endif
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        #if os(macOS)
        .padding(.horizontal, 36)
        .padding(.top, 52)
        #else
        .padding(.horizontal, 24)
        .padding(.top, 20)
        #endif
        .padding(.bottom, 24)
    }

    private func artwork(width: CGFloat) -> some View {
        Image("conduck-pro-workspace")
            .resizable()
            .scaledToFit()
            .frame(width: width, height: width * 2 / 3)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .accessibilityHidden(true)
    }

    private func introduction(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 16) {
            HStack(spacing: 10) {
                Text(verbatim: "Conduck").font(.title3.weight(.semibold))
                Text(verbatim: "PRO")
                    .font(.caption.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(AppColors.brandAmber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(AppColors.brandAmber.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            Text(store.hasProAccess
                 ? LocalizedStringResource("pro.title.active", defaultValue: "Room for all your work.")
                 : context.title)
                .font(.system(size: titleSize, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            if !store.hasProAccess {
                Text(context.explanation)
                    .font(.system(size: bodySize))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineSpacing(3)
            }
        }
        .multilineTextAlignment(alignment == .leading ? .leading : .center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
    }

    private func benefit(_ title: LocalizedStringResource, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Image(systemName: systemImage)
                .foregroundStyle(AppColors.brandAmber)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: bodySize, weight: .medium))
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if hasPreparedSession, let message = store.message {
                Text(message)
                    .font(.system(size: footnoteSize))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Text(LocalizedStringResource("pro.provider.cost", defaultValue: "AI and speech usage are billed separately by your providers."))
                .font(.system(size: footnoteSize))
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { footerActions }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 4) { footerActions }
            }
            .font(.system(size: footnoteSize))
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var footerActions: some View {
        if let onManage, context != .manual, !store.hasProAccess {
            Button(context.managementTitle) { dismiss(); onManage() }
                .frame(minHeight: 44)
                .inlineLinkButton()
        }
        if store.isConfigured {
            Button {
                Task {
                    await store.restorePurchases()
                    if store.hasProAccess { dismiss() }
                }
            } label: {
                HStack {
                    if store.isRestoring { ProgressView().controlSize(.small) }
                    Text(LocalizedStringResource("pro.restore", defaultValue: "Restore Purchases"))
                }
                .frame(minHeight: 44)
            }
            .inlineLinkButton()
            .disabled(store.isRestoring)
        }
    }
}

/// A permanent entry that opens over the current Settings screen. Opening the
/// offer never switches categories or discards a buffered settings editor.
struct ProSettingsEntry: View {
    @State private var showingPro = false
    @State private var store = ProSubscriptionStore.shared

    var body: some View {
        Button { showingPro = true } label: {
            HStack(spacing: 10) {
                Image("conduck-app-mark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                Text(verbatim: "Conduck Pro")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(AppColors.cardBackgroundElevated, in: RoundedRectangle(cornerRadius: 10))
        }
        .settingsRowButton(minHeight: 48, washCornerRadius: 10)
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .accessibilityLabel(Text(verbatim: "Conduck Pro"))
        .accessibilityValue(store.hasProAccess
            ? Text(LocalizedStringResource("pro.active", defaultValue: "Conduck Pro is active"))
            : Text(verbatim: ""))
        .sheet(isPresented: $showingPro) { ProPaywallView() }
    }
}
