import Foundation

/// Which kinds appear at or below a node.
///
/// A closed folder still has to answer "could there be an `only left` in
/// there?", because hiding it would make everything inside unreachable. For the
/// folders the comparison walked into this is exact, accumulated from their
/// children; for the ones it stopped at, the answer follows from what stopping
/// meant — an identical folder holds only identical things, and a folder one
/// side does not have holds only things that side does not have.
public struct DiffKindMask: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let identical = DiffKindMask(rawValue: 1 << 0)
    public static let differs   = DiffKindMask(rawValue: 1 << 1)
    public static let onlyLeft  = DiffKindMask(rawValue: 1 << 2)
    public static let onlyRight = DiffKindMask(rawValue: 1 << 3)
    public static let typeClash = DiffKindMask(rawValue: 1 << 4)
    public static let everything: DiffKindMask =
        [.identical, .differs, .onlyLeft, .onlyRight, .typeClash]

    public static func of(_ kind: DiffKind) -> DiffKindMask {
        switch kind {
        case .identical: .identical
        case .differs: .differs
        case .onlyLeft: .onlyLeft
        case .onlyRight: .onlyRight
        // Opening a clash shows the folder side's contents, which the other
        // side has nothing to match, so one-sided things are what is in there.
        case .typeClash: [.typeClash, .onlyLeft, .onlyRight]
        }
    }
}

/// The two folders as one tree of pairs, opened as far as it has been asked to.
///
/// Every node is a *name*, with the node it resolves to on each side or -1 for
/// the side that does not have it. Nothing is stored per node that either scan
/// already holds — no paths, no names, no sizes — so a node is twenty-odd bytes
/// and opening a folder is a merge of two child ranges rather than a walk of
/// the disk.
///
/// Two folders that differ are opened while the comparison runs, because
/// finding the differences means walking into them anyway. Folders it stopped
/// at — one whose contents match all the way down, or one the other side does
/// not have at all — are opened the first time somebody asks, which is what
/// makes a hundred-thousand-file match cost one row until it is clicked.
///
/// `@unchecked Sendable`: built on whichever thread ran the comparison, then
/// handed over and only ever opened from the main actor.
public final class DiffTree: @unchecked Sendable {
    public struct Node: Sendable {
        public var parent: Int32
        public var depth: Int32
        /// -1 when this side does not have it.
        public var leftNode: Int32
        public var rightNode: Int32
        public var kind: DiffKind
        /// -1 until the children have been worked out.
        public var firstChild: Int32 = -1
        public var childCount: Int32 = 0
        public var contains: DiffKindMask = []
    }

    let left: NodeStore
    let right: NodeStore
    let leftSig: [UInt64]
    let rightSig: [UInt64]
    let leftItems: [Int32]
    let rightItems: [Int32]

    public private(set) var nodes: [Node] = []
    public var count: Int { nodes.count }

    init(left: NodeStore, right: NodeStore,
         leftSig: [UInt64], rightSig: [UInt64],
         leftItems: [Int32], rightItems: [Int32]) {
        self.left = left
        self.right = right
        self.leftSig = leftSig
        self.rightSig = rightSig
        self.leftItems = leftItems
        self.rightItems = rightItems
        // The root is the pair of folders being compared. It is never shown as
        // a row; its children are the top level of the list.
        nodes.append(Node(parent: -1, depth: -1, leftNode: 0, rightNode: 0, kind: .differs))
    }

    // MARK: - Reading a node

    public subscript(_ id: Int32) -> Node { nodes[Int(id)] }
    public func kind(_ id: Int32) -> DiffKind { nodes[Int(id)].kind }
    public func depth(_ id: Int32) -> Int { Int(nodes[Int(id)].depth) }
    public func contains(_ id: Int32) -> DiffKindMask { nodes[Int(id)].contains }

    public func node(_ id: Int32, on side: Side) -> Int32 {
        side == .left ? nodes[Int(id)].leftNode : nodes[Int(id)].rightNode
    }
    public func isPresent(_ id: Int32, on side: Side) -> Bool { node(id, on: side) >= 0 }
    public func store(_ side: Side) -> NodeStore { side == .left ? left : right }

    public func isDirectory(_ id: Int32, on side: Side) -> Bool {
        let n = node(id, on: side)
        return n >= 0 && store(side).isDirectory(n)
    }

    /// A folder on at least one side, with something inside it.
    public func isExpandable(_ id: Int32) -> Bool {
        for side in Side.allCases {
            let n = node(id, on: side)
            if n >= 0, store(side).isDirectory(n), store(side).childCount[Int(n)] > 0 { return true }
        }
        return false
    }

    public func bytes(_ id: Int32, on side: Side) -> Int64 {
        let n = node(id, on: side)
        return n >= 0 ? store(side).totalPhysical[Int(n)] : 0
    }

    public func modified(_ id: Int32, on side: Side) -> Int32 {
        let n = node(id, on: side)
        return n >= 0 ? store(side).mtime[Int(n)] : 0
    }

    /// Everything below this node on that side, not counting the node itself.
    public func items(_ id: Int32, on side: Side) -> Int {
        let n = node(id, on: side)
        guard n >= 0 else { return 0 }
        return Int((side == .left ? leftItems : rightItems)[Int(n)]) - 1
    }

    public func dataless(_ id: Int32) -> Bool {
        Side.allCases.contains { side in
            let n = node(id, on: side)
            return n >= 0 && store(side).flagSet(n).contains(.dataless)
        }
    }

    /// The side written last, or nil where the dates agree or one side is
    /// absent. Guessing at "newer" with only one date is the kind of silent
    /// wrong answer this screen exists to prevent.
    public func newerSide(_ id: Int32) -> Side? {
        let l = modified(id, on: .left), r = modified(id, on: .right)
        guard l > 0, r > 0, l != r else { return nil }
        return l > r ? .left : .right
    }

    public func name(_ id: Int32) -> String {
        let n = nodes[Int(id)]
        if n.leftNode >= 0 { return left.name(n.leftNode) }
        if n.rightNode >= 0 { return right.name(n.rightNode) }
        return ""
    }

    /// Below the two folders being compared, with no leading separator.
    /// Rebuilt by walking up, which is a dozen steps at most.
    public func relativePath(_ id: Int32) -> String {
        var parts: [String] = []
        var current = id
        while current > 0 {
            parts.append(name(current))
            current = nodes[Int(current)].parent
        }
        return parts.reversed().joined(separator: "/")
    }

    // MARK: - Opening a folder

    public func isOpen(_ id: Int32) -> Bool { nodes[Int(id)].firstChild >= 0 }

    /// The children of a node, working them out first if nobody has yet.
    @discardableResult
    public func children(of id: Int32) -> Range<Int32> {
        if nodes[Int(id)].firstChild < 0 { open(id) }
        let n = nodes[Int(id)]
        guard n.childCount > 0 else { return 0..<0 }
        return n.firstChild..<(n.firstChild + n.childCount)
    }

    /// Merges the two sides' children by name and appends the result as one
    /// contiguous block, then orders that block by size so the biggest decision
    /// in a folder is its first row.
    ///
    /// Byte order for the merge, not collation: both sides use the same rule,
    /// which is all a merge needs, and it costs no Strings — at a million names
    /// that is the difference between a second and a minute.
    private func open(_ id: Int32) {
        let parentNode = nodes[Int(id)]
        let base = Int32(nodes.count)
        let depth = parentNode.depth + 1

        left.withNameBytes { lb in
            right.withNameBytes { rb in
                let lk = sortedChildren(left, parentNode.leftNode, lb)
                let rk = sortedChildren(right, parentNode.rightNode, rb)
                var i = 0, j = 0
                while i < lk.count || j < rk.count {
                    if j == rk.count {
                        append(id, depth, lk[i], -1); i += 1; continue
                    }
                    if i == lk.count {
                        append(id, depth, -1, rk[j]); j += 1; continue
                    }
                    let order = DiffTree.compareNames(lb, left.nameSpan(lk[i]),
                                                      rb, right.nameSpan(rk[j]))
                    if order < 0 {
                        append(id, depth, lk[i], -1); i += 1
                    } else if order > 0 {
                        append(id, depth, -1, rk[j]); j += 1
                    } else {
                        append(id, depth, lk[i], rk[j]); i += 1; j += 1
                    }
                }
            }
        }

        let end = Int32(nodes.count)
        // Safe to reorder here and only here: these nodes have just been made
        // and nothing points at them yet.
        if end > base {
            let block = nodes[Int(base)..<Int(end)].sorted {
                max(bytesOf($0, .left), bytesOf($0, .right))
                    > max(bytesOf($1, .left), bytesOf($1, .right))
            }
            nodes.replaceSubrange(Int(base)..<Int(end), with: block)
        }
        // An empty folder is still opened — firstChild is set — or every look
        // at it would walk the merge again to find nothing.
        nodes[Int(id)].firstChild = base
        nodes[Int(id)].childCount = end - base
    }

    private func append(_ parent: Int32, _ depth: Int32, _ l: Int32, _ r: Int32) {
        let kind = classify(l, r)
        var node = Node(parent: parent, depth: depth, leftNode: l, rightNode: r, kind: kind)
        // A folder that differs is not itself a decision — what is under it is
        // — so it starts empty and takes what its children turn out to hold.
        let bothDirectories = l >= 0 && r >= 0 && left.isDirectory(l) && right.isDirectory(r)
        node.contains = kind == .differs && bothDirectories ? [] : DiffKindMask.of(kind)
        nodes.append(node)
    }

    private func bytesOf(_ node: Node, _ side: Side) -> Int64 {
        let n = side == .left ? node.leftNode : node.rightNode
        return n >= 0 ? store(side).totalPhysical[Int(n)] : 0
    }

    func classify(_ l: Int32, _ r: Int32) -> DiffKind {
        if l < 0 { return .onlyRight }
        if r < 0 { return .onlyLeft }
        let leftIsDir = left.isDirectory(l), rightIsDir = right.isDirectory(r)
        if leftIsDir != rightIsDir { return .typeClash }
        if leftIsDir { return leftSig[Int(l)] == rightSig[Int(r)] ? .identical : .differs }
        return left.totalLogical[Int(l)] == right.totalLogical[Int(r)] ? .identical : .differs
    }

    /// Set while the comparison walks the folders that differ, so a folder on
    /// that spine knows what its subtree actually holds rather than having to
    /// assume.
    func absorb(_ child: Int32, into parent: Int32) {
        nodes[Int(parent)].contains.formUnion(nodes[Int(child)].contains)
    }

    private func sortedChildren(_ store: NodeStore, _ node: Int32,
                                _ bytes: UnsafeBufferPointer<UInt8>) -> [Int32] {
        guard node >= 0, store.isDirectory(node) else { return [] }
        var kids: [Int32] = []
        for child in store.children(node) where !store.flagSet(child).contains(.removed) {
            kids.append(child)
        }
        kids.sort { DiffTree.compareNames(bytes, store.nameSpan($0), bytes, store.nameSpan($1)) < 0 }
        return kids
    }

    @inline(__always)
    static func compareNames(_ a: UnsafeBufferPointer<UInt8>, _ sa: (offset: Int, length: Int),
                             _ b: UnsafeBufferPointer<UInt8>,
                             _ sb: (offset: Int, length: Int)) -> Int {
        let shared = min(sa.length, sb.length)
        if shared > 0, let pa = a.baseAddress, let pb = b.baseAddress {
            let order = memcmp(pa + sa.offset, pb + sb.offset, shared)
            if order != 0 { return order < 0 ? -1 : 1 }
        }
        if sa.length == sb.length { return 0 }
        return sa.length < sb.length ? -1 : 1
    }
}
