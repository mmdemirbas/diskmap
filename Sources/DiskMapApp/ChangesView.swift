import DiskMapCore
import SwiftUI

extension FolderChange.Kind {
    var symbol: String {
        switch self {
        case .grew: "arrow.up.right"
        case .shrank: "arrow.down.right"
        case .appeared: "plus.circle"
        case .vanished: "minus.circle"
        }
    }
    var tint: Color {
        switch self {
        case .grew, .appeared: .orange
        case .shrank, .vanished: .green
        }
    }
}

/// What moved since an earlier scan.
///
/// The question a single scan cannot answer. "My disk lost 40 GB this week"
/// has no answer in a picture of what is big now — only in a comparison with
/// what was big before.
///
/// Every change is attributed to the deepest folder that explains it, so a
/// download appears once, in Downloads, rather than five times up the chain
/// with the least useful statement of it at the top.
struct ChangesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        ReadableColumn { column }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.history.isEmpty {
                empty
            } else {
                picker
                Divider()
                body(of: model.comparison)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc[.whatChanged]).font(.system(size: 15, weight: .semibold))
            if let diff = model.comparison {
                HStack(spacing: 6) {
                    Text(headline(diff)).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(diff.totalDelta > 0 ? .orange : .green)
                    Text(loc.sinceWhen(loc.dateTime(diff.from)))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
    }

    private func headline(_ diff: DigestDiff) -> String {
        diff.totalDelta == 0 ? loc[.noNetChange]
            : diff.totalDelta > 0 ? loc.grewBy(shortBytes(diff.totalDelta))
                                  : loc.shrankBy(shortBytes(-diff.totalDelta))
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text(loc[.noEarlierScans]).font(.callout).foregroundStyle(.secondary)
            Text(loc[.comeBackAfterAnotherScan]).font(.caption).foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center).padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The earlier scans, newest first. Kept to one row so the comparison and
    /// its subject stay on screen together.
    private var picker: some View {
        viewportScroller(renderMode: model.renderMode, axis: .horizontal) {
            HStack(spacing: 6) {
                ForEach(model.history) { entry in
                    let chosen = model.comparingTo == entry.id
                    Button {
                        model.compare(with: entry)
                    } label: {
                        VStack(spacing: 1) {
                            Text(loc.dateTime(entry.takenAt))
                                .font(.system(size: 10, weight: chosen ? .semibold : .regular))
                            Text(shortBytes(entry.totalPhysical))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(chosen ? Color.accentColor.opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(chosen ? Color.accentColor.opacity(0.5) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
    }

    @ViewBuilder private func body(of diff: DigestDiff?) -> some View {
        if let diff, !diff.isEmpty {
            viewportScroller(renderMode: model.renderMode) {
                LazyVStack(spacing: 0) {
                    ForEach(diff.changes) { row($0) }
                }
            }
        } else if diff != nil {
            Text(loc[.nothingMovedMuch]).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear.frame(maxHeight: .infinity)
        }
    }

    private func row(_ change: FolderChange) -> some View {
        HStack(spacing: 10) {
            Image(systemName: change.kind.symbol)
                .font(.system(size: 11)).foregroundStyle(change.kind.tint).frame(width: 14)
            Text(signed(change.ownDelta))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(change.kind.tint)
                .frame(width: 86, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text((change.path as NSString).lastPathComponent)
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(change.path).font(.system(size: 9)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 6)
            Text("\(shortBytes(change.before)) → \(shortBytes(change.after))")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 148, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.revealChange(change) }
        .contextMenu {
            Button(loc[.openHere]) { model.revealChange(change) }
            Button(loc[.copyPath]) { FileActions.copyToPasteboard(change.path) }
        }
    }

    private func signed(_ bytes: Int64) -> String {
        (bytes > 0 ? "+" : bytes < 0 ? "−" : "") + shortBytes(abs(bytes))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label(loc[.deepestFolderExplains], systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button(loc[.close]) { model.close(.changes) }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

}
