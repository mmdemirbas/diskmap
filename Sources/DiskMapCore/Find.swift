import Foundation

public struct FoundItem: Sendable, Identifiable, Equatable {
    public var id: Int32 { node }
    public var node: Int32
    public var path: String
    public var physical: Int64
    public var logical: Int64
    public var isDirectory: Bool
    /// How well the name matched, so the screen can say why a row is here.
    public var kind: Find.MatchKind = .substring
}

/// What a search found, and how much of it there was.
///
/// Returned together because the list is capped and the count is not: a reader
/// must never take the rows they can see for the whole answer, and making the
/// caller run the search twice to learn the difference is how that used to be
/// paid for.
public struct FindResults: Sendable {
    public var items: [FoundItem]
    public var total: Int
    public init(items: [FoundItem], total: Int) {
        self.items = items
        self.total = total
    }
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
    /// How the name matched, best first. The order is the ranking.
    public enum MatchKind: Int, Sendable, Comparable, Equatable {
        /// The whole name, ignoring case.
        case exact = 0
        /// The name begins with it.
        case prefix = 1
        /// The name holds it, somewhere.
        case substring = 2
        /// The letters appear in order but not together — `rprt` for
        /// `report.pdf`. How people type when they half-remember a name.
        case subsequence = 3

        public static func < (a: MatchKind, b: MatchKind) -> Bool {
            a.rawValue < b.rawValue
        }
    }

    /// A subsequence match is only interesting when the letters stay near each
    /// other. Without a bound, a two-letter needle matches almost every name on
    /// the disk — `ab` would hit anything with an `a` somewhere before a `b` —
    /// and the answer becomes several million rows that mean nothing.
    ///
    /// Bounding the span is what turns "the letters are in there" into "this is
    /// an abbreviation of that", which is what people mean when they type
    /// loosely. Three times the needle: `rprt` may spread over twelve
    /// characters, which covers real abbreviations and rejects three letters
    /// scattered across a sentence.
    private static func allowedSpan(_ needleCount: Int) -> Int { needleCount * 3 }

    /// Below this, a subsequence match says nothing: every name has an `e`
    /// before an `s` somewhere.
    private static let shortestFuzzyNeedle = 3

    /// The loose pass runs only when the strict one found nothing.
    ///
    /// Letting it fill in a thin answer was tried and measured against real
    /// names, and it adds coincidences rather than results: a subsequence over
    /// a long name matches by accident often enough that searching `final` in a
    /// small tree turned up a temporary directory whose random hex happened to
    /// spell out the rest of the letters. Ranking keeps such a match below the
    /// real ones, but it is still a row that means nothing.
    ///
    /// So: when what you typed matched something, that is the answer. When it
    /// matched nothing, the letters are read as an abbreviation instead.

    public static func search(store: NodeStore, needle rawNeedle: String,
                              limit: Int = 300) -> FindResults {
        let needle = rawNeedle.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return FindResults(items: [], total: 0) }
        let span = Telemetry.begin("find")

        // A needle with a separator in it names a path: the last segment is the
        // thing being looked for, the ones before it are where to look.
        //
        // Building every node's path to search it costs eighty-two seconds on a
        // nine-million-node disk, because each one walks to the root and
        // allocates a string. Matching the last segment first leaves a handful
        // of candidates, and only those walk their ancestors.
        let segments = needle.split(separator: "/").map { $0.lowercased() }
        let leaf = segments.last ?? needle.lowercased()
        let ancestors = segments.count > 1 ? Array(segments.dropLast()) : []

        var hits = scanStrict(store: store, leaf: leaf, ancestors: ancestors)

        if hits.isEmpty, leaf.count >= shortestFuzzyNeedle {
            hits += scanFuzzy(store: store, leaf: leaf, ancestors: ancestors)
        }

        // Best kind first; within a kind the tighter match; then biggest, since
        // in a tool about space the large one is what is being looked for far
        // more often than the alphabetically first.
        hits.sort {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            if $0.tie != $1.tie { return $0.tie < $1.tie }
            return $0.bytes > $1.bytes
        }
        let found = hits.prefix(limit).map { hit in
            FoundItem(node: hit.node, path: store.path(hit.node),
                      physical: store.totalPhysical[Int(hit.node)],
                      logical: store.totalLogical[Int(hit.node)],
                      isDirectory: store.isDirectory(hit.node), kind: hit.kind)
        }
        span.end(["needle": .int(Int64(needle.count)), "matches": .int(Int64(hits.count)),
                  "returned": .int(Int64(found.count)), "nodes": .int(Int64(store.count))],
                 minMilliseconds: 100)
        return FindResults(items: Array(found), total: hits.count)
    }

    private struct Hit {
        var node: Int32
        var kind: MatchKind
        /// Lower is better within a kind: where the match starts for a
        /// substring, how far it is spread for a subsequence.
        var tie: Int
        var bytes: Int64
    }

    /// One pass over every name, for the strict kinds.
    ///
    /// `@inline(__always)` is load-bearing, and the reason is worth writing
    /// down because it is not obvious. This loop used to sit inside `search`.
    /// Moving it into a function of its own — with no change to the work it
    /// does — took a search over ten million nodes from a median of 268ms to
    /// about 470ms, because across the call boundary the store accessors stop
    /// being inlined and every one of ten million iterations pays for it.
    /// Inlining it again restored 274ms.
    ///
    /// Two other suspects were measured and cleared: splitting the strict and
    /// loose passes into separate loops rather than one loop behind a flag, and
    /// returning a plain index rather than an optional tuple. Both are better
    /// shapes and neither moved the number.
    @inline(__always)
    private static func scanStrict(store: NodeStore, leaf: String,
                                   ancestors: [String]) -> [Hit] {
        var out: [Hit] = []
        if let pattern = asciiLowered(leaf) {
            store.withNameBytes { bytes in
                for node in 1..<Int32(store.count) {
                    guard !store.flagSet(node).contains(.removed) else { continue }
                    let offset = Int(store.nameOffset[Int(node)])
                    let length = Int(store.nameLen[Int(node)])
                    guard length >= pattern.count else { continue }
                    let at = matchStart(bytes, offset, length, pattern)
                    guard at >= 0 else { continue }
                    // Worked out per match rather than per name: there are a
                    // few thousand of the first and ten million of the second.
                    let kind: MatchKind = at > 0
                        ? .substring
                        : (length == pattern.count ? .exact : .prefix)
                    out.append(Hit(node: node, kind: kind, tie: at,
                                   bytes: store.totalPhysical[Int(node)]))
                }
            }
        } else {
            // Not plain ASCII, so fold the way the language does rather than by
            // adding 32 to a byte.
            for node in 1..<Int32(store.count) {
                guard !store.flagSet(node).contains(.removed) else { continue }
                let name = store.name(node).lowercased()
                guard let range = name.range(of: leaf) else { continue }
                let at = name.distance(from: name.startIndex, to: range.lowerBound)
                let kind: MatchKind = name == leaf ? .exact : (at == 0 ? .prefix : .substring)
                out.append(Hit(node: node, kind: kind, tie: at,
                               bytes: store.totalPhysical[Int(node)]))
            }
        }
        return narrow(out, store: store, ancestors: ancestors)
    }

    /// The same walk, reading the needle as an abbreviation. Only ever runs
    /// when the strict pass found nothing, so its cost is paid on searches that
    /// would otherwise have come back empty.
    private static func scanFuzzy(store: NodeStore, leaf: String,
                                  ancestors: [String]) -> [Hit] {
        var out: [Hit] = []
        let allowed = allowedSpan(leaf.count)
        if let pattern = asciiLowered(leaf) {
            store.withNameBytes { bytes in
                for node in 1..<Int32(store.count) {
                    guard !store.flagSet(node).contains(.removed) else { continue }
                    let offset = Int(store.nameOffset[Int(node)])
                    let length = Int(store.nameLen[Int(node)])
                    guard length >= pattern.count,
                          let spread = subsequenceSpan(bytes, offset, length, pattern),
                          spread <= allowed else { continue }
                    out.append(Hit(node: node, kind: .subsequence, tie: spread,
                                   bytes: store.totalPhysical[Int(node)]))
                }
            }
        } else {
            let needle = Array(leaf.unicodeScalars)
            for node in 1..<Int32(store.count) {
                guard !store.flagSet(node).contains(.removed) else { continue }
                let name = store.name(node).lowercased()
                guard let spread = subsequenceSpan(Array(name.unicodeScalars), needle),
                      spread <= allowed else { continue }
                out.append(Hit(node: node, kind: .subsequence, tie: spread,
                               bytes: store.totalPhysical[Int(node)]))
            }
        }
        return narrow(out, store: store, ancestors: ancestors)
    }

    /// Drops what does not sit under the named folders. Applied to the hits
    /// rather than inside the walk, because it builds ancestor names and there
    /// are a handful of hits against ten million nodes.
    private static func narrow(_ hits: [Hit], store: NodeStore,
                               ancestors: [String]) -> [Hit] {
        guard !ancestors.isEmpty else { return hits }
        return hits.filter { matchesAncestors(store: store, node: $0.node, ancestors) }
    }

    /// Where the needle starts in the name, or -1.
    ///
    /// A plain index rather than an optional tuple of (kind, position), and the
    /// kind derived afterwards for the few thousand names that matched rather
    /// than computed for the ten million that were looked at. Measured as no
    /// faster than the tuple once the caller is inlined — kept because it is
    /// the simpler thing to read, not because it bought anything.
    @inline(__always)
    private static func matchStart(_ haystack: UnsafeBufferPointer<UInt8>,
                                   _ offset: Int, _ length: Int,
                                   _ needle: [UInt8]) -> Int {
        guard let base = haystack.baseAddress else { return -1 }
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
            if i == needle.count { return start }
            start += 1
        }
        return -1
    }

    /// How far apart the needle's letters are when they appear in order, or nil
    /// when they do not. Matched from the left and then tightened from the
    /// right, so `rprt` against `report.part` measures the closest run rather
    /// than the first one found.
    @inline(__always)
    private static func subsequenceSpan(_ haystack: UnsafeBufferPointer<UInt8>,
                                        _ offset: Int, _ length: Int,
                                        _ needle: [UInt8]) -> Int? {
        guard let base = haystack.baseAddress else { return nil }
        var i = 0
        var end = -1
        for j in 0..<length {
            var c = base[offset + j]
            if c >= 65 && c <= 90 { c += 32 }
            if c == needle[i] {
                i += 1
                if i == needle.count { end = j; break }
            }
        }
        guard end >= 0 else { return nil }
        // Walk back from where it finished to find the latest possible start.
        var k = needle.count - 1
        var begin = end
        var j = end
        while j >= 0 {
            var c = base[offset + j]
            if c >= 65 && c <= 90 { c += 32 }
            if c == needle[k] {
                begin = j
                if k == 0 { break }
                k -= 1
            }
            j -= 1
        }
        return end - begin
    }

    /// The same measurement for a needle that is not plain ASCII.
    private static func subsequenceSpan(_ haystack: [Unicode.Scalar],
                                        _ needle: [Unicode.Scalar]) -> Int? {
        var i = 0
        var end = -1
        for j in 0..<haystack.count where haystack[j] == needle[i] {
            i += 1
            if i == needle.count { end = j; break }
        }
        guard end >= 0 else { return nil }
        var k = needle.count - 1
        var begin = end
        var j = end
        while j >= 0 {
            if haystack[j] == needle[k] {
                begin = j
                if k == 0 { break }
                k -= 1
            }
            j -= 1
        }
        return end - begin
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
}
