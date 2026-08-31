import DiskMapCore
import SwiftUI

/// A tree table: folders open in place instead of replacing the view, so you
/// can compare two branches without losing your position. One column track per
/// field, so sizes are read by scanning down rather than re-parsing each row.
struct ContentsList: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared

    private static let rowHeight: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.rows.isEmpty { empty } else { list }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(loc[.size]).frame(width: 78, alignment: .trailing)
            Text(loc[.share]).frame(width: 50, alignment: .trailing)
            Color.clear.frame(width: 44, height: 1)
            Text(loc[.name]).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var empty: some View {
        Text(model.filterText.isEmpty ? loc[.emptyFolder] : loc[.noMatches])
            .foregroundStyle(.secondary).font(.callout)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var list: some View {
        if model.renderMode {
            // A GeometryReader claims the space it is given instead of asking
            // for the height of its content, so rows cannot push the rest of
            // the window out of frame when there is no scroll view.
            GeometryReader { geo in
                let fits = max(1, Int(geo.size.height / Self.rowHeight))
                VStack(spacing: 0) {
                    ForEach(model.rows.prefix(fits)) { row in rowView(row) }
                    Spacer(minLength: 0)
                }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in rowView(row) }
                }
            }
        }
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        if row.hiddenSiblings > 0 {
            TruncationRow(row: row)
        } else {
            RowView(row: row,
                    selected: model.selection == row.id,
                    onToggle: { model.toggleExpanded(row.id) })
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if row.isDirectory { model.enter(row.id) } }
                .onTapGesture { model.select(row.id) }
                .contextMenu { menu(row) }
        }
    }

    @ViewBuilder private func menu(_ row: Row) -> some View {
        if row.hasChildren {
            Button(row.isExpanded ? loc[.collapseFolder] : loc[.expandFolder]) {
                model.toggleExpanded(row.id)
            }
        }
        if row.isDirectory { Button(loc[.openHere]) { model.enter(row.id) } }
        Button(loc[.revealInFinder]) { model.reveal(row.id) }
        Button(loc[.copyPath]) { model.copyPath(row.id) }
        Divider()
        Button(loc[.moveToTrash]) { model.requestTrash(row.id) }
    }
}

/// Stands in for entries beyond the per-level cap, so a truncated list still
/// says how much it is not showing.
private struct TruncationRow: View {
    let row: Row
    var body: some View {
        HStack(spacing: 8) {
            Text(shortBytes(row.physical))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 78, alignment: .trailing)
            Text(percentString(row.fractionOfParent))
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 50, alignment: .trailing)
            Color.clear.frame(width: 44, height: 1)
            Text(L10n.shared.moreRows(row.hiddenSiblings)).font(.system(size: 11))
            Spacer(minLength: 4)
        }
        .foregroundStyle(.tertiary)
        .padding(.leading, CGFloat(row.depth) * 14)
        .padding(.horizontal, 12).padding(.vertical, 3)
    }
}

private struct RowView: View {
    let row: Row
    let selected: Bool
    let onToggle: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Text(shortBytes(row.physical))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 78, alignment: .trailing)
                .foregroundStyle(row.physical == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))

            Text(percentString(row.fractionOfParent))
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 50, alignment: .trailing)
                .foregroundStyle(.secondary)

            bar

            // Indentation lives here, after the fixed columns, so the numbers
            // stay in one straight track however deep the tree goes.
            HStack(spacing: 4) {
                Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
                disclosure
                icon
                Text(row.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                badges
                Spacer(minLength: 4)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear)
    }

    @ViewBuilder private var disclosure: some View {
        if row.hasChildren {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.isExpanded ? L10n.shared[.collapseFolder] : L10n.shared[.expandFolder])
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    private var bar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(height: 6)
                RoundedRectangle(cornerRadius: 2)
                    .fill(row.category.color(scheme))
                    .frame(width: max(1, g.size.width * min(1, max(0, row.fractionOfParent))), height: 6)
            }
            .frame(height: g.size.height, alignment: .center)
        }
        .frame(width: 44, height: 16)
    }

    private var icon: some View {
        Image(systemName: row.isDirectory ? "folder.fill" : iconName(row.category))
            .font(.system(size: 11))
            .foregroundStyle(row.category.color(scheme))
            .frame(width: 14)
    }

    @ViewBuilder private var badges: some View {
        if row.flags.contains(.dataless) {
            Image(systemName: "icloud").font(.system(size: 9)).foregroundStyle(.tertiary)
                .help(L10n.shared[.icloudZero])
        }
        if row.flags.contains(.hardlinkDuplicate) {
            Image(systemName: "link").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        if row.flags.contains(.unreadable) {
            Image(systemName: "lock.fill").font(.system(size: 9))
                .foregroundStyle(Palette.warning(scheme))
        }
    }

    private func iconName(_ c: FileCategory) -> String {
        switch c {
        case .video: "film";                case .image: "photo"
        case .audio: "waveform";            case .archive: "shippingbox"
        case .document: "doc.text";         case .code: "chevron.left.forwardslash.chevron.right"
        case .application: "app";           case .diskImage: "externaldrive"
        case .virtualMachine: "desktopcomputer"
        case .model: "brain";               case .cache: "clock.arrow.circlepath"
        default: "doc"
        }
    }
}
struct DetailsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let item = model.selectedInfo { details(item) } else { placeholder }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func details(_ item: ItemInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(item.category.color(scheme))
                Text(item.name).font(.system(size: 13, weight: .semibold))
                    .lineLimit(2).truncationMode(.middle)
            }
            Text(item.path).font(.system(size: 10)).foregroundStyle(.tertiary)
                .lineLimit(3).truncationMode(.middle).textSelection(.enabled)

            HStack(spacing: 18) {
                stat(loc[.onDisk], shortBytes(item.physical))
                stat(loc[.apparent], shortBytes(item.logical))
                stat(loc[.ofVolume], percentString(item.fractionOfVolume))
            }

            if item.logical > item.physical * 2 {
                Label(loc[.apparentMismatch], systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button { model.reveal(item.node) } label: {
                    Label(loc[.reveal], systemImage: "arrow.right.circle")
                }
                Button(role: .destructive) { model.requestTrash(item.node) } label: {
                    Label(loc[.trash], systemImage: "trash")
                }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc[.nothingSelected]).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(loc[.nothingSelectedHint]).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }
}
