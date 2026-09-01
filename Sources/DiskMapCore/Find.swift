import Foundation

public struct FoundItem: Sendable, Identifiable, Equatable {
    public var id: Int32 { node }
    public var node: Int32
    public var path: String
    public var physical: Int64
    public var logical: Int64
    public var isDirectory: Bool
}

/// Looking for one thing in a tree of nine million.
///
/// The filter box narrows the level being browsed, which answers "what is in
/// this folder" and not "where is that file". This answers the second one, and
/// it has to do it over the whole tree while somebody types.
///
/// The cost that matters is not the comparison, it is building nine million
/// Swift strings to compare against: names are interned as bytes, so the search
/// runs over those bytes and only materialises a path for the handful of rows
/// it is about to return. For an ASCII needle the fold is a byte operation; a
/// needle with anything else in it falls back to real string comparison, which
/// is slower and correct, and rare enough not to matter.
public enum Find {
    public static func search(store: NodeStore, needle rawNeedle: String,
                              limit: Int = 300) -> [FoundItem] {
        let needle = rawNeedle.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        let span = Telemetry.begin("find")

        // A needle with a separator in it names a path: the last segment is the
        // thing being looked for, the ones before it are where to look.
        //
        // Building every node's path to search it costs eighty-two seconds on a
        // nine-million-node disk, because each one walks to the root and
        // allocates a string. Matching the last segment first leaves a handful
        // of candidates, and only those walk their ancestors.
        let segments = needle.split(separator: "/").map { $0.lowercased() }
        var hits: [(node: Int32, bytes: Int64)] = []

        if segments.count > 1, let leaf = segments.last {
            let ancestors = segments.dropLast()
            for node in candidates(store: store, needle: leaf) {
                guard matchesAncestors(store: store, node: node, Array(ancestors)) else { continue }
                hits.append((node, store.totalPhysical[Int(node)]))
            }
        } else if let pattern = asciiLowered(segments.first ?? needle.lowercased()) {
            store.withNameBytes { bytes in
                for node in 1..<Int32(store.count) {
                    guard !store.flagSet(node).contains(.removed) else { continue }
                    let offset = Int(store.nameOffset[Int(node)])
                    let length = Int(store.nameLen[Int(node)])
                    guard length >= pattern.count else { continue }
                    if contains(bytes, offset, length, pattern) {
                        hits.append((node, store.totalPhysical[Int(node)]))
                    }
                }
            }
        } else {
            let lowered = segments.first ?? needle.lowercased()
            for node in 1..<Int32(store.count) {
                guard !store.flagSet(node).contains(.removed) else { continue }
                guard store.name(node).lowercased().contains(lowered) else { continue }
                hits.append((node, store.totalPhysical[Int(node)]))
            }
        }

        // Biggest first: in a tool about space, the large match is the one
        // being looked for far more often than the alphabetically first.
        hits.sort { $0.bytes > $1.bytes }
        let found = hits.prefix(limit).map { hit in
            FoundItem(node: hit.node, path: store.path(hit.node),
                      physical: store.totalPhysical[Int(hit.node)],
                      logical: store.totalLogical[Int(hit.node)],
                      isDirectory: store.isDirectory(hit.node))
        }
        span.end(["needle": .int(Int64(needle.count)), "matches": .int(Int64(hits.count)),
                  "returned": .int(Int64(found.count)), "nodes": .int(Int64(store.count))],
                 minMilliseconds: 100)
        return Array(found)
    }

    /// Nodes whose own name contains `needle`, by whichever path is available.
    private static func candidates(store: NodeStore, needle: String) -> [Int32] {
        var out: [Int32] = []
        if let pattern = asciiLowered(needle) {
            store.withNameBytes { bytes in
                for node in 1..<Int32(store.count) {
                    guard !store.flagSet(node).contains(.removed) else { continue }
                    let offset = Int(store.nameOffset[Int(node)])
                    let length = Int(store.nameLen[Int(node)])
                    guard length >= pattern.count else { continue }
                    if contains(bytes, offset, length, pattern) { out.append(node) }
                }
            }
        } else {
            for node in 1..<Int32(store.count) {
                guard !store.flagSet(node).contains(.removed) else { continue }
                if store.name(node).lowercased().contains(needle) { out.append(node) }
            }
        }
        return out
    }

    /// True when the segments appear, in order, among the node's ancestors.
    /// They need not be adjacent: "dev/report" should find a report several
    /// folders below dev, which is how people remember where things are.
    private static func matchesAncestors(store: NodeStore, node: Int32,
                                         _ segments: [String]) -> Bool {
        var remaining = segments
        var current = store.parent[Int(node)]
        while current >= 0, !remaining.isEmpty {
            if store.name(current).lowercased().contains(remaining[remaining.count - 1]) {
                remaining.removeLast()
            }
            current = store.parent[Int(current)]
        }
        return remaining.isEmpty
    }

    /// How many matched in total, since the list is capped and a reader should
    /// never take the visible rows for the whole answer.
    public static func count(store: NodeStore, needle: String) -> Int {
        search(store: store, needle: needle, limit: .max).count
    }

    /// Nil when the needle is not plain ASCII, which is the signal to take the
    /// slower path that folds case properly.
    private static func asciiLowered(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count)
        for byte in s.utf8 {
            guard byte < 0x80 else { return nil }
            out.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
        }
        return out.isEmpty ? nil : out
    }

    @inline(__always)
    private static func contains(_ haystack: UnsafeBufferPointer<UInt8>,
                                 _ offset: Int, _ length: Int,
                                 _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress else { return false }
        let last = length - needle.count
        var start = 0
        while start <= last {
            var i = 0
            while i < needle.count {
                var c = base[offset + start + i]
                if c >= 65 && c <= 90 { c += 32 }
                if c != needle[i] { break }
                i += 1
            }
            if i == needle.count { return true }
            start += 1
        }
        return false
    }
}
