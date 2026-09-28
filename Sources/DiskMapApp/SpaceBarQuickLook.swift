import AppKit
import Quartz

/// The space bar previews the selection, as it does in the Finder.
///
/// A menu item cannot take a bare space: it would fire while one is being
/// typed into the filter field. So this watches key presses in the app and
/// takes a space only when nothing else wants it — not while text is being
/// typed, not when a button has keyboard focus, not in a sheet or a panel
/// (the Quick Look panel closes itself on a space, and the Open panel
/// previews on its own).
@MainActor
enum SpaceBarQuickLook {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let bareSpace = event.keyCode == 49
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            guard bareSpace else { return event }
            return MainActor.assumeIsolated { previewSelection() } ? nil : event
        }
    }

    private static func previewSelection() -> Bool {
        guard let window = NSApp.keyWindow, !(window is NSPanel), window.sheetParent == nil,
              !(window.firstResponder is NSText), !(window.firstResponder is NSButton),
              let model = ServicesProvider.shared.model, let node = model.selection
        else { return false }
        model.quickLook(node)
        return true
    }
}
