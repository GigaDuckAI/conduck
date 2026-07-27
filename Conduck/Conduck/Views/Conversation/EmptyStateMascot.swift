// SPDX-License-Identifier: Apache-2.0

// Conduck
// EmptyStateMascot.swift
//
// Shared empty-state mascot renderer. Replaces the previously-inlined
// `Image("conduck-wrestling-bear")` block repeated across the empty-state
// surfaces (iOS/iPad host states + the iOS thread hint + the macOS new-chat
// state). The pose is chosen by the caller from `MascotShuffleBag` and held
// stable on the caller's model.

import SwiftUI

/// Shared empty-state mascot renderer. The pose is chosen by the caller (from
/// `MascotShuffleBag`) and held stable on the caller's model — this view never
/// selects, so it cannot flicker on re-render. Glow matches the prior inline style.
struct EmptyStateMascot: View {
    let pose: String
    var height: CGFloat

    var body: some View {
        Image(pose)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .shadow(color: AppColors.brandAmber.opacity(0.3), radius: 16, y: 8)
    }
}
