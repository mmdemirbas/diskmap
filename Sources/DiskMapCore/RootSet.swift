import Darwin
import Foundation

/// Why a requested scan target was not used.
public enum RootRejection: Sendable, Equatable, Hashable {
    case missing
    case notADirectory
    case duplicate(of: String)
    case containedIn(String)

    public var explanation: String {
        switch self {
        case .missing: "does not exist"
        case .notADirectory: "is not a folder"
        case .duplicate(let other): "is the same folder as \(other)"
        case .containedIn(let parent): "is already inside \(parent)"
        }
    }
}

public struct RejectedRoot: Sendable {
    public let path: String
    public let reason: RootRejection
    public init(path: String, reason: RootRejection) { self.path = path; self.reason = reason }
}

public struct NormalizedRoots: Sendable {
    public var roots: [String]
    public var rejected: [RejectedRoot]
    public var isEmpty: Bool { roots.isEmpty }
}

/// Turns whatever the user dropped on the window into a set of folders that can
/// be measured as one total.
///
/// The rule that matters: a folder inside another chosen folder is dropped.
/// Keeping both would count its bytes twice, and a disk analyser that reports a
/// number larger than the disk is worse than useless.
public enum RootSet {
    public static let startupDataVolume = "/System/Volumes/Data"

    /// macOS splits the startup disk into a read-only System volume mounted at
    /// "/" and a writable Data volume at /System/Volumes/Data. Firmlinks make
    /// the Data volume *appear* beneath "/" as /Users, /Applications, /private
    /// and so on, and those paths have to be skipped when walking "/" or every
    /// user file is counted twice.
    ///
    /// The consequence is that walking "/" on its own measures only the System
    /// volume — around 11 GB — and every byte the user cares about is missing.
    /// "Scan the startup disk" therefore has to mean both volumes. They are
    /// separate devices, so nothing is double counted.
    public static func expandStartupVolume(_ paths: [String]) -> [String] {
        var out: [String] = []
        for path in paths {
            out.append(path)
            guard path == "/", !out.contains(startupDataVolume) else { continue }
            // Not a device-number comparison: APFS volumes in one container
            // share st_dev, so "/" and the Data volume look identical to stat.
            guard volumeMountPoint(startupDataVolume) == startupDataVolume else { continue }
            out.append(startupDataVolume)
        }
        return out
    }

    /// The startup disk is two mounted volumes, a read-only System at "/" and a
    /// writable Data volume, but it is one disk with one capacity. Anything
    /// counting disks has to fold them together or it reports the same disk
    /// twice, with the same size, under the same name.
    public static func physicalDisk(_ mountPoint: String) -> String {
        mountPoint == startupDataVolume ? "/" : mountPoint
    }

    /// True when these roots together cover an entire volume, which is the only
    /// case where comparing the scan against the volume's own used figure means
    /// anything.
    public static func coversWholeVolume(_ roots: [String]) -> Bool {
        if roots == [startupDataVolume] { return true }
        if roots == ["/"] { return true }
        if Set(roots) == ["/", startupDataVolume] { return true }
        return false
    }

    public static func normalize(_ paths: [String], followMountPoints: Bool = false) -> NormalizedRoots {
        var accepted: [(path: String, mount: String)] = []
        var rejected: [RejectedRoot] = []
        var seen: [String: String] = [:]   // canonical -> first path that produced it

        // Shortest first, so a parent is always considered before its children.
        let candidates = paths.map { (original: $0, canonical: canonicalPath($0)) }
            .sorted { ($0.canonical ?? $0.original).count < ($1.canonical ?? $1.original).count }

        for candidate in candidates {
            guard let canonical = candidate.canonical else {
                rejected.append(RejectedRoot(path: candidate.original, reason: .missing)); continue
            }
            var st = stat()
            guard lstat(canonical, &st) == 0 else {
                rejected.append(RejectedRoot(path: candidate.original, reason: .missing)); continue
            }
            guard (st.st_mode & S_IFMT) == S_IFDIR else {
                rejected.append(RejectedRoot(path: candidate.original, reason: .notADirectory)); continue
            }
            if let first = seen[canonical] {
                rejected.append(RejectedRoot(path: candidate.original, reason: .duplicate(of: first))); continue
            }

            // A path under an accepted root is only *really* inside it if the
            // scan would reach it. A separate volume mounted below is not,
            // unless we are following mount points. Compared by mount point
            // rather than device number, which APFS shares across a container.
            let mount = volumeMountPoint(canonical) ?? "/"
            if let parent = accepted.first(where: { isDescendant(canonical, of: $0.path)
                                                    && (followMountPoints || $0.mount == mount) }) {
                rejected.append(RejectedRoot(path: candidate.original, reason: .containedIn(parent.path))); continue
            }

            seen[canonical] = canonical
            accepted.append((canonical, mount))
        }
        return NormalizedRoots(roots: accepted.map(\.path), rejected: rejected)
    }

    static func isDescendant(_ path: String, of parent: String) -> Bool {
        if parent == "/" { return path != "/" }
        return path.hasPrefix(parent + "/")
    }
}


/// A root node's name is its whole absolute path, which is unambiguous but too
/// long to read in a list. The last two components keep it short while still
/// telling two folders of the same name apart.
public func abbreviatedName(_ name: String) -> String {
    guard name.hasPrefix("/") else { return name }
    let parts = name.split(separator: "/")
    // Short absolute paths are already readable; only long ones need trimming.
    guard parts.count > 3 else { return name }
    return "…/" + parts.suffix(2).joined(separator: "/")
}
