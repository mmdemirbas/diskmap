import Darwin
import Foundation

/// A scanned tree that keeps itself in step with the filesystem.
///
/// Every filesystem event is reduced to "relist this one directory". That single
/// operation covers create, delete, rename and resize, and it reuses the
/// subtrees of directories that did not change, so the cost is proportional to
/// the entries in the affected directory rather than to the tree below it.
public final class LiveTree: @unchecked Sendable {
    /// Every folder being watched. One entry is the ordinary case; several
    /// means the tree has a synthetic node 0 with the roots beneath it.
    public let roots: [String]
    public var rootPath: String { roots.first ?? "" }
    public private(set) var stats: ScanStats
    private var store: NodeStore
    private let lock = NSRecursiveLock()
    private var watcher: FileSystemWatcher?
    private var pending = Set<String>()
    private var flushScheduled = false
    private let applyQueue = DispatchQueue(label: "diskmap.live", qos: .utility)

    /// Called on the main queue after the tree changed.
    public var onChange: (@Sendable () -> Void)?
    private var watching = false
    private var lastChange: Date?
    private var changes = 0
    /// Increments whenever the store is mutated. Anything cached against the
    /// tree keys on this rather than on a UI counter, which also moves when
    /// somebody types in the filter box and the tree has not changed at all.
    public var changeCount: Int { lock.lock(); defer { lock.unlock() }; return changes }
    public var liveUpdatesActive: Bool { lock.lock(); defer { lock.unlock() }; return watching }
    public var lastChangeAt: Date? { lock.lock(); defer { lock.unlock() }; return lastChange }

    public private(set) var rejectedRoots: [RejectedRoot]

    public init(result: ScanResult) {
        self.store = result.store
        self.stats = result.stats
        self.roots = result.roots
        self.rejectedRoots = result.rejectedRoots
    }

    /// All reads of the tree go through here; live updates mutate under the same lock.
    public func withStore<T>(_ body: (NodeStore) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(store)
    }

    public func startWatching() {
        guard watcher == nil, !roots.isEmpty else { return }
        let w = FileSystemWatcher(paths: roots) { [weak self] paths in
            self?.enqueue(paths)
        }
        w.start()
        watcher = w
        lock.lock(); watching = true; lock.unlock()
    }

    public func stopWatching() {
        watcher?.stop(); watcher = nil
        lock.lock(); watching = false; lock.unlock()
    }

    /// True when `path` is one of the roots or sits beneath one. Compares
    /// against "root/" so `/Users/md/dev` does not swallow `/Users/md/development`.
    private func isInsideRoot(_ path: String) -> Bool {
        candidatePaths(path).contains { candidate in
            roots.contains { candidate == $0 || candidate.hasPrefix($0 == "/" ? "/" : $0 + "/") }
        }
    }

    /// FSEvents reports `/Users/md/...`; a Data-volume tree stores
    /// `/System/Volumes/Data/Users/md/...`. Both forms have to be considered.
    private func candidatePaths(_ path: String) -> [String] {
        guard let onData = Firmlinks.onDataVolume(path) else { return [path] }
        return [path, onData]
    }

    private func enqueue(_ paths: [String]) {
        // Resolving an event to a directory costs a stat() and sometimes a
        // realpath(). Under the lock that would block every UI read on
        // filesystem calls during an event burst — the exact thing the
        // three-phase relist below exists to avoid. `roots` is immutable, so
        // this needs no lock at all.
        var dirs: [String] = []
        dirs.reserveCapacity(paths.count)
        for p in paths {
            // Reduce every event to the directory that must be relisted.
            var isDir: ObjCBool = false
            var dir = FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
                ? p : (p as NSString).deletingLastPathComponent
            if !isInsideRoot(dir) {
                guard let canon = canonicalPath(dir), isInsideRoot(canon) else { continue }
                dir = canon
            }
            dirs.append(dir)
        }
        guard !dirs.isEmpty else { return }

        lock.lock()
        for dir in dirs { pending.insert(dir) }
        let shouldFlush = !flushScheduled
        if shouldFlush { flushScheduled = true }
        lock.unlock()

        guard shouldFlush else { return }
        applyQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.flush() }
    }

    private func flush() {
        lock.lock()
        let dirs = pending
        pending.removeAll()
        flushScheduled = false
        lock.unlock()
        guard !dirs.isEmpty else { return }

        // A parent relist already covers its descendants in this batch.
        let sorted = dirs.sorted { $0.count < $1.count }
        var roots: [String] = []
        for d in sorted where !roots.contains(where: { d == $0 || d.hasPrefix($0 + "/") }) {
            roots.append(d)
        }

        // No lock across the loop: relist takes it only for the two short
        // phases that touch the store.
        let span = Telemetry.begin("live.flush")
        var changed = false
        var moved = 0
        for d in roots where relist(directory: d) { changed = true; moved += 1 }
        span.end(["events": .int(Int64(dirs.count)), "relisted": .int(Int64(roots.count)),
                  "changed": .int(Int64(moved))], minMilliseconds: 20)

        if changed {
            lock.lock()
            lastChange = Date()
            let cb = onChange
            lock.unlock()
            DispatchQueue.main.async { cb?() }
        }
    }

    private struct DirEntry {
        var name: String
        var logical: Int64
        var physical: Int64
        var mtime: Int32
        var flags: NodeFlags
    }

    /// Rebuilds one directory's child list in place. Returns true if anything moved.
    ///
    /// Split into three phases so the lock is never held across filesystem work.
    /// Scanning a newly appeared folder can take seconds; doing that under the
    /// lock would block every UI read for the whole duration.
    @discardableResult
    private func relist(directory rawPath: String) -> Bool {
        let path = canonicalPath(rawPath) ?? rawPath

        // Phase A: locate the node and note the names it already holds.
        lock.lock()
        guard let node = store.find(path: path), store.isDirectory(node) else {
            lock.unlock(); return false
        }
        var knownNames = Set<String>()
        for c in store.children(node) where !store.flagSet(c).contains(.removed) {
            knownNames.insert(store.name(c))
        }
        lock.unlock()

        // Phase B: filesystem work, no lock held.
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { return markVanished(node) }
        var entries: [DirEntry] = []
        _ = BulkReader().enumerate(dirFD: fd) { e in
            var fl = NodeFlags()
            if e.isDir { fl.insert(.directory) }
            if e.isSymlink { fl.insert(.symlink) }
            if e.isDataless { fl.insert(.dataless) }
            if e.stFlags & UF_COMPRESSED_FLAG != 0 { fl.insert(.compressed) }
            entries.append(DirEntry(
                name: String(decoding: UnsafeRawBufferPointer(start: e.name, count: e.nameLen), as: UTF8.self),
                logical: e.logicalSize, physical: e.isDataless ? 0 : e.physicalSize,
                mtime: Int32(truncatingIfNeeded: e.mtime), flags: fl))
        }
        close(fd)

        // Only genuinely new subdirectories need scanning; the rest keep the
        // subtree they already have.
        var freshSubtrees: [String: NodeStore] = [:]
        for e in entries where e.flags.contains(.directory)
            && !e.flags.contains(.symlink) && !knownNames.contains(e.name) {
            freshSubtrees[e.name] = DiskScanner().scan(ScanOptions(rootPath: path + "/" + e.name)).store
        }

        // Phase C: commit. Re-read the node, since the tree may have moved on.
        lock.lock(); defer { lock.unlock() }
        guard node < Int32(store.count), store.isDirectory(node),
              !store.flagSet(node).contains(.removed) else { return false }

        var existing: [String: Int32] = [:]
        for c in store.children(node) where !store.flagSet(c).contains(.removed) {
            existing[store.name(c)] = c
        }

        // The common event by far is "a file in this folder changed size" —
        // a build writing output, a log growing, a download filling in. The
        // names are the same, so nothing needs to be appended: updating the
        // rows in place keeps the store from growing on every event, which
        // over a working day is otherwise hundreds of megabytes of nodes that
        // are immediately marked removed.
        if entries.count == existing.count,
           entries.allSatisfy({ e in
               guard let c = existing[e.name] else { return false }
               return store.isDirectory(c) == e.flags.contains(.directory)
           }) {
            var delta: Int64 = 0, deltaPhysical: Int64 = 0
            for e in entries {
                let c = existing[e.name]!
                guard !store.isDirectory(c) else { continue }
                delta += e.logical - store.totalLogical[Int(c)]
                deltaPhysical += e.physical - store.totalPhysical[Int(c)]
                store.totalLogical[Int(c)] = e.logical
                store.totalPhysical[Int(c)] = e.physical
                store.mtime[Int(c)] = e.mtime
                store.flags[Int(c)] = e.flags.rawValue
            }
            guard delta != 0 || deltaPhysical != 0 else { return false }
            Telemetry.record("live.resize", ["entries": .int(Int64(entries.count)),
                                             "physical": .int(deltaPhysical)])
            changes += 1
            store.totalLogical[Int(node)] += delta
            store.totalPhysical[Int(node)] += deltaPhysical
            store.propagate(from: node, logical: delta, physical: deltaPhysical)
            return true
        }

        let oldLogical = store.totalLogical[Int(node)]
        let oldPhysical = store.totalPhysical[Int(node)]
        let oldChildren = Array(store.children(node))
        let base = Int32(store.count)
        var newLogical: Int64 = 0, newPhysical: Int64 = 0
        var reused = Set<Int32>()

        for e in entries {
            let nameBytes = Array(e.name.utf8)
            let isDir = e.flags.contains(.directory)
            let newID: Int32 = nameBytes.withUnsafeBytes { nb -> Int32 in
                store.append(name: nb.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!,
                             nameLength: nb.count, parent: node,
                             logical: isDir ? 0 : e.logical,
                             physical: isDir ? 0 : e.physical,
                             mtime: e.mtime, flags: e.flags)
            }
            if isDir && !e.flags.contains(.symlink) {
                if let old = existing[e.name], store.isDirectory(old) {
                    store.reattach(oldNode: old, to: newID)   // keep the subtree
                    reused.insert(old)
                } else if let sub = freshSubtrees[e.name] {
                    store.graft(sub, under: newID)
                    store.totalLogical[Int(newID)] = sub.totalLogical[0]
                    store.totalPhysical[Int(newID)] = sub.totalPhysical[0]
                }
            }
            newLogical += store.totalLogical[Int(newID)]
            newPhysical += store.totalPhysical[Int(newID)]
        }

        for c in oldChildren where !reused.contains(c) {
            store.flags[Int(c)] |= NodeFlags.removed.rawValue
        }
        store.firstChild[Int(node)] = base
        store.childCount[Int(node)] = Int32(entries.count)
        store.totalLogical[Int(node)] = newLogical
        store.totalPhysical[Int(node)] = newPhysical
        store.propagate(from: node, logical: newLogical - oldLogical, physical: newPhysical - oldPhysical)
        changes += 1
        Telemetry.record("live.relist", [
            "entries": .int(Int64(entries.count)),
            "reused": .int(Int64(reused.count)),
            "scanned": .int(Int64(freshSubtrees.count)),
            "nodes": .int(Int64(store.count)),
        ])
        return true
    }

    /// The directory is gone: drop its whole contribution from the ancestors.
    private func markVanished(_ node: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard node < Int32(store.count), !store.flagSet(node).contains(.removed) else { return false }
        let dl = -store.totalLogical[Int(node)], dp = -store.totalPhysical[Int(node)]
        store.totalLogical[Int(node)] = 0
        store.totalPhysical[Int(node)] = 0
        store.childCount[Int(node)] = 0
        store.flags[Int(node)] |= NodeFlags.removed.rawValue
        store.propagate(from: node, logical: dl, physical: dp)
        changes += 1
        return true
    }

    /// Re-reads one directory right now, without waiting for FSEvents. Used
    /// after an action this app itself performed, and by tests that assert on
    /// update logic rather than on event delivery timing.
    @discardableResult
    public func refresh(directory path: String) -> Bool {
        relist(directory: path)
    }

    /// Applies a deletion immediately, so the UI reflects a trashed item before
    /// FSEvents reports it. The later event resolves to a no-op relist.
    public func markRemoved(_ node: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard node > 0, !store.flagSet(node).contains(.removed) else { return }
        let dl = -store.totalLogical[Int(node)], dp = -store.totalPhysical[Int(node)]
        store.flags[Int(node)] |= NodeFlags.removed.rawValue
        store.totalLogical[Int(node)] = 0
        store.totalPhysical[Int(node)] = 0
        store.propagate(from: node, logical: dl, physical: dp)
        lastChange = Date()
        changes += 1
    }
}
