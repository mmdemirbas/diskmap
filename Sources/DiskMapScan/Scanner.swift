import Darwin
import Foundation

public struct ScanOptions: Sendable {
    /// One or more folders measured as a single total.
    public var roots: [String]
    /// Off by default: an external drive is a separate budget, not part of this one.
    public var followMountPoints: Bool = false
    public var threadCount: Int = min(12, ProcessInfo.processInfo.activeProcessorCount)
    public var extraExclusions: Set<String> = []

    /// How many nodes to size the arrays for, when the caller knows better
    /// than the volume does.
    ///
    /// Left nil, the scanner asks `statfs` how many inodes the volume is using.
    /// That is the right guess for "measure this whole disk" and a ruinous one
    /// for "measure this folder that just appeared", because `statfs` answers
    /// for the volume whatever path it is handed. A live update scans thousands
    /// of new directories an hour and nearly all of them hold a handful of
    /// entries — each was reserving room for twelve million nodes, some six
    /// hundred megabytes of arrays plus a hundred-megabyte intern table, mapped
    /// and thrown away several times a second.
    public var expectedNodes: Int?

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
/// Which inodes have already been counted, so a second name for one file does
/// not count its bytes twice.
///
/// Keyed by volume as well as by inode, because an inode number only means
/// anything on the volume that issued it. Two freshly formatted volumes hand
/// out the same low numbers, so a scan of several roots would see one file
/// where there are two - and zero the second one's bytes. Measured on two
/// 20 MB images, each holding six hardlinked pairs: 17 extra links reported
/// where there were 12.
final class InodeSet: @unchecked Sendable {
    private struct Key: Hashable { let device: Int32; let id: UInt64 }
    private let lock = NSLock()
    private var seen = Set<Key>()
    func isFirstSighting(onDevice device: Int32, _ id: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert(Key(device: device, id: id)).inserted
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

    public let cancelToken: CancelToken

    /// A caller with its own token — a folder comparison runs two scans and one
    /// Cancel has to stop both — passes it in; everyone else gets a fresh one.
    public init(cancel: CancelToken = CancelToken()) { cancelToken = cancel }

    /// True when the path is the mount point of its filesystem: its device
    /// differs from its parent's, so the inode estimate describes this tree.
    /// Opens a directory whose absolute path may be longer than the system
    /// will accept in one call.
    ///
    /// `open(2)` takes the whole path and refuses at `PATH_MAX`, but nothing
    /// stops a tree from being *built* past it: npm, git and rsync all create
    /// directories with relative steps or `openat`, which have no such limit.
    /// A folder can therefore exist that cannot be named in a single call - and
    /// the walk would report it, and everything under it, as unreadable. Seen
    /// at 2453 bytes: five directories, no files, zero bytes.
    ///
    /// Walking down one component at a time has no limit, and costs a syscall
    /// per level only where the ordinary open has already failed.
    static func openDirectory(_ path: String) -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 || errno != ENAMETOOLONG { return fd }

        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { return -1 }
        let parts = path.split(separator: "/")
        for (index, component) in parts.enumerated() {
            // `open` only refuses to follow the *last* component, so the walk
            // has to match that or it would reject paths the old call accepted.
            let last = index == parts.count - 1
            let next = String(component).withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC
                                    | (last ? O_NOFOLLOW : 0))
            }
            close(current)
            guard next >= 0 else { return -1 }
            current = next
        }
        return current
    }

    public static func isVolumeRoot(_ path: String) -> Bool {
        if path == "/" || path == "/System/Volumes/Data" { return true }
        var here = stat(), up = stat()
        guard lstat(path, &here) == 0, lstat(path + "/..", &up) == 0 else { return false }
        return here.st_dev != up.st_dev
    }

    public func scan(_ rawOptions: ScanOptions,
                     progress: (@Sendable (ScanProgress) -> Void)? = nil) -> ScanResult {
        let started = Date()
        let span = Telemetry.begin("scan")
        // Canonical paths throughout: FSEvents reports the resolved form
        // ("/private/var/..."), so a tree rooted anywhere else silently matches
        // nothing. Normalising also drops duplicates and any folder already
        // inside another, which would otherwise be counted twice.
        let requested = RootSet.expandStartupVolume(rawOptions.roots)
        let normalized = RootSet.normalize(requested,
                                           followMountPoints: rawOptions.followMountPoints)
        guard !normalized.roots.isEmpty else {
            span.end(["roots": .int(0), "rejected": .int(Int64(normalized.rejected.count))])
            return ScanResult(store: NodeStore(), stats: ScanStats(), roots: [],
                              rejectedRoots: normalized.rejected)
        }

        let store = NodeStore()
        store.roots = normalized.roots
        let inodes = InodeSet()
        let multi = normalized.roots.count > 1

        // One allocation up front for the whole tree, sized from the volumes'
        // own used-inode counts. Growing 11M nodes geometrically instead would
        // copy hundreds of megabytes and leave as much again in slack.
        // A caller-supplied figure says how much to allocate; it says nothing
        // about the volume, so it does not become a progress denominator. The
        // estimate stays nil there rather than becoming a made-up fraction.
        let estimate = rawOptions.expectedNodes == nil
            ? normalized.roots.reduce(0) { $0 + usedInodeCount($1) }
            : 0
        let capacity = rawOptions.expectedNodes
            ?? (estimate > 0 ? min(Int(Double(estimate) * 1.05) + 1024, 80_000_000) : 1 << 20)
        store.reserve(capacity)
        store.beginInterning(expectedNodes: capacity)

        var hosts: [Int32] = []
        if multi {
            // Node 0 is synthetic; the roots hang off it as one contiguous block.
            _ = [UInt8]().withUnsafeBytes {
                store.append(name: $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, nameLength: 0,
                             parent: -1, logical: 0, physical: 0, mtime: 0, flags: .directory)
            }
            let block = Int32(store.count)
            for root in normalized.roots {
                let bytes = Array(root.utf8)
                let id = bytes.withUnsafeBytes {
                    store.append(name: $0.baseAddress!, nameLength: $0.count, parent: 0,
                                 logical: 0, physical: 0, mtime: 0, flags: .directory)
                }
                hosts.append(id)
            }
            store.firstChild[0] = block
            store.childCount[0] = Int32(normalized.roots.count)
        } else {
            let root = normalized.roots[0]
            var rootStat = stat()
            _ = lstat(root, &rootStat)
            let bytes = Array(root.utf8)
            let id = bytes.withUnsafeBytes {
                store.append(name: $0.baseAddress!, nameLength: $0.count, parent: -1,
                             logical: 0, physical: 0,
                             mtime: Int32(truncatingIfNeeded: rootStat.st_mtimespec.tv_sec),
                             flags: .directory)
            }
            hosts.append(id)
        }

        var merged = ScanStats()
        var carry = Carry()
        for (index, root) in normalized.roots.enumerated() {
            if cancelToken.isCancelled { break }
            // Straight into the destination store: no second copy to graft.
            let part = scanOne(root: root, into: store, hostNode: hosts[index],
                               options: rawOptions, inodes: inodes,
                               estimate: estimate, carry: carry, progress: progress)
            merged.merge(part)
            carry.nodes = store.count
            carry.bytes = merged.totalPhysical
        }

        store.endInterning()
        store.aggregate()
        var stats = merged
        stats.cancelled = cancelToken.isCancelled
        stats.totalLogical = store.totalLogical[0]
        stats.totalPhysical = store.totalPhysical[0]
        stats.elapsed = Date().timeIntervalSince(started)

        span.end([
            "roots": .int(Int64(normalized.roots.count)),
            "threads": .int(Int64(rawOptions.threadCount)),
            "nodes": .int(Int64(store.count)),
            "files": .int(Int64(stats.files)),
            "dirs": .int(Int64(stats.directories)),
            "logical": .int(stats.totalLogical),
            "physical": .int(stats.totalPhysical),
            "dataless": .int(Int64(stats.datalessCount)),
            "hardlinks": .int(Int64(stats.hardlinkDuplicates)),
            "unreadable": .int(Int64(stats.unreadableDirectories)),
            "cancelled": .flag(stats.cancelled),
            "footprint": .int(Telemetry.footprintBytes()),
            // A live update scans thousands of newly appeared directories an
            // hour, nearly all of them empty. One record each buries the log in
            // noise and costs a write per filesystem event; the flush record
            // carries the count instead, and only a slow one is worth a line.
        ], minMilliseconds: rawOptions.expectedNodes == nil ? 0 : 250)
        if stats.unreadableDirectories > 0 {
            // Almost always missing Full Disk Access, which makes every total
            // on screen an understatement. Worth a record of its own.
            Telemetry.problem("scan.unreadable", "directories could not be read",
                              ["count": .int(Int64(stats.unreadableDirectories))])
        }
        return ScanResult(store: store, stats: stats, roots: normalized.roots,
                          rejectedRoots: normalized.rejected)
    }

    /// Walks one root into an existing store, beneath a node the caller made.
    /// Aggregation is left to the caller so the combined tree is summed once.
    private func scanOne(root: String, into store: NodeStore, hostNode: Int32,
                         options: ScanOptions, inodes: InodeSet, estimate: Int,
                         carry: Carry,
                         progress: (@Sendable (ScanProgress) -> Void)?) -> ScanStats {
        var stats = ScanStats()
        let exclusions = options.exclusions(for: root)

        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else { return stats }
        let rootDev = rootStat.st_dev
        // st_dev cannot separate APFS volumes inside one container, so mount
        // points are matched by path instead. The root itself is normally a
        // mount point and must not be skipped.
        var crossings = options.followMountPoints ? [] : MountTable.mountPoints()
        crossings.remove(root)

        let queue = Queue(seed: Task(path: root, node: hostNode))
        let lock = NSLock()
        var currentPath = root

        let progressTimer: DispatchSourceTimer? = progress.map { callback in
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler {
                lock.lock()
                let nodes = store.count
                let snapshot = ScanProgress(
                    nodes: nodes, directories: stats.directories,
                    bytes: carry.bytes + stats.totalPhysical, currentPath: currentPath,
                    fraction: estimate > 0 ? min(1.0, Double(nodes) / Double(estimate)) : nil)
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

                    let fd = DiskScanner.openDirectory(task.path)
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
                               !inodes.isFirstSighting(onDevice: rootDev, p.fileID) {
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

                    // Rebuilding the child path as a String would mangle a name
                    // that is not valid UTF-8, and the open would then fail on a
                    // folder that is perfectly readable. It cannot happen: APFS
                    // refuses such a name at creation with EILSEQ, checked by
                    // trying it. A network share serving one is the case this
                    // does not cover.
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
        return stats
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
