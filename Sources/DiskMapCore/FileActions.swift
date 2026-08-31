import AppKit
import Foundation

public struct TrashedItem: Sendable, Identifiable {
    public let id = UUID()
    public let originalURL: URL
    public let trashURL: URL?
    public let bytesFreed: Int64
    public let node: Int32
}

public enum FileActionError: LocalizedError {
    case failed(url: URL, underlying: String)
    public var errorDescription: String? {
        switch self {
        case .failed(let url, let msg): "Could not move \(url.lastPathComponent) to Trash: \(msg)"
        }
    }
}

public enum FileActions {
    /// Selects the items in Finder rather than opening them, so a 40 GB video
    /// never launches a player by accident.
    public static func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    public static func openInFinder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Uses the real Trash, so Finder's "Put Back" restores the original
    /// location. A plain move to ~/.Trash would lose that.
    public static func moveToTrash(_ urls: [(url: URL, node: Int32, bytes: Int64)])
        throws -> (trashed: [TrashedItem], failures: [FileActionError]) {
        var trashed: [TrashedItem] = []
        var failures: [FileActionError] = []
        for item in urls {
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
                trashed.append(TrashedItem(originalURL: item.url,
                                           trashURL: resulting as URL?,
                                           bytesFreed: item.bytes, node: item.node))
            } catch {
                failures.append(.failed(url: item.url, underlying: error.localizedDescription))
            }
        }
        return (trashed, failures)
    }

    /// Undo for a trash operation: moves the item back where it came from.
    public static func restore(_ item: TrashedItem) throws {
        guard let from = item.trashURL else { return }
        try FileManager.default.moveItem(at: from, to: item.originalURL)
    }

    public static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Full Disk Access cannot be granted programmatically; this opens the pane.
    ///
    /// macOS 13 renamed the pane. The pre-Ventura identifier opens no window at
    /// all on current systems, and `open` still reports success, so the failure
    /// is silent unless you go looking for the window.
    @discardableResult
    public static func openFullDiskAccessSettings() -> Bool {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return true }
        }
        // Better to land in Settings somewhere than nowhere.
        let app = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        return NSWorkspace.shared.open(app)
    }

    /// True when we can read a path that is unreadable without Full Disk Access.
    public static func hasFullDiskAccess() -> Bool {
        let probe = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        return FileManager.default.isReadableFile(atPath: probe)
    }
}
