// SPDX-License-Identifier: Apache-2.0

// One offer with three entry contexts. Each presenting editor keeps ownership
// of its draft; this sheet carries no project contents or gateway credentials.
// StoreKit supplies the real localized price, billing period and purchase UI.
// A verified purchase closes only this sheet, never saves or sends the draft.

import SwiftUI
import StoreKit

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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .pointerIconButton(size: 44, shape: .circle)
                .accessibilityLabel(Text(LocalizedStringResource("pro.close", defaultValue: "Close Conduck Pro")))
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            if store.hasProAccess {
                ScrollView {
                    marketingHeader
                    Text(LocalizedStringResource("pro.active", defaultValue: "Conduck Pro is active"))
                        .font(.headline)
                        .padding(.top)
                    Button(LocalizedStringResource("pro.subscription.manage", defaultValue: "Manage subscription")) {
                        #if os(macOS)
                        openURL(URL(string: "https://apps.apple.com/account/subscriptions")!)
                        #else
                        showingManagement = true
                        #endif
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            } else if let product = store.product {
                SubscriptionStoreView(subscriptions: [product]) {
                    marketingHeader
                }
                .subscriptionStoreControlStyle(.prominentPicker)
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
                    if store.isLoadingProduct {
                        ProgressView().padding()
                    } else {
                        Text(store.isConfigured
                             ? LocalizedStringResource("pro.store.unavailable", defaultValue: "Subscriptions are unavailable right now. Please try again later.")
                             : LocalizedStringResource("pro.store.community", defaultValue: "Subscriptions are not available in this build."))
                            .foregroundStyle(AppColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding()
                        if store.isConfigured {
                            Button(LocalizedStringResource("pro.store.retry", defaultValue: "Try again")) {
                                Task { store.message = nil; await store.loadProduct(); await store.refresh() }
                            }
                            .buttonStyle(.bordered)
                            .padding(.bottom)
                        }
                    }
                }
            }

            footer
        }
        .background(AppColors.cardBackground)
        .foregroundStyle(AppColors.textPrimary)
        .tint(AppColors.brandAmber)
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(width: 480, height: 760)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $showingManagement)
        #endif
        .task {
            store.start()
            store.message = nil
            await store.refresh()
            if store.hasProAccess && context != .manual { dismiss(); return }
            await store.loadProduct()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
        }
        .onChange(of: store.hasProAccess) { _, active in
            if active && (context != .manual || didBeginPurchase) { dismiss() }
        }
    }

    private var marketingHeader: some View {
        VStack(spacing: 16) {
            Image("conduck-pro-workspace")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 250, maxHeight: 140)
                .mask {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.white)
                        .padding(4)
                        .blur(radius: 5)
                }
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                Text(verbatim: "Conduck").font(.headline)
                Text(verbatim: "PRO")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(AppColors.brandAmber)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(AppColors.brandAmber.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            }
            Text(store.hasProAccess
                 ? LocalizedStringResource("pro.title.active", defaultValue: "Room for all your work.")
                 : context.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !store.hasProAccess {
                Text(context.explanation)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                Label(LocalizedStringResource("pro.benefit.projects", defaultValue: "Unlimited active projects"), systemImage: "folder")
                Label(LocalizedStringResource("pro.benefit.gateways", defaultValue: "Unlimited configured gateways"), systemImage: "server.rack")
            }
            .font(.subheadline.weight(.medium))
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
            .overlay(alignment: .top) { Divider().overlay(AppColors.border) }
            .overlay(alignment: .bottom) { Divider().overlay(AppColors.border) }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let message = store.message, !store.isLoadingProduct {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Text(LocalizedStringResource("pro.provider.cost", defaultValue: "AI and speech usage are billed separately by your providers."))
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
                .multilineTextAlignment(.center)
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
                .font(.footnote)
                .inlineLinkButton()
                .disabled(store.isRestoring)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }
}

/// A permanent entry that opens over the current Settings screen. Opening the
/// offer never switches categories or discards a buffered settings editor.
struct ProSettingsEntry: View {
    @State private var showingPro = false
    @State private var store = ProSubscriptionStore.shared

    var body: some View {
        Button { showingPro = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(AppColors.brandAmber)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Conduck Pro").font(.headline)
                    Text(store.hasProAccess
                         ? LocalizedStringResource("pro.subscription.manage", defaultValue: "Manage subscription")
                         : LocalizedStringResource("pro.settings.subtitle", defaultValue: "Unlimited projects and gateways"))
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .settingsRowButton(minHeight: 44)
        .sheet(isPresented: $showingPro) { ProPaywallView() }
    }
}
