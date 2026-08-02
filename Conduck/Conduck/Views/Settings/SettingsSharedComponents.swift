// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsSharedComponents.swift
//
// Cross-platform Settings building blocks lifted out of `SettingsView.swift`
// so both the iOS Settings sheet AND the macOS `MacSettingsView` modal (+ the
// `MainWindowView` identity footer) can reuse them without duplication:
//   - Feedback helpers (`feedbackEmailBody`, `feedbackMailtoURL`,
//     `openFeedbackEmail`) — mailto composition + open. macOS has no
//     `MessageUI`, so it always uses the `mailto:` open path.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - DisclosureGroup label tap target (macOS fix)

extension View {
    /// Make a `DisclosureGroup` label toggle the disclosure when the user taps
    /// anywhere on the label row — not only on the small chevron.
    ///
    /// On macOS a `DisclosureGroup`'s built-in label-tap is dead: only the
    /// disclosure triangle is a hit target, so clicking the "Advanced" text does
    /// nothing (the chevron is a tiny, easy-to-miss aim). We widen the label to
    /// the full row and drive `isExpanded` ourselves via an explicit tap. No-op
    /// on iOS, where the whole row already toggles (and adding a second gesture
    /// would risk a double-toggle). Apply to the `label:` content of a
    /// `DisclosureGroup(isExpanded:)`.
    func tappableDisclosureLabel(_ isExpanded: Binding<Bool>) -> some View {
        #if os(macOS)
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            // The row is live edge to edge but looks inert under the pointer, so
            // the wash is the only thing announcing it. Painted BEFORE the tap
            // scaffolding below, which stays exactly as it was.
            .pointerHoverWash()
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { isExpanded.wrappedValue.toggle() } }
        #else
        self
        #endif
    }
}

// MARK: - Feedback Helpers (shared, platform-neutral)

/// The trailing diagnostic block appended to a feedback email body (app
/// version + OS + device). Platform-branched on macOS vs UIKit hosts.
func feedbackEmailBody() -> String {
    #if os(macOS)
    let platform = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    let device = "Mac"
    #else
    let platform = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    let device = DeviceCapabilities.modelName
    #endif

    return """


---
App: Conduck \(Constants.fullVersion)
OS: \(platform)
Device: \(device)
"""
}

/// The `mailto:` URL for a feedback email (recipient + subject + diagnostic
/// body). Nil only if URL composition fails.
func feedbackMailtoURL() -> URL? {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = Constants.feedbackEmail
    components.queryItems = [
        URLQueryItem(name: "subject", value: String(localized: "Conduck Feedback")), // xcstrings
        URLQueryItem(name: "body", value: feedbackEmailBody()),
    ]
    return components.url
}

#if os(macOS)
/// macOS feedback open — no `MessageUI`, so open the `mailto:` URL in the
/// user's default mail client. Returns false if there is nothing to open
/// (the caller then surfaces the copy-address fallback).
@discardableResult
func openFeedbackEmailMac() -> Bool {
    guard let url = feedbackMailtoURL() else { return false }
    return NSWorkspace.shared.open(url)
}
#endif

#if os(macOS)
/// `NSApp.applicationIconImage` defaults to a low-res rep; SwiftUI's
/// `Image(nsImage:)` then picks that rep, producing visibly pixelated icons
/// at small frames on Retina. Copying the image and setting `.size` forces
/// AppKit to choose the rep matching that backing size (≥ 256 picks the
/// 512/1024 rep). Pair with `.interpolation(.high)` for any remaining
/// downscale.
func highResAppIcon(size: CGFloat) -> NSImage {
    let source = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    guard let copy = source.copy() as? NSImage else { return source }
    let pixelSize = max(size * 2, 256)
    copy.size = NSSize(width: pixelSize, height: pixelSize)
    return copy
}
#endif

#if canImport(UIKit)
/// The app icon as a `UIImage` on iOS/iPadOS. `UIImage(named: "AppIcon")`
/// returns nil for the *app* icon (asset-catalog app icons aren't addressable
/// by name), so resolve the highest-res primary-icon filename out of the
/// bundle's `CFBundleIcons` and load THAT. The 1024 asset is a full-bleed
/// square; the identity header rounds it at display (iOS draws app icons as a
/// superellipse, which the raw PNG isn't).
func appIconUIImage() -> UIImage? {
    guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
          let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
          let files = primary["CFBundleIconFiles"] as? [String],
          let lastName = files.last else { return nil }
    return UIImage(named: lastName)
}
#endif

// MARK: - App Identity Header (shared icon + name + version)

/// Shared "Conduck + version" identity block, the single source of truth for
/// the About / Support surfaces so macOS (About section), iPad (About pane) and
/// iPhone (Support footer) never drift again. The only platform-split is icon
/// loading — macOS via `highResAppIcon`, UIKit via `appIconUIImage` (+ display
/// rounding, since the iOS asset is an un-rounded square). The version string
/// is `Constants.fullVersion`, read live from the bundle's Info.plist
/// (`CFBundleShortVersionString` + `CFBundleVersion`) — it tracks the shipped
/// build automatically.
struct AppIdentityHeader: View {
    /// `.row` — icon left, name+version stacked right (Mac/iPad sections).
    /// `.centered` — icon over name over version, centered (iPhone footer).
    enum Layout { case row, centered }

    var layout: Layout = .row
    var iconSize: CGFloat = 56

    var body: some View {
        switch layout {
        case .row:
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    name
                    version
                }
                Spacer()
            }
        case .centered:
            VStack(spacing: 6) {
                icon
                name
                version
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var icon: some View {
        iconImage
            .frame(width: iconSize, height: iconSize)
    }

    private var iconImage: some View {
        #if os(macOS)
        // macOS icon image already carries its squircle + margins — no clip.
        Image(nsImage: highResAppIcon(size: iconSize))
            .resizable()
            .interpolation(.high)
        #else
        Group {
            if let ui = appIconUIImage() {
                Image(uiImage: ui).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.2237, style: .continuous))
        #endif
    }

    private var name: some View {
        Text(verbatim: "Conduck")
            .font(.headline)
            .foregroundStyle(AppColors.textPrimary)
    }

    private var version: some View {
        // Marketing version only ("Version 1.0") — the build number
        // (`CFBundleVersion`) is a support/debug identifier with no meaning to
        // an end user. It still rides along in the feedback-email diagnostics
        // (`feedbackEmailBody` uses `Constants.fullVersion`), so support keeps
        // full build fidelity without surfacing a cryptic "(1)" in the UI.
        Text("Version \(Constants.appVersion)") // xcstrings
            .font(.caption)
            .foregroundStyle(AppColors.textTertiary)
    }
}

/// Decorative mascot "thank you" sign-off shown as the final element at the
/// bottom of the About surface on every platform. This is just the centered
/// art (single source of truth for the asset, size, centering, a11y) — each
/// surface supplies its own container: iOS/iPadOS wrap it in a full-bleed
/// `Section` row (`.listRowInsets(EdgeInsets())` + `.listRowBackground(.clear)`),
/// while macOS places it OUTSIDE the grouped `Form` (which can't drop its row
/// card) so it floats free on the window background instead of in a grey box.
/// The sticker already carries baked-in "Thank You" art, so the a11y label is
/// `Text(verbatim:)` — non-localized, and deliberately adds no `.xcstrings` key.
struct AboutThankYouFooter: View {
    var body: some View {
        Image("conduck-bathtub-thank-you")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 240)
            .frame(maxWidth: .infinity)        // center horizontally
            .accessibilityLabel(Text(verbatim: "Thank you"))
    }
}
