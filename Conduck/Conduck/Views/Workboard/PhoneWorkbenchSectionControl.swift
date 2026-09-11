// SPDX-License-Identifier: Apache-2.0

// Conduck
// PhoneWorkbenchSectionControl.swift
//
// Compact iPhone navigation: a native toolbar trigger reveals the existing
// icon-and-label section capsule inside the active navigation container. The
// overlay does not claim a sheet/popover presenter, so entering Work cannot
// compete with its first-visit tutorial. Its outside-tap shield belongs only
// to the expanded state and consumes the dismissing tap before the composer.

#if os(iOS)

import SwiftUI

private struct PhoneWorkbenchRouterKey: EnvironmentKey {
    static let defaultValue: PersonalWorkbenchRouter? = nil
}

extension EnvironmentValues {
    /// Present only in the compact phone shell. iPad keeps its own persistent
    /// section control, even when both platforms share a destination view.
    var phoneWorkbenchRouter: PersonalWorkbenchRouter? {
        get { self[PhoneWorkbenchRouterKey.self] }
        set { self[PhoneWorkbenchRouterKey.self] = newValue }
    }
}

struct PhoneWorkbenchSectionButton: View {
    let router: PersonalWorkbenchRouter
    let destination: PersonalWorkbenchRouter.Destination

    @AccessibilityFocusState private var triggerIsFocused: Bool

    private var isExpanded: Bool {
        router.isPhoneSectionExpanded(for: destination)
    }

    var body: some View {
        Button {
            KeyboardDismissal.dismissKeyboard()
            router.togglePhoneSection(for: destination)
        } label: {
            HStack(spacing: 4) {
                Text(phoneSectionTitle(destination))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        // Let the system own this toolbar button's glass and foreground;
        // applying amber tint here would leak into native toolbar neighbors.
        .accessibilityLabel(Text(LocalizedStringResource(
            "workbench.section", defaultValue: "Section"
        )))
        .accessibilityValue(Text(phoneSectionTitle(destination)))
        .accessibilityHint(Text(isExpanded
            ? LocalizedStringResource(
                "workbench.section.collapseHint", defaultValue: "Close section chooser"
            )
            : LocalizedStringResource(
                "workbench.section.expandHint", defaultValue: "Choose Chats or Work"
            )
        ))
        .accessibilityIdentifier("workbench.phone.section")
        .accessibilityFocused($triggerIsFocused)
        .onChange(of: isExpanded) { wasExpanded, expanded in
            if expanded {
                triggerIsFocused = false
            } else if wasExpanded, router.destination == destination {
                // Outside tap, escape, and choosing the current section all
                // return the accessibility cursor to the control that opened.
                triggerIsFocused = true
            }
        }
    }
}

struct PhoneWorkbenchSectionOverlay: View {
    let router: PersonalWorkbenchRouter
    let destination: PersonalWorkbenchRouter.Destination

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var preferredWidth: CGFloat = 212
    @ScaledMetric(relativeTo: .caption) private var segmentHeight: CGFloat = 56
    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 24
    @AccessibilityFocusState private var focusedSection: PersonalWorkbenchRouter.Destination?

    private var isExpanded: Bool {
        router.isPhoneSectionExpanded(for: destination)
    }

    var body: some View {
        Group {
            if isExpanded {
                GeometryReader { geometry in
                    ZStack(alignment: .topTrailing) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { router.dismissPhoneSection() }
                            .accessibilityHidden(true)

                        HStack(spacing: 0) {
                            segment(.chats, symbol: "bubble.left.and.bubble.right")
                            segment(.work, symbol: "tray.full")
                        }
                        .padding(4)
                        .frame(width: min(preferredWidth, max(44, geometry.size.width - 32)))
                        .fixedSize(horizontal: false, vertical: true)
                        .background(AppColors.cardBackgroundElevated.opacity(0.96), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Text(LocalizedStringResource(
                            "workbench.section", defaultValue: "Section"
                        )))
                        .accessibilityAddTraits(.isModal)
                        .accessibilityAction(.escape) { router.dismissPhoneSection() }
                        .accessibilityIdentifier("workbench.phone.sections")
                        .padding(.top, 8)
                        .padding(.trailing, 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .transition(.opacity)
                .task {
                    // Wait for the two accessibility elements to join the tree.
                    await Task.yield()
                    guard !Task.isCancelled,
                          router.isPhoneSectionExpanded(for: destination) else { return }
                    focusedSection = destination
                }
            }
        }
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isExpanded)
    }

    private func segment(
        _ section: PersonalWorkbenchRouter.Destination,
        symbol: String
    ) -> some View {
        let isSelected = destination == section
        return Button {
            router.selectPhoneSection(section)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: iconSize, weight: .semibold))
                    .accessibilityHidden(true)
                Text(phoneSectionTitle(section))
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isSelected ? AppColors.brandAmber : .white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: max(44, segmentHeight))
            .background(isSelected ? Color.white.opacity(0.14) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PhoneWorkbenchSectionSegmentStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityFocused($focusedSection, equals: section)
        .accessibilityIdentifier(
            section == .chats ? "workbench.phone.section.chats" : "workbench.phone.section.work"
        )
    }
}

private struct PhoneWorkbenchSectionSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private func phoneSectionTitle(
    _ destination: PersonalWorkbenchRouter.Destination
) -> LocalizedStringResource {
    destination == .chats
        ? LocalizedStringResource("workbench.chats", defaultValue: "Chats")
        : LocalizedStringResource("workbench.work", defaultValue: "Work")
}

#endif
