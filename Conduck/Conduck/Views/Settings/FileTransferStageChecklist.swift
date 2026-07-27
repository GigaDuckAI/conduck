// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileTransferStageChecklist.swift
//
// Agent File Transfer. The staged test-result checklist (Reachability &
// TLS → Authentication → Write a test file → Read it back), extracted from
// `FileTransferSetupGuideView` so the editor's pushed file-transfer page
// (`GatewayFileTransferPage`) and the composer's setup sheet share ONE
// rendering. Pure presentation: it takes a `FileTransferTestResult?` and draws
// one row per `FileTransferTestStage`; a nil result → all rows pending.
//
// The "single line at rest + Show details on failure" gating is the HOST's
// concern (each caller owns a `showDetails` @State), so this view stays dumb and
// reusable — it always renders the full four-stage list when shown.

import SwiftUI

/// The four-stage file-transfer test checklist. `result == nil` → every stage
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
                        .foregroundStyle(AppColors.error)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer()
        }
    }

    private enum StageOutcome { case pending, passed, failed }

    private func outcome(for stage: FileTransferTestStage) -> StageOutcome {
        guard let result else { return .pending }
        if stage.rawValue < result.reachedStage.rawValue { return .passed }
        if stage.rawValue == result.reachedStage.rawValue {
            return result.success ? .passed : .failed
        }
        return .pending
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
        }
    }

    private func stageDetail(_ stage: FileTransferTestStage) -> String? {
        guard let result, !result.success,
              stage.rawValue == result.reachedStage.rawValue,
              let failure = result.failure else {
            return nil
        }
        return failure.errorDescription
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
        }
    }
}
