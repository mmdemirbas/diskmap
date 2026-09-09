import DiskMapCore
import SwiftUI

/// The window, divided between the tools that are open.
///
/// The tools were tabs: one on screen, the rest behind it. They are now panes
/// in the same dock the map uses for its own views, one level up — drag a
/// tool's tab onto the edge of another to put the two side by side, onto the
/// middle to make them tabs of one group. The map ends up as a dock inside a
/// dock, which is exactly what it is: a tool with its own arrangement inside.
///
/// Home and the map keep no close button. The window always has something in
/// it, and the map is the scan rather than a view of it.
struct ToolDockView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        DockView(layout: model.tools,
                 actions: DockActions(activate: { model.activeTab = $0 },
                                      close: model.close,
                                      add: model.addTool,
                                      move: model.moveTool,
                                      ratio: model.setToolRatio),
                 space: "dock.tools") { tool in
            content(tool)
        } footer: {
            EmptyView()
        }
    }

    @ViewBuilder private func content(_ tool: ModuleTab) -> some View {
        switch tool {
        case .home:       HomeView(model: model)
        case .map:        MapTool(model: model)
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
}
