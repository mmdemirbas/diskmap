import DiskMapCore
import SwiftUI

/// The last thing between a ticked list and the Trash.
///
/// It shows every single path that will move — not a count, not a summary. A
/// count is something you agree to; a list is something you check. The window
/// is sized so a mistaken extra entry is visible without scrolling in the
/// common case, and scrolls rather than truncating when it is not.
struct TrashConfirmView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    let plan: TrashPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !plan.synced.isEmpty { syncWarning }
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 640, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc.confirmBulkTitle(plan.items.count, shortBytes(plan.bytes)))
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 10) {
                Label(loc[.keepsOneCopy], systemImage: "checkmark.shield")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if plan.coveredByAnAncestor > 0 {
                    Text(loc.alsoCovered(plan.coveredByAnAncestor))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
    }

    /// The one thing a user cannot undo from the Trash. It gets its own block,
    /// above the list, in the warning colour — not a badge on a row that scrolls
    /// out of sight.
    private var syncWarning: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.system(size: 12))
                Text(loc[.syncWarningTitle]).font(.system(size: 12, weight: .semibold))
                Text(loc.syncedItemCount(plan.synced.count, providers))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(loc[.alsoDeletedFromService])
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.orange.opacity(0.45)))
        .padding(.horizontal, 18).padding(.bottom, 12)
    }

    private var providers: String {
        Array(Set(plan.synced.compactMap(\.syncProvider))).sorted()
            .formatted(.list(type: .and))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc[.reviewBeforeTrashing])
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4)
            viewportScroller(renderMode: model.renderMode) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(plan.items) { item in row(item) }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func row(_ item: TrashCandidate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 12)
            Text(shortBytes(item.bytes))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 68, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    if let provider = item.syncProvider {
                        Text(provider)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    if item.isDirectory {
                        Text(loc.itemCount(item.itemCount))
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                Text(item.path)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 18).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.reveal(item.node) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label(loc[.trashIsRecoverable], systemImage: "arrow.uturn.backward")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button(loc[.cancel]) { model.cancelBulkTrash() }
                .keyboardShortcut(.cancelAction)
            Button(loc[.moveToTrash], role: .destructive) { model.confirmBulkTrash() }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}
