import Darwin
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
        /// Where this node's run of decisions starts in the comparison's flat
        /// list, and how many there are. Zero for anything the comparison did
        /// not walk into — those sit inside somebody else's decision.
        public var firstDecision: Int32 = 0
        public var decisionCount: Int32 = 0
    }

    let left: NodeStore
    let right: NodeStore
    let leftSig: [UInt64]
    let rightSig: [UInt64]
    /// Per node, whether anything below it was left out by the ignore
    /// patterns. A folder that matches only because something was ignored is
    /// still a folder holding a file the other side has never seen.
    let leftHasIgnored: [Bool]
    let rightHasIgnored: [Bool]
    let leftItems: [Int32]
    let rightItems: [Int32]
    public let options: CompareOptions
    /// Names the ignore patterns kept out. Counted rather than dropped
    /// silently: a filter nobody can see is a filter that lies.
    /// Names the patterns left out, counted per side.
    ///
    /// Counted during the signature pass rather than while folders are opened,
    /// because the folders where it matters most are the ones that never get
    /// opened: a folder that matches only because a name was ignored collapses,
    /// and a count taken at open time would report zero for exactly the case
    /// the pattern was written for.
    public internal(set) var ignored = 0

    public private(set) var nodes: [Node] = []
    public var count: Int { nodes.count }

    init(left: NodeStore, right: NodeStore,
         leftSig: [UInt64], rightSig: [UInt64],
         leftHasIgnored: [Bool] = [], rightHasIgnored: [Bool] = [],
         leftItems: [Int32], rightItems: [Int32],
         options: CompareOptions = CompareOptions()) {
        self.options = options
        self.leftHasIgnored = leftHasIgnored.isEmpty
            ? [Bool](repeating: false, count: left.count) : leftHasIgnored
        self.rightHasIgnored = rightHasIgnored.isEmpty
            ? [Bool](repeating: false, count: right.count) : rightHasIgnored
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

    /// The size the file system reports, not the space it occupies. Allocated
    /// size is the honest number for "how much would this free"; this is the
    /// one that can be checked against the file again later.
    public func logicalBytes(_ id: Int32, on side: Side) -> Int64 {
        let n = node(id, on: side)
        return n >= 0 ? store(side).totalLogical[Int(n)] : 0
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
        guard l > 0, r > 0 else { return nil }
        // Within the tolerance the two are the same moment, which is the whole
        // reason a tolerance exists: a copy that went through exFAT or a
        // network share comes back a second or two out on every single file.
        guard abs(Int64(l) - Int64(r)) > Int64(options.dateTolerance) else { return nil }
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
                var lk = childList(left, parentNode.leftNode, lb)
                var rk = childList(right, parentNode.rightNode, rb)

                // Three ways to pair up a folder's names, cheapest first. See
                // `foldedKeys` for why folding is needed at all, and
                // `sortByKey` for when it has to be given up.
                if DiffTree.anyHighByte(left, lk, lb) || DiffTree.anyHighByte(right, rk, rb) {
                    // A byte over 0x7f means the name can be spelled two ways,
                    // and telling those apart needs the composed form, which
                    // needs somewhere to put it.
                    var lKeys = DiffTree.foldedKeys(left, lk, lb)
                    var rKeys = DiffTree.foldedKeys(right, rk, rb)
                    if DiffTree.sortByKey(&lk, &lKeys), DiffTree.sortByKey(&rk, &rKeys) {
                        return merge(id, depth, lk, lKeys, rk, rKeys)
                    }
                } else {
                    // Plain ASCII: case folds a byte at a time, in place. This
                    // is the overwhelming majority of folders, and it is the
                    // reason the keys above are not built for every one of
                    // them — this tree is built to hold 39 bytes a node, and
                    // two arrays a node is not that.
                    lk.sort { DiffTree.compareFolded(lb, self.left.nameSpan($0),
                                                     lb, self.left.nameSpan($1)) < 0 }
                    rk.sort { DiffTree.compareFolded(rb, self.right.nameSpan($0),
                                                     rb, self.right.nameSpan($1)) < 0 }
                    if !DiffTree.hasTie(left, lk, lb), !DiffTree.hasTie(right, rk, rb) {
                        return merge(id, depth, lk, lb, rk, rb, folding: true)
                    }
                }

                // Two names in this folder fold together, so it is on a volume
                // that tells them apart. The raw bytes are the only honest key.
                lk.sort { DiffTree.compareNames(lb, self.left.nameSpan($0),
                                                lb, self.left.nameSpan($1)) < 0 }
                rk.sort { DiffTree.compareNames(rb, self.right.nameSpan($0),
                                                rb, self.right.nameSpan($1)) < 0 }
                merge(id, depth, lk, lb, rk, rb, folding: false)
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

    /// Walks the two child lists together, pairing the names that match.
    private func merge(_ id: Int32, _ depth: Int32,
                       _ lk: [Int32], _ lKeys: [[UInt8]],
                       _ rk: [Int32], _ rKeys: [[UInt8]]) {
        var i = 0, j = 0
        while i < lk.count || j < rk.count {
            if j == rk.count { append(id, depth, lk[i], -1); i += 1; continue }
            if i == lk.count { append(id, depth, -1, rk[j]); j += 1; continue }
            let order = DiffTree.compareKeys(lKeys[i], rKeys[j])
            if order < 0 { append(id, depth, lk[i], -1); i += 1 }
            else if order > 0 { append(id, depth, -1, rk[j]); j += 1 }
            else { append(id, depth, lk[i], rk[j]); i += 1; j += 1 }
        }
    }

    private func merge(_ id: Int32, _ depth: Int32,
                       _ lk: [Int32], _ lb: UnsafeBufferPointer<UInt8>,
                       _ rk: [Int32], _ rb: UnsafeBufferPointer<UInt8>,
                       folding: Bool) {
        var i = 0, j = 0
        while i < lk.count || j < rk.count {
            if j == rk.count { append(id, depth, lk[i], -1); i += 1; continue }
            if i == lk.count { append(id, depth, -1, rk[j]); j += 1; continue }
            let order = folding
                ? DiffTree.compareFolded(lb, left.nameSpan(lk[i]), rb, right.nameSpan(rk[j]))
                : DiffTree.compareNames(lb, left.nameSpan(lk[i]), rb, right.nameSpan(rk[j]))
            if order < 0 { append(id, depth, lk[i], -1); i += 1 }
            else if order > 0 { append(id, depth, -1, rk[j]); j += 1 }
            else { append(id, depth, lk[i], rk[j]); i += 1; j += 1 }
        }
    }

    /// The name a folder is merged on, folded the way the volume folds it.
    ///
    /// A Mac volume folds case, and folds the two ways a letter such as "ş"
    /// can be spelled, when it looks a name up — but it stores whichever bytes
    /// it was handed. Foundation hands it decomposed ones; a zip, an rsync or
    /// another system hands it precomposed ones. So one file can sit on the
    /// two sides under different bytes. Compared byte for byte it reads as
    /// present on one side only, and a mirror acts on that by moving the copy
    /// on the other side to the Trash.
    static func foldedKeys(_ store: NodeStore, _ kids: [Int32],
                           _ bytes: UnsafeBufferPointer<UInt8>) -> [[UInt8]] {
        kids.map { node in
            let span = store.nameSpan(node)
            guard let base = bytes.baseAddress, span.length > 0 else { return [] }
            var folded = [UInt8](repeating: 0, count: span.length)
            var ascii = true
            for k in 0..<span.length {
                let b = base[span.offset + k]
                if b >= 0x80 { ascii = false }
                folded[k] = (b >= 65 && b <= 90) ? b + 32 : b
            }
            guard !ascii, let text = String(bytes: folded, encoding: .utf8) else { return folded }
            return Array(text.precomposedStringWithCanonicalMapping.lowercased().utf8)
        }
    }

    /// Sorts a folder's children by folded name, and says whether the result
    /// can be trusted.
    ///
    /// False when two names in one folder fold together. A volume that folds
    /// names could never hold both, so this folder is on one that does not —
    /// there the two really are different files, and the raw bytes are the
    /// only honest way to tell them apart.
    ///
    /// There is no test for the false case, and there cannot be one that runs
    /// here: producing it needs a folder holding both names, which needs a
    /// volume that tells them apart, and creating one is refused on this
    /// machine. It is a guard against a volume the suite cannot make, not a
    /// behaviour anybody can reach on the one it runs on.
    static func sortByKey(_ kids: inout [Int32], _ keys: inout [[UInt8]]) -> Bool {
        let order = (0..<kids.count).sorted { compareKeys(keys[$0], keys[$1]) < 0 }
        kids = order.map { kids[$0] }
        keys = order.map { keys[$0] }
        for k in 1..<max(keys.count, 1) where keys[k] == keys[k - 1] { return false }
        return true
    }

    /// True when any of these names holds a byte that is not plain ASCII, and
    /// so could be the composed or the decomposed spelling of the other side's.
    static func anyHighByte(_ store: NodeStore, _ kids: [Int32],
                            _ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = bytes.baseAddress else { return false }
        for node in kids {
            let span = store.nameSpan(node)
            for k in 0..<span.length where base[span.offset + k] >= 0x80 { return true }
        }
        return false
    }

    /// Two names in one folder that fold to the same thing. See `sortByKey`.
    static func hasTie(_ store: NodeStore, _ kids: [Int32],
                       _ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard kids.count > 1 else { return false }
        for k in 1..<kids.count
        where compareFolded(bytes, store.nameSpan(kids[k]),
                            bytes, store.nameSpan(kids[k - 1])) == 0 {
            return true
        }
        return false
    }

    @inline(__always)
    static func lowerASCII(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }

    /// Byte order, with ASCII case folded on the way past. No allocation: this
    /// runs on every name in every folder that is opened.
    @inline(__always)
    static func compareFolded(_ a: UnsafeBufferPointer<UInt8>, _ sa: (offset: Int, length: Int),
                              _ b: UnsafeBufferPointer<UInt8>,
                              _ sb: (offset: Int, length: Int)) -> Int {
        guard let pa = a.baseAddress, let pb = b.baseAddress else { return 0 }
        for k in 0..<min(sa.length, sb.length) {
            let x = lowerASCII(pa[sa.offset + k]), y = lowerASCII(pb[sb.offset + k])
            if x != y { return x < y ? -1 : 1 }
        }
        if sa.length == sb.length { return 0 }
        return sa.length < sb.length ? -1 : 1
    }

    @inline(__always)
    static func compareKeys(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let shared = min(a.count, b.count)
        if shared > 0 {
            let order = a.withUnsafeBytes { pa in
                b.withUnsafeBytes { pb in memcmp(pa.baseAddress!, pb.baseAddress!, shared) }
            }
            if order != 0 { return order < 0 ? -1 : 1 }
        }
        if a.count == b.count { return 0 }
        return a.count < b.count ? -1 : 1
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
        // Nothing on either side of this was compared, so nothing about it can
        // be called the same. It shows as a difference and is never acted on.
        if left.flagSet(l).contains(.mountPoint) || right.flagSet(r).contains(.mountPoint) {
            return .differs
        }
        let leftIsDir = left.isDirectory(l), rightIsDir = right.isDirectory(r)
        if leftIsDir != rightIsDir { return .typeClash }
        if leftIsDir { return leftSig[Int(l)] == rightSig[Int(r)] ? .identical : .differs }

        // A link and a file are not the same kind of thing whatever their
        // lengths say, and a link's length is the length of the path it holds
        // — two links pointing somewhere completely different are the same
        // size. Nothing downstream can catch that either: the content check
        // reads regular files, so it never opens a link to disagree.
        let leftIsLink = left.flagSet(l).contains(.symlink)
        let rightIsLink = right.flagSet(r).contains(.symlink)
        if leftIsLink != rightIsLink { return .typeClash }
        if leftIsLink {
            return DiffTree.linkTarget(left, l) == DiffTree.linkTarget(right, r)
                ? .identical : .differs
        }
        return left.totalLogical[Int(l)] == right.totalLogical[Int(r)] ? .identical : .differs
    }

    static func linkTarget(_ store: NodeStore, _ node: Int32) -> String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: store.path(node))) ?? ""
    }

    /// True when the ignore patterns kept something out of this item's subtree.
    ///
    /// It is the one thing a filter changes that is not cosmetic: a folder that
    /// matches only because a name was ignored still holds that name, and
    /// copying or removing the folder whole takes it along.
    /// Either side is a doorway to another disk, so the walk never went in.
    public func notCompared(_ id: Int32) -> Bool {
        let l = node(id, on: .left), r = node(id, on: .right)
        if l >= 0, left.flagSet(l).contains(.mountPoint) { return true }
        if r >= 0, right.flagSet(r).contains(.mountPoint) { return true }
        return false
    }

    public func coversIgnored(_ id: Int32, on side: Side) -> Bool {
        let n = node(id, on: side)
        guard n >= 0 else { return false }
        let flags = side == .left ? leftHasIgnored : rightHasIgnored
        return Int(n) < flags.count && flags[Int(n)]
    }

    /// Subtree hashes, with the two corrections a folder comparison needs that
    /// the duplicate finder does not.
    ///
    /// A name the patterns leave out must not decide whether two folders match
    /// — otherwise ignoring `.DS_Store` stops the folder collapsing, which is
    /// the entire point of ignoring it. And a symlink is what it points at, not
    /// how long that path happens to be.
    static func signatures(_ store: NodeStore, ignore: [String], salt: UInt64)
        -> (values: [UInt64], hasIgnored: [Bool], volumes: [Int32], ignored: Int) {
        var sig = [UInt64](repeating: 0, count: store.count)
        var dirty = [Bool](repeating: false, count: store.count)
        var volumes: [Int32] = []
        var ignored = 0
        guard store.count > 0 else { return (sig, dirty, volumes, ignored) }
        let order = FolderMatches.evaluationOrder(store)

        store.nameBytes.withUnsafeBufferPointer { names in
            for index in stride(from: order.count - 1, through: 0, by: -1) {
                let id = order[index]
                let i = Int(id)
                // Another disk is mounted here. The walk stopped at the door,
                // so this folder is empty as far as anything downstream can
                // tell — and an empty folder matches every other empty folder.
                // Salted per side, so it can never match its opposite number
                // and the folders above it cannot collapse over it either.
                if store.flagSet(id).contains(.mountPoint) {
                    volumes.append(id)
                    dirty[i] = true
                    sig[i] = FolderMatches.mix(salt &* 0x9E37_79B9_7F4A_7C15)
                    continue
                }
                if store.isDirectory(id) {
                    var acc: UInt64 = 0, kids: UInt64 = 0
                    for c in store.children(id) where !store.flagSet(c).contains(.removed) {
                        if matchesAny(store, c, names, ignore) {
                            dirty[i] = true; ignored += 1; continue
                        }
                        if dirty[Int(c)] { dirty[i] = true }
                        if store.flagSet(c).contains(.mountPoint) { dirty[i] = true }
                        acc = acc &+ FolderMatches.mix(sig[Int(c)])
                        kids &+= 1
                    }
                    sig[i] = kids == 0 ? 0 : FolderMatches.mix(acc ^ (kids &* 0x9E37_79B9_7F4A_7C15))
                } else {
                    // Folded, so that the hash agrees with the way the folders
                    // above it were merged — otherwise one file spelled two
                    // ways stops two matching folders from collapsing.
                    let start = Int(store.nameOffset[i])
                    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                    var ascii = true
                    for k in start..<(start + Int(store.nameLen[i])) {
                        let b = names[k]
                        if b >= 0x80 { ascii = false }
                        hash = (hash ^ UInt64((b >= 65 && b <= 90) ? b + 32 : b)) &* 0x100_0000_01b3
                    }
                    if !ascii {
                        hash = 0xcbf2_9ce4_8422_2325
                        for b in foldedKeys(store, [id], names)[0] {
                            hash = (hash ^ UInt64(b)) &* 0x100_0000_01b3
                        }
                    }
                    if store.flagSet(id).contains(.symlink) {
                        for byte in linkTarget(store, id).utf8 {
                            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
                        }
                        // Salted, so a link can never hash equal to a file that
                        // happens to be the length of its target path.
                        sig[i] = FolderMatches.mix(hash ^ 0x5EED_C0DE_5EED_C0DE)
                    } else {
                        sig[i] = FolderMatches.mix(
                            hash ^ FolderMatches.mix(UInt64(bitPattern: store.totalLogical[i])))
                    }
                }
            }
        }
        return (sig, dirty, volumes, ignored)
    }

    static func matchesAny(_ store: NodeStore, _ node: Int32,
                           _ bytes: UnsafeBufferPointer<UInt8>, _ patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        let span = store.nameSpan(node)
        guard span.length > 0, span.length < 255, let base = bytes.baseAddress else { return false }
        var name = [CChar](repeating: 0, count: span.length + 1)
        for k in 0..<span.length { name[k] = CChar(bitPattern: base[span.offset + k]) }
        return patterns.contains { pattern in
            pattern.withCString { fnmatch($0, name, FNM_CASEFOLD) == 0 }
        }
    }

    /// The run of decisions this row stands for.
    ///
    /// A row the comparison never walked into owns none of its own — it sits
    /// inside a decision made further up, like a file inside a folder that is
    /// being copied whole — so the answer is the nearest ancestor that does.
    public func decisions(_ id: Int32) -> Range<Int> {
        var current = id
        while current >= 0 {
            let node = nodes[Int(current)]
            if node.decisionCount > 0 {
                return Int(node.firstDecision)..<Int(node.firstDecision + node.decisionCount)
            }
            current = node.parent
        }
        return 0..<0
    }

    func beginDecisions(_ id: Int32, at index: Int) {
        nodes[Int(id)].firstDecision = Int32(index)
    }

    func endDecisions(_ id: Int32, at index: Int) {
        nodes[Int(id)].decisionCount = Int32(index) - nodes[Int(id)].firstDecision
    }

    /// Set while the comparison walks the folders that differ, so a folder on
    /// that spine knows what its subtree actually holds rather than having to
    /// assume.
    func absorb(_ child: Int32, into parent: Int32) {
        nodes[Int(parent)].contains.formUnion(nodes[Int(child)].contains)
    }

    /// A folder's children, minus the names the patterns leave out. Unsorted:
    /// which order they go in depends on how they will be paired up.
    private func childList(_ store: NodeStore, _ node: Int32,
                           _ bytes: UnsafeBufferPointer<UInt8>) -> [Int32] {
        guard node >= 0, store.isDirectory(node) else { return [] }
        var kids: [Int32] = []
        for child in store.children(node) where !store.flagSet(child).contains(.removed) {
            if isIgnored(store, child, bytes) { continue }
            kids.append(child)
        }
        return kids
    }

    /// Shell-glob matching on the name alone, through `fnmatch`, so the
    /// patterns behave the way the same patterns behave in a shell rather than
    /// in a scheme invented here.
    private func isIgnored(_ store: NodeStore, _ node: Int32,
                           _ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        DiffTree.matchesAny(store, node, bytes, options.ignore)
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
