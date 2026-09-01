import Foundation

/// Folders whose contents are mirrored to a service.
///
/// This matters because moving a file to the Trash inside one of these is not a
/// local operation. The sync client sees the deletion and removes the file from
/// the service, and from every other device signed into it. Finder's *Put Back*
/// restores the local copy; it does not undo what the service already did.
///
/// The app ranks duplicate folders by size, and on a machine that keeps a
/// mirrored Drive or Dropbox the biggest matches are very often inside one. So
/// the most dangerous deletion on the disk is also the one the app puts at the
/// top of the list, which is exactly the case worth a warning.
public struct SyncRoots: Sendable {
    public struct Root: Sendable {
        public let path: String
        public let provider: String
        public init(path: String, provider: String) {
            self.path = path
            self.provider = provider
        }
    }

    public let roots: [Root]

    /// Longest path first, so a provider nested inside another still wins.
    ///
    /// Paths are canonicalised on the way in, because they are compared against
    /// paths the store produces and those are canonical. A home directory
    /// reached through a symlink would otherwise match nothing, and the warning
    /// would be silently absent — the worst way for a safety check to fail.
    public init(roots: [Root]) {
        self.roots = roots
            .map { Root(path: canonicalPath($0.path) ?? $0.path, provider: $0.provider) }
            .sorted { $0.path.count > $1.path.count }
    }

    public func provider(for path: String) -> String? {
        roots.first { path == $0.path || path.hasPrefix($0.path + "/") }?.provider
    }

    public var isEmpty: Bool { roots.isEmpty }

    /// Every modern provider on macOS mounts under `Library/CloudStorage`
    /// through the File Provider API; iCloud Drive and the legacy Dropbox
    /// location are the two that do not.
    public static func detected(home: String = NSHomeDirectory()) -> SyncRoots {
        let fm = FileManager.default
        var found: [Root] = []

        let cloudStorage = home + "/Library/CloudStorage"
        if let entries = try? fm.contentsOfDirectory(atPath: cloudStorage) {
            for entry in entries where !entry.hasPrefix(".") {
                found.append(Root(path: cloudStorage + "/" + entry, provider: providerName(entry)))
            }
        }

        let iCloud = home + "/Library/Mobile Documents"
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: iCloud, isDirectory: &isDir), isDir.boolValue {
            found.append(Root(path: iCloud, provider: "iCloud Drive"))
        }

        let legacyDropbox = home + "/Dropbox"
        if fm.fileExists(atPath: legacyDropbox, isDirectory: &isDir), isDir.boolValue {
            found.append(Root(path: legacyDropbox, provider: "Dropbox"))
        }

        return SyncRoots(roots: found)
    }

    /// `GoogleDrive-someone@example.com` names the provider and the account.
    /// Only the provider half is wanted: the account is the user's address and
    /// has no business being on screen next to a delete button.
    static func providerName(_ directoryName: String) -> String {
        let head = String(directoryName.split(separator: "-").first ?? "")
        switch head {
        case "GoogleDrive": return "Google Drive"
        case "OneDrive": return "OneDrive"
        case "Box": return "Box"
        case "ProtonDrive": return "Proton Drive"
        case "": return directoryName
        default: return head
        }
    }
}
