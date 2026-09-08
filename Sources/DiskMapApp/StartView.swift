import DiskMapCore
import SwiftUI

/// Picks what to measure: a whole volume, or any number of folders combined
/// into one total. Folders can be dropped straight onto the panel.
struct StartView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "internaldrive").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(loc[.chooseTarget]).font(.title3.weight(.medium))

            dropPanel.frame(width: 520)

            skipped.frame(width: 520).opacity(model.rejectedRoots.isEmpty ? 0 : 1)

            actions

            if !model.hasFullDiskAccess { accessWarning.padding(.top, 4) }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - One list of things to measure

    /// A disk and a folder are the same kind of thing here: a path to walk.
    ///
    /// They used to be two mechanisms — a picker that chose exactly one volume,
    /// shown only while no folder had been added, and a separate list of
    /// folders. Between them there was no way to measure two disks at once,
    /// which is the obvious thing to want from a tool that adds up space. Now
    /// there is one list. Tick the disks, add the folders, scan the lot.
    private var dropPanel: some View {
        VStack(spacing: 0) {
            sectionHeader(loc[.disksHeader])
            ForEach(model.volumes, id: \.path) { volume in
                Divider()
                diskRow(volume)
            }
            Divider()
            sectionHeader(loc[.foldersHeader], trailing: {
                Button(loc[.addMore]) { model.chooseFolders() }.controlSize(.mini)
            })
            Divider()
            // One shape, always. Ticking a disk can absorb a folder that was
            // inside it, and that must not resize the panel under the pointer.
            targetScroller {
                if folderTargets.isEmpty {
                    emptyFolders
                } else {
                    ForEach(folderTargets, id: \.self) { path in
                        folderRow(path)
                        Divider()
                    }
                }
            }
            .frame(height: 108)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: URL.self) { urls, _ in
            model.addTargets(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    /// Every folder that has been added, ticked or not, minus anything that is
    /// really one of the mounted disks.
    private var folderTargets: [String] {
        let disks = Set(model.volumes.map(\.path))
        return model.addedFolders.filter { !disks.contains($0) }
    }

    private func sectionHeader<T: View>(_ title: String,
                                        @ViewBuilder trailing: () -> T = { EmptyView() }) -> some View {
        HStack {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func diskRow(_ volume: VolumeInfo) -> some View {
        let on = model.isTargeted(volume)
        return HStack(spacing: 9) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            Image(systemName: volume.isRemovable ? "externaldrive" : "internaldrive")
                .foregroundStyle(.secondary)
            Text(volume.name).font(.system(size: 12, weight: on ? .medium : .regular))
            Text(volume.path).font(.system(size: 10)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(loc.usedOfTotal(shortBytes(volume.used), shortBytes(volume.total)))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(volume) }
    }

    /// The same shape as a disk row, because a disk and a folder are the same
    /// kind of thing here. It ticks, it unticks, and the × forgets it — three
    /// separate ideas that used to be one button.
    private func folderRow(_ path: String) -> some View {
        let covered = model.coveringTarget(path)
        let on = model.isTargeted(folder: path)
        return HStack(spacing: 9) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? AnyShapeStyle(covered == nil ? Color.accentColor : Color.secondary)
                                    : AnyShapeStyle(.tertiary))
            Image(systemName: "folder.fill")
                .foregroundStyle(FileCategory.folder.color(scheme))
            Text(path).font(.system(size: 11, weight: on ? .medium : .regular))
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            // Says why the tick will not move rather than letting the click
            // appear to do nothing.
            Text(covered == nil ? "" : loc[.alreadyCovered])
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .lineLimit(1)
            Button { model.forgetFolder(path) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain).help(loc[.forgetFolder])
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(folder: path) }
        .help(covered.map { loc.coveredBy($0) } ?? "")
    }

    private var emptyFolders: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.plus").font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Text(loc[.dropFolders]).font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    /// Offscreen rendering has no viewport, so a ScrollView shows nothing.
    @ViewBuilder private func targetScroller<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        viewportScroller(renderMode: model.renderMode) {
            VStack(spacing: 0, content: content)
        }
    }

    private var skipped: some View {
        viewportScroller(renderMode: model.renderMode) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.rejectedRoots.enumerated()), id: \.offset) { _, item in
                    Label(loc.rejectedNote(item.path, localizedReason(item.reason)),
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 34)
    }

    // MARK: - Actions

    private var actions: some View {
        Button(model.scanTargets.count == 1 ? loc[.scanWholeDisk]
                                            : loc.scanLocations(model.scanTargets.count)) {
            model.scan()
        }
        .keyboardShortcut(.defaultAction).controlSize(.large)
        .disabled(!model.canScan)
        .frame(width: 240)
    }

    private var accessWarning: some View {
        VStack(spacing: 6) {
            Label(loc[.fdaWarning], systemImage: "lock.fill")
                .font(.callout).foregroundStyle(Palette.warning(scheme))
            Button(loc[.openPrivacy]) { FileActions.openFullDiskAccessSettings() }
                .controlSize(.small)
        }
    }
}
