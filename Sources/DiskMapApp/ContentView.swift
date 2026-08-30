import DiskMapCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showReconciliation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.phase {
            case .idle:            StartView(model: model)
            case .scanning(let p): ScanningView(progress: p)
            case .failed(let msg): failure(msg)
            case .ready:           results
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .sheet(isPresented: $showReconciliation) {
            if let v = model.volume {
                ReconciliationSheet(volume: v, reconciliation: model.reconciliation, stats: model.stats)
            }
        }
    }

    @ViewBuilder private var header: some View {
        if let v = model.volume {
            CapacityBar(volume: v) { showReconciliation = true }
        }
    }

    private func failure(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Palette.warning)
            Text(msg).foregroundStyle(.secondary)
            Button("Try Again") { model.scan() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            // HSplitView is an AppKit-backed control and cannot be drawn by
            // ImageRenderer, so offscreen rendering uses a fixed split instead.
            if model.renderMode {
                HStack(spacing: 0) {
                    TreemapView(model: model)
                    Divider()
                    sidePanel.frame(width: 360)
                }
            } else {
                HSplitView {
                    TreemapView(model: model).frame(minWidth: 420)
                    sidePanel.frame(minWidth: 320, idealWidth: 360, maxWidth: 520)
                }
            }
            Divider()
            statusBar
        }
    }

    private var sidePanel: some View {
        VStack(spacing: 0) {
            DetailsPanel(model: model)
            Divider()
            ContentsList(model: model)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                .disabled(model.currentDirectory == 0)
                .help("Go to enclosing folder")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { idx, crumb in
                        if idx > 0 {
                            Image(systemName: "chevron.right").font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        Button(crumb.name.isEmpty ? "/" : crumb.name) { model.enter(crumb.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12,
                                          weight: idx == model.breadcrumb.count - 1 ? .semibold : .regular))
                            .foregroundStyle(idx == model.breadcrumb.count - 1 ? .primary : .secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            TextField("Filter", text: $model.filterText)
                .textFieldStyle(.roundedBorder).frame(width: 150)
                .onChange(of: model.filterText) { _, _ in model.rebuild() }

            Picker("", selection: $model.usePhysicalSize) {
                Text("On disk").tag(true)
                Text("Apparent").tag(false)
            }
            .pickerStyle(.segmented).frame(width: 150)
            .onChange(of: model.usePhysicalSize) { _, _ in model.rebuild() }
            .help("On disk = bytes actually allocated. Apparent = size reported by the file.")

            Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if let s = model.stats {
                Text("\((s.files + s.directories).formatted()) items")
                Text("scanned in \(String(format: "%.1fs", s.elapsed))")
                if s.unreadableDirectories > 0 {
                    Button {
                        FileActions.openFullDiskAccessSettings()
                    } label: {
                        Label("\(s.unreadableDirectories) folders unreadable — grant Full Disk Access",
                              systemImage: "lock.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.warning)
                }
            }
            Spacer()
            if let t = model.toast {
                Text(t).foregroundStyle(.secondary)
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        if model.toast == t { model.toast = nil }
                    }
            }
            if !model.undoStack.isEmpty {
                Button("Undo Trash") { model.undoLastTrash() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            HStack(spacing: 5) {
                Circle().fill(model.liveActive ? .green : .gray).frame(width: 7, height: 7)
                Text(model.liveActive ? "watching" : "not watching")
            }
            .help("Changes on disk update this view automatically")
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }
}

struct StartView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "internaldrive").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("Choose what to measure").font(.title3.weight(.medium))

            Picker("Volume", selection: $model.selectedVolumePath) {
                ForEach(model.volumes, id: \.path) { v in
                    Text("\(v.name) — \(shortBytes(v.used)) used").tag(v.path)
                }
            }
            .frame(width: 340)
            .onChange(of: model.selectedVolumePath) { _, _ in model.refreshVolume() }

            HStack(spacing: 10) {
                Button("Scan Volume") { model.scan() }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
                Button("Scan Home Folder…") {
                    model.selectedVolumePath = NSHomeDirectory()
                    model.refreshVolume()
                    model.scan()
                }
                .controlSize(.large)
            }

            if !model.hasFullDiskAccess {
                VStack(spacing: 6) {
                    Label("Without Full Disk Access some folders will be invisible and the totals will be short.",
                          systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(Palette.warning)
                    Button("Open Privacy Settings") { FileActions.openFullDiskAccessSettings() }
                        .controlSize(.small)
                }
                .padding(.top, 6)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScanningView: View {
    let progress: ScanProgressSnapshot

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
            Text("\(progress.nodes.formatted()) items · \(progress.directories.formatted()) folders · \(shortBytes(progress.bytes))")
                .font(.system(size: 12, design: .monospaced))
            Text(progress.path).font(.caption).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).frame(width: 460)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
