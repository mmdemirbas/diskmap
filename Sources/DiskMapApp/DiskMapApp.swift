import AppKit
import DiskMapCore
import SwiftUI
import UniformTypeIdentifiers

/// Which window's session the menu bar is talking about.
///
/// With one window this was `model`, a field on the app. With several it has to
/// be a question rather than an answer: the Trash item has to empty the
/// selection of the window in front, not of whichever window happened to be
/// built first.
private struct FocusedModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[FocusedModelKey.self] }
        set { self[FocusedModelKey.self] = newValue }
    }
}

@main
struct DiskMapApp: App {
    init() {
        // Runs before any window exists, so headless rendering stays headless.
        if MainActor.assumeIsolated({ OffscreenRenderer.runIfRequested() }) { exit(0) }
    }

    var body: some Scene {
        // A group rather than a single window: one window is one session — one
        // scan, and the tools over it. Two disks at once is two windows, which
        // is also how the rest of the system answers that question.
        WindowGroup(L10n.shared[.appName]) {
            SessionWindow()
        }
        .commands {
            ExportCommands()
            SettingsCommands()
            ToolCommands()
            ScanCommands()
        }
    }
}

/// One window, one session. The model is made here rather than on the app, so
/// each window gets its own scan instead of all of them sharing one.
private struct SessionWindow: View {
    @StateObject private var model = AppModel()
    /// Whether this window is the one in front. Services and the menu bar both
    /// need to know, and there is no other way to ask from SwiftUI.
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        ContentView(model: model)
            .focusedSceneValue(\.appModel, model)
            .onAppear {
                // A service can arrive before anything is on screen, since
                // choosing one is what launches the app.
                ServicesProvider.shared.use(model)
                NSApplication.shared.servicesProvider = ServicesProvider.shared
                NSUpdateDynamicServices()
                Telemetry.record("app.launch", [
                    "os": .text(ProcessInfo.processInfo.operatingSystemVersionString),
                    "cores": .int(Int64(ProcessInfo.processInfo.activeProcessorCount)),
                    "memory": .int(Int64(ProcessInfo.processInfo.physicalMemory)),
                ])
                openLaunchPath()
            }
            .onChange(of: activeState) { _, state in
                if state == .key { ServicesProvider.shared.use(model) }
            }
    }

    /// Lets the app be pointed at a folder from the command line. Several,
    /// separated by colons, since a scan can measure any number of disks and
    /// folders as one total.
    private func openLaunchPath() {
        guard !LaunchPath.consumed,
              let spec = ProcessInfo.processInfo.environment["DISKMAP_SCAN_PATH"] else { return }
        LaunchPath.consumed = true
        model.clearTargets()
        model.addTargets(spec.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        model.scan()
    }
}

/// The folder named on the command line belongs to the first window. A second
/// window opened afterwards is a new session and starts empty, rather than a
/// copy of the first.
@MainActor private enum LaunchPath {
    static var consumed = false
}

// MARK: - The menu bar

/// Appearance and language are the app's, not a window's: both are stored
/// preferences and every window reads the same ones. Binding them here rather
/// than through a window's model keeps them working when no window is in front.
private struct SettingsCommands: Commands {
    @AppStorage("appearance") private var appearance: Appearance = .system
    @ObservedObject private var loc = L10n.shared

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Picker(loc[.appearance], selection: $appearance) {
                ForEach(Appearance.allCases) { a in Text(loc[a.key]).tag(a) }
            }
            Picker(loc[.language], selection: $loc.preference) {
                ForEach(L10n.Language.allCases) { l in
                    Text(l == .system ? loc[.appearanceSystem] : l.nativeName).tag(l)
                }
            }
            Divider()
            // The app measures itself; this is where those measurements land.
            // Local file, never sent anywhere.
            Button(loc[.showDiagnostics]) { FileActions.revealInFinder([Telemetry.logURL]) }
        }
    }
}

private struct ExportCommands: Commands {
    @FocusedValue(\.appModel) private var model
    @ObservedObject private var loc = L10n.shared

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button(loc[.exportResults]) { model?.exportResults() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model?.phase != .ready)
        }
    }
}

/// Every tool, in one place, in the order the home screen shows them. Three of
/// them used to be under Scan and the other four could not be opened from
/// anywhere at all.
private struct ToolCommands: Commands {
    @FocusedValue(\.appModel) private var model
    @ObservedObject private var loc = L10n.shared

    var body: some Commands {
        CommandMenu(loc[.tabHome]) {
            ForEach(ModuleTab.allCases) { tab in
                Button(loc[tab.key]) { model?.openTool(tab) }
                    .keyboardShortcut(tab.shortcut, modifiers: [.command, .shift])
                    .disabled(model == nil)
            }
        }
    }
}

private struct ScanCommands: Commands {
    @FocusedValue(\.appModel) private var model
    @ObservedObject private var loc = L10n.shared

    var body: some Commands {
        CommandMenu(loc[.scanMenu]) {
            Button(loc[.exclusions]) { model?.showExclusions = true }
            Divider()
            Button(loc[.rescan]) { model?.scan() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button(loc[.goBack]) { model?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(model?.canGoBack ?? false))
            Button(loc[.goForward]) { model?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(model?.canGoForward ?? false))
            Button(loc[.enclosingFolder]) { model?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model?.currentDirectory == 0)
            Divider()
            Button(loc[.revealInFinder]) { if let s = model?.selection { model?.reveal(s) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.selection == nil)
            Button(loc[.moveToTrash]) { if let s = model?.selection { model?.requestTrash(s) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model?.selection == nil)
            Button(loc[.undoTrash]) { model?.undoLastTrash() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(model?.undoStack.isEmpty ?? true)
        }
    }
}
