// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationActivityMark.swift
//
// The conversation-list row's trailing activity mark and its status/elapsed
// line — the SwiftUI rendering of `ConversationRowState`.
//
// SHAPE, NOT COLOUR. Every state is distinguishable with the colour channel
// removed: nothing / a spinner ring / a static clock glyph / a solid disc / an
// exclamation punched out of a circle. Colour only reinforces what the shape
// already says — amber means an answer wants you, red means a problem, neutral
// means information.
//
// iOS/macOS only, by file location: the wrist renders delivery state as WORDS in
// its existing date slot (it has neither the width for a mark nor the budget for
// a clock), and CarPlay renders a phrase. `InFlightTurnRegistry` and
// `ReadStateStore` are not Watch members either, so this file's re-resolution
// could not compile there.

import SwiftUI

// MARK: - Shared derivation

/// The ONE place a conversation-list row's state is derived from the two
/// device-local sources the resolver needs.
///
/// Static and shared because THREE readers must reach the same answer for one
/// row: `ConversationListViewModel.rowState` (which decides the bold title and
/// the brighter subtitle), the trailing mark, and the status line. One
/// `ConversationActivityClock` per row re-derives it for all three at once — a
/// single definition on a single schedule is what keeps a spinner from sitting
/// beside the words "No reply yet".
///
/// Both singletons are `@Observable` with in-memory stored state, so reading
/// them from inside a `body` registers a real SwiftUI dependency: the row
/// repaints when a claim ends or a thread is marked viewed, with no notification
/// plumbing.
enum ConversationRowActivity {
    static func state(
        inputs: ConversationActivityInputs,
        conversationID: UUID,
        now: Date = Date()
    ) -> ConversationRowState {
        ConversationActivityResolver.resolve(
            inputs,
            locallyLiveSince: InFlightTurnRegistry.shared.liveSince(conversationID, now: now),
            lastViewedAt: ReadStateStore.shared.lastViewed(conversationID),
            failureSeenAt: ReadStateStore.shared.lastFailureSeen(conversationID),
            now: now
        )
    }
}

// MARK: - The clock

/// Re-derives a WORKING row's state once a minute, and does nothing at all for
/// every other row.
///
/// Two transitions change a row's truth with no state mutation behind them —
/// `.hedged` aging into `.stale` at the 30-minute grace boundary, and a local
/// claim aging out at its TTL. Neither writes anything, so neither would ever
/// repaint an `@Observable`-driven row: without this the list would keep
/// promising "Waiting for a reply…" indefinitely.
///
/// The schedule lives HERE, in a subtree that exists only for working rows, so
/// the invalidation is scoped to those 0–2 rows. Deliberately NOT a
/// `TimelineView` around the `List` and NOT a `@State` tick loop on
/// `ConversationListView`: both re-run `filteredConversations` and
/// `filteredTimeGroups` for the whole list every minute, to repaint two rows.
///
/// ONE PER ROW, wrapping the mark and the status line TOGETHER. Two independent
/// timelines would each re-run the resolver on their own schedule, doubling the
/// per-minute invalidations and — worse — letting the glyph and the words
/// disagree across the grace boundary, which is the exact contradiction this
/// file exists to prevent. The row's VoiceOver label is deliberately left
/// OUTSIDE: a label that rewrites on a timer produces repeated announcements.
///
/// On every tick it re-runs the RESOLVER, not just the elapsed string —
/// recomputing only the elapsed text would leave a stale status word (and a
/// stale glyph) on screen forever. Elapsed is recomputed from `since` each tick
/// too, so a throttled timeline catches up instead of drifting.
struct ConversationActivityClock<Content: View>: View {
    /// The state the parent's `body` resolved. Its `.working(_, since:)` stamp
    /// anchors the schedule.
    let state: ConversationRowState
    let inputs: ConversationActivityInputs
    let conversationID: UUID
    @ViewBuilder let content: (ConversationRowState, Date) -> Content

    var body: some View {
        if case .working(_, let since) = state.activity {
            TimelineView(.periodic(from: since, by: 60)) { context in
                content(
                    ConversationRowActivity.state(
                        inputs: inputs,
                        conversationID: conversationID,
                        now: context.date
                    ),
                    context.date
                )
            }
        } else {
            content(state, Date())
        }
    }
}

// MARK: - Trailing mark

/// The row's trailing activity mark, on the title line.
///
/// The slot is ALWAYS present — `.idle` renders `Color.clear` at the same size —
/// so a title's truncation point never moves when the row changes state. That is
/// the whole reason the mark is a reserved slot rather than a conditional view.
///
/// Trailing on the title line, never a leading rail: a red mark beside the
/// gateway monogram reads as one confusing compound glyph, and the badge is
/// conditional, so the leading edge is not a stable column for the
/// single-gateway majority. The gateway badge itself is never tinted, dimmed or
/// overlaid by any of this.
struct ConversationActivityMark: View {
    /// Already resolved by the row's single `ConversationActivityClock` — this
    /// view owns no schedule of its own, so the glyph and the status words below
    /// can never be resolved a minute apart.
    let state: ConversationRowState

    /// Scales with Dynamic Type so the mark keeps its proportion to the headline
    /// beside it at AX5 instead of shrinking to a speck.
    @ScaledMetric private var slot: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        mark
            .frame(width: slot, height: slot)
            // Same gating as `CaptureCircleButton`: the symbol cross-fade is
            // motion, so Reduce Motion swaps it for a hard cut.
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            // The composed row label already leads with the state word. An
            // independently focusable glyph would announce it a second time, out
            // of order.
            .accessibilityHidden(true)
    }

    /// An acknowledged failure keeps its WORDS and loses its MARK. The row still
    /// says the message was not sent, because it still was not; what it drops is
    /// the alert, which has already been delivered and does not need repeating
    /// every time the user scans the list. Renders the same reserved-empty slot
    /// `.idle` does, so nothing shifts when a failure is retired.
    /// The `.failed` check is NOT redundant with the flag. The resolver only
    /// ever sets `failureAcknowledged` alongside `.failed`, but the memberwise
    /// initializer accepts any pairing and validates nothing, so a stray
    /// `failureAcknowledged: true` on `.answeredUnseen` would silently blank the
    /// amber disc — the list's only call-to-action. The view is the wrong layer
    /// to depend on a constructor's discipline.
    @ViewBuilder
    private var mark: some View {
        if state.failureAcknowledged, case .failed = state.activity {
            Color.clear
        } else {
            glyph(state.activity)
        }
    }

    @ViewBuilder
    private func glyph(_ activity: ConversationActivity) -> some View {
        switch activity {
        case .idle:
            Color.clear

        case .working(.live, _), .working(.hedged, _):
            // NEUTRAL, not amber. The list is a triage surface: a working row is
            // information, an answered row is a call to action. Amber for both
            // destroys the one signal that means "go look", and it collides with
            // the selected-row amber wash.
            if reduceMotion {
                symbol("circle.dotted", tint: neutral)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    // `.controlSize(.mini)` resolves differently per platform;
                    // an explicit scale against the slot does not.
                    .scaleEffect(slot / 20)
                    .tint(neutral)
            }

        case .working(.stale, _):
            // STATIC. An animated spinner beside "No reply yet" is internally
            // contradictory, and `.stale` is the one state where nothing is
            // known to be running.
            symbol("clock.badge.questionmark", tint: neutral)

        case .answeredUnseen:
            Circle()
                .fill(AppColors.brandAmber)
                .frame(width: slot * 0.5, height: slot * 0.5)
                // Increase Contrast: a hairline ring separates the disc from the
                // 15 % amber selected-row wash it can sit on.
                .overlay {
                    if contrast == .increased {
                        Circle().strokeBorder(AppColors.textEmphasis, lineWidth: 1)
                    }
                }

        case .failed:
            symbol("exclamationmark.circle.fill", tint: AppColors.error)
        }
    }

    /// `resizable().scaledToFit()` rather than a point size: it guarantees the
    /// glyph stays inside the reserved slot at every Dynamic Type size, including
    /// the wider-than-tall `clock.badge.questionmark`.
    private func symbol(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .fontWeight(contrast == .increased ? .semibold : .regular)
            .foregroundStyle(tint)
            .frame(width: slot * 0.9, height: slot * 0.9)
    }

    private var neutral: Color {
        contrast == .increased ? AppColors.textPrimary : AppColors.textSecondary
    }
}

// MARK: - Metadata line

/// The row's metadata line: a date when nothing is happening, the status words
/// (plus a coarse elapsed clock) while a turn is in flight, and "Not sent" when
/// one never left the device.
///
/// ALWAYS one line, always present — `.lineLimit(1)` unconditionally. A wrapping
/// metadata line would change the row's height on a row that is simultaneously
/// moving to the top of the list.
struct ConversationActivityLine: View {
    /// Already resolved by the row's single `ConversationActivityClock`.
    let state: ConversationRowState
    /// The tick this state was resolved at — the elapsed clock counts to HERE,
    /// not to a second reading of `Date()`, so the words and the number belong
    /// to one instant.
    let now: Date
    /// Resolved gateway display name, or "" when the ref does not resolve — the
    /// shared copy then falls back to a bare "Answering…" rather than rendering
    /// " is answering…".
    let gatewayName: String
    let lastActivityAt: Date

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        content(state, at: now)
    }

    @ViewBuilder
    private func content(_ resolved: ConversationRowState, at date: Date) -> some View {
        switch resolved.activity {
        case .idle, .answeredUnseen:
            Text(MessageRowFormatters.conversationListDate(from: lastActivityAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

        case .working(let confidence, let since):
            HStack(spacing: 6) {
                Text(ConversationActivityCopy.working(confidence, gatewayName: gatewayName))
                    .foregroundStyle(statusColor)
                // No elapsed beside "No reply yet": `.stale` is a statement about
                // the send, and a running clock next to it would imply something
                // is still being waited on.
                if confidence != .stale,
                   let elapsed = ConversationActivityCopy.coarseElapsed(date.timeIntervalSince(since)) {
                    Text(elapsed)
                        .monospacedDigit()
                        .foregroundStyle(elapsedColor)
                }
            }
            .font(.caption)
            .lineLimit(1)

        case .failed:
            // The words are the same either way — the message did not go, and
            // that stays true after the user has read the error. Only the
            // URGENCY is spent, so an acknowledged failure drops to the ordinary
            // metadata colour and stops reading as a live alert.
            Text(ConversationActivityCopy.notSent)
                .font(.caption)
                .foregroundStyle(resolved.failureAcknowledged ? statusColor : AppColors.error)
                .lineLimit(1)
        }
    }

    private var statusColor: Color {
        contrast == .increased ? AppColors.textPrimary : AppColors.textSecondary
    }

    private var elapsedColor: Color {
        contrast == .increased ? AppColors.textSecondary : AppColors.textTertiary
    }
}
