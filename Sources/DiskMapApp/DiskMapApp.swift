import DiskMapCore
import SwiftUI

@main
struct DiskMapApp: App {
    @StateObject private var model = AppModel()
    @ObservedObject private var loc = L10n.shared

    init() {
        // Runs before any window exists, so headless rendering stays headless.
        if MainActor.assumeIsolated({ OffscreenRenderer.runIfRequested() }) { exit(0) }
    }

    var body: some Scene {
        Window(L10n.shared[.appName], id: "main") {
            ContentView(model: model)
                .onAppear {
                    Telemetry.record("app.launch", [
                        "os": .text(ProcessInfo.processInfo.operatingSystemVersionString),
                        "cores": .int(Int64(ProcessInfo.processInfo.activeProcessorCount)),
                        "memory": .int(Int64(ProcessInfo.processInfo.physicalMemory)),
                    ])
                    // Lets the app be pointed at a folder from the command line.
                    if let p = ProcessInfo.processInfo.environment["DISKMAP_SCAN_PATH"] {
                        model.selectedVolumePath = p
                        model.refreshVolume()
                        model.scan()
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Picker(loc[.appearance], selection: $model.appearance) {
                    ForEach(Appearance.allCases) { a in Text(loc[a.key]).tag(a) }
                }
                Picker(loc[.language], selection: $loc.preference) {
                    ForEach(L10n.Language.allCases) { l in
                        Text(l == .system ? loc[.appearanceSystem] : l.nativeName).tag(l)
                    }
                }
                Divider()
                // The app measures itself; this is where those measurements
                // land. Local file, never sent anywhere.
                Button(loc[.showDiagnostics]) {
                    FileActions.revealInFinder([Telemetry.logURL])
                }
            }
            CommandMenu(loc[.scanMenu]) {
                Button(loc[.freeUpSpace]) { model.openCleanup() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button(loc[.whatChanged]) { model.openChanges() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button(loc[.rescan]) { model.scan() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button(loc[.goBack]) { model.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canGoBack)
                Button(loc[.goForward]) { model.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.canGoForward)
                Button(loc[.enclosingFolder]) { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.currentDirectory == 0)
                Divider()
                Button(loc[.revealInFinder]) { if let s = model.selection { model.reveal(s) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.selection == nil)
                Button(loc[.moveToTrash]) { if let s = model.selection { model.requestTrash(s) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection == nil)
                Button(loc[.undoTrash]) { model.undoLastTrash() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(model.undoStack.isEmpty)
            }
        }
    }
}
