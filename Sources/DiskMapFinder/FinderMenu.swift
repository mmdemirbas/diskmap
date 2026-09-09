import AppKit
import FinderSync
import Foundation

/// The right-click menu item, at the top level where it was asked for.
///
/// The Services entry works and is not enough: macOS files third-party services
/// under a *Services* submenu at the bottom of the contextual menu, which is
/// exactly the browsing-to-discover-it problem it was meant to solve. Only a
/// Finder Sync extension can put an item in the menu itself, and that is what
/// this is: a second bundle, with its own identifier and its own signature,
/// embedded in the app.
///
/// It does as little as possible. Deciding what a comparison means, refusing a
/// selection, opening a tab — all of that already exists and is tested in the
/// app. This puts the selection on a pasteboard and hands it to the same
/// service the Services menu calls, so there is one path into the app rather
/// than two that can drift apart.
@objc(FinderMenu)
final class FinderMenu: FIFinderSync {
    override init() {
        super.init()
        // Menu items appear for directories this extension is watching. Every
        // mounted volume, because "where are my duplicates" is a question about
        // wherever the user happens to be looking, not about one folder.
        FIFinderSyncController.default().directoryURLs =
            Set(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                      options: [])
                ?? [URL(fileURLWithPath: "/")])
    }

    override func menu(for kind: FIMenuKind) -> NSMenu? {
        guard kind == .contextualMenuForItems || kind == .contextualMenuForContainer else {
            return nil
        }
        let menu = NSMenu(title: "")
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []

        // Two folders is the only count a comparison means something for, so
        // the item is there when it can act and absent when it cannot — rather
        // than present and refusing after the click.
        if selected.count == 2 {
            menu.addItem(item("Compare in Disk Map", #selector(compare(_:))))
        }
        menu.addItem(item("Measure in Disk Map", #selector(measure(_:))))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: nil)
        return entry
    }

    @objc private func compare(_ sender: AnyObject?) { perform("Compare in Disk Map") }
    @objc private func measure(_ sender: AnyObject?) { perform("Measure in Disk Map") }

    /// Hands the selection to the app through its own Services entry.
    ///
    /// The alternative is a URL scheme, which would mean encoding paths into a
    /// URL and parsing them back — a second way in, with its own escaping bugs,
    /// for a job the pasteboard already does.
    private func perform(_ service: String) {
        let controller = FIFinderSyncController.default()
        let selected = controller.selectedItemURLs() ?? []
        let urls = selected.isEmpty ? [controller.targetedURL()].compactMap { $0 } : selected
        guard !urls.isEmpty else { return }

        let pasteboard = NSPasteboard(name: .init(rawValue: "DiskMapFinderMenu"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        NSPerformService(service, pasteboard)
    }
}
