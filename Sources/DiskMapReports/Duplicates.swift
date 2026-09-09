import Foundation
import DiskMapScan

public struct DuplicateGroup: Sendable, Identifiable {
    public var id: Int32 { nodes.first ?? -1 }
    /// Every file sharing this name and size, biggest group first.
    public var nodes: [Int32]
    public var name: String
    /// Size of a single copy.
    public var bytes: Int64
    /// What deleting all but one copy would free.
    public var reclaimable: Int64 { bytes * Int64(max(0, nodes.count - 1)) }
}

/// Files that look like copies of each other.
///
/// Deliberately shallow: files are grouped by identical name *and* identical
/// byte length, and nothing is read. That makes it as fast as the rest of the
/// scan and safe on iCloud placeholders, which reading would pull down from the
/// network.
///
/// The cost of being shallow is that this cannot prove two files are identical,
/// only that they are strong candidates. Two different photos of the same size
/// exported with the same name would appear here. The UI says so; nothing is
/// deleted without you choosing it.
///
/// Hard links are excluded on purpose. They are already one set of bytes under
/// two names, so removing one frees nothing, and listing them as duplicates
/// would promise space that does not exist.
public enum Duplicates {
    /// `insideMatched` suppresses files whose folders are already reported as
    /// copies of each other: every file in a matched folder has a twin in its
    /// counterpart, and listing them again says nothing the folder row did not.
    public static func find(store: NodeStore, root: Int32,
                            minimumSize: Int64 = 1_000_000,
                            limit: Int = 200,
                            insideMatched: [FolderMatch] = [],
                            onProgress: MatchProgress.Report? = nil) -> [DuplicateGroup] {
        let span = Telemetry.begin("match.files")
        onProgress?(MatchProgress(phase: .files, done: 0, total: store.count))
        var seen = 0
        struct Key: Hashable { let name: String; let size: Int64 }
        var groups: [Key: [Int32]] = [:]
        var stack: [Int32] = [root]

        while let node = stack.popLast() {
            for child in store.children(node) {
                let flags = store.flagSet(child)
                if flags.contains(.removed) { continue }
                seen += 1
                if let onProgress, seen & MatchProgress.every == 0 {
                    onProgress(MatchProgress(phase: .files, done: seen, total: store.count))
                }
                if store.isDirectory(child) { stack.append(child); continue }
                // Hard links share bytes already; placeholders hold none here.
                if flags.contains(.hardlinkDuplicate) || flags.contains(.dataless) { continue }

                let size = store.totalLogical[Int(child)]
                guard size >= minimumSize else { continue }
                // Folded: `Photo.jpg` and `photo.jpg` are one name on the
                // volumes this runs on, and two files with one name and one
                // size are what this screen is for.
                groups[Key(name: NameKey.folded(store.name(child)), size: size),
                       default: []].append(child)
            }
        }

        var folderOf: [Int32: Set<Int>] = [:]
        for (index, match) in insideMatched.enumerated() {
            for node in match.nodes { folderOf[node, default: []].insert(index) }
        }

        defer {
            span.end(["candidates": .int(Int64(groups.count)),
                      "suppressed": .flag(!insideMatched.isEmpty)])
        }

        return groups
            .filter { $0.value.count > 1 }
            .filter { _, nodes in
                guard !folderOf.isEmpty else { return true }
                let owners = nodes.map { folderOf[store.parent[Int($0)]] ?? [] }
                return owners.dropFirst().reduce(owners[0]) { $0.intersection($1) }.isEmpty
            }
            .map { DuplicateGroup(nodes: $0.value, name: $0.key.name, bytes: $0.key.size) }
            .sorted { $0.reclaimable > $1.reclaimable }
            .prefix(limit)
            .map { $0 }
    }
}
