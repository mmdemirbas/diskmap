import DiskMapCore
import SwiftUI

/// Files that share a name and a byte length, biggest saving first.
///
/// The header says what the match is based on, because the honest answer is
/// "these look like copies", not "these are copies". Nothing is read from disk
/// to produce this, which is what makes it as fast as the rest of the app and
/// safe on iCloud placeholders.
struct DuplicatesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared

    @State private var opened: Set<Int32> = []

    private static let rowHeight: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            if model.summarizing {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(loc[.computing]).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.duplicates.isEmpty {
                Text(loc[.duplicatesEmpty]).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                Divider()
                list
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                Text(loc[.duplicatesNote]).font(.system(size: 10))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            // The leading number is what deleting the extras would free, not
            // the size of a file. Saying so once beats repeating it per row.
            HStack(spacing: 8) {
                Spacer().frame(width: 10)
                Text(loc[.reclaimable]).frame(width: 70, alignment: .trailing)
                Text(loc[.name])
                Spacer(minLength: 4)
                Text(loc[.panelDuplicates]).frame(width: 58, alignment: .trailing)
                Text(loc[.size]).frame(width: 76, alignment: .trailing)
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 5)
    }

    private var total: Int64 { model.duplicates.reduce(0) { $0 + $1.reclaimable } }

    @ViewBuilder private var list: some View {
        if model.renderMode {
            // Offscreen there is no viewport, so rows would ask for the height
            // of the whole list and push the window open.
            GeometryReader { geo in
                let fits = max(1, Int(geo.size.height / Self.rowHeight))
                VStack(spacing: 0) {
                    ForEach(model.duplicates.prefix(fits - 1)) { group in groupRow(group) }
                    Spacer(minLength: 0)
                    summaryRow
                }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.duplicates) { group in
                        groupRow(group)
                        if opened.contains(group.id) {
                            ForEach(group.copies) { copy in copyRow(copy) }
                        }
                    }
                    summaryRow
                }
            }
        }
    }

    private var summaryRow: some View {
        HStack {
            Spacer()
            Text("\(shortBytes(total)) \(loc[.reclaimable])")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func groupRow(_ group: DuplicateEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: opened.contains(group.id) ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 10)
            Text(shortBytes(group.reclaimable))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 70, alignment: .trailing)
            Text(group.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(loc.copyCount(group.copies.count))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            Text("× \(shortBytes(group.bytes))")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            if opened.contains(group.id) { opened.remove(group.id) } else { opened.insert(group.id) }
        }
    }

    /// One copy. The first is not marked as the one to keep on purpose — this
    /// match is a candidate, so which copy is the real one is your call.
    private func copyRow(_ copy: DuplicateEntry.Copy) -> some View {
        HStack(spacing: 8) {
            Text(copy.path)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
        }
        .padding(.leading, 34).padding(.trailing, 12).padding(.vertical, 3)
        .background(model.selection == copy.id ? Color.accentColor.opacity(0.22) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.select(copy.id) }
        .onTapGesture(count: 2) { model.reveal(copy.id) }
        .contextMenu {
            Button(loc[.revealInFinder]) { model.reveal(copy.id) }
            Button(loc[.copyPath]) { model.copyPath(copy.id) }
            Divider()
            Button(loc[.moveToTrash]) { model.requestTrash(copy.id) }
        }
    }
}
