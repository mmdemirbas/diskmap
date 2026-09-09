import DiskMapCore
import SwiftUI

/// What still belongs over the window rather than beside it.
///
/// The tools stopped being sheets because opening one closed another, and are
/// now panes in a dock. Two things stayed sheets on purpose: the never-touch
/// list is a settings dialog, and the confirmation before the Trash is a
/// decision point — letting the tree move while that one is being read is the
/// drift the safety review spent eight passes closing.
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

    var body: some View {
        ToolDockView(model: model)
        // The map's toolbar carries the breadcrumb plus five controls; below
        // this the breadcrumb is squeezed to nothing before anything else
        // gives way.
        .frame(minWidth: 1080, minHeight: 640)
        // Explicit, rather than inheriting whatever the window happens to be:
        // without it the panels stay light while dark-mode text turns white.
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(model.appearance.colorScheme)
        .modifier(Sheets(model: model))
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
