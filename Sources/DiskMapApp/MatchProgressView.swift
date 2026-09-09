import DiskMapCore
import SwiftUI

/// What the copy hunt is doing, while it does it.
///
/// Finding copies is three passes over the whole tree and on a full disk that
/// is minutes. A spinner over the word "Working…" is what a hang looks like
/// too, so this shows the passes as a list: the ones behind us ticked, the one
/// running with its count, the ones ahead dimmed. The question it answers is
/// the one that was asked — what is done, and what is being done now.
struct MatchProgressView: View {
    let progress: MatchProgress?
    /// The passes this screen actually runs, in the order it runs them. The
    /// copies report adds up the subtree first; the cleanup screen does not.
    let phases: [MatchProgress.Phase]

    @ObservedObject private var loc = L10n.shared

    private static let iconColumn: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(phases, id: \.self) { row($0) }
        }
        .frame(width: 240, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var current: Int {
        guard let phase = progress?.phase, let at = phases.firstIndex(of: phase) else { return 0 }
        return at
    }

    private func row(_ phase: MatchProgress.Phase) -> some View {
        let mine = phases.firstIndex(of: phase) ?? 0
        let done = mine < current
        let running = mine == current

        return HStack(alignment: .top, spacing: 8) {
            // A fixed column so the labels start at the same x whatever the
            // glyph, rather than shifting as each pass finishes.
            Image(systemName: done ? "checkmark.circle.fill" : running ? "circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(done || running ? Color.accentColor
                                                 : Color.secondary.opacity(0.4))
                .frame(width: Self.iconColumn, alignment: .leading)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(loc[label(phase)])
                    .font(.system(size: 11, weight: running ? .semibold : .regular))
                    .foregroundStyle(running ? .primary : done ? .secondary : .tertiary)
                if running { detail }
            }
        }
    }

    /// The bar, and under it the count when the pass can say one.
    ///
    /// A pass that does not know its total draws a bar that moves rather than
    /// one that fills — claiming a percentage nobody computed would be worse
    /// than admitting the total is unknown.
    @ViewBuilder private var detail: some View {
        if let fraction = progress?.fraction {
            ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.small)
            Text(loc.passProgress(progress?.done ?? 0, progress?.total ?? 0))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .monospacedDigit()
        } else {
            ProgressView().progressViewStyle(.linear).controlSize(.small)
        }
    }

    private func label(_ phase: MatchProgress.Phase) -> L10n.K {
        switch phase {
        case .measuring: .phaseMeasuring
        case .signing: .phaseSigning
        case .folders: .phaseFolders
        case .files: .phaseFiles
        }
    }
}
