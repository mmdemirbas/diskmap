import CoreServices
import Foundation

/// Questions about what is *in* files, asked of the index rather than of the
/// files.
///
/// A fixed set rather than a predicate field. Someone clearing space asks a
/// handful of things — where are the big photos, what are these long
/// recordings, how many screenshots have I kept — and a query language would
/// make them learn Spotlight's attribute names to ask any of them.
public enum ContentQuestion: String, CaseIterable, Sendable, Identifiable {
    case any
    case largePictures
    case longRecordings
    case screenshots
    case olderThanFiveYears

    public var id: String { rawValue }

    /// Nil for `any`, which is not a question.
    ///
    /// `olderThanFiveYears` is counted from now rather than written as a year,
    /// so the menu does not quietly become wrong in January.
    public func predicate(now: Date = Date()) -> String? {
        switch self {
        case .any:
            return nil
        case .largePictures:
            return "kMDItemPixelWidth >= 2000 || kMDItemPixelHeight >= 2000"
        case .longRecordings:
            return "kMDItemDurationSeconds >= 600"
        case .screenshots:
            return "kMDItemIsScreenCapture == 1"
        case .olderThanFiveYears:
            let cutoff = now.addingTimeInterval(-5 * 365 * 86_400)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            // Narrowed to things that were *taken* rather than merely written.
            // Without the second clause this matches every source file in every
            // old checkout — two hundred thousand of them on this machine —
            // which is a slow way to answer a question nobody asked.
            return "kMDItemContentCreationDate < $time.iso(\(formatter.string(from: cutoff)))"
                + " && (kMDItemPixelWidth > 0 || kMDItemDurationSeconds > 0)"
        }
    }
}

/// One question, asked once, of the whole index.
///
/// The measurement that decided this shape: the same 208,308 files cost 333
/// seconds asked one at a time and about nine seconds asked as a query. Asking
/// per file scales with the size of the tree; asking as a query scales with the
/// number of matches. So a whole-tree content filter is never a sweep — it is
/// one query, and then an intersection with the tree that has been scanned.
public enum SpotlightQuery {
    /// Paths the index says match, under the given roots.
    ///
    /// Synchronous on purpose: the caller is already off the main thread and a
    /// live-updating query would be answering a question nobody is still
    /// asking. Bounded by `limit` because a predicate can match millions and
    /// the intersection only needs as many as the table will show.
    public static func paths(matching predicate: String, under roots: [String],
                             limit: Int = 50_000) -> [String] {
        // No roots means no scope, and no scope means the whole index — every
        // volume, every home folder, answers about files nobody scanned. The
        // question is always "what is inside the tree on screen".
        guard !predicate.isEmpty, limit > 0, !roots.isEmpty else { return [] }
        let span = Telemetry.begin("spotlight.query")
        guard let query = MDQueryCreate(nil, predicate as CFString, nil, nil) else {
            span.end(["matches": .int(0)])
            return []
        }
        MDQuerySetSearchScope(query, roots as CFArray, 0)
        // Synchronous: gather everything, then stop. Without this the query
        // stays live and keeps a callback alive for a screen that has moved on.
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            span.end(["matches": .int(0)])
            return []
        }
        MDQueryDisableUpdates(query)
        defer { MDQueryStop(query) }

        let found = MDQueryGetResultCount(query)
        var out: [String] = []
        out.reserveCapacity(min(found, limit))
        for index in 0..<min(found, limit) {
            // One MDItem per result, which costs a few hundred microseconds
            // each. `MDQueryGetAttributeValueOfResultAtIndex` is documented as
            // the cheaper way and was tried both with and without the path in
            // the query's value-list attributes; it returned nothing either
            // way, so this is the accessor that actually answers. The cost is
            // why `limit` exists and why the questions are narrow.
            let raw = MDQueryGetResultAtIndex(query, index)
            let item = unsafeBitCast(raw, to: MDItem?.self)
            guard let item,
                  let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            out.append(path)
        }
        span.end(["matched": .int(Int64(found)), "returned": .int(Int64(out.count))],
                 minMilliseconds: 100)
        return out
    }
}

public extension SpotlightQuery {
    /// Whether the index knows anything at all about this place.
    ///
    /// An empty answer and an unanswerable question look identical otherwise,
    /// and they mean opposite things: no screenshots here, or no index here.
    /// One match is enough to tell them apart, so the query is bounded to one.
    static func isIndexed(_ root: String) -> Bool {
        !paths(matching: "kMDItemContentType == \"*\"", under: [root], limit: 1).isEmpty
    }
}

/// The answer to a content question, in a shape the tree walk can test cheaply.
///
/// The walk deliberately never builds a path — doing it for nine million nodes
/// costs eighty-two seconds — so an intersection cannot simply compare paths.
/// It compares *names* first, as a hash of the interned bytes, and only the
/// handful of nodes whose name matches something pay for a path.
public struct ContentMatches: Sendable, Equatable {
    /// Compared by what was asked and how much came back, not by every path: a
    /// filter is "the same filter" when it is the same answer, and two sets of
    /// two hundred thousand strings are not worth walking to find that out.
    public static func == (a: ContentMatches, b: ContentMatches) -> Bool {
        a.token == b.token && a.count == b.count
    }

    /// What produced this answer, so two of them can be told apart.
    public let token: String

    /// Hashes of the matched basenames, folded to lower case.
    let nameHashes: Set<UInt64>
    /// The paths themselves, for the second test.
    let paths: Set<String>
    /// How many the index returned, before any intersection.
    public let count: Int

    public init(paths: [String], token: String = "") {
        self.token = token
        var hashes = Set<UInt64>()
        hashes.reserveCapacity(paths.count)
        for path in paths {
            hashes.insert(Self.hash(name: (path as NSString).lastPathComponent))
        }
        self.nameHashes = hashes
        self.paths = Set(paths)
        self.count = paths.count
    }

    /// FNV-1a over the lower-cased bytes, the same fold the search uses, so a
    /// name from the index and a name from the tree hash alike.
    static func hash(name: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            let folded = byte >= 65 && byte <= 90 ? byte + 32 : byte
            hash = (hash ^ UInt64(folded)) &* 0x100_0000_01b3
        }
        return hash
    }

    @inline(__always)
    static func hash(bytes base: UnsafePointer<UInt8>, offset: Int, length: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for i in 0..<length {
            var byte = base[offset + i]
            if byte >= 65 && byte <= 90 { byte += 32 }
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }

    /// Cheap: does any match share this name?
    @inline(__always)
    func mightHold(nameHash: UInt64) -> Bool { nameHashes.contains(nameHash) }

    /// Dear: is this exact file one of them?
    public func holds(path: String) -> Bool { paths.contains(path) }
}
