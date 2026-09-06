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
    /// Why the thing at this path is not the thing that was described, or nil
    /// when it still is.
    ///
    /// Between a plan appearing on screen and the button being pressed, a sync
    /// client, a download or another window can put something else there. Both
    /// destructive paths in the app check this, and they check it here so they
    /// cannot come to different answers.
    ///
    /// A missing item is not drift: there is nothing there to lose. `bytes`
    /// below zero means the size is not worth re-reading, which is the case
    /// for a folder.
    public static func changedSincePlanning(_ path: String, isFolder expected: Bool,
                                            bytes: Int64, modified: Int32) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let isFolder = (info.st_mode & S_IFMT) == S_IFDIR
        if isFolder != expected {
            return isFolder
                ? "a folder is there now, not the file that was described"
                : "a file is there now, not the folder that was described"
        }
        if !isFolder, bytes >= 0, info.st_size != bytes {
            return "its size changed after the plan was made, so look again"
        }
        if Int32(truncatingIfNeeded: info.st_mtimespec.tv_sec) != modified {
            return "it changed after the plan was made, so look again"
        }
        return nil
    }

    /// One thing to be moved to the Trash, and what it looked like when
    /// somebody decided it should go.
    public struct Target: Sendable {
        public var url: URL
        public var node: Int32
        /// Space this frees. Not the same as the length checked below: a
        /// folder's is the whole subtree, and a second name for one file
        /// frees nothing.
        public var bytes: Int64
        public var isFolder: Bool
        /// Length as the plan saw it, or below zero for a folder.
        public var length: Int64
        public var modified: Int32

        /// No defaults on purpose. A caller that forgets to say what it saw
        /// would silently get a target nothing checks, which is how the
        /// content check lost two of its own categories a few rounds ago.
        public init(url: URL, node: Int32, bytes: Int64,
                    isFolder: Bool, length: Int64, modified: Int32) {
            self.url = url; self.node = node; self.bytes = bytes
            self.isFolder = isFolder; self.length = length; self.modified = modified
        }
    }

    public static func moveToTrash(_ urls: [Target])
        throws -> (trashed: [TrashedItem], failures: [FileActionError]) {
        var trashed: [TrashedItem] = []
        var failures: [FileActionError] = []
        for item in urls {
            if let changed = changedSincePlanning(item.url.path, isFolder: item.isFolder,
                                                  bytes: item.length, modified: item.modified) {
                failures.append(.failed(url: item.url, underlying: changed))
                continue
            }
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
