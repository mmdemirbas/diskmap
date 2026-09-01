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

    /// Every row exists whether or not anything is selected.
    ///
    /// Selecting a file used to replace a two-line placeholder with a five-row
    /// block, so the panel roughly tripled in height and the list below it
    /// jumped down. Two of those rows were themselves conditional — the path
    /// took one, two or three lines, and a note appeared only for files whose
    /// apparent size ran ahead of their blocks — so the panel also moved
    /// between one selection and the next.
    ///
    /// The layout is now the same shape at all times. Selecting fills the rows
    /// in; it never adds one. Nothing below this panel moves, ever.
    /// The panel is this tall, always.
    ///
    /// Reserving space row by row gets close and does not get there: text that
    /// really wraps onto a second line pays for the gap between lines, while
    /// text merely reserving two lines does not, so a long path still moved the
    /// panel by two points against a short one. Two points is still the list
    /// jumping under the pointer. The height is therefore fixed outright, and
    /// `testNothingIsClipped` is what keeps the number honest: it fails if any
    /// selection, in any language, needs more room than this.
    static let height: CGFloat = 168

    var body: some View {
        content
            .frame(height: Self.height, alignment: .topLeading)
            .clipped()
    }

    /// The panel's natural size, before it is pinned. Separate so a test can
    /// measure what it would have wanted.
    var content: some View {
        let item = model.selectedInfo
        return VStack(alignment: .leading, spacing: 10) {
            heading(item)
            subtitle(item)
            figures(item)
            actions(item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func heading(_ item: ItemInfo?) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: item.map { $0.isDirectory ? "folder.fill" : "doc.fill" }
                              ?? "square.dashed")
                .foregroundStyle(item.map { AnyShapeStyle($0.category.color(scheme)) }
                                 ?? AnyShapeStyle(.tertiary))
                .padding(.top, 1)
            // Two lines always: one long name must not push the panel taller
            // than the short name that preceded it.
            Text(item?.name ?? loc[.nothingSelected])
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(2, reservesSpace: true)
                .lineSpacing(0)
                .truncationMode(.middle)
        }
    }

    private func subtitle(_ item: ItemInfo?) -> some View {
        Text(item?.path ?? loc[.nothingSelectedHint])
            .font(.system(size: 10)).foregroundStyle(.tertiary)
            .lineLimit(2, reservesSpace: true)
            .lineSpacing(0)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    private func figures(_ item: ItemInfo?) -> some View {
        HStack(alignment: .top, spacing: 18) {
            figure(loc[.onDisk], item.map { shortBytes($0.physical) })
            // The note about apparent size belongs beside the number it is
            // about, not on a row of its own that exists for some files and
            // not others. As a mark in the label it costs no height at all.
            figure(loc[.apparent], item.map { shortBytes($0.logical) },
                   flagged: item.map { $0.logical > $0.physical * 2 } ?? false)
            figure(loc[.ofVolume], item.map { percentString($0.fractionOfVolume) })
            Spacer(minLength: 0)
        }
    }

    private func figure(_ label: String, _ value: String?, flagged: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
                    .lineLimit(1, reservesSpace: true)
                Image(systemName: "info.circle").font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .opacity(flagged ? 1 : 0)
                    .accessibilityHidden(!flagged)
                    .help(loc[.apparentMismatch])
            }
            // Reserved rather than merely present: a line box sized by the
            // glyphs in it is two points shorter for a dash than for digits,
            // and two points is still the panel moving.
            Text(value ?? "—")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1, reservesSpace: true)
                .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
    }

    /// Present and disabled rather than absent: what can be done with a
    /// selection is worth knowing before there is one.
    private func actions(_ item: ItemInfo?) -> some View {
        HStack(spacing: 8) {
            Button { if let item { model.reveal(item.node) } } label: {
                Label(loc[.reveal], systemImage: "arrow.right.circle")
            }
            .disabled(item == nil)
            Button(role: .destructive) { if let item { model.requestTrash(item.node) } } label: {
                Label(loc[.trash], systemImage: "trash")
            }
            .disabled(item == nil)
            Spacer()
        }
        .controlSize(.small)
    }
}
