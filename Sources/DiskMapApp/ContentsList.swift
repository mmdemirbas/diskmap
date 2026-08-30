import DiskMapCore
import SwiftUI

/// One column track per field, so a folder's size is read by scanning straight
/// down rather than re-parsing every row. Name goes last because it is the only
/// field of unbounded width.
struct ContentsList: View {
    @ObservedObject var model: AppModel

    /// Scrolling and lazy stacks only materialise rows against a real viewport,
    /// which offscreen rendering does not have.
    @ViewBuilder private func scroller<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if model.renderMode {
            VStack(spacing: 0) { content(); Spacer(minLength: 0) }
        } else {
            ScrollView { LazyVStack(spacing: 0, content: content) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Size").frame(width: 74, alignment: .trailing)
                Text("Share").frame(width: 48, alignment: .trailing)
                Text("").frame(width: 62)
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.vertical, 6)

            Divider()

            if model.rows.isEmpty {
                VStack(spacing: 4) {
                    Text(model.filterText.isEmpty ? "Empty folder" : "Nothing matches")
                        .foregroundStyle(.secondary).font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                scroller {
                    Group {
                        ForEach(model.renderMode ? Array(model.rows.prefix(30)) : model.rows) { row in
                            RowView(row: row, selected: model.selection == row.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { if row.isDirectory { model.enter(row.id) } }
                                .onTapGesture { model.select(row.id) }
                                .contextMenu {
                                    if row.isDirectory { Button("Open in Disk Map") { model.enter(row.id) } }
                                    Button("Reveal in Finder") { model.reveal(row.id) }
                                    Button("Copy Path") { model.copyPath(row.id) }
                                    Divider()
                                    Button("Move to Trash") { model.moveToTrash(row.id) }
                                }
                        }
                    }
                }
            }
        }
    }
}

private struct RowView: View {
    let row: Row
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(shortBytes(row.physical))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 74, alignment: .trailing)
                .foregroundStyle(row.physical == 0 ? .tertiary : .primary)

            Text(percentString(row.fractionOfParent))
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 48, alignment: .trailing)
                .foregroundStyle(.secondary)

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(row.category.color)
                        .frame(width: max(1, g.size.width * min(1, row.fractionOfParent)), height: 6)
                }
                .frame(height: g.size.height, alignment: .center)
            }
            .frame(width: 62, height: 16)

            Image(systemName: row.isDirectory ? "folder.fill" : iconName(row.category))
                .font(.system(size: 11))
                .foregroundStyle(row.category.color)
                .frame(width: 14)

            Text(row.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)

            if row.flags.contains(.dataless) {
                Image(systemName: "icloud").font(.system(size: 9)).foregroundStyle(.tertiary)
                    .help("iCloud placeholder: 0 bytes on this disk")
            }
            if row.flags.contains(.hardlinkDuplicate) {
                Image(systemName: "link").font(.system(size: 9)).foregroundStyle(.tertiary)
                    .help("Hard link to a file already counted")
            }
            if row.flags.contains(.unreadable) {
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Palette.warning)
                    .help("Could not be read. Full Disk Access may be needed.")
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.20) : .clear)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = model.selectedInfo {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(item.category.color)
                        Text(item.name).font(.system(size: 13, weight: .semibold))
                            .lineLimit(2).truncationMode(.middle)
                    }
                    Text(item.path).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(3).truncationMode(.middle).textSelection(.enabled)

                    HStack(spacing: 18) {
                        stat("On disk", shortBytes(item.physical))
                        stat("Apparent", shortBytes(item.logical))
                        stat("Of volume", percentString(item.fractionOfVolume))
                    }

                    if item.logical > item.physical * 2 && item.physical >= 0 {
                        Label("Apparent size is far larger than the bytes on disk. iCloud placeholders, sparse files or compression.",
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Button { model.reveal(item.node) } label: {
                            Label("Reveal", systemImage: "arrow.right.circle")
                        }
                        Button(role: .destructive) { model.moveToTrash(item.node) } label: {
                            Label("Trash", systemImage: "trash")
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                }
                .padding(12)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing selected").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Click a rectangle or a row. Double-click a folder to go inside.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }
}
