// SPDX-License-Identifier: Apache-2.0

// WorkboardTutorialExamples.swift
// Conduck
//
// Local illustrations for the Work tour. Optional controls mutate bindings to
// the teaching session only. No store, gateway, capture, or filesystem is used;
// the pictured Send action is passive. Semantic text sizes and wrapping cards
// preserve the instruction when the user needs larger type.

import SwiftUI

struct WorkboardTourCard<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text(title).fixedSize()
                    Spacer(minLength: 0)
                    exampleBadge
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                    exampleBadge
                }
            }
            .onboardingScaledFont(.subheadline, weight: .semibold)
            .foregroundStyle(AppColors.textPrimary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCardPadding()
        .glassCardBackground()
    }

    private var exampleBadge: some View {
        Text(LocalizedStringResource("workdesk.tour.example", defaultValue: "Example"))
            .onboardingScaledFont(.caption)
            .foregroundStyle(AppColors.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppColors.border))
            .fixedSize()
    }
}

private enum WorkboardTourExampleCopy {
    static let home = LocalizedStringResource("workdesk.tour.example.home", defaultValue: "Home")
    static let project = LocalizedStringResource("workdesk.tour.example.project", defaultValue: "Website refresh")
    static let idea = LocalizedStringResource("workdesk.tour.example.idea", defaultValue: "Homepage idea")
    static let screenshot = LocalizedStringResource("workdesk.tour.example.screenshot", defaultValue: "Homepage screenshot")
    static let research = LocalizedStringResource("workdesk.tour.example.research", defaultValue: "Research link")
    static let assistant = LocalizedStringResource("workdesk.tour.example.assistant", defaultValue: "My assistant")
}

struct WorkboardTourCaptureExample: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        WorkboardTourCard(title: WorkboardTourExampleCopy.home) {
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringResource("workdesk.tour.example.thought", defaultValue: "Thought"))
                    .onboardingScaledFont(.caption)
                Text(LocalizedStringResource("workdesk.tour.example.thought.body", defaultValue: "Make the homepage clearer."))
                    .onboardingScaledFont(.headline)
            }
            .foregroundStyle(AppColors.background)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.93, green: 0.87, blue: 0.76), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)

            HStack(spacing: 12) {
                Image(systemName: "paperclip")
                Text(LocalizedStringResource("workdesk.tour.example.composer", defaultValue: "Add to Home…"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "mic")
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(AppColors.brandAmber)
                }
            }
            .onboardingScaledFont(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .padding(14)
            .background(AppColors.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColors.border))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(LocalizedStringResource(
                "workdesk.tour.example.composer.accessibility",
                defaultValue: "Work composer: attach material, type in Add to Home, record a spoken note, or add the thought."
            )))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { captureLabels }
                VStack(alignment: .leading, spacing: 10) { captureLabels }
            }
            .onboardingScaledFont(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var captureLabels: some View {
        Label {
            Text(LocalizedStringResource("workdesk.tour.example.type", defaultValue: "Type"))
        } icon: { Image(systemName: "square.and.pencil").accessibilityHidden(true) }
        Label {
            Text(LocalizedStringResource("workdesk.tour.example.speak", defaultValue: "Speak"))
        } icon: { Image(systemName: "mic").accessibilityHidden(true) }
        Label {
            Text(LocalizedStringResource("workdesk.tour.example.attach", defaultValue: "Attach"))
        } icon: { Image(systemName: "paperclip").accessibilityHidden(true) }
    }
}

struct WorkboardTourShareExample: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) { choices }
            } else {
                HStack(spacing: 8) { choices }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringResource(
            "workdesk.tour.example.share.accessibility",
            defaultValue: "Share offers separate Add to Work and Send to My assistant actions. Choose Add to Work to collect for later."
        )))
    }

    @ViewBuilder private var choices: some View {
        Text(LocalizedStringResource("workdesk.tour.example.add", defaultValue: "Add to Work"))
            .onboardingScaledFont(.subheadline, weight: .medium)
            .foregroundStyle(AppColors.brandAmber)
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(AppColors.brandAmber.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppColors.brandAmber.opacity(0.5)))
        Text(LocalizedStringResource("workdesk.tour.example.send", defaultValue: "Send to My assistant"))
            .onboardingScaledFont(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppColors.border))
    }
}

struct WorkboardTourProjectExample: View {
    @Binding var stage: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        WorkboardTourCard(title: stage == 2 ? WorkboardTourExampleCopy.project : WorkboardTourExampleCopy.home) {
            if stage == 1 {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.title)
                        .accessibilityHidden(true)
                    Text(WorkboardTourExampleCopy.project)
                        .onboardingScaledFont(.title3, weight: .semibold)
                    Text(LocalizedStringResource("workdesk.tour.example.project.count", defaultValue: "2 materials"))
                        .onboardingScaledFont(.subheadline)
                }
                .foregroundStyle(AppColors.background)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color(red: 0.69, green: 0.79, blue: 0.71), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) { materials }
            } else {
                HStack(alignment: .top, spacing: 12) { materials }
            }

            Button {
                stage = stage == 0 ? 1 : stage == 1 ? 2 : 1
            } label: {
                Text(actionTitle)
                    .onboardingScaledFont(.subheadline, weight: .medium)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 12)
                    .background(AppColors.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            .choiceCardButton(cornerRadius: 10)
            .accessibilityHint(Text(LocalizedStringResource(
                "workdesk.tour.example.project.action.hint",
                defaultValue: "Changes only this example. Your own materials stay as they are."
            )))
        }
    }

    @ViewBuilder private var materials: some View {
        material(WorkboardTourExampleCopy.idea, symbol: "note.text", color: Color(red: 0.93, green: 0.87, blue: 0.76))
        material(WorkboardTourExampleCopy.screenshot, symbol: "photo", color: Color(red: 0.73, green: 0.81, blue: 0.85))
    }

    private func material(_ title: LocalizedStringResource, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: symbol)
                .font(.title3)
                .accessibilityHidden(true)
            Text(title)
                .onboardingScaledFont(.subheadline, weight: .medium)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(AppColors.background)
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color, in: RoundedRectangle(cornerRadius: 10))
    }

    private var actionTitle: LocalizedStringResource {
        switch stage {
        case 0: .init("workdesk.tour.example.project.create", defaultValue: "Select → Create project")
        case 1: .init("workdesk.tour.example.project.open", defaultValue: "Open project")
        default: .init("workdesk.tour.example.project.home", defaultValue: "Back to Home")
        }
    }
}

struct WorkboardTourRequestExample: View {
    @Binding var includesResearch: Bool
    @Binding var reviewsRequest: Bool

    var body: some View {
        WorkboardTourCard(title: reviewsRequest
                         ? LocalizedStringResource("workdesk.tour.example.review.title", defaultValue: "Review conversation")
                         : LocalizedStringResource("workdesk.tour.example.request.title", defaultValue: "New conversation")) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    projectTitle
                    Spacer(minLength: 0)
                    assistant
                }
                VStack(alignment: .leading, spacing: 10) {
                    projectTitle
                    assistant
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                fieldLabel(.init("workdesk.tour.example.task.label", defaultValue: "What would you like to do?"))
                Text(LocalizedStringResource("workdesk.tour.example.task", defaultValue: "Draft a clearer homepage."))
                    .onboardingScaledFont(.title3, weight: .medium)
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                fieldLabel(.init("workdesk.tour.example.context.label", defaultValue: "Project context · optional"))
                Text(LocalizedStringResource("workdesk.tour.example.context", defaultValue: "For independent consultants. Keep it friendly."))
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                fieldLabel(.init("workdesk.tour.example.materials", defaultValue: "Materials · \(includesResearch ? 3 : 2) included"))
                materialRow(WorkboardTourExampleCopy.idea, included: true)
                materialRow(WorkboardTourExampleCopy.screenshot, included: true)
                if reviewsRequest {
                    materialRow(WorkboardTourExampleCopy.research, included: includesResearch)
                } else {
                    Button {
                        includesResearch.toggle()
                    } label: {
                        materialRow(WorkboardTourExampleCopy.research, included: includesResearch)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .choiceCardButton(cornerRadius: 8)
                    .accessibilityHint(Text(LocalizedStringResource(
                        "workdesk.tour.example.material.toggle.hint",
                        defaultValue: "Include or leave out this material in the example request."
                    )))
                }
            }
            if reviewsRequest {
                // Passive illustration: no dispatch action exists to activate.
                Text(LocalizedStringResource("workdesk.tour.example.send", defaultValue: "Send to My assistant"))
                    .onboardingScaledFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppColors.background)
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .background(AppColors.brandAmber, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(Text(LocalizedStringResource(
                        "workdesk.tour.example.send.accessibility",
                        defaultValue: "Example final confirmation: Send to My assistant. Nothing is sent from this tour."
                    )))
            }
            Button {
                reviewsRequest.toggle()
            } label: {
                Text(reviewsRequest
                     ? LocalizedStringResource("workdesk.tour.example.review.back", defaultValue: "Back to example request")
                     : LocalizedStringResource("workdesk.tour.example.review", defaultValue: "Review"))
                    .onboardingScaledFont(.subheadline, weight: .medium)
                    .foregroundStyle(AppColors.brandAmber)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 12)
                    .background(AppColors.brandAmber.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColors.brandAmber.opacity(0.4)))
            }
            .choiceCardButton(cornerRadius: 10)
        }
    }

    private var projectTitle: some View {
        Text(WorkboardTourExampleCopy.project)
            .onboardingScaledFont(.subheadline, weight: .semibold)
            .foregroundStyle(AppColors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var assistant: some View {
        Text(WorkboardTourExampleCopy.assistant)
            .onboardingScaledFont(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay(Capsule().stroke(AppColors.border))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fieldLabel(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .onboardingScaledFont(.subheadline, weight: .medium)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func materialRow(_ text: LocalizedStringResource, included: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: included ? "checkmark.square.fill" : "square")
                .foregroundStyle(included ? AppColors.brandTeal : AppColors.textTertiary)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onboardingScaledFont(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(included
                                ? LocalizedStringResource("workdesk.tour.example.material.included", defaultValue: "Included")
                                : LocalizedStringResource("workdesk.tour.example.material.excluded", defaultValue: "Left out")))
    }
}

struct WorkboardTourContinueExample: View {
    var body: some View {
        WorkboardTourCard(title: WorkboardTourExampleCopy.project) {
            row(
                symbol: "bubble.left.and.bubble.right",
                title: .init("workdesk.tour.example.continue.chat", defaultValue: "Keep talking in the project"),
                detail: .init("workdesk.tour.example.continue.chat.detail", defaultValue: "Open its conversation to read the reply or ask a follow-up.")
            )
            Divider()
            row(
                symbol: "folder",
                title: .init("workdesk.tour.example.continue.reuse", defaultValue: "Use the next useful piece"),
                detail: .init("workdesk.tour.example.continue.reuse.detail", defaultValue: "Save a message to Work, or select returned files for another task.")
            )
        }
    }

    private func row(symbol: String, title: LocalizedStringResource, detail: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(AppColors.brandTeal)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .onboardingScaledFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppColors.textPrimary)
                Text(detail)
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
