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
    public internal(set) var nameBytes: [UInt8] = []
    public internal(set) var nameOffset: [UInt32] = []
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

    func reserve(_ n: Int) {
        nameOffset.reserveCapacity(n); nameLen.reserveCapacity(n)
        parent.reserveCapacity(n); firstChild.reserveCapacity(n); childCount.reserveCapacity(n)
        totalLogical.reserveCapacity(n); totalPhysical.reserveCapacity(n)
        mtime.reserveCapacity(n); flags.reserveCapacity(n)
        nameBytes.reserveCapacity(n * 16)
    }

    @inline(__always)
    func append(name: UnsafeRawPointer, nameLength: Int, parent p: Int32,
                logical: Int64, physical: Int64, mtime t: Int32, flags fl: NodeFlags) -> Int32 {
        let id = Int32(parent.count)
        // Offsets are 32-bit to keep the row small; refuse to wrap rather than
        // corrupt every name after the 4 GB mark.
        let room = nameBytes.count <= Int(UInt32.max) - nameLength
        nameOffset.append(room ? UInt32(nameBytes.count) : 0)
        nameLen.append(room ? UInt16(min(nameLength, Int(UInt16.max))) : 0)
        if room {
            nameBytes.append(contentsOf: UnsafeRawBufferPointer(start: name, count: nameLength))
        }
        self.parent.append(p)
        firstChild.append(-1); childCount.append(0)
        totalLogical.append(logical); totalPhysical.append(physical)
        mtime.append(t)
        flags.append(fl.rawValue)
        return id
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
    public func isDirectory(_ id: Int32) -> Bool { flags[Int(id)] & NodeFlags.directory.rawValue != 0 }

    public func children(_ id: Int32) -> Range<Int32> {
        let f = firstChild[Int(id)], c = childCount[Int(id)]
        return f < 0 || c == 0 ? 0..<0 : f..<(f + c)
    }

    /// Rebuilds an absolute path by walking to the root. Cheap: depth is ~10-20.
    public func path(_ id: Int32, rootPath: String) -> String {
        var parts: [String] = []
        var cur = id
        while cur > 0 {
            parts.append(name(cur))
            cur = parent[Int(cur)]
        }
        if parts.isEmpty { return rootPath }
        let base = rootPath == "/" ? "" : rootPath
        return base + "/" + parts.reversed().joined(separator: "/")
    }

    public func url(_ id: Int32, rootPath: String) -> URL {
        URL(fileURLWithPath: path(id, rootPath: rootPath))
    }

    public func childNamed(_ parentID: Int32, _ target: String) -> Int32? {
        for c in children(parentID) where name(c) == target { return c }
        return nil
    }

    /// Resolves an absolute path to a node by walking down from the root.
    /// Depth is small, so this stays cheap without a path index costing
    /// hundreds of megabytes at 12M nodes.
    public func find(path: String, rootPath: String) -> Int32? {
        guard path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") else { return nil }
        let rest = String(path.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1))
        var cur: Int32 = 0
        for part in rest.split(separator: "/") where !part.isEmpty {
            guard let next = childNamed(cur, String(part)) else { return nil }
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
