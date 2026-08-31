import DiskMapCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme
    @State private var showReconciliation = false

    var body: some View {
        VStack(spacing: 0) {
            if let v = model.volume {
                CapacityBar(volume: v) { showReconciliation = true }
                Divider()
            }
            switch model.phase {
            case .idle:            StartView(model: model)
            case .scanning(let p): ScanningView(progress: p) { model.cancelScan(); model.phase = .idle }
            case .failed(let msg): failure(msg)
            case .ready:           results
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        // Explicit, rather than inheriting whatever the window happens to be:
        // without it the panels stay light while dark-mode text turns white.
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(model.appearance.colorScheme)
        .sheet(isPresented: $showReconciliation) {
            if let v = model.volume {
                ReconciliationSheet(volume: v, reconciliation: model.reconciliation, stats: model.stats)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .preferredColorScheme(model.appearance.colorScheme)
            }
        }
        .confirmationDialog(
            model.pendingTrash.map { loc.confirmTrashTitle($0.name) } ?? "",
            isPresented: Binding(get: { model.pendingTrash != nil },
                                 set: { if !$0 { model.pendingTrash = nil } }),
            presenting: model.pendingTrash
        ) { pending in
            Button(loc[.moveToTrash], role: .destructive) { model.confirmPendingTrash() }
            Button(loc[.cancel], role: .cancel) { model.pendingTrash = nil }
        } message: { pending in
            Text(loc.confirmTrashBody(pending.itemCount, shortBytes(pending.bytes)))
        }
    }

    private func failure(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                .foregroundStyle(Palette.warning(scheme))
            Text(msg).foregroundStyle(.secondary)
            Button(loc[.tryAgain]) { model.scan() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            // HSplitView is AppKit-backed and cannot be drawn by ImageRenderer,
            // so offscreen rendering uses a fixed split instead.
            if model.renderMode {
                HStack(spacing: 0) {
                    TreemapView(model: model)
                    Divider()
                    sidePanel.frame(width: 470)
                }
            } else {
                HSplitView {
                    TreemapView(model: model).frame(minWidth: 420)
                    sidePanel.frame(minWidth: 340, idealWidth: 470, maxWidth: 680)
                }
            }
            Divider()
            statusBar
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addTargets(urls)
            model.scan()
            return true
        }
    }

    private var sidePanel: some View {
        VStack(spacing: 0) {
            DetailsPanel(model: model)
            Divider()
            ContentsList(model: model)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack).help(loc[.goBack])
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward).help(loc[.goForward])
                Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                    .disabled(model.currentDirectory == 0)
                    .help(loc[.enclosingFolder])
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { idx, crumb in
                        if idx > 0 {
                            Image(systemName: "chevron.right").font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        Button(crumbLabel(crumb)) { model.enter(crumb.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12,
                                          weight: idx == model.breadcrumb.count - 1 ? .semibold : .regular))
                            .foregroundStyle(idx == model.breadcrumb.count - 1
                                             ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(idx == model.breadcrumb.count - 1
                                      ? Color.secondary.opacity(0.14) : Color.clear))
                            .contentShape(Rectangle())
                    }
                }
            }

            Spacer(minLength: 8)

            TextField(loc[.filter], text: $model.filterText)
                .textFieldStyle(.roundedBorder).frame(width: 150)
                .onChange(of: model.filterText) { _, _ in model.rebuild() }

            Picker("", selection: $model.usePhysicalSize) {
                Text(loc[.onDisk]).tag(true)
                Text(loc[.apparent]).tag(false)
            }
            .pickerStyle(.segmented).frame(width: 170).labelsHidden()
            .onChange(of: model.usePhysicalSize) { _, _ in model.rebuild() }
            .help(loc[.sizeMetricHelp])

            Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                .help(loc[.rescan])

            settingsMenu
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    /// The synthetic root of a multi-folder scan has no path to show.
    private func crumbLabel(_ crumb: (id: Int32, name: String)) -> String {
        guard crumb.name.isEmpty else { return crumb.name }
        return model.rootLabel
    }

    private var settingsMenu: some View {
        Menu {
            Picker(loc[.appearance], selection: $model.appearance) {
                ForEach(Appearance.allCases) { a in Text(loc[a.key]).tag(a) }
            }
            Picker(loc[.language], selection: $loc.preference) {
                ForEach(L10n.Language.allCases) { l in
                    Text(l == .system ? loc[.appearanceSystem] : l.nativeName).tag(l)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 34)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if let s = model.stats {
                Text(loc.itemCount(s.files + s.directories))
                Text(loc.scannedIn(s.elapsed))
                if model.rootsSpanVolumes {
                    Label(loc[.multipleVolumesNote], systemImage: "externaldrive")
                        .foregroundStyle(.secondary)
                }
                if s.unreadableDirectories > 0 {
                    Button { FileActions.openFullDiskAccessSettings() } label: {
                        Label(loc.unreadableWarning(s.unreadableDirectories), systemImage: "lock.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.warning(scheme))
                }
            }
            Spacer()
            if let toast = model.toast {
                Text(toast).foregroundStyle(.secondary)
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        if model.toast == toast { model.toast = nil }
                    }
            }
            if !model.undoStack.isEmpty {
                Button(loc[.undoTrash]) { model.undoLastTrash() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            HStack(spacing: 5) {
                Circle().fill(model.liveActive ? .green : .gray).frame(width: 7, height: 7)
                Text(model.liveActive ? loc[.watching] : loc[.notWatching])
            }
            .help(loc[.watchHelp])
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }
}

struct ScanningView: View {
    let progress: ScanProgressSnapshot
    var onCancel: () -> Void
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            if let f = progress.fraction {
                ProgressView(value: f).frame(width: 360)
                Text(percentString(f)).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().frame(width: 360)
            }
            Text("\(loc.itemCount(progress.nodes)) · \(loc.folderCount(progress.directories)) · \(shortBytes(progress.bytes))")
                .font(.system(size: 12, design: .monospaced))
            Text(progress.path).font(.caption).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).frame(width: 460)
            Button(loc[.cancelScan], action: onCancel).controlSize(.small).padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
