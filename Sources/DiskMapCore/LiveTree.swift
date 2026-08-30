import Darwin
import Foundation

/// A scanned tree that keeps itself in step with the filesystem.
///
/// Every filesystem event is reduced to "relist this one directory". That single
/// operation covers create, delete, rename and resize, and it reuses the
/// subtrees of directories that did not change, so the cost is proportional to
/// the entries in the affected directory rather than to the tree below it.
public final class LiveTree: @unchecked Sendable {
    public let rootPath: String
    public private(set) var stats: ScanStats
    private var store: NodeStore
    private let lock = NSRecursiveLock()
    private var watcher: FileSystemWatcher?
    private var pending = Set<String>()
    private var flushScheduled = false
    private let applyQueue = DispatchQueue(label: "diskmap.live", qos: .utility)

    /// Called on the main queue after the tree changed.
    public var onChange: (@Sendable () -> Void)?
    public private(set) var liveUpdatesActive = false
    public private(set) var lastChangeAt: Date?

    public init(result: ScanResult) {
        self.store = result.store
        self.stats = result.stats
        self.rootPath = result.rootPath
    }

    /// All reads of the tree go through here; live updates mutate under the same lock.
    public func withStore<T>(_ body: (NodeStore) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(store)
    }

    public func startWatching() {
        guard watcher == nil else { return }
        let w = FileSystemWatcher(paths: [rootPath]) { [weak self] paths in
            self?.enqueue(paths)
        }
        w.start()
        watcher = w
        liveUpdatesActive = true
    }

    public func stopWatching() {
        watcher?.stop(); watcher = nil; liveUpdatesActive = false
    }

    /// True when `path` is the root or sits beneath it. Compares against
    /// "root/" so that `/Users/md/dev` does not swallow `/Users/md/development`.
    private func isInsideRoot(_ path: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    private func enqueue(_ paths: [String]) {
        lock.lock()
        for p in paths {
            // Reduce every event to the directory that must be relisted.
            var isDir: ObjCBool = false
            var dir = FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
                ? p : (p as NSString).deletingLastPathComponent
            if !isInsideRoot(dir) {
                guard let canon = canonicalPath(dir), isInsideRoot(canon) else { continue }
                dir = canon
            }
            pending.insert(dir)
        }
        let shouldFlush = !flushScheduled && !pending.isEmpty
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

        var changed = false
        lock.lock()
        for d in roots where relist(directory: d) { changed = true }
        lock.unlock()

        if changed {
            lastChangeAt = Date()
            let cb = onChange
            DispatchQueue.main.async { cb?() }
        }
    }

    /// Rebuilds one directory's child list in place. Returns true if anything moved.
    @discardableResult
    private func relist(directory rawPath: String) -> Bool {
        // Callers hand us whatever path they have. The tree is rooted at the
        // resolved form, so normalise before looking anything up. realpath
        // fails for a directory that has just been deleted, hence the fallback.
        let path = canonicalPath(rawPath) ?? rawPath
        guard let node = store.find(path: path, rootPath: rootPath)
                ?? store.find(path: rawPath, rootPath: rootPath) else { return false }
        guard store.isDirectory(node) else { return false }

        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            // Vanished: drop its whole contribution from the ancestors.
            let dl = -store.totalLogical[Int(node)], dp = -store.totalPhysical[Int(node)]
            store.totalLogical[Int(node)] = 0; store.totalPhysical[Int(node)] = 0
            store.childCount[Int(node)] = 0
            store.flags[Int(node)] |= NodeFlags.removed.rawValue
            store.propagate(from: node, logical: dl, physical: dp)
            return true
        }
        defer { close(fd) }

        var existing: [String: Int32] = [:]
        for c in store.children(node) where !store.flagSet(c).contains(.removed) {
            existing[store.name(c)] = c
        }

        struct Entry { var name: String; var logical: Int64; var physical: Int64
                       var mtime: Int32; var flags: NodeFlags }
        var entries: [Entry] = []
        _ = BulkReader().enumerate(dirFD: fd) { e in
            var fl = NodeFlags()
            if e.isDir { fl.insert(.directory) }
            if e.isSymlink { fl.insert(.symlink) }
            if e.isDataless { fl.insert(.dataless) }
            if e.stFlags & UF_COMPRESSED_FLAG != 0 { fl.insert(.compressed) }
            entries.append(Entry(name: String(decoding: UnsafeRawBufferPointer(start: e.name, count: e.nameLen), as: UTF8.self),
                                 logical: e.logicalSize, physical: e.isDataless ? 0 : e.physicalSize,
                                 mtime: Int32(truncatingIfNeeded: e.mtime), flags: fl))
        }

        let oldLogical = store.totalLogical[Int(node)]
        let oldPhysical = store.totalPhysical[Int(node)]
        let oldChildren = Array(store.children(node))

        // Detect a pure no-op so idle FSEvents traffic does not churn memory.
        if entries.count == oldChildren.count {
            var identical = true
            for e in entries {
                guard let c = existing[e.name] else { identical = false; break }
                if !store.isDirectory(c),
                   store.totalPhysical[Int(c)] != e.physical || store.totalLogical[Int(c)] != e.logical {
                    identical = false; break
                }
            }
            if identical { return false }
        }

        let base = Int32(store.count)
        var newLogical: Int64 = 0, newPhysical: Int64 = 0
        var reused = Set<Int32>()

        for e in entries {
            let nameBytes = Array(e.name.utf8)
            let newID: Int32 = nameBytes.withUnsafeBytes { nb -> Int32 in
                store.append(name: nb.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!,
                             nameLength: nb.count, parent: node,
                             logical: e.flags.contains(.directory) ? 0 : e.logical,
                             physical: e.flags.contains(.directory) ? 0 : e.physical,
                             mtime: e.mtime, flags: e.flags)
            }
            if e.flags.contains(.directory) && !e.flags.contains(.symlink) {
                if let old = existing[e.name], store.isDirectory(old) {
                    store.reattach(oldNode: old, to: newID)   // keep the subtree
                    reused.insert(old)
                } else {
                    let sub = DiskScanner().scan(ScanOptions(rootPath: path + "/" + e.name))
                    store.graft(sub.store, under: newID)
                    store.totalLogical[Int(newID)] = sub.store.totalLogical[0]
                    store.totalPhysical[Int(newID)] = sub.store.totalPhysical[0]
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
        return true
    }

    /// Re-reads one directory right now, without waiting for FSEvents. Used
    /// after an action this app itself performed, and by tests that assert on
    /// update logic rather than on event delivery timing.
    @discardableResult
    public func refresh(directory path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return relist(directory: path)
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
        lastChangeAt = Date()
    }
}
