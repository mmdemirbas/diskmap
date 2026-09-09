import DiskMapCore
import SwiftUI

/// What still belongs over the window rather than beside it.
///
/// The five tools became tabs, because opening one used to close another. Two
/// things stayed sheets on purpose: the never-touch list is a settings dialog,
/// and the confirmation before the Trash is a decision point — letting the
/// tree move while that one is being read is the drift the safety review spent
/// eight passes closing.
private struct Sheets: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { model.showExclusions },
                                        set: { model.showExclusions = $0 })) {
                ExclusionsView(model: model)
            }
            .sheet(isPresented: Binding(get: { model.showCompareIgnore },
                                        set: { model.showCompareIgnore = $0 })) {
                CompareIgnoreView(model: model)
            }
            .sheet(isPresented: Binding(get: { model.reviewing != nil },
                                        set: { if !$0 { model.cancelBulkTrash() } })) {
                TrashConfirmView(model: model, groups: model.reviewing ?? [])
            }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme
    /// Which volume's breakdown is open, rather than whether *a* breakdown is.
    /// With two disks measured together, "the reconciliation" was one screen
    /// built from both and shown for either.
    @State private var explaining: VolumeInfo?

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
            Divider()
            openTool
        }
        // The toolbar carries the breadcrumb plus five controls; below this the
        // breadcrumb is squeezed to nothing before anything else gives way.
        .frame(minWidth: 1080, minHeight: 640)
        // Explicit, rather than inheriting whatever the window happens to be:
        // without it the panels stay light while dark-mode text turns white.
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(model.appearance.colorScheme)
        .modifier(Sheets(model: model))
        .sheet(item: $explaining) { volume in
            ReconciliationSheet(volume: volume,
                                reconciliation: model.reconciliation(for: volume),
                                renderMode: model.renderMode)
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .confirmationDialog(loc[.startOverTitle],
                            isPresented: Binding(get: { model.pendingNewScan },
                                                 set: { model.pendingNewScan = $0 }),
                            titleVisibility: .visible) {
            Button(loc[.startOverConfirm], role: .destructive) {
                model.pendingNewScan = false
                model.newScan()
            }
            Button(loc[.cancel], role: .cancel) { model.pendingNewScan = false }
        } message: {
            Text(loc[.startOverBody])
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
            Text(pending.isDirectory
                 ? loc.confirmTrashBody(pending.itemCount, shortBytes(pending.bytes))
                 : loc.confirmTrashFileBody(shortBytes(pending.bytes)))
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

    /// Whichever tool is in front. Only the map waits for a scan — comparing
    /// two folders reads them directly, so it opens from a cold launch.
    @ViewBuilder private var openTool: some View {
        switch model.activeTab {
        case .home:       HomeView(model: model)
        case .map:        mapTab
        case .files:      needsScan { FilesView(model: model) }
        case .space:      needsScan { CleanupView(model: model) }
        case .duplicates: needsScan { CopiesView(model: model) }
        case .compare:    CompareView(model: model)
        case .search:     needsScan { FindView(model: model) }
        case .changes:    needsScan { ChangesView(model: model) }
        }
    }

    /// A tool that reads the scanned tree cannot show anything before there is
    /// one. Saying so and offering to scan beats an empty screen that looks
    /// like an answer.
    @ViewBuilder private func needsScan<Content: View>(
        @ViewBuilder _ content: () -> Content) -> some View {
        if model.tree != nil {
            content()
        } else {
            VStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: 26)).foregroundStyle(.tertiary)
                Text(loc[.needsAScan]).foregroundStyle(.secondary)
                Button(loc[.chooseWhatToScan]) { model.activeTab = .map }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var mapTab: some View {
        switch model.phase {
        case .idle:            StartView(model: model)
        case .scanning(let p): ScanningView(progress: p) { model.stopScanning() }
        case .failed(let msg): failure(msg)
        case .ready:           results
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            // One bar per disk being measured, and only here. How full a disk
            // is answers a question the map asks; it says nothing about a
            // folder comparison or a search, and standing above every tool it
            // read as a header belonging to all of them.
            ForEach(model.targetedVolumes) { v in
                CapacityBar(volume: v) { explaining = v }
                Divider()
            }
            toolbar
            Divider()
            // Was a fixed split: one picture on the left, one table on the
            // right, each chosen from a segmented picker. Those seven views are
            // not alternatives to each other, so the area is now divided the
            // way the user divided it.
            //
            // The details panel stays outside the dock. It describes whatever
            // is selected, wherever that selection was made, so it belongs to
            // the window rather than to one pane — and it is the panel the
            // no-drift work pinned to a fixed height.
            HStack(spacing: 0) {
                DockView(model: model)
                Divider()
                // An inspector: fixed width, pinned to the top, its own
                // background. The space below it is empty because there is
                // nothing else to say about one selection — the same shape
                // every inspector on this platform has.
                DetailsPanel(model: model)
                    .frame(width: 320, alignment: .top)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color(nsColor: .controlBackgroundColor))
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

            viewportScroller(renderMode: model.renderMode, axis: .horizontal) {
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
                .textFieldStyle(.roundedBorder).frame(width: 120)
                .onChange(of: model.filterText) { _, _ in model.rebuild() }

            Button { model.openFind() } label: { Image(systemName: "magnifyingglass") }
                .help(loc[.findTitle]).keyboardShortcut("f", modifiers: .command)

            Button { model.openCompare() } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help(loc[.compareTitle])

            Button { model.openCleanup() } label: {
                Label(loc[.freeUpSpace], systemImage: "sparkles")
            }
            .help(loc[.freeUpSpace])

            Picker("", selection: $model.colourMode) {
                ForEach(ColourMode.allCases) { c in Text(loc[c.shortKey]).tag(c) }
            }
            .pickerStyle(.segmented).frame(width: 104).labelsHidden()
            .help(loc[.colourBy])

            Picker("", selection: $model.usePhysicalSize) {
                Text(loc[.onDisk]).tag(true)
                Text(loc[.apparent]).tag(false)
            }
            .pickerStyle(.segmented).frame(width: 148).labelsHidden()
            .onChange(of: model.usePhysicalSize) { _, _ in model.rebuild() }
            .help(loc[.sizeMetricHelp])

            HStack(spacing: 2) {
                // Was a magnifier with a plus on it, which is the zoom-in
                // glyph everywhere else. This button throws the scan away and
                // goes back to the list of things to measure.
                Button { model.requestNewScan() } label: { Image(systemName: "checklist") }
                    .help(loc[.newScanHelp])
                Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                    .help(loc[.rescan])
            }

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
            // Reserved, not conditional. Appearing after a trash would shove
            // the watching indicator to its left, and the one moment the user
            // is looking at that indicator is right after something moved.
            Button(loc[.undoTrash]) { model.undoLastTrash() }
                .buttonStyle(.link).font(.system(size: 11))
                .disabled(model.undoStack.isEmpty)
                .opacity(model.undoStack.isEmpty ? 0 : 1)
                .accessibilityHidden(model.undoStack.isEmpty)
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
