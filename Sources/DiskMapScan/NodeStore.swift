import Foundation

public struct NodeFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let directory         = NodeFlags(rawValue: 1 << 0)
    public static let symlink           = NodeFlags(rawValue: 1 << 1)
    /// iCloud placeholder: has a logical size but occupies no bytes here.
    public static let dataless          = NodeFlags(rawValue: 1 << 2)
    /// A second-or-later link to an inode already counted; physical set to 0.
    public static let hardlinkDuplicate = NodeFlags(rawValue: 1 << 3)
    public static let compressed        = NodeFlags(rawValue: 1 << 4)
    /// Directory we could not open (permissions, or FDA not granted).
    public static let unreadable        = NodeFlags(rawValue: 1 << 5)
    public static let mountPoint        = NodeFlags(rawValue: 1 << 6)
    public static let excluded          = NodeFlags(rawValue: 1 << 7)
    /// Deleted, or replaced by a newer node after a live refresh.
    public static let removed           = NodeFlags(rawValue: 1 << 8)
}

/// Structure-of-arrays tree. At 12M inodes an object graph would cost GBs and
/// shred cache locality, so every field is a flat array indexed by node id.
///
/// Invariant: a child's index is always greater than its parent's, because a
/// node must exist before it can be queued for traversal. Bottom-up aggregation
/// is therefore a single reverse pass, no sorting and no recursion.
public final class NodeStore {
    /// Absolute paths of the scan roots.
    ///
    /// One entry: node 0 *is* that folder. Several: node 0 is synthetic and its
    /// children are the roots, whose names are their own absolute paths.
    public internal(set) var roots: [String] = []
    public var isMultiRoot: Bool { roots.count > 1 }

    public internal(set) var nameBytes: [UInt8] = []

    /// Direct access to the interned names, for a search that would otherwise
    /// build a Swift string per node to throw it away again.
    public func withNameBytes<T>(_ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        nameBytes.withUnsafeBufferPointer(body)
    }

    public internal(set) var nameOffset: [UInt32] = []
    /// NAME_MAX is 255, but APFS counts it in characters and stores UTF-8:
    /// a name of 250 letters outside ASCII is 500 bytes, and one of 250
    /// emoji is a thousand. One byte held the first 255 and lost the rest —
    /// a truncated span, a path that named nothing, and a file the actions
    /// could not reach. Two bytes hold any name a volume will make.
    public internal(set) var nameLen: [UInt16] = []
    public internal(set) var parent: [Int32] = []
    public internal(set) var firstChild: [Int32] = []
    public internal(set) var childCount: [Int32] = []
    /// Subtree size as reported by file metadata (what Get Info shows).
    /// For a leaf this is also its own size: leaves have no children.
    public internal(set) var totalLogical: [Int64] = []
    public internal(set) var totalPhysical: [Int64] = []
    public internal(set) var mtime: [Int32] = []
    public internal(set) var flags: [UInt16] = []

    public var count: Int { parent.count }

    // MARK: - Name interning
    //
    // 11.5M nodes carry only 3.4M distinct names: "Contents", "Resources",
    // "package.json", ".DS_Store" recur endlessly. Storing each distinct name
    // once cuts the name blob by more than half. The lookup table is open
    // addressed rather than a Dictionary, whose per-entry overhead would cost
    // more than the saving, and it is discarded once the scan finishes.
    private var internTable: [UInt64] = []
    private var internMask: Int = 0

    /// Open addressing, linear probing, and — the part that was missing — a
    /// table that doubles when half full. The hint is a starting size, not a
    /// promise: a folder that appears with more distinct names than the live
    /// update allowed for, or a comparison over more names than its fixed
    /// figure, used to probe for an empty slot that did not exist, forever.
    func beginInterning(expectedNodes: Int) {
        var slots = 1 << 12
        while slots < expectedNodes * 2 && slots < Self.internSlotCap { slots <<= 1 }
        internTable = [UInt64](repeating: 0, count: slots)
        internMask = slots - 1
        internCount = 0
    }

    func endInterning() {
        internTable = []
        internMask = 0
        internCount = 0
    }

    /// 2^26 slots is 512 MB of table and room for 33 million distinct names
    /// at half load. Past that, names are stored without interning, which
    /// costs bytes and never time.
    static let internSlotCap = 1 << 26
    private var internCount = 0

    /// Doubles the table, re-placing every entry by its name's hash. False
    /// when it is at the cap, in which case the caller stops interning.
    private func growInternTable() -> Bool {
        let size = internTable.count << 1
        guard size <= Self.internSlotCap else { return false }
        var table = [UInt64](repeating: 0, count: size)
        let mask = size - 1
        nameBytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for entry in internTable where entry != 0 {
                let offset = Int(UInt32((entry >> 16) &- 1)), length = Int(entry & 0xFFFF)
                var slot = Int(hashName(UnsafeRawPointer(base + offset), length) & UInt64(mask))
                while table[slot] != 0 { slot = (slot &+ 1) & mask }
                table[slot] = entry
            }
        }
        internTable = table
        internMask = mask
        return true
    }

    @inline(__always)
    private func hashName(_ name: UnsafeRawPointer, _ length: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for k in 0..<length {
            hash = (hash ^ UInt64(name.load(fromByteOffset: k, as: UInt8.self))) &* 0x100_0000_01b3
        }
        return hash
    }

    /// Offset of `name` in the blob, appending it only if it is new.
    /// Hits are confirmed byte-for-byte, so a hash collision cannot swap names.
    @inline(__always)
    private func internedOffset(_ name: UnsafeRawPointer, _ length: Int) -> UInt32 {
        guard internMask > 0, length > 0, length <= 0xFFFF else { return appendNameBytes(name, length) }
        var slot = Int(hashName(name, length) & UInt64(internMask))
        while true {
            let entry = internTable[slot]
            if entry == 0 {
                // A new name. Half full: double first, or stop interning
                // when the table cannot double, so a lookup always ends.
                if (internCount + 1) * 2 > internTable.count {
                    guard growInternTable() else {
                        endInterning()
                        return appendNameBytes(name, length)
                    }
                    return internedOffset(name, length)
                }
                let offset = appendNameBytes(name, length)
                internTable[slot] = (UInt64(offset) &+ 1) << 16 | UInt64(length)
                internCount += 1
                return offset
            }
            if Int(entry & 0xFFFF) == length {
                let offset = UInt32((entry >> 16) &- 1)
                let same = nameBytes.withUnsafeBufferPointer { buf -> Bool in
                    guard let base = buf.baseAddress else { return false }
                    return memcmp(base + Int(offset), name, length) == 0
                }
                if same { return offset }
            }
            slot = (slot &+ 1) & internMask
        }
    }

    @inline(__always)
    private func appendNameBytes(_ name: UnsafeRawPointer, _ length: Int) -> UInt32 {
        let offset = UInt32(nameBytes.count)
        nameBytes.append(contentsOf: UnsafeRawBufferPointer(start: name, count: length))
        return offset
    }

    func reserve(_ n: Int) {
        nameOffset.reserveCapacity(n); nameLen.reserveCapacity(n)
        parent.reserveCapacity(n); firstChild.reserveCapacity(n); childCount.reserveCapacity(n)
        totalLogical.reserveCapacity(n); totalPhysical.reserveCapacity(n)
        mtime.reserveCapacity(n); flags.reserveCapacity(n)
        // Interned names measure ~9 bytes per node; 12 leaves headroom without
        // reserving a blob twice the size actually needed.
        nameBytes.reserveCapacity(n * 12)
    }

    @inline(__always)
    func append(name: UnsafeRawPointer, nameLength: Int, parent p: Int32,
                logical: Int64, physical: Int64, mtime t: Int32, flags fl: NodeFlags) -> Int32 {
        let id = Int32(parent.count)
        // Offsets are 32-bit to keep the row small; refuse to wrap rather than
        // corrupt every name after the 4 GB mark.
        let room = nameBytes.count <= Int(UInt32.max) - nameLength
        nameOffset.append(room ? internedOffset(name, nameLength) : 0)
        nameLen.append(room ? UInt16(min(nameLength, Int(UInt16.max))) : 0)
        self.parent.append(p)
        firstChild.append(-1); childCount.append(0)
        totalLogical.append(logical); totalPhysical.append(physical)
        mtime.append(t)
        flags.append(fl.rawValue)
        return id
    }

    /// One subtree, copied into a store of its own.
    ///
    /// Exists so a folder that has already been walked is never walked again.
    /// Comparing two folders needs each side as a store whose node 0 is that
    /// folder; when both sides are already inside a scan, building those two
    /// stores from memory costs a pass over the nodes instead of a pass over
    /// the disk.
    ///
    /// Breadth-first, so the invariant every bottom-up pass relies on — a
    /// child's index is greater than its parent's — holds in the copy as it
    /// does here. Nodes a live update has marked removed are left behind, along
    /// with everything under them.
    ///
    /// Rolled-up totals are copied rather than recomputed. A node's total
    /// depends only on its descendants, and a subtree is closed under
    /// descendants, so the numbers carry over exactly.
    public func subtree(root: Int32) -> NodeStore {
        let out = NodeStore()
        guard root >= 0, root < Int32(count),
              !NodeFlags(rawValue: flags[Int(root)]).contains(.removed) else { return out }
        out.roots = [path(root)]

        // Two passes rather than a dictionary: the first counts what will be
        // copied so the arrays are sized once, the second copies. A hash lookup
        // per node costs more than the extra walk on every tree measured.
        var queue: [Int32] = [root]
        var head = 0
        while head < queue.count {
            let node = queue[head]; head += 1
            for child in kept(of: node) { queue.append(child) }
        }
        out.reserve(queue.count)
        out.beginInterning(expectedNodes: queue.count)

        // Where each copied node landed, so a child can name its parent. Sized
        // to the source, which is one Int32 per node of the whole store and
        // still far cheaper than walking the folder again.
        var moved = [Int32](repeating: -1, count: count)
        // A scan names its root node with the root's absolute path, and the
        // copy has to do the same or it is not the same store: everything that
        // reads a root — the path builder, the comparison's two headings —
        // would show one folder name where a scan shows a location.
        var rootName = Array(out.roots[0].utf8)
        nameBytes.withUnsafeBufferPointer { blob in
            let base = blob.baseAddress!
            rootName.withUnsafeBufferPointer { rootBytes in
                for node in queue {
                    let i = Int(node)
                    let isRoot = node == root
                    let mapped = out.append(
                        name: isRoot ? UnsafeRawPointer(rootBytes.baseAddress!)
                                     : UnsafeRawPointer(base + Int(nameOffset[i])),
                        nameLength: isRoot ? rootName.count : Int(nameLen[i]),
                        parent: isRoot ? -1 : moved[Int(parent[i])],
                        logical: totalLogical[i], physical: totalPhysical[i],
                        mtime: mtime[i],
                        flags: NodeFlags(rawValue: flags[i]))
                    moved[i] = mapped
                }
            }
        }
        out.endInterning()
        // The children kept for one parent were enqueued together and copied in
        // that order, so they are contiguous in the copy — the span can be
        // written from the same walk rather than sorted out afterwards.
        for node in queue {
            let survivors = kept(of: node)
            guard let first = survivors.first else { continue }
            out.firstChild[Int(moved[Int(node)])] = moved[Int(first)]
            out.childCount[Int(moved[Int(node)])] = Int32(survivors.count)
        }
        return out
    }

    /// A node's children that a live update has not marked removed. The removed
    /// ones are tombstones: still in the arrays so ids stay stable, and not
    /// part of the tree any more.
    private func kept(of node: Int32) -> [Int32] {
        children(node).filter { !NodeFlags(rawValue: flags[Int($0)]).contains(.removed) }
    }

    /// Where a node's interned name sits in the blob.
    ///
    /// For a comparison that would otherwise build a Swift String per node only
    /// to throw it away: at a million names that is the difference between a
    /// second and a minute.
    public func nameSpan(_ id: Int32) -> (offset: Int, length: Int) {
        (Int(nameOffset[Int(id)]), Int(nameLen[Int(id)]))
    }

    /// The name as the volume holds it.
    public func nameBytes(of id: Int32) -> [UInt8] {
        let span = nameSpan(id)
        return nameBytes.withUnsafeBufferPointer { Array($0[span.offset..<(span.offset + span.length)]) }
    }

    public func name(_ id: Int32) -> String {
        let i = Int(id), off = Int(nameOffset[i]), len = Int(nameLen[i])
        guard len > 0 else { return "" }
        return nameBytes.withUnsafeBufferPointer {
            String(decoding: UnsafeBufferPointer(start: $0.baseAddress! + off, count: len), as: UTF8.self)
        }
    }

    /// Bytes belonging to this node alone, excluding children.
    public func ownPhysical(_ id: Int32) -> Int64 { isDirectory(id) ? 0 : totalPhysical[Int(id)] }
    public func ownLogical(_ id: Int32) -> Int64 { isDirectory(id) ? 0 : totalLogical[Int(id)] }

    public func flagSet(_ id: Int32) -> NodeFlags { NodeFlags(rawValue: flags[Int(id)]) }

    /// Where a node went when a relist rebuilt its folder.
    ///
    /// Children are one contiguous block, so adding or removing a single entry
    /// appends a fresh block for the whole folder and marks the old one
    /// removed. Everything that holds a node — a tick, a review, a selection —
    /// would otherwise be pointing at a node that says "gone" about a file
    /// sitting right there.
    ///
    /// Only entries that came back unchanged are recorded, so following one
    /// can never arrive at different bytes under the same name.
    private var superseded: [Int32: Int32] = [:]

    func supersede(_ old: Int32, by new: Int32) { superseded[old] = new }

    /// The node this one became, or itself. Bounded: a folder relisted many
    /// times builds a chain, and a cycle would be a bug rather than a shape.
    public func current(_ node: Int32) -> Int32 {
        var id = node
        for _ in 0..<64 {
            guard let next = superseded[id] else { return id }
            id = next
        }
        return id
    }
    public func isDirectory(_ id: Int32) -> Bool { flags[Int(id)] & NodeFlags.directory.rawValue != 0 }

    public func children(_ id: Int32) -> Range<Int32> {
        let f = firstChild[Int(id)], c = childCount[Int(id)]
        return f < 0 || c == 0 ? 0..<0 : f..<(f + c)
    }

    /// Rebuilds an absolute path by walking to the root. Cheap: depth is ~10-20.
    ///
    /// Bytes, not text. A name is whatever the volume allowed, and turning one
    /// that is not valid UTF-8 into a `String` puts U+FFFD where the awkward
    /// bytes were — after which the path names nothing and every action on it
    /// fails, or worse, matches something else. `path(_:)` below is this, shown
    /// to a person.
    public func pathBytes(_ id: Int32) -> RawPath {
        var spans: [(offset: Int, length: Int)] = []
        var cur = id
        while cur > 0 {
            spans.append(nameSpan(cur))
            cur = parent[Int(cur)]
        }
        guard !spans.isEmpty else { return roots.count == 1 ? rootBytes(0) : RawPath("") }
        spans.reverse()

        return nameBytes.withUnsafeBufferPointer { blob -> RawPath in
            guard let base = blob.baseAddress else { return RawPath("") }
            func component(_ span: (offset: Int, length: Int)) -> UnsafeBufferPointer<UInt8> {
                UnsafeBufferPointer(start: base + span.offset, count: span.length)
            }
            // In a multi-root tree the first component is already absolute.
            let head = spans[0]
            var path = head.length > 0 && base[head.offset] == RawPath.separator
                ? RawPath(bytes: Array(component(head)))
                : rootBytes(0).appending(component(head))
            for span in spans.dropFirst() { path = path.appending(component(span)) }
            return Firmlinks.displayPath(path)
        }
    }

    public func path(_ id: Int32) -> String { pathBytes(id).display }

    /// The URL to act on. Built from the bytes rather than from `path(_:)`,
    /// because `URL(fileURLWithPath:)` takes a `String` and would lose exactly
    /// what `pathBytes` went to the trouble of keeping.
    public func url(_ id: Int32) -> URL {
        pathBytes(id).url(isDirectory: isDirectory(id))
    }

    public func childNamed(_ parentID: Int32, _ target: String) -> Int32? {
        childNamed(parentID, bytes: Array(target.utf8))
    }

    /// The child with exactly these name bytes. Compared on the bytes, so a
    /// name that is not valid UTF-8 is found and two names that decode to the
    /// same U+FFFD are not confused.
    public func childNamed<C: Collection>(_ parentID: Int32, bytes target: C) -> Int32?
        where C.Element == UInt8 {
        // The lookup is a walk over the run comparing lengths first, so a
        // wide folder costs one byte per child and a memcmp per same-length
        // name. No copy of the wanted bytes unless they are not contiguous.
        func scan(_ wanted: UnsafeBufferPointer<UInt8>) -> Int32? {
            guard let want = wanted.baseAddress else { return nil }
            let n = wanted.count
            return nameBytes.withUnsafeBufferPointer { blob -> Int32? in
                guard let base = blob.baseAddress else { return nil }
                for c in children(parentID) where Int(nameLen[Int(c)]) == n {
                    if memcmp(base + Int(nameOffset[Int(c)]), want, n) == 0 { return c }
                }
                return nil
            }
        }
        if let hit = target.withContiguousStorageIfAvailable(scan) { return hit }
        return Array(target).withUnsafeBufferPointer(scan)
    }

    /// Resolves an absolute path to a node by walking down from the root.
    /// Depth is small, so this stays cheap without a path index costing
    /// hundreds of megabytes at 12M nodes.
    public func find(path: String) -> Int32? { find(RawPath(path)) }

    /// The same on bytes, which is what FSEvents and the walk hold. The text
    /// form above is for callers holding text, and gives the same answer for
    /// any path text can express.
    public func find(_ path: RawPath) -> Int32? {
        if let hit = lookup(path) { return hit }
        // The tree is rooted at resolved paths, but callers pass whatever they
        // happen to hold. Returning nil for "/var/..." when the tree stores
        // "/private/var/..." is a silent wrong answer, so resolve and retry.
        if let canonical = canonicalPath(path), canonical != path { return locate(canonical) }
        return nil
    }

    /// `find` without the trip to the filesystem: the path as given, and its
    /// Data-volume form. For a caller that holds a resolved path already and
    /// cannot afford a syscall on a miss.
    func lookup(_ path: RawPath) -> Int32? {
        if let hit = locate(path) { return hit }
        // `/Users/md` and `/System/Volumes/Data/Users/md` are the same folder;
        // callers and FSEvents use the first form, the tree stores the second.
        if let onData = Firmlinks.onDataVolume(path), let hit = locate(onData) { return hit }
        return nil
    }

    /// A root's path, as the bytes its node was named with. `roots` is text
    /// and would lose a root whose name cannot be decoded; the node cannot.
    private func rootBytes(_ node: Int32) -> RawPath {
        let span = nameSpan(node)
        guard span.length > 0 else { return RawPath("/") }
        return RawPath(bytes: nameBytes.withUnsafeBufferPointer {
            Array($0[span.offset..<(span.offset + span.length)])
        })
    }

    private func locate(_ path: RawPath) -> Int32? {
        if roots.count <= 1 {
            return descend(from: 0, rootPath: rootBytes(0), to: path)
        }
        // Roots are the children of the synthetic node, grafted in order.
        let base = firstChild[0]
        guard base >= 0 else { return nil }
        // Longest root first: "/" is a prefix of every path, so it would
        // otherwise shadow a more specific root like /System/Volumes/Data and
        // the lookup would stop at an excluded firmlink stub.
        let ordered = (0..<Int32(roots.count))
            .map { (index: $0, root: rootBytes(base + $0)) }
            .sorted { $0.root.bytes.count > $1.root.bytes.count }
        for entry in ordered where path.isInside(entry.root) {
            if let hit = descend(from: base + entry.index, rootPath: entry.root, to: path) {
                return hit
            }
        }
        return nil
    }

    private func descend(from node: Int32, rootPath: RawPath, to path: RawPath) -> Int32? {
        guard path.isInside(rootPath) else { return nil }
        let dropCount = rootPath.isRoot ? 1 : rootPath.bytes.count + 1
        let rest = path.bytes.count >= dropCount ? path.bytes[dropCount...] : []
        var cur = node
        for part in rest.split(separator: RawPath.separator, omittingEmptySubsequences: true) {
            guard let next = childNamed(cur, bytes: part) else { return nil }
            cur = next
        }
        return cur
    }

    /// Applies a size delta to every ancestor. Used after a live change so the
    /// whole chain stays consistent without re-walking the tree.
    func propagate(from node: Int32, logical: Int64, physical: Int64) {
        guard logical != 0 || physical != 0 else { return }
        var cur = parent[Int(node)]
        while cur >= 0 {
            totalLogical[Int(cur)] &+= logical
            totalPhysical[Int(cur)] &+= physical
            cur = parent[Int(cur)]
        }
    }

    /// Copies another store's tree in under `newParent`.
    ///
    /// Node order is preserved, so sub-index `i` lands at `base + i - 1` and
    /// every directory's children stay contiguous, exactly as after a fresh scan.
    @discardableResult
    func graft(_ sub: NodeStore, under newParent: Int32) -> Int32 {
        guard sub.count > 1 else { return -1 }
        let base = Int32(count)
        for i in 1..<sub.count {
            let sp = sub.parent[i]
            let np = sp == 0 ? newParent : base + sp - 1
            let off = Int(sub.nameOffset[i]), len = Int(sub.nameLen[i])
            sub.nameBytes.withUnsafeBufferPointer { nb in
                _ = append(name: nb.baseAddress! + off, nameLength: len, parent: np,
                           logical: sub.totalLogical[i], physical: sub.totalPhysical[i],
                           mtime: sub.mtime[i], flags: NodeFlags(rawValue: sub.flags[i]))
            }
        }
        for i in 1..<sub.count where sub.childCount[i] > 0 {
            let n = Int(base) + i - 1
            firstChild[n] = base + sub.firstChild[i] - 1
            childCount[n] = sub.childCount[i]
        }
        // The folder's own children, which the loop above skips because
        // they hang off the subtree's node 0 and not off a copied node.
        // Without this the folder carried its total and listed nothing.
        if sub.childCount[0] > 0 {
            firstChild[Int(newParent)] = base + sub.firstChild[0] - 1
            childCount[Int(newParent)] = sub.childCount[0]
        }
        return base
    }

    /// Re-points an existing subtree at a new parent node. O(direct children):
    /// a relist can reuse untouched subtrees instead of rescanning them.
    func reattach(oldNode: Int32, to newNode: Int32) {
        firstChild[Int(newNode)] = firstChild[Int(oldNode)]
        childCount[Int(newNode)] = childCount[Int(oldNode)]
        totalLogical[Int(newNode)] = totalLogical[Int(oldNode)]
        totalPhysical[Int(newNode)] = totalPhysical[Int(oldNode)]
        for c in children(newNode) { parent[Int(c)] = newNode }
        flags[Int(oldNode)] |= NodeFlags.removed.rawValue
    }

    /// Single reverse pass: every child is visited before its parent.
    func aggregate() {
        guard count > 1 else { return }
        totalLogical.withUnsafeMutableBufferPointer { tl in
            totalPhysical.withUnsafeMutableBufferPointer { tp in
                parent.withUnsafeBufferPointer { par in
                    var i = tl.count - 1
                    while i > 0 {
                        let p = Int(par[i])
                        if p >= 0 { tl[p] &+= tl[i]; tp[p] &+= tp[i] }
                        i -= 1
                    }
                }
            }
        }
    }
}
