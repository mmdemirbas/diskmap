import Darwin
import Foundation

public struct ScanOptions: Sendable {
    /// One or more folders measured as a single total.
    public var roots: [String]
    /// Off by default: an external drive is a separate budget, not part of this one.
    public var followMountPoints: Bool = false
    public var threadCount: Int = min(12, ProcessInfo.processInfo.activeProcessorCount)
    public var extraExclusions: Set<String> = []

    public init(rootPath: String) { self.roots = [rootPath] }
    public init(roots: [String]) { self.roots = roots }

    /// The first root. Only meaningful for a single-root scan.
    public var rootPath: String { roots.first ?? "/" }

    /// Paths that must never be walked, relative to one root.
    ///
    /// `/net` and `/home` are autofs: merely opening them triggers an automount
    /// and can hang for the network timeout. The firmlinked paths are the same
    /// bytes as the Data volume reached by another name, so walking them from
    /// `/` double-counts most of the disk.
    public func exclusions(for root: String) -> Set<String> {
        var out: Set<String> = ["/dev", "/net", "/home", "/.vol", "/.fseventsd", "/.DocumentRevisions-V100"]
        if root == "/" {
            out.formUnion(Firmlinks.mountPaths())
            out.insert("/System/Volumes/Data")
            out.insert("/Volumes")
        }
        out.formUnion(extraExclusions)
        return out
    }
}

/// Cooperative cancellation. A scan of a full volume runs for a minute; the
/// user must be able to change their mind without waiting it out.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
}

public struct ScanStats: Sendable {
    public var directories = 0
    public var files = 0
    public var symlinks = 0
    public var totalLogical: Int64 = 0
    public var totalPhysical: Int64 = 0
    /// iCloud placeholders: counted in logical, zero in physical.
    public var datalessCount = 0
    public var datalessLogical: Int64 = 0
    /// Extra links to an inode already counted. Their bytes exist once.
    public var hardlinkDuplicates = 0
    public var hardlinkDuplicateLogical: Int64 = 0
    public var compressedCount = 0
    public var unreadableDirectories = 0
    public var skippedMountPoints = 0
    public var elapsed: TimeInterval = 0
    public var unreadableSamples: [String] = []
    /// True when the scan stopped early; totals are partial.
    public var cancelled = false

    mutating func merge(_ other: ScanStats) {
        directories += other.directories
        files += other.files
        symlinks += other.symlinks
        totalLogical += other.totalLogical
        totalPhysical += other.totalPhysical
        datalessCount += other.datalessCount
        datalessLogical += other.datalessLogical
        hardlinkDuplicates += other.hardlinkDuplicates
        hardlinkDuplicateLogical += other.hardlinkDuplicateLogical
        compressedCount += other.compressedCount
        unreadableDirectories += other.unreadableDirectories
        skippedMountPoints += other.skippedMountPoints
        unreadableSamples += other.unreadableSamples.prefix(max(0, 25 - unreadableSamples.count))
        cancelled = cancelled || other.cancelled
    }
}

public struct ScanResult: Sendable {
    public let store: NodeStore
    public let stats: ScanStats
    public let roots: [String]
    /// Targets that were asked for but not measured, and why.
    public let rejectedRoots: [RejectedRoot]
    public var rootPath: String { roots.first ?? "" }
    public var isMultiRoot: Bool { roots.count > 1 }
    public var rootID: Int32 { 0 }
}

public struct ScanProgress: Sendable {
    public var nodes: Int
    public var directories: Int
    public var bytes: Int64
    public var currentPath: String
    /// Estimated from the volume's used-inode count. Nil where no honest
    /// estimate exists, rather than a made-up one.
    public var fraction: Double?
}

/// Inodes with more than one link, shared across the roots of one scan so a
/// file reachable from two chosen folders is still counted once.
final class InodeSet: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<UInt64>()
    func isFirstSighting(_ id: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert(id).inserted
    }
}

public final class DiskScanner {
    private struct Task { let path: String; let node: Int32 }

    private struct Pending {
        var nameOffset: Int; var nameLength: Int
        var logical: Int64; var physical: Int64
        var mtime: Int32; var flags: NodeFlags
        var fileID: UInt64; var linkCount: UInt32
    }

    private struct Carry { var nodes = 0; var bytes: Int64 = 0 }

    private final class Queue {
        private var stack: [Task]
        private let cond = NSCondition()
        private var busy = 0
        private var shutdown = false
        init(seed: Task) { stack = [seed] }

        func pop() -> Task? {
            cond.lock(); defer { cond.unlock() }
            while true {
                if let t = stack.popLast() { busy += 1; return t }
                if busy == 0 { shutdown = true; cond.broadcast(); return nil }
                if shutdown { return nil }
                cond.wait()
            }
        }
        func push(_ items: [Task]) {
            guard !items.isEmpty else { return }
            cond.lock(); stack.append(contentsOf: items); cond.broadcast(); cond.unlock()
        }
        func complete() {
            cond.lock()
            busy -= 1
            if busy == 0 && stack.isEmpty { shutdown = true; cond.broadcast() }
            cond.unlock()
        }
    }

    public let cancelToken = CancelToken()

    public init() {}

    /// True when the path is the mount point of its filesystem: its device
    /// differs from its parent's, so the inode estimate describes this tree.
    static func isVolumeRoot(_ path: String) -> Bool {
        if path == "/" || path == "/System/Volumes/Data" { return true }
        var here = stat(), up = stat()
        guard lstat(path, &here) == 0, lstat(path + "/..", &up) == 0 else { return false }
        return here.st_dev != up.st_dev
    }

    public func scan(_ rawOptions: ScanOptions,
                     progress: (@Sendable (ScanProgress) -> Void)? = nil) -> ScanResult {
        let started = Date()
        // Canonical paths throughout: FSEvents reports the resolved form
        // ("/private/var/..."), so a tree rooted anywhere else silently matches
        // nothing. Normalising also drops duplicates and any folder already
        // inside another, which would otherwise be counted twice.
        let requested = RootSet.expandStartupVolume(rawOptions.roots)
        let normalized = RootSet.normalize(requested,
                                           followMountPoints: rawOptions.followMountPoints)
        guard !normalized.roots.isEmpty else {
            return ScanResult(store: NodeStore(), stats: ScanStats(), roots: [],
                              rejectedRoots: normalized.rejected)
        }
        let inodes = InodeSet()

        if normalized.roots.count == 1 {
            let part = scanOne(root: normalized.roots[0], options: rawOptions,
                               inodes: inodes, carry: Carry(), progress: progress)
            part.store.roots = normalized.roots
            part.store.aggregate()
            var stats = part.stats
            stats.cancelled = cancelToken.isCancelled
            stats.totalLogical = part.store.totalLogical[0]
            stats.totalPhysical = part.store.totalPhysical[0]
            stats.elapsed = Date().timeIntervalSince(started)
            return ScanResult(store: part.store, stats: stats, roots: normalized.roots,
                              rejectedRoots: normalized.rejected)
        }

        // Several roots: node 0 is synthetic and the roots hang off it. They are
        // appended up front so they form one contiguous block, which is what
        // children(0) and path lookup depend on.
        let store = NodeStore()
        store.roots = normalized.roots
        _ = [UInt8]().withUnsafeBytes {
            store.append(name: $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, nameLength: 0,
                         parent: -1, logical: 0, physical: 0, mtime: 0, flags: .directory)
        }
        let rootBlock = Int32(store.count)
        for root in normalized.roots {
            let bytes = Array(root.utf8)
            _ = bytes.withUnsafeBytes {
                store.append(name: $0.baseAddress!, nameLength: $0.count, parent: 0,
                             logical: 0, physical: 0, mtime: 0, flags: .directory)
            }
        }
        store.firstChild[0] = rootBlock
        store.childCount[0] = Int32(normalized.roots.count)

        var merged = ScanStats()
        var carry = Carry()
        for (index, root) in normalized.roots.enumerated() {
            if cancelToken.isCancelled { break }
            let part = scanOne(root: root, options: rawOptions, inodes: inodes,
                               carry: carry, progress: progress)
            let host = rootBlock + Int32(index)
            let base = store.graft(part.store, under: host)
            if part.store.childCount[0] > 0, base >= 0 {
                store.firstChild[Int(host)] = base + part.store.firstChild[0] - 1
                store.childCount[Int(host)] = part.store.childCount[0]
            }
            merged.merge(part.stats)
            carry.nodes += part.store.count
            carry.bytes = merged.totalPhysical
        }

        // Subtree totals are computed once over the combined tree, so the
        // grafted parts do not each need their own aggregation pass.
        store.aggregate()
        var stats = merged
        stats.cancelled = cancelToken.isCancelled
        stats.totalLogical = store.totalLogical[0]
        stats.totalPhysical = store.totalPhysical[0]
        stats.elapsed = Date().timeIntervalSince(started)
        return ScanResult(store: store, stats: stats, roots: normalized.roots,
                          rejectedRoots: normalized.rejected)
    }

    /// Walks exactly one root. Leaves aggregation to the caller.
    private func scanOne(root: String, options: ScanOptions, inodes: InodeSet,
                         carry: Carry,
                         progress: (@Sendable (ScanProgress) -> Void)?) -> (store: NodeStore, stats: ScanStats) {
        let store = NodeStore()
        store.roots = [root]
        var stats = ScanStats()
        let exclusions = options.exclusions(for: root)

        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else { return (store, stats) }
        let rootDev = rootStat.st_dev
        // st_dev cannot separate APFS volumes inside one container, so mount
        // points are matched by path instead. The root itself is normally a
        // mount point and must not be skipped.
        var crossings = options.followMountPoints ? [] : MountTable.mountPoints()
        crossings.remove(root)

        // statfs knows how many inodes are in use. For a whole-volume scan that
        // is the node count, so the arrays can be sized once instead of growing
        // through ~24 reallocations, and progress can show a real fraction.
        let inodeEstimate = usedInodeCount(root)
        let isVolumeRoot = Self.isVolumeRoot(root)
        store.reserve(isVolumeRoot && inodeEstimate > 0 ? min(inodeEstimate, 60_000_000) : 1 << 20)

        let rootName = Array(root.utf8)
        _ = rootName.withUnsafeBytes { buf in
            store.append(name: buf.baseAddress!, nameLength: buf.count, parent: -1,
                         logical: 0, physical: 0,
                         mtime: Int32(truncatingIfNeeded: rootStat.st_mtimespec.tv_sec),
                         flags: .directory)
        }

        let queue = Queue(seed: Task(path: root, node: 0))
        let lock = NSLock()
        var currentPath = root

        let progressTimer: DispatchSourceTimer? = progress.map { callback in
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler {
                lock.lock()
                let nodes = carry.nodes + store.count
                let snapshot = ScanProgress(
                    nodes: nodes, directories: stats.directories,
                    bytes: carry.bytes + stats.totalPhysical, currentPath: currentPath,
                    fraction: isVolumeRoot && inodeEstimate > 0
                        ? min(1.0, Double(nodes) / Double(inodeEstimate)) : nil)
                lock.unlock()
                callback(snapshot)
            }
            timer.resume()
            return timer
        }

        let group = DispatchGroup()
        for _ in 0..<max(1, options.threadCount) {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let reader = BulkReader()
                var pending: [Pending] = []
                var nameBuf: [UInt8] = []
                pending.reserveCapacity(2048); nameBuf.reserveCapacity(64 * 1024)

                while let task = queue.pop() {
                    defer { queue.complete() }
                    if self.cancelToken.isCancelled { continue }

                    let fd = open(task.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if fd < 0 {
                        lock.lock()
                        store.flags[Int(task.node)] |= NodeFlags.unreadable.rawValue
                        stats.unreadableDirectories += 1
                        if stats.unreadableSamples.count < 25 { stats.unreadableSamples.append(task.path) }
                        lock.unlock()
                        continue
                    }

                    var dirStat = stat()
                    if fstat(fd, &dirStat) == 0, dirStat.st_dev != rootDev, !options.followMountPoints {
                        close(fd)
                        lock.lock()
                        store.flags[Int(task.node)] |= NodeFlags.mountPoint.rawValue
                        stats.skippedMountPoints += 1
                        lock.unlock()
                        continue
                    }

                    pending.removeAll(keepingCapacity: true)
                    nameBuf.removeAll(keepingCapacity: true)

                    _ = reader.enumerate(dirFD: fd) { e in
                        // The entry points into the reader's reusable buffer,
                        // which the next syscall overwrites. Copy the name now.
                        let offset = nameBuf.count
                        nameBuf.append(contentsOf: UnsafeRawBufferPointer(start: e.name, count: e.nameLen))

                        var flags = NodeFlags()
                        if e.isDir { flags.insert(.directory) }
                        if e.isSymlink { flags.insert(.symlink) }
                        if e.isDataless { flags.insert(.dataless) }
                        if e.stFlags & UF_COMPRESSED_FLAG != 0 { flags.insert(.compressed) }

                        // A dataless file's bytes live in iCloud, not here.
                        let physical = e.isDataless ? 0 : e.physicalSize

                        pending.append(Pending(nameOffset: offset, nameLength: e.nameLen,
                                               logical: e.logicalSize, physical: physical,
                                               mtime: Int32(truncatingIfNeeded: e.mtime),
                                               flags: flags, fileID: e.fileID, linkCount: e.linkCount))
                    }
                    close(fd)
                    if pending.isEmpty { continue }

                    var subdirs: [Task] = []
                    subdirs.reserveCapacity(16)

                    lock.lock()
                    let base = Int32(store.count)
                    nameBuf.withUnsafeBufferPointer { nb in
                        let nbBase = nb.baseAddress!
                        for var p in pending {
                            var physical = p.physical
                            // Extra links to one inode: the bytes exist once.
                            if p.linkCount > 1, !p.flags.contains(.directory),
                               !inodes.isFirstSighting(p.fileID) {
                                p.flags.insert(.hardlinkDuplicate)
                                stats.hardlinkDuplicates += 1
                                stats.hardlinkDuplicateLogical += p.logical
                                physical = 0
                            }
                            _ = store.append(name: nbBase + p.nameOffset, nameLength: p.nameLength,
                                             parent: task.node, logical: p.logical, physical: physical,
                                             mtime: p.mtime, flags: p.flags)
                            if p.flags.contains(.directory) {
                                stats.directories += 1
                            } else if p.flags.contains(.symlink) {
                                stats.symlinks += 1
                            } else {
                                stats.files += 1
                                stats.totalLogical += p.logical
                                stats.totalPhysical += physical
                                if p.flags.contains(.dataless) {
                                    stats.datalessCount += 1
                                    stats.datalessLogical += p.logical
                                }
                                if p.flags.contains(.compressed) { stats.compressedCount += 1 }
                            }
                        }
                    }
                    store.firstChild[Int(task.node)] = base
                    store.childCount[Int(task.node)] = Int32(pending.count)
                    currentPath = task.path
                    lock.unlock()

                    let prefix = task.path == "/" ? "" : task.path
                    for (i, p) in pending.enumerated()
                    where p.flags.contains(.directory) && !p.flags.contains(.symlink) {
                        let name = String(decoding: nameBuf[p.nameOffset..<(p.nameOffset + p.nameLength)],
                                          as: UTF8.self)
                        let childPath = prefix + "/" + name
                        if exclusions.contains(childPath) {
                            lock.lock()
                            store.flags[Int(base) + i] |= NodeFlags.excluded.rawValue
                            lock.unlock()
                            continue
                        }
                        if crossings.contains(childPath) {
                            lock.lock()
                            store.flags[Int(base) + i] |= NodeFlags.mountPoint.rawValue
                            stats.skippedMountPoints += 1
                            lock.unlock()
                            continue
                        }
                        subdirs.append(Task(path: childPath, node: base + Int32(i)))
                    }
                    queue.push(subdirs)
                }
            }
        }
        group.wait()
        progressTimer?.cancel()
        return (store, stats)
    }
}

/// Fully resolved path, with symlinks and `.`/`..` removed.
public func canonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Inodes currently allocated on the filesystem containing `path`.
func usedInodeCount(_ path: String) -> Int {
    var fs = statfs()
    guard statfs(path, &fs) == 0 else { return 0 }
    return max(0, Int(fs.f_files) - Int(fs.f_ffree))
}
