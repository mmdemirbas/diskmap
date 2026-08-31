import Foundation

public struct FolderMatch: Sendable, Identifiable {
    public var id: Int32 { nodes.first ?? -1 }
    /// The folders that match each other.
    public var nodes: [Int32]
    /// Physical size of the smallest copy.
    public var bytes: Int64
    /// For an exact match, what deleting all but one copy would free. For a
    /// partial one, the bytes the folders hold in common.
    public var reclaimable: Int64
    /// Every name and size below the folder matches, recursively.
    public var exact: Bool
    public var sharedItems: Int
    public var comparedItems: Int
}

/// Folders that hold the same thing.
///
/// A folder is reduced to a hash of everything below it: each file contributes
/// its name and byte length, each folder the combined hash of its children. A
/// folder's own name is left out, so a renamed copy still matches. Children
/// combine commutatively because directory order is not stable between two
/// copies of the same tree.
///
/// Two folders with the same hash hold the same names at the same sizes in the
/// same shape. That is a much stronger signal than two files matching, and it
/// still costs no disk reads — but it is still not proof, because content is
/// never compared. `DeepVerify` is the answer to that question, and it only
/// runs when asked.
///
/// Folders that share most but not all of their children are reported too,
/// which is the case that matters in practice: two copies of a photo library
/// where one has a few more pictures in it.
public enum FolderMatches {
    /// splitmix64's finalizer. Cheap, and it avalanches well enough that
    /// summing children does not lose information.
    @inline(__always) static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// One hash per node, files first: children always sit at a higher index
    /// than their parent, so a single reverse pass sees them in order.
    public static func signatures(_ store: NodeStore) -> [UInt64] {
        var sig = [UInt64](repeating: 0, count: store.count)
        guard store.count > 0 else { return sig }
        store.nameBytes.withUnsafeBufferPointer { names in
            sig.withUnsafeMutableBufferPointer { out in
                var i = store.count - 1
                while i >= 0 {
                    let id = Int32(i)
                    if store.isDirectory(id) {
                        var acc: UInt64 = 0
                        var kids: UInt64 = 0
                        for c in store.children(id) where !store.flagSet(c).contains(.removed) {
                            acc = acc &+ mix(out[Int(c)])
                            kids &+= 1
                        }
                        out[i] = kids == 0 ? 0 : mix(acc ^ (kids &* 0x9E37_79B9_7F4A_7C15))
                    } else {
                        let start = Int(store.nameOffset[i])
                        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                        for k in start..<(start + Int(store.nameLen[i])) {
                            hash = (hash ^ UInt64(names[k])) &* 0x100_0000_01b3
                        }
                        out[i] = mix(hash ^ mix(UInt64(bitPattern: store.totalLogical[i])))
                    }
                    i -= 1
                }
            }
        }
        return sig
    }

    /// `precomputed` lets a caller reuse the hash pass across navigations: it
    /// covers the whole tree and only changes when the tree does.
    public static func find(store: NodeStore, root: Int32,
                            minimumSize: Int64 = 50_000_000,
                            similarity: Double = 0.6,
                            limit: Int = 200,
                            precomputed: [UInt64]? = nil) -> [FolderMatch] {
        let sig = precomputed?.count == store.count ? precomputed! : signatures(store)

        // Only folders big enough to be worth a decision are candidates. That
        // also drops the endless empty and near-empty directories, which would
        // otherwise all hash alike.
        var candidates: [Int32] = []
        var stack: [Int32] = [root]
        while let node = stack.popLast() {
            for child in store.children(node) where store.isDirectory(child) {
                let flags = store.flagSet(child)
                if flags.contains(.removed) { continue }
                stack.append(child)
                if store.totalPhysical[Int(child)] >= minimumSize, store.childCount[Int(child)] > 0 {
                    candidates.append(child)
                }
            }
        }
        guard candidates.count > 1 else { return [] }

        var matches = exactGroups(store, sig, candidates)
        matches += similarPairs(store, sig, candidates, threshold: similarity,
                                exact: matches)
        return Array(matches.sorted { $0.reclaimable > $1.reclaimable }.prefix(limit))
    }

    // MARK: - Identical folders

    private static func exactGroups(_ store: NodeStore, _ sig: [UInt64],
                                    _ candidates: [Int32]) -> [FolderMatch] {
        var buckets: [UInt64: [Int32]] = [:]
        for node in candidates { buckets[sig[Int(node)], default: []].append(node) }
        let groups = buckets.values.filter { $0.count > 1 }

        var groupOf: [Int32: Int] = [:]
        for (index, group) in groups.enumerated() { for node in group { groupOf[node] = index } }

        return groups.enumerated().compactMap { index, group -> FolderMatch? in
            // Inside two identical folders every subfolder matches too. Report
            // the outermost one and drop the copies of it further down, but
            // only when the parents alone explain the whole group.
            var parentGroups = Set<Int>()
            var anyLoose = false
            for node in group {
                let parent = store.parent[Int(node)]
                if parent >= 0, let g = groupOf[parent], g != index { parentGroups.insert(g) }
                else { anyLoose = true }
            }
            if !anyLoose && parentGroups.count == 1 { return nil }

            let bytes = group.map { store.totalPhysical[Int($0)] }.min() ?? 0
            let items = Int(store.childCount[Int(group[0])])
            return FolderMatch(nodes: group.sorted { store.path($0) < store.path($1) },
                               bytes: bytes, reclaimable: bytes * Int64(group.count - 1),
                               exact: true, sharedItems: items, comparedItems: items)
        }
    }

    // MARK: - Folders that share most of their contents

    /// Compared by direct children only, which is enough because a child's hash
    /// already covers everything below it: one changed file deep in a subtree
    /// changes exactly one of these entries.
    private static func similarPairs(_ store: NodeStore, _ sig: [UInt64],
                                     _ candidates: [Int32], threshold: Double,
                                     exact: [FolderMatch]) -> [FolderMatch] {
        var exactGroupOf: [Int32: Int] = [:]
        for (index, match) in exact.enumerated() { for node in match.nodes { exactGroupOf[node] = index } }

        // Children of each candidate, sorted by hash, with the size that hash
        // stands for so a partial match can be priced.
        var contents: [[(hash: UInt64, bytes: Int64)]] = []
        contents.reserveCapacity(candidates.count)
        for node in candidates {
            var entries: [(UInt64, Int64)] = []
            for child in store.children(node) where !store.flagSet(child).contains(.removed) {
                entries.append((sig[Int(child)], store.totalPhysical[Int(child)]))
            }
            entries.sort { $0.0 < $1.0 }
            contents.append(entries)
        }

        // A hash shared by hundreds of folders is boilerplate, not evidence, so
        // it is not used to propose pairs. It still counts once a pair exists.
        var postings: [UInt64: [Int]] = [:]
        for (slot, entries) in contents.enumerated() {
            var last: UInt64 = 0
            for (index, entry) in entries.enumerated() where index == 0 || entry.hash != last {
                postings[entry.hash, default: []].append(slot)
                last = entry.hash
            }
        }

        var shared: [UInt64: Int] = [:]
        for list in postings.values where list.count > 1 && list.count <= 32 {
            for a in 0..<list.count {
                for b in (a + 1)..<list.count {
                    shared[UInt64(list[a]) << 32 | UInt64(list[b]), default: 0] += 1
                }
            }
        }

        var proposed: [(Int, Int, Int, Int64)] = []
        var pairKeys = Set<UInt64>()
        // Folders already known to be identical stand in for each other: if A
        // and B are the same folder, "A is like C" and "B is like C" are one
        // finding, not two.
        var seenClasses = Set<UInt64>()
        for (key, count) in shared.sorted(by: { $0.key < $1.key }) where count > 1 {
            let a = Int(key >> 32), b = Int(key & 0xFFFF_FFFF)
            let (items, bytes) = overlap(contents[a], contents[b])
            let union = contents[a].count + contents[b].count - items
            guard union > 0, Double(items) / Double(union) >= threshold else { continue }
            pairKeys.insert(pack(candidates[a], candidates[b]))
            let classA = Int32(exactGroupOf[candidates[a]].map { -1 - $0 } ?? Int(candidates[a]))
            let classB = Int32(exactGroupOf[candidates[b]].map { -1 - $0 } ?? Int(candidates[b]))
            guard seenClasses.insert(pack(classA, classB)).inserted else { continue }
            proposed.append((a, b, items, bytes))
        }

        return proposed.compactMap { a, b, items, bytes -> FolderMatch? in
            let left = candidates[a], right = candidates[b]
            // Already reported as identical.
            if let ga = exactGroupOf[left], ga == exactGroupOf[right] { return nil }
            // Their parents match, so this pair is a restatement of that.
            let pa = store.parent[Int(left)], pb = store.parent[Int(right)]
            if pa >= 0, pb >= 0 {
                if let ga = exactGroupOf[pa], ga == exactGroupOf[pb] { return nil }
                if pairKeys.contains(pack(pa, pb)) { return nil }
            }
            let compared = max(contents[a].count, contents[b].count)
            return FolderMatch(nodes: store.path(left) < store.path(right) ? [left, right] : [right, left],
                               bytes: min(store.totalPhysical[Int(left)], store.totalPhysical[Int(right)]),
                               reclaimable: bytes, exact: false,
                               sharedItems: items, comparedItems: compared)
        }
    }

    private static func pack(_ a: Int32, _ b: Int32) -> UInt64 {
        let lo = UInt64(UInt32(bitPattern: min(a, b))), hi = UInt64(UInt32(bitPattern: max(a, b)))
        return hi << 32 | lo
    }

    /// Multiset intersection of two hash-sorted child lists.
    private static func overlap(_ left: [(hash: UInt64, bytes: Int64)],
                                _ right: [(hash: UInt64, bytes: Int64)]) -> (Int, Int64) {
        var i = 0, j = 0, items = 0, bytes: Int64 = 0
        while i < left.count && j < right.count {
            if left[i].hash == right[j].hash {
                items += 1
                bytes += min(left[i].bytes, right[j].bytes)
                i += 1; j += 1
            } else if left[i].hash < right[j].hash {
                i += 1
            } else {
                j += 1
            }
        }
        return (items, bytes)
    }
}
