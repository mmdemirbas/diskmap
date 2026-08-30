import Darwin
import Foundation

public struct ScanOptions: Sendable {
    public var rootPath: String
    /// Off by default: an external drive is a separate budget, not part of this one.
    public var followMountPoints: Bool = false
    public var threadCount: Int = min(12, ProcessInfo.processInfo.activeProcessorCount)
    public var extraExclusions: Set<String> = []

    public init(rootPath: String) { self.rootPath = rootPath }

    /// Paths that must never be walked.
    ///
    /// `/net` and `/home` are autofs: merely opening them triggers an automount
    /// and can hang for the network timeout. The firmlinked paths are the same
    /// bytes as the Data volume reached by another name — walking them from `/`
    /// double-counts most of the disk.
    public func exclusions() -> Set<String> {
        var out: Set<String> = ["/dev", "/net", "/home", "/.vol", "/.fseventsd", "/.DocumentRevisions-V100"]
        if rootPath == "/" {
            out.formUnion(Firmlinks.mountPaths())
            out.insert("/System/Volumes/Data")
            out.insert("/Volumes")
        }
        out.formUnion(extraExclusions)
        return out
    }
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
}

public struct ScanResult: Sendable {
    public let store: NodeStore
    public let stats: ScanStats
    public let rootPath: String
    public var rootID: Int32 { 0 }
}

public struct ScanProgress: Sendable {
    public var nodes: Int
    public var directories: Int
    public var bytes: Int64
    public var currentPath: String
    /// Estimated from the volume's used-inode count. Nil for subtree scans,
    /// where no honest estimate exists.
    public var fraction: Double?
}

public final class DiskScanner {
    private struct Task { let path: String; let node: Int32 }

    private struct Pending {
        var nameOffset: Int; var nameLength: Int
        var logical: Int64; var physical: Int64
        var mtime: Int32; var flags: NodeFlags
        var fileID: UInt64; var linkCount: UInt32
    }

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
        // FSEvents always reports fully resolved paths ("/private/var/..."),
        // so the tree must be rooted at the resolved form or live updates
        // silently match nothing.
        var options = rawOptions
        options.rootPath = canonicalPath(rawOptions.rootPath) ?? rawOptions.rootPath
        let store = NodeStore()

        // statfs knows exactly how many inodes are in use. For a whole-volume
        // scan that is the node count, so we can size the arrays once instead
        // of growing through ~24 reallocations, and show a real progress bar.
        let inodeEstimate = usedInodeCount(options.rootPath)
        let isVolumeRoot = Self.isVolumeRoot(options.rootPath)
        store.reserve(isVolumeRoot && inodeEstimate > 0 ? min(inodeEstimate, 60_000_000) : 1 << 20)
        var stats = ScanStats()
        let exclusions = options.exclusions()

        var rootStat = stat()
        guard lstat(options.rootPath, &rootStat) == 0 else {
            return ScanResult(store: store, stats: stats, rootPath: options.rootPath)
        }
        let rootDev = rootStat.st_dev

        // Node 0 is the root itself.
        let rootName = Array(options.rootPath.utf8)
        _ = rootName.withUnsafeBytes { buf in
            store.append(name: buf.baseAddress!, nameLength: buf.count, parent: -1,
                         logical: 0, physical: 0,
                         mtime: Int32(truncatingIfNeeded: rootStat.st_mtimespec.tv_sec),
                         flags: .directory)
        }

        let queue = Queue(seed: Task(path: options.rootPath, node: 0))
        let lock = NSLock()
        var seenMultiLinkInodes = Set<UInt64>()
        var currentPath = options.rootPath

        let progressTimer: DispatchSourceTimer? = progress.map { cb in
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now() + 0.1, repeating: 0.1)
            t.setEventHandler {
                lock.lock()
                let n = store.count
                let p = ScanProgress(nodes: n, directories: stats.directories,
                                     bytes: stats.totalPhysical, currentPath: currentPath,
                                     fraction: isVolumeRoot && inodeEstimate > 0
                                         ? min(1.0, Double(n) / Double(inodeEstimate)) : nil)
                lock.unlock()
                cb(p)
            }
            t.resume()
            return t
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

                    let fd = open(task.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if fd < 0 {
                        lock.lock()
                        store.flags[Int(task.node)] |= NodeFlags.unreadable.rawValue
                        stats.unreadableDirectories += 1
                        if stats.unreadableSamples.count < 25 { stats.unreadableSamples.append(task.path) }
                        lock.unlock()
                        continue
                    }

                    var dst = stat()
                    if fstat(fd, &dst) == 0, dst.st_dev != rootDev, !options.followMountPoints {
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
                        let off = nameBuf.count
                        nameBuf.append(contentsOf: UnsafeRawBufferPointer(start: e.name, count: e.nameLen))

                        var fl = NodeFlags()
                        if e.isDir { fl.insert(.directory) }
                        if e.isSymlink { fl.insert(.symlink) }
                        if e.isDataless { fl.insert(.dataless) }
                        if e.stFlags & UF_COMPRESSED_FLAG != 0 { fl.insert(.compressed) }

                        // A dataless file's bytes live in iCloud, not here.
                        let physical = e.isDataless ? 0 : e.physicalSize

                        pending.append(Pending(nameOffset: off, nameLength: e.nameLen,
                                               logical: e.logicalSize, physical: physical,
                                               mtime: Int32(truncatingIfNeeded: e.mtime),
                                               flags: fl, fileID: e.fileID, linkCount: e.linkCount))
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
                            if p.linkCount > 1 && !p.flags.contains(.directory) {
                                if seenMultiLinkInodes.insert(p.fileID).inserted == false {
                                    p.flags.insert(.hardlinkDuplicate)
                                    stats.hardlinkDuplicates += 1
                                    stats.hardlinkDuplicateLogical += p.logical
                                    physical = 0
                                }
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
                    for (i, p) in pending.enumerated() where p.flags.contains(.directory) && !p.flags.contains(.symlink) {
                        let name = String(decoding: nameBuf[p.nameOffset..<(p.nameOffset + p.nameLength)], as: UTF8.self)
                        let childPath = prefix + "/" + name
                        if exclusions.contains(childPath) {
                            lock.lock(); store.flags[Int(base) + i] |= NodeFlags.excluded.rawValue; lock.unlock()
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

        store.aggregate()
        stats.elapsed = Date().timeIntervalSince(started)
        stats.totalLogical = store.totalLogical[0]
        stats.totalPhysical = store.totalPhysical[0]
        return ScanResult(store: store, stats: stats, rootPath: options.rootPath)
    }
}


/// Inodes currently allocated on the filesystem containing `path`.
func usedInodeCount(_ path: String) -> Int {
    var fs = statfs()
    guard statfs(path, &fs) == 0 else { return 0 }
    return max(0, Int(fs.f_files) - Int(fs.f_ffree))
}


/// Fully resolved path, with symlinks and `.`/`..` removed.
public func canonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
