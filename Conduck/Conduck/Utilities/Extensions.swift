import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Transcript Appending

/// Merge a fresh STT transcript into the composer draft for the voice-populates-
/// the-field flow (Part 1). The transcript is APPENDED to whatever the user has
/// already typed/dictated — it NEVER replaces an existing draft — so a user can
/// dictate, edit, dictate again, then send once with attachments still staged.
///
/// SwiftUI's `TextField` exposes no caret position, so V1 appends at the end
/// rather than inserting at the cursor (acceptable per the approved plan).
///
/// Rules:
///   - the transcript is trimmed of surrounding whitespace/newlines first;
///   - an empty existing draft → return the trimmed transcript verbatim;
///   - otherwise append with a SINGLE separating space, but only when the
///     existing draft doesn't already end in whitespace/newline (so we never
///     double a space or stack a space after a trailing newline).
func appendingTranscript(_ transcript: String, to existing: String) -> String {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !existing.isEmpty else { return trimmed }
    guard !trimmed.isEmpty else { return existing }
    if let last = existing.last, last.isWhitespace || last.isNewline {
        return existing + trimmed
    }
    return existing + " " + trimmed
}

// MARK: - View Extensions

extension View {
    /// Card background with optional colored border
    @ViewBuilder
    func glassCardBackground(borderColor: Color? = nil, borderWidth: CGFloat = 1) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppColors.cardBackgroundElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(borderColor ?? AppColors.borderSubtle, lineWidth: borderWidth)
                    }
            }
            .shadow(color: AppColors.shadow.opacity(0.15), radius: 10, y: 4)
    }

    /// Scrolls only when content exceeds available space; centers content when it fits.
    func scrollableWhenNeeded() -> some View {
        GeometryReader { geometry in
            ScrollView {
                self
                    .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

// MARK: - Numbered Step Row (Onboarding)

/// Reusable numbered step indicator used across onboarding instruction cards.
/// The badge scales with Dynamic Type (`@ScaledMetric`) so the digit can't
/// outgrow the circle at accessibility sizes, and the row aligns on the first
/// text baseline so the badge stays paired with line 1 of a tall, wrapped
/// sentence rather than floating against its vertical center.
struct NumberedStepRow: View {
    let number: Int
    let text: LocalizedStringKey

    @ScaledMetric private var badgeSize: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: badgeSize, height: badgeSize)

                Text("\(number)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.tint)
            }

            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Cross-platform image decoding

extension Image {
    /// Decode raw image bytes into a SwiftUI `Image` (iOS `UIImage` / macOS
    /// `NSImage`); `nil` if undecodable. Shared by the attachment grid, preview
    /// strip, and full-screen gallery. (The Watch target keeps its own analogue.)
    static func platformImage(from data: Data) -> Image? {
        #if os(iOS)
        if let ui = UIImage(data: data) { return Image(uiImage: ui) }
        #elseif os(macOS)
        if let ns = NSImage(data: data) { return Image(nsImage: ns) }
        #endif
        return nil
    }
}
