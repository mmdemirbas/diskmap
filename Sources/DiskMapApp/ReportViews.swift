import DiskMapCore
import SwiftUI

/// The biggest files anywhere below the current folder.
///
/// The tree table answers "what is in this folder"; this answers "what should I
/// delete", which usually means one 40 GB video buried six levels down rather
/// than anything visible at the level you happen to be browsing.
struct LargestFilesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            if model.summarizing {
                ProgressView().controlSize(.small).padding(.vertical, 14)
                Text(loc[.computing]).font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else if model.largeFiles.isEmpty {
                Text(loc[.emptyFolder]).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                rows
            }
        }
    }

    private static let rowHeight: CGFloat = 31

    @ViewBuilder private var rows: some View {
        if model.renderMode {
            // A GeometryReader takes the space it is given rather than asking
            // for the height of its content, so rows cannot stretch the window.
            GeometryReader { geo in
                let fits = max(1, Int(geo.size.height / Self.rowHeight))
                VStack(spacing: 0) {
                    ForEach(model.largeFiles.prefix(fits)) { file in row(file) }
                    Spacer(minLength: 0)
                }
            }
        } else {
            ScrollView { LazyVStack(spacing: 0) { ForEach(model.largeFiles) { file in row(file) } } }
        }
    }

    private func row(_ file: LargeFile) -> some View {
        HStack(spacing: 8) {
            Text(shortBytes(file.bytes))
        .font(.system(size: 11, design: .monospaced))
        .frame(width: 78, alignment: .trailing)
            Image(systemName: "doc.fill").font(.system(size: 10))
        .foregroundStyle(file.category.color(scheme)).frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
        Text(file.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
        Text(file.path).font(.system(size: 9)).foregroundStyle(.tertiary)
            .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .background(model.selection == file.id ? Color.accentColor.opacity(0.22) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.select(file.id) }
        .onTapGesture(count: 2) { model.reveal(file.id) }
        .contextMenu {
            Button(loc[.revealInFinder]) { model.reveal(file.id) }
            Button(loc[.copyPath]) { model.copyPath(file.id) }
            Divider()
            Button(loc[.moveToTrash]) { model.requestTrash(file.id) }
        }
    }
}

/// Where the space went by kind of file, and by how long ago it was touched.
struct TypeBreakdownView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if model.summarizing {
            VStack {
                ProgressView().controlSize(.small)
                Text(loc[.computing]).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let summary = model.summary {
            scroller {
                VStack(alignment: .leading, spacing: 14) {
                    section(loc[.panelTypes], summary.byCategory.map {
                        ($0.category.localizedLabel, $0.bytes, $0.files, $0.category.color(scheme))
                    }, total: summary.totalPhysical)

                    section(loc[.colourByAge], summary.byAge.filter { $0.bytes > 0 }.map {
                        ($0.bucket.localizedLabel, $0.bytes, $0.files, $0.bucket.color(scheme))
                    }, total: summary.totalPhysical)

                    if let stale = summary.byAge.first(where: { $0.bucket == .older }), stale.bytes > 0 {
                        Label("\(shortBytes(stale.bytes)) \(loc[.staleNote])", systemImage: "clock.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
        } else {
            Color.clear
        }
    }

    private func section(_ title: String,
                         _ items: [(String, Int64, Int, Color)],
                         total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                Spacer()
                Text(loc[.ofSubtree]).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Text(shortBytes(item.1)).font(.system(size: 11, design: .monospaced))
                        .frame(width: 74, alignment: .trailing)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(height: 8)
                            RoundedRectangle(cornerRadius: 2).fill(item.3)
                                .frame(width: max(2, g.size.width * fraction(item.1, total)), height: 8)
                        }
                        .frame(height: g.size.height, alignment: .center)
                    }
                    .frame(height: 14)
                    Text(item.0).font(.system(size: 11)).frame(width: 110, alignment: .leading)
                }
            }
        }
    }

    private func fraction(_ value: Int64, _ total: Int64) -> CGFloat {
        total > 0 ? min(1, CGFloat(value) / CGFloat(total)) : 0
    }

    /// Offscreen rendering has no viewport, so a ScrollView draws nothing.
    @ViewBuilder private func scroller<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if model.renderMode {
            VStack(spacing: 0) { content(); Spacer(minLength: 0) }
                .frame(maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollView { content() }
        }
    }
}
