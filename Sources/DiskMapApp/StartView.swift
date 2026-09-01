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

            if !model.rejectedRoots.isEmpty { skipped.frame(width: 520) }

            actions

            if !model.hasFullDiskAccess { accessWarning.padding(.top, 4) }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drop panel

    private var dropPanel: some View {
        VStack(spacing: 0) {
            if model.scanTargets.isEmpty { emptyDropZone } else { targetList }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1,
                                                 dash: model.scanTargets.isEmpty ? [6, 4] : [])))
        .dropDestination(for: URL.self) { urls, _ in
            model.addTargets(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus").font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(loc[.dropFolders]).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(loc[.orWord]).font(.caption).foregroundStyle(.tertiary)
                Button(loc[.chooseFolders]) { model.chooseFolders() }.controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private var targetList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(loc[.targetsHeader]).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(loc[.addMore]) { model.chooseFolders() }.controlSize(.mini)
                Button(loc[.clearTargets]) { model.clearTargets() }.controlSize(.mini)
            }
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 5)

            Divider()

            targetScroller {
                    ForEach(model.scanTargets, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(FileCategory.folder.color(scheme))
                                .font(.system(size: 11))
                            Text(path).font(.system(size: 11))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 6)
                            Button { model.removeTarget(path) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                    }
            }
            .frame(maxHeight: 150)
        }
    }

    /// Offscreen rendering has no viewport, so a ScrollView shows nothing.
    @ViewBuilder private func targetScroller<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        viewportScroller(renderMode: model.renderMode) {
            VStack(spacing: 0, content: content)
        }
    }

    private var skipped: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(model.rejectedRoots.enumerated()), id: \.offset) { _, item in
                Label(loc.rejectedNote(item.path, localizedReason(item.reason)),
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    @ViewBuilder private var actions: some View {
        if model.scanTargets.isEmpty {
            HStack(spacing: 10) {
                Picker("", selection: $model.selectedVolumePath) {
                    ForEach(model.volumes, id: \.path) { v in
                        Text("\(v.name) — \(shortBytes(v.used))").tag(v.path)
                    }
                }
                .labelsHidden().frame(width: 260)
                .onChange(of: model.selectedVolumePath) { _, _ in model.refreshVolume() }

                Button(loc[.scanWholeDisk]) { model.scan() }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            }
        } else {
            Button(loc.scanLocations(model.scanTargets.count)) { model.scan() }
                .keyboardShortcut(.defaultAction).controlSize(.large)
        }
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
