// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileTransferStageChecklist.swift
//
// Agent File Transfer. The staged test-result checklist (Reachability &
// TLS → Authentication → Write a test file → Read it back → List a folder),
// extracted from
// `FileTransferSetupGuideView` so the editor's pushed file-transfer page
// (`GatewayFileTransferPage`) and the composer's setup sheet share ONE
// rendering. Pure presentation: it takes a `FileTransferTestResult?` and draws
// one row per `FileTransferTestStage`; a nil result → all rows pending.
//
// The "single line at rest + Show details on failure" gating is the HOST's
// concern (each caller owns a `showDetails` @State), so this view stays dumb and
// reusable — it always renders the full stage list when shown.
//
// THE LISTING ROW HAS FOUR STATES, not two. A server that PUTs and GETs but
// cannot PROPFIND (plain nginx with `dav_methods PUT DELETE`) passes every other
// stage and is genuinely usable for uploads, and a server whose PROPFIND merely
// timed out has told us nothing at all. Both draw amber and say what does and
// does not work — never a red X, which would read as a broken setup on a lane
// that uploads perfectly, and never a green tick, which would claim a capability
// nobody measured.

import SwiftUI

/// The file-transfer test checklist, one row per `FileTransferTestStage`.
/// `result == nil` → every stage
/// renders pending (empty circle); a result lights stages up to `reachedStage`
/// (passed) and marks the reached stage passed/failed, with the failure detail
/// inline under the stage it stopped on.
struct FileTransferStageChecklist: View {
    let result: FileTransferTestResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(FileTransferTestStage.allCases, id: \.self) { stage in
                stageRow(stage)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stageRow(_ stage: FileTransferTestStage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            stageGlyph(stage)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(stageTitle(stage))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                if let detail = stageDetail(stage) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailTint(stage))
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer()
        }
    }

    /// FIVE outcomes, not three, and the two extra ones both belong to the
    /// listing stage — the only stage whose question has three answers.
    /// `.unsupported` is a server that said it does not do this; `.unchecked` is
    /// a probe that could not find out. A red X on either would read as "your
    /// setup is broken" about a file server that works, and a green tick would
    /// claim a capability nobody measured, so both get amber and their own
    /// sentence.
    private enum StageOutcome { case pending, passed, failed, unsupported, unchecked }

    private func outcome(for stage: FileTransferTestStage) -> StageOutcome {
        guard let result else { return .pending }
        if stage.rawValue < result.reachedStage.rawValue { return .passed }
        guard stage.rawValue == result.reachedStage.rawValue else { return .pending }
        // Both reads below imply `success` and therefore `reachedStage ==
        // .listing` (every earlier stage's failure clears `success`), so they can
        // only ever describe the listing row.
        if result.isUploadOnly { return .unsupported }
        if result.listingUnverified != nil { return .unchecked }
        return result.success ? .passed : .failed
    }

    @ViewBuilder
    private func stageGlyph(_ stage: FileTransferTestStage) -> some View {
        switch outcome(for: stage) {
        case .pending:
            Image(systemName: "circle").foregroundStyle(AppColors.textTertiary)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(AppColors.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(AppColors.error)
        case .unsupported, .unchecked:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppColors.warning)
        }
    }

    /// Cause AND remedy — this checklist is the whole story for a failed stage.
    /// It has no Troubleshoot chip and no second slot, so rendering
    /// `errorDescription` alone would leave a terminal refusal (a certificate
    /// this device won't accept) on screen with no way to act on it.
    ///
    /// The unsupported listing stage has no `AppError` to render — nothing
    /// failed — so it carries its own sentence. The UNCHECKED one does have a
    /// code, and it is rendered with its recovery text like any other, because
    /// "couldn't check" without "here is what to look at" is just a shrug. Its
    /// own leading sentence says which half of the lane is in question, since
    /// the code alone would read as though the whole test had failed.
    /// `detailTint` keeps both out of the red the failure text uses.
    private func stageDetail(_ stage: FileTransferTestStage) -> String? {
        guard let result, stage.rawValue == result.reachedStage.rawValue else { return nil }
        if result.isUploadOnly {
            return String(localized: LocalizedStringResource(
                "fileTransfer.test.stage.listing.unsupported",
                defaultValue: "This server can't list folders. Sending files to the agent works; files the agent creates can't come back on their own."))
        }
        if let unverified = result.listingUnverified {
            let lead = String(localized: LocalizedStringResource(
                "fileTransfer.test.stage.listing.unchecked",
                defaultValue: "Sending files works. Conduck couldn't check whether files can come back — try this test again."))
            return lead + " " + unverified.descriptionWithRecovery
        }
        guard !result.success, let failure = result.failure else { return nil }
        return failure.descriptionWithRecovery
    }

    private func detailTint(_ stage: FileTransferTestStage) -> Color {
        switch outcome(for: stage) {
        case .unsupported, .unchecked: return AppColors.textSecondary
        case .pending, .passed, .failed: return AppColors.error
        }
    }

    private func stageTitle(_ stage: FileTransferTestStage) -> LocalizedStringResource {
        switch stage {
        case .reachability:
            return LocalizedStringResource("fileTransfer.test.stage.reachability", defaultValue: "Reachability & TLS")
        case .auth:
            return LocalizedStringResource("fileTransfer.test.stage.auth", defaultValue: "Authentication")
        case .write:
            return LocalizedStringResource("fileTransfer.test.stage.write", defaultValue: "Write a test file")
        case .read:
            return LocalizedStringResource("fileTransfer.test.stage.read", defaultValue: "Read it back")
        case .listing:
            // The return direction, in the user's terms: this is the capability
            // that decides whether files an agent produces ever reach the device.
            return LocalizedStringResource("fileTransfer.test.stage.listing", defaultValue: "List a folder")
        }
    }
}
