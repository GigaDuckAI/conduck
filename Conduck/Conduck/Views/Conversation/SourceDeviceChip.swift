// Conduck
// SourceDeviceChip.swift
//
// The chip lives in the per-message bubble footer (`sourceDevice` is a
// `Message` field). Icon + label come from `MessageRowFormatters` (which adds
// the `carplay` case).

import SwiftUI

/// Capsule chip showing which device originated a message turn — and, when the
/// tag carries a modality suffix (`iphone-text` / `mac-voice`), a subtle glyph
/// for how the turn was entered (typed vs spoken). Legacy tags without a suffix
/// render device-only (backward compatible).
struct SourceDeviceChip: View {
    /// The raw `Message.sourceDevice` tag (may carry a `-voice`/`-text` suffix).
    let device: String

    private var baseDevice: String {
        MessageRowFormatters.baseDevice(from: device)
    }

    private var modalityIcon: String? {
        MessageRowFormatters.modalityIcon(from: device)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: MessageRowFormatters.icon(forDevice: baseDevice))
                .font(.system(size: 10))
            Text(MessageRowFormatters.label(forDevice: baseDevice))
                .font(.caption2)
            if let modalityIcon {
                Image(systemName: modalityIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(AppColors.textTertiary.opacity(0.8))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(AppColors.backgroundSecondary)
        .foregroundStyle(AppColors.textTertiary)
        .clipShape(Capsule())
    }
}
