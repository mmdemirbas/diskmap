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
    /// The same, as bytes, made once: every event is checked against them.
    private let rootPaths: [RawPath]
    public var rootPath: String { roots.first ?? "" }
    public private(set) var stats: ScanStats
    private var store: NodeStore
    private let lock = NSRecursiveLock()
    private var watcher: FileSystemWatcher?
    private var pending = Set<RawPath>()
    private var flushScheduled = false
    private let applyQueue = DispatchQueue(label: "diskmap.live", qos: .utility)

    /// How long the last flush took, and whether anyone is watching.
    ///
    /// A fixed third-of-a-second debounce means a machine doing steady work —
    /// a build, a sync, an install — keeps the tree busy about three quarters
    /// of the time, indefinitely. Waiting in proportion to what the last flush
    /// actually cost turns that into a duty cycle: a quiet disk still updates
    /// in a third of a second, a busy one backs off on its own, and no constant
    /// has to guess how fast this particular machine writes.
    var lastFlushSeconds: Double = 0
    public private(set) var suspended = false
    /// Counters folded into the next flush record. One line per relist is a
    /// disk write per filesystem event, which is a cost the instrumentation
    /// adds to the thing it is measuring.
    private var resizedSinceFlush = 0
    private var entriesSinceFlush = 0
    private var scannedSinceFlush = 0

    /// What each directory last cost to relist, and when it was last done.
    ///
    /// One folder can dominate everything else put together. Measured on a
    /// working machine, a browser cache holding 78,995 entries produced 1,567
    /// events in two minutes, and every relist of it walks all 78,995 and
    /// appends that many rows — essentially the whole of the store's growth and
    /// most of the CPU, from one directory nobody has ever looked at in this
    /// app. Each directory is therefore held off in proportion to what it cost
    /// last time, so an expensive one settles into its own duty cycle while a
    /// small one beside it stays immediate.
    ///
    /// Only ever touched from `applyQueue`, which is serial.
    private var lastRelist: [RawPath: (at: DispatchTime, cost: Double)] = [:]
    var lastRelistCount: Int { lastRelist.count }
    private static let holdOffFactor = 10.0
    /// However expensive a folder is, it is never more than this out of date.
    private static let holdOffCeiling = 30.0

    /// Seconds still to wait before this directory is worth relisting again,
    /// or nil if it may be done now.
    func holdOff(_ dir: String, now: DispatchTime) -> Double? {
        holdOff(RawPath(dir), now: now)
    }

    func holdOff(_ dir: RawPath, now: DispatchTime) -> Double? {
        guard let last = lastRelist[dir] else { return nil }
        let wait = min(last.cost * Self.holdOffFactor, Self.holdOffCeiling)
        let since = Double(now.uptimeNanoseconds - last.at.uptimeNanoseconds) / 1e9
        return since < wait ? wait - since : nil
    }

    func noteRelist(_ dir: String, cost: Double, at: DispatchTime) {
        noteRelist(RawPath(dir), cost: cost, at: at)
    }

    func noteRelist(_ dir: RawPath, cost: Double, at: DispatchTime) {
        lastRelist[dir] = (at, cost)
        guard lastRelist.count > 4096 else { return }
        // Bounded: drop the quarter that has gone longest without an event.
        let ages = lastRelist.values.map(\.at.uptimeNanoseconds).sorted()
        let cutoff = ages[ages.count / 4]
        lastRelist = lastRelist.filter { $0.value.at.uptimeNanoseconds > cutoff }
    }

    /// Quiet: answer quickly. Busy: keep the duty cycle near a fifth.
    /// Unwatched: correctness still matters, promptness does not.
    public var flushDelay: Double {
        if suspended { return 30 }
        return min(max(0.35, lastFlushSeconds * 5), 8)
    }

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

    /// Which node keeps each multi-link inode's bytes. The walk gives a
    /// file's bytes to the first link it meets and flags the rest; a relist
    /// sees a flagged link as a plain file in the listing, and a folder that
    /// appears may hold a link to bytes the tree already counts. This table
    /// is how the relist knows. Consulted under the store lock, since who
    /// keeps what is part of what the tree says.
    private let inodes: InodeSet

    public init(result: ScanResult) {
        self.store = result.store
        self.stats = result.stats
        self.roots = result.roots
        self.rootPaths = result.roots.map(RawPath.init)
        self.rejectedRoots = result.rejectedRoots
        self.inodes = result.inodes
        var st = stat()
        self.rootDevice = result.roots.first.flatMap { RawPath($0).withCString { lstat($0, &st) } == 0 ? st.st_dev : nil } ?? 0
    }

    private let rootDevice: Int32

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
    private func isInsideRoot(_ path: RawPath) -> Bool {
        candidatePaths(path).contains { candidate in
            rootPaths.contains { candidate.isInside($0) }
        }
    }

    /// FSEvents reports `/Users/md/...`; a Data-volume tree stores
    /// `/System/Volumes/Data/Users/md/...`. Both forms have to be considered.
    private func candidatePaths(_ path: RawPath) -> [RawPath] {
        guard let onData = Firmlinks.onDataVolume(path) else { return [path] }
        return [path, onData]
    }

    /// Whether the path names a directory right now. `lstat` on the bytes,
    /// because `fileExists(atPath:)` takes text.
    private static func isDirectory(_ path: RawPath) -> Bool {
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func enqueue(_ paths: [RawPath]) {
        // Resolving an event to a directory costs a stat() and sometimes a
        // realpath(). Under the lock that would block every UI read on
        // filesystem calls during an event burst — the exact thing the
        // three-phase relist below exists to avoid. `roots` is immutable, so
        // this needs no lock at all.
        let dirs = paths.compactMap(directoryToRelist)
        guard !dirs.isEmpty else { return }

        lock.lock()
        for dir in dirs { pending.insert(dir) }
        let shouldFlush = !flushScheduled
        if shouldFlush { flushScheduled = true }
        let delay = flushDelay
        lock.unlock()

        guard shouldFlush else { return }
        applyQueue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush() }
    }

    /// Live updates never stop — the tree has to be right the moment the window
    /// comes back, and a window that lies is the thing this app exists not to
    /// be. What changes is the rate. Nobody needs a third-of-a-second response
    /// from a window they are not looking at, and over a working day that
    /// difference is most of what the app costs the battery.
    public func setSuspended(_ value: Bool) {
        lock.lock()
        let resuming = suspended && !value
        suspended = value
        // Coming back to the front, apply whatever accumulated straight away
        // rather than leaving the user looking at a stale tree for 30 seconds.
        let wake = resuming && !pending.isEmpty && !flushScheduled
        if wake { flushScheduled = true }
        lock.unlock()
        if wake { applyQueue.async { [weak self] in self?.flush() } }
    }

    /// Reduces an event to the directory that must be relisted: the path
    /// itself when it is a directory, otherwise the one holding it. Inside a
    /// root in either the reported or the resolved form, or nothing.
    private func directoryToRelist(for event: RawPath) -> RawPath? {
        let dir = Self.isDirectory(event) ? event : event.parent
        if isInsideRoot(dir) { return dir }
        guard let canon = canonicalPath(dir), isInsideRoot(canon) else { return nil }
        return canon
    }

    /// What the watcher would have handed over, applied now and on this
    /// thread. For tests, which otherwise have to wait on the event stream
    /// and the debounce to see a batch handled.
    func flushNow(events: [RawPath]) {
        lock.lock()
        for d in events.compactMap(directoryToRelist) { pending.insert(d) }
        lock.unlock()
        flush()
        // A folder relisted a moment ago is held off, and the flush that
        // comes back for it is asynchronous. A test wants the tree as it
        // will be, now: forget the hold-offs and apply what was deferred.
        lock.lock()
        let deferred = !pending.isEmpty
        lock.unlock()
        if deferred {
            lastRelist.removeAll()
            flush()
        }
    }

    private func flush() {
        lock.lock()
        let dirs = pending
        pending.removeAll()
        flushScheduled = false
        lock.unlock()
        guard !dirs.isEmpty else { return }

        // An event names the thing that changed, and a directory that was
        // just made — or deleted and made again — is a thing the store has
        // never seen. Relisting it would find nothing and nothing would be
        // added; what has to be relisted is the nearest folder above it the
        // store does hold, whose relist then measures it as a fresh subtree.
        //
        // Nothing below that is dropped. A parent's relist keeps a known
        // subfolder's subtree exactly as it was, so a subfolder that changed
        // in the same batch as its parent needs its own relist as well.
        // Parents go first, so the child's relist finds the node its parent
        // just moved.
        //
        // And a folder that is gone is reduced first to the nearest folder
        // above it that still exists — with no lock, a stat per step, and
        // one answer per folder — so a tree deleted whole costs one relist
        // of the folder that held it rather than a lookup and a failed open
        // for every folder that was in it.
        var present: [RawPath: RawPath] = [:]
        func nearestPresent(_ dir: RawPath) -> RawPath? {
            if let hit = present[dir] { return hit }
            var d = dir
            while !Self.isDirectory(d) {
                guard !d.isRoot, isInsideRoot(d.parent) else { return nil }
                d = d.parent
            }
            present[dir] = d
            return d
        }
        let standing = Set(dirs.compactMap(nearestPresent))
        lock.lock()
        let known = Set(standing.compactMap { nearestKnown($0) })
        lock.unlock()
        let roots = known.sorted { $0.bytes.count < $1.bytes.count }

        // No lock across the loop: relist takes it only for the two short
        // phases that touch the store.
        let span = Telemetry.begin("live.flush")
        let began = DispatchTime.now()
        var changed = false
        var moved = 0
        var deferred: [(RawPath, Double)] = []
        for d in roots {
            let now = DispatchTime.now()
            if let wait = holdOff(d, now: now) { deferred.append((d, wait)); continue }
            let did = relist(directory: d)
            let after = DispatchTime.now()
            noteRelist(d, cost: Double(after.uptimeNanoseconds - now.uptimeNanoseconds) / 1e9,
                       at: after)
            if did { changed = true; moved += 1 }
        }

        resolveTouchedInodes()

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds
                             - began.uptimeNanoseconds) / 1e9
        lock.lock()
        // The next debounce is set from this, so it is measured whether or not
        // the record clears the reporting threshold.
        lastFlushSeconds = elapsed
        let resized = resizedSinceFlush, entries = entriesSinceFlush
        let scanned = scannedSinceFlush, nodes = store.count
        resizedSinceFlush = 0; entriesSinceFlush = 0; scannedSinceFlush = 0
        lock.unlock()

        span.end(["events": .int(Int64(dirs.count)), "relisted": .int(Int64(roots.count)),
                  "changed": .int(Int64(moved)), "resized": .int(Int64(resized)),
                  "entries": .int(Int64(entries)), "scanned": .int(Int64(scanned)),
                  "nodes": .int(Int64(nodes)), "held": .int(Int64(deferred.count))],
                 minMilliseconds: 20)

        // A directory that was held off is still owed a relist. Come back when
        // the earliest hold-off expires rather than spinning on the debounce,
        // so a folder waiting half a minute does not keep the process awake.
        if !deferred.isEmpty {
            let wakeIn = max(0.25, deferred.map(\.1).min() ?? 0.25)
            lock.lock()
            for (d, _) in deferred { pending.insert(d) }
            let schedule = !flushScheduled
            if schedule { flushScheduled = true }
            lock.unlock()
            if schedule {
                applyQueue.asyncAfter(deadline: .now() + wakeIn) { [weak self] in self?.flush() }
            }
        }

        if changed {
            lock.lock()
            lastChange = Date()
            let cb = onChange
            lock.unlock()
            DispatchQueue.main.async { cb?() }
        }
    }

    /// The nearest directory at or above `dir` that the store holds and has
    /// not marked removed, or nil when the walk leaves every root. The caller
    /// holds the lock. The chain is short: it ends at the scan root at the
    /// latest, and a fresh folder is normally one step below a known one.
    private func nearestKnown(_ dir: RawPath) -> RawPath? {
        var d = dir
        while true {
            // `lookup`, not `find`: the lock is held, and a miss here is the
            // ordinary case — a folder that just appeared — not a path in
            // need of resolving. Resolving would be a syscall per miss under
            // the lock, thousands of them when a tree is unpacked.
            if let node = store.lookup(d), store.isDirectory(node),
               !store.flagSet(node).contains(.removed) {
                return d
            }
            guard !d.isRoot, isInsideRoot(d.parent) else { return nil }
            d = d.parent
        }
    }

    private struct DirEntry {
        /// As listed, never decoded: a relist writes these back into the
        /// store, and a name that went through text on the way would come
        /// back with U+FFFD in it and stop naming the file it names.
        var name: [UInt8]
        var logical: Int64
        var physical: Int64
        var mtime: Int32
        var flags: NodeFlags
        var fileID: UInt64
        var linkCount: UInt32
        var isMultiLinkFile: Bool {
            linkCount > 1 && !flags.contains(.directory) && !flags.contains(.symlink)
        }
    }

    struct InodeRef: Hashable { let device: Int32; let id: UInt64 }
    /// Inodes met during this flush whose keeper the table could not name.
    /// Only ever touched from `applyQueue`, like `lastRelist`.
    private var unresolvedInodes = Set<InodeRef>()

    /// The one pass that needs the inode column. For every inode the batch
    /// met without a keeper it could name, every live node holding that
    /// inode is found — the file that had one link at scan time and was
    /// just given another is the usual find — and the bytes are settled on
    /// exactly one of them: the one already keeping them if any, else the
    /// oldest. Every other link is flagged and zeroed. One walk over the
    /// column however many inodes are in question, so a package manager
    /// linking a thousand files costs one pass, not a thousand.
    private func resolveTouchedInodes() {
        guard !unresolvedInodes.isEmpty else { return }
        let wanted = unresolvedInodes
        unresolvedInodes.removeAll()
        lock.lock(); defer { lock.unlock() }
        //
        // The inode column can lie in one direction: a deleted file's number
        // is reassigned by the volume to the next new file, so a stored id
        // may now belong to something else. Each candidate is confirmed by
        // its current path: only a node whose file still carries that inode
        // is a link of the group. A node whose file was replaced lstats to a
        // different number and drops out — it is settled by its own listing.
        var holders: [UInt64: [Int32]] = [:]
        let ids = Set(wanted.map(\.id))
        for i in 0..<store.count where ids.contains(store.fileID[i]) {
            let n = Int32(i)
            guard !store.isDirectory(n), !store.flagSet(n).contains(.symlink), isLive(n) else { continue }
            var info = stat()
            guard store.pathBytes(n).withCString({ lstat($0, &info) }) == 0,
                  info.st_ino == store.fileID[i] else { continue }
            holders[store.fileID[i], default: []].append(n)
        }
        for ref in wanted {
            guard let nodes = holders[ref.id], !nodes.isEmpty else { continue }
            // The keeper: whoever holds the bytes now, else the oldest name.
            let current = nodes.filter { !store.flagSet($0).contains(.hardlinkDuplicate) }
            let keeper = current.min() ?? nodes.min()!
            // The sizes come from the disk. Nothing stored can be trusted
            // here: a link met by a subtree walk was zeroed, a keeper handed
            // its bytes over at whatever size it last had, and the write that
            // made this inode a question may have gone through any name.
            var logical = store.totalLogical[Int(keeper)]
            var bytes = nodes.map { store.totalPhysical[Int($0)] }.max() ?? 0
            var info = stat()
            if store.pathBytes(keeper).withCString({ lstat($0, &info) }) == 0 {
                logical = Int64(info.st_size)
                if !store.flagSet(keeper).contains(.dataless) { bytes = Int64(info.st_blocks) * 512 }
            }
            for n in nodes {
                let isKeeper = n == keeper
                let want = isKeeper ? bytes : 0
                let dl = logical - store.totalLogical[Int(n)]
                let dp = want - store.totalPhysical[Int(n)]
                if isKeeper { store.flags[Int(n)] &= ~NodeFlags.hardlinkDuplicate.rawValue }
                else { store.flags[Int(n)] |= NodeFlags.hardlinkDuplicate.rawValue }
                if dl != 0 || dp != 0 {
                    store.totalLogical[Int(n)] = logical
                    store.totalPhysical[Int(n)] = want
                    store.propagate(from: n, logical: dl, physical: dp)
                }
            }
            inodes.settle(onDevice: ref.device, ref.id, keeper: keeper)
        }
    }

    /// A node the tree still shows: not removed, and under nothing removed.
    /// The caller holds the lock.
    private func isLive(_ node: Int32) -> Bool {
        var n = node
        while n >= 0 {
            if store.flagSet(n).contains(.removed) { return false }
            n = store.parent[Int(n)]
        }
        return true
    }

    /// Rebuilds one directory's child list in place. Returns true if anything moved.
    ///
    /// Split into three phases so the lock is never held across filesystem work.
    /// Scanning a newly appeared folder can take seconds; doing that under the
    /// lock would block every UI read for the whole duration.
    @discardableResult
    private func relist(directory rawPath: RawPath) -> Bool {
        let path = canonicalPath(rawPath) ?? rawPath

        // Phase A: locate the node and note the names it already holds.
        lock.lock()
        guard let node = store.find(path), store.isDirectory(node) else {
            lock.unlock(); return false
        }
        // The folders already held under this one, by name. A name held as
        // a *file* does not count: a file replaced by a folder of the same
        // name is a new folder, and it has to be measured like one rather
        // than entering the tree empty because its name was already known.
        var knownFolders = Set<[UInt8]>()
        for c in store.children(node) where !store.flagSet(c).contains(.removed)
            && store.isDirectory(c) && !store.flagSet(c).contains(.symlink) {
            knownFolders.insert(store.nameBytes(of: c))
        }
        lock.unlock()

        // Phase B: filesystem work, no lock held.
        let fd = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        if fd < 0 {
            // Only some of the ways this fails mean the directory is gone.
            // Running out of descriptors, an interrupted call, or a permission
            // that was revoked are all temporary, and treating them as a
            // deletion does real damage twice over: the folder's bytes leave
            // every total above it, and the next event on it finds no known
            // children and rescans the entire subtree from scratch.
            switch errno {
            case ENOENT, ENOTDIR, ELOOP: return markVanished(node)
            default: return false
            }
        }
        var dirStat = stat()
        let device: Int32 = fstat(fd, &dirStat) == 0 ? dirStat.st_dev : 0
        var entries: [DirEntry] = []
        _ = BulkReader().enumerate(dirFD: fd) { e in
            var fl = NodeFlags()
            if e.isDir { fl.insert(.directory) }
            if e.isSymlink { fl.insert(.symlink) }
            if e.isDataless { fl.insert(.dataless) }
            if e.stFlags & UF_COMPRESSED_FLAG != 0 { fl.insert(.compressed) }
            entries.append(DirEntry(
                name: Array(UnsafeRawBufferPointer(start: e.name, count: e.nameLen)),
                logical: e.logicalSize, physical: e.isDataless ? 0 : e.physicalSize,
                mtime: Int32(truncatingIfNeeded: e.mtime), flags: fl,
                fileID: e.fileID, linkCount: e.linkCount))
        }
        close(fd)

        // Only genuinely new subdirectories need scanning; the rest keep the
        // subtree they already have.
        var freshSubtrees: [[UInt8]: ScanResult] = [:]
        for e in entries where e.flags.contains(.directory)
            && !e.flags.contains(.symlink) && !knownFolders.contains(e.name) {
            var options = ScanOptions(rootPath: path.display)
            // A directory that has just appeared is nearly always empty or
            // close to it — a build creating an output folder, a package
            // manager laying down a tree one level at a time. Sizing for the
            // volume here is what made a live update cost hundreds of megabytes
            // of mapping per event; the arrays grow by themselves in the rare
            // case that something large arrives at once.
            options.expectedNodes = 4096
            // And it needs no thread pool. Twelve threads to read one empty
            // directory is most of the cost of reading it.
            options.threadCount = 2
            // Against the tree's own inode table, so a link in here to bytes
            // the tree already counts is flagged and not counted again.
            freshSubtrees[e.name] = DiskScanner().scan(subtree: path.appending(e.name),
                                                       options: options, inodes: inodes)
        }

        // Phase C: commit. Re-read the node, since the tree may have moved on.
        lock.lock(); defer { lock.unlock() }
        guard node < Int32(store.count), store.isDirectory(node),
              !store.flagSet(node).contains(.removed) else { return false }

        var existing: [[UInt8]: Int32] = [:]
        for c in store.children(node) where !store.flagSet(c).contains(.removed) {
            existing[store.nameBytes(of: c)] = c
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
            // The date and the flags are written here too, so the size alone
            // cannot say whether anything moved. A symlink is the case that
            // costs something: its contribution to a folder hash is *where it
            // points*, read from disk when hashing and never held in the store,
            // so re-pointing `current` from one release to a same-length
            // sibling changes no size at all. The revision then does not move,
            // and the report cache keyed on it keeps answering for where the
            // link used to point — including "these two folders are copies".
            var touched = false
            for e in entries {
                let c = existing[e.name]!
                guard !store.isDirectory(c) else { continue }
                delta += e.logical - store.totalLogical[Int(c)]
                deltaPhysical += e.physical - store.totalPhysical[Int(c)]
                if store.mtime[Int(c)] != e.mtime
                    || store.flags[Int(c)] != e.flags.rawValue { touched = true }
                let wasInode = store.fileID[Int(c)]
                store.totalLogical[Int(c)] = e.logical
                store.totalPhysical[Int(c)] = e.physical
                store.mtime[Int(c)] = e.mtime
                store.flags[Int(c)] = e.flags.rawValue
                noteMultiLink(e, at: c, device: device)
                // A name that was a link and is now a different file leaves
                // its old inode a name short; recompute that one too.
                if wasInode != 0, wasInode != e.fileID {
                    unresolvedInodes.insert(InodeRef(device: device, id: wasInode))
                }
            }
            guard delta != 0 || deltaPhysical != 0 || touched else { return false }
            // Counted as a resize only when something actually resized; this is
            // the number the flush interval is tuned against.
            if delta != 0 || deltaPhysical != 0 { resizedSinceFlush += 1 }
            entriesSinceFlush += entries.count
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
        // Fresh subtrees go in after the block, not into it. The block is
        // `children(node)`, one contiguous run from `base`; a subtree grafted
        // mid-loop put its nodes inside that run, so the folder listed the
        // subtree's nodes as its own and lost every sibling appended after.
        var grafts: [(under: Int32, sub: ScanResult)] = []

        for e in entries {
            let isDir = e.flags.contains(.directory)
            let newID: Int32 = e.name.withUnsafeBytes { nb -> Int32 in
                store.append(name: nb.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!,
                             nameLength: nb.count, parent: node,
                             logical: isDir ? 0 : e.logical,
                             physical: isDir ? 0 : e.physical,
                             mtime: e.mtime, flags: e.flags, fileID: e.fileID)
            }
            noteMultiLink(e, at: newID, device: device)
            if let old = existing[e.name], !store.isDirectory(old) {
                let wasInode = store.fileID[Int(old)]
                if wasInode != 0, wasInode != e.fileID {
                    unresolvedInodes.insert(InodeRef(device: device, id: wasInode))
                }
            }
            // Came back exactly as it was, under a new id only because the
            // block had to be rebuilt. Anything holding the old one can follow.
            if let old = existing[e.name],
               store.isDirectory(old) == isDir,
               store.mtime[Int(old)] == e.mtime,
               isDir || store.totalLogical[Int(old)] == e.logical {
                store.supersede(old, by: newID)
            }
            if isDir && !e.flags.contains(.symlink) {
                if let old = existing[e.name], store.isDirectory(old) {
                    store.reattach(oldNode: old, to: newID)   // keep the subtree
                    reused.insert(old)
                } else if let sub = freshSubtrees[e.name] {
                    store.totalLogical[Int(newID)] = sub.store.totalLogical[0]
                    store.totalPhysical[Int(newID)] = sub.store.totalPhysical[0]
                    grafts.append((newID, sub))
                }
            }
            newLogical += store.totalLogical[Int(newID)]
            newPhysical += store.totalPhysical[Int(newID)]
        }
        for g in grafts {
            let base = store.graft(g.sub.store, under: g.under)
            // The subtree's keepers, at the ids the graft gave them. Any of
            // them may be a link to bytes the tree holds under a name the
            // subtree walk could not see, so they are all looked at again
            // once the batch is done.
            if base >= 0 {
                for ref in inodes.absorb(g.sub.inodes, offset: base - 1) {
                    unresolvedInodes.insert(InodeRef(device: ref.device, id: ref.id))
                }
            }
        }

        var gone: [Int32] = []
        for c in oldChildren where !reused.contains(c) {
            store.flags[Int(c)] |= NodeFlags.removed.rawValue
            gone.append(c)
        }
        store.firstChild[Int(node)] = base
        store.childCount[Int(node)] = Int32(entries.count)
        store.totalLogical[Int(node)] = newLogical
        store.totalPhysical[Int(node)] = newPhysical
        store.propagate(from: node, logical: newLogical - oldLogical, physical: newPhysical - oldPhysical)
        // After the folder's own totals are settled, so a link promoted
        // inside this very folder adds its bytes on top of them.
        for c in gone { handOverKeptBytes(under: c) }
        changes += 1
        entriesSinceFlush += entries.count
        scannedSinceFlush += freshSubtrees.count
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
        handOverKeptBytes(under: node)
        changes += 1
        return true
    }

    /// A multi-link file the relist touched — created, resized, renamed,
    /// relinked or removed — is not settled where it is met. Which of an
    /// inode's names keeps its bytes is a walk-order fact two walks need
    /// not share, and tracking it incrementally through a rebuild that may
    /// touch several names at once drifts by a block. Instead the inode is
    /// noted, and `resolveTouchedInodes` recomputes it once from the column
    /// and the disk — the same answer a scan gives — for every inode any
    /// folder in the batch disturbed. Batches touching no hard link pay
    /// nothing. The caller holds the lock.
    private func noteMultiLink(_ e: DirEntry, at node: Int32, device: Int32) {
        guard e.isMultiLinkFile else { return }
        store.fileID[Int(node)] = e.fileID
        unresolvedInodes.insert(InodeRef(device: device, id: e.fileID))
    }

    /// A node has just been marked removed. Every multi-link file under it
    /// puts its inode on the list the flush resolves at the end: which name
    /// keeps the bytes, and what those bytes are, is a question best answered
    /// once from the column and the disk than tracked through a rebuild that
    /// may remove several names of one inode at once. A file still on disk
    /// under another name keeps its bytes; one whose last name went drops
    /// out, as it should. The caller holds the lock.
    private func handOverKeptBytes(under node: Int32) {
        var queue = [node]
        while let n = queue.popLast() {
            if store.isDirectory(n) {
                queue.append(contentsOf: store.children(n)); continue
            }
            guard store.fileID[Int(n)] != 0, !store.flagSet(n).contains(.symlink) else { continue }
            unresolvedInodes.insert(InodeRef(device: device(of: n), id: store.fileID[Int(n)]))
        }
    }

    /// The device an inode was recorded against. The relist keys by the
    /// directory's device; between scans everything is one volume, so the
    /// root's device is the answer whenever a folder's own is not to hand.
    private func device(of node: Int32) -> Int32 { rootDevice }

    /// Re-reads one directory right now, without waiting for FSEvents. Used
    /// after an action this app itself performed, and by tests that assert on
    /// update logic rather than on event delivery timing.
    @discardableResult
    public func refresh(directory path: String) -> Bool {
        relist(directory: RawPath(path))
    }

    @discardableResult
    public func refresh(directory path: RawPath) -> Bool {
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
        handOverKeptBytes(under: node)
        lastChange = Date()
        changes += 1
    }
}
