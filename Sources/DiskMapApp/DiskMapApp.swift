import DiskMapCore
import SwiftUI

@main
struct DiskMapApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Runs before any window exists, so headless rendering stays headless.
        if MainActor.assumeIsolated({ OffscreenRenderer.runIfRequested() }) { exit(0) }
    }

    var body: some Scene {
        Window("Disk Map", id: "main") {
            ContentView(model: model)
                .onAppear {
                    // Lets the app be pointed at a folder from the command line,
                    // and gives the UI a deterministic starting state to test.
                    if let p = ProcessInfo.processInfo.environment["DISKMAP_SCAN_PATH"] {
                        model.selectedVolumePath = p
                        model.refreshVolume()
                        model.scan()
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Rescan") { model.scan() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Enclosing Folder") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button("Reveal in Finder") { if let s = model.selection { model.reveal(s) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.selection == nil)
                Button("Move to Trash") { if let s = model.selection { model.moveToTrash(s) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection == nil)
                Button("Undo Trash") { model.undoLastTrash() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(model.undoStack.isEmpty)
            }
        }
    }
}
