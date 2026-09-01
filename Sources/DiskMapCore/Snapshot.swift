import Foundation

/// What one scan looked like, small enough to keep dozens of.
///
/// Not the tree. Keeping the whole tree would cost about half a gigabyte per
/// scan on a nine-million-node disk, which is an absurd thing for a tool about
/// freeing space to write. What is kept is every folder big enough to matter,
/// with its size — enough to answer "what grew since last week", which is the
/// question a single scan cannot answer at all.
public struct DiskDigest: Sendable, Codable {
    public var takenAt: Date
    public var roots: [String]
    public var totalPhysical: Int64
    public var totalLogical: Int64
    public var files: Int
    public var directories: Int
    /// Folder path to its size on disk. Folders below the floor are absent and
    /// their bytes are accounted for by the nearest ancestor that is present.
    public var folders: [String: Int64]

    public init(takenAt: Date, roots: [String], totalPhysical: Int64, totalLogical: Int64,
                files: Int, directories: Int, folders: [String: Int64]) {
        self.takenAt = takenAt
        self.roots = roots
        self.totalPhysical = totalPhysical
        self.totalLogical = totalLogical
        self.files = files
        self.directories = directories
        self.folders = folders
    }

    /// `floor` trades detail for file size. At 20 MB a full home directory
    /// comes to a few tens of thousands of entries.
    public static func of(store: NodeStore, stats: ScanStats,
                          floor: Int64 = 20_000_000, limit: Int = 40_000,
                          takenAt: Date = Date()) -> DiskDigest {
        var candidates: [(String, Int64)] = []
        var stack: [Int32] = [0]
        while let node = stack.popLast() {
            for child in store.children(node) where store.isDirectory(child) {
                guard !store.flagSet(child).contains(.removed) else { continue }
                let bytes = store.totalPhysical[Int(child)]
                guard bytes >= floor else { continue }
                candidates.append((store.path(child), bytes))
                stack.append(child)
            }
        }
        if candidates.count > limit {
            candidates.sort { $0.1 > $1.1 }
            candidates = Array(candidates.prefix(limit))
        }
        return DiskDigest(takenAt: takenAt, roots: store.roots,
                          totalPhysical: store.totalPhysical[0],
                          totalLogical: store.totalLogical[0],
                          files: stats.files, directories: stats.directories,
                          folders: Dictionary(candidates, uniquingKeysWith: { a, _ in a }))
    }
}

public struct FolderChange: Sendable, Identifiable {
    public enum Kind: String, Sendable { case grew, shrank, appeared, vanished }
    public var id: String { path }
    public var path: String
    public var kind: Kind
    public var before: Int64
    public var after: Int64
    /// The change this folder is responsible for, with its listed children's
    /// changes taken out. Without this every ancestor of a change repeats it.
    public var ownDelta: Int64
}

public struct DigestDiff: Sendable {
    public var from: Date
    public var to: Date
    public var totalDelta: Int64
    public var changes: [FolderChange]
    public var isEmpty: Bool { changes.isEmpty }

    /// A digest only holds folders above its floor, so one that shrank below it
    /// is indistinguishable from one that was deleted — and "vanished" is a
    /// much stronger claim than "got smaller". Anything the caller can still
    /// find is relabelled.
    public func resolvingVanished(stillThere: (String) -> Bool) -> DigestDiff {
        var copy = self
        copy.changes = changes.map { change in
            guard change.kind == .vanished, stillThere(change.path) else { return change }
            var fixed = change
            fixed.kind = .shrank
            return fixed
        }
        return copy
    }
}

public extension DiskDigest {
    /// Compares two digests and attributes each change to the deepest folder
    /// that explains it.
    ///
    /// The naive version reports a download as a change in Downloads, in the
    /// home folder, and in every folder between — the same fact, five times,
    /// with the least useful statement of it at the top because it is biggest.
    static func diff(from old: DiskDigest, to new: DiskDigest,
                     floor: Int64 = 50_000_000) -> DigestDiff {
        var deltas: [String: (before: Int64, after: Int64)] = [:]
        for (path, bytes) in old.folders { deltas[path, default: (0, 0)].before = bytes }
        for (path, bytes) in new.folders { deltas[path, default: (0, 0)].after = bytes }

        // Deepest first, so a child's contribution is already removed from the
        // running total by the time its parent is considered.
        var absorbed: [String: Int64] = [:]
        var out: [FolderChange] = []
        for path in deltas.keys.sorted(by: { $0.count > $1.count }) {
            let entry = deltas[path]!
            let delta = entry.after - entry.before
            let own = delta - (absorbed[path] ?? 0)

            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty, parent != path { absorbed[parent, default: 0] += delta }

            guard abs(own) >= floor else { continue }
            let kind: FolderChange.Kind =
                entry.before == 0 ? .appeared
                : entry.after == 0 ? .vanished
                : (delta > 0 ? .grew : .shrank)
            out.append(FolderChange(path: path, kind: kind,
                                    before: entry.before, after: entry.after, ownDelta: own))
        }
        out.sort { abs($0.ownDelta) > abs($1.ownDelta) }
        return DigestDiff(from: old.takenAt, to: new.takenAt,
                          totalDelta: new.totalPhysical - old.totalPhysical, changes: out)
    }
}

/// Where digests live, and how many are kept.
///
/// Only ever touches its own directory, and only files it wrote: the pruning
/// step matches the extension it writes and nothing else.
public struct SnapshotStore: Sendable {
    public static let fileExtension = "dmsnap"
    public let directory: URL
    public let keep: Int

    public init(directory: URL = Telemetry.directory.appendingPathComponent("history"),
                keep: Int = 30) {
        self.directory = directory
        self.keep = keep
    }

    public struct Entry: Sendable, Identifiable {
        public var id: String { url.lastPathComponent }
        public var url: URL
        public var takenAt: Date
        public var totalPhysical: Int64
    }

    /// Newest last.
    public func list() -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [Entry] = []
        for name in names where name.hasSuffix("." + Self.fileExtension) {
            let url = directory.appendingPathComponent(name)
            guard let digest = try? read(url) else { continue }
            out.append(Entry(url: url, takenAt: digest.takenAt,
                             totalPhysical: digest.totalPhysical))
        }
        return out.sorted { $0.takenAt < $1.takenAt }
    }

    public func read(_ url: URL) throws -> DiskDigest {
        let raw = try Data(contentsOf: url)
        let json = (try? (raw as NSData).decompressed(using: .zlib) as Data) ?? raw
        return try JSONDecoder().decode(DiskDigest.self, from: json)
    }

    @discardableResult
    public func write(_ digest: DiskDigest) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.stamp.string(from: digest.takenAt)
        let url = directory.appendingPathComponent("scan-\(stamp).\(Self.fileExtension)")
        let json = try JSONEncoder().encode(digest)
        // Mostly long shared path prefixes, so this compresses to a fraction.
        let body = (try? (json as NSData).compressed(using: .zlib) as Data) ?? json
        try body.write(to: url, options: .atomic)
        prune()
        return url
    }

    /// Keeps the newest `keep`. Deletes only files in its own directory whose
    /// name ends in its own extension — nothing else is ever considered.
    private func prune() {
        let entries = list()
        guard entries.count > keep else { return }
        for entry in entries.prefix(entries.count - keep) {
            guard entry.url.pathExtension == Self.fileExtension,
                  entry.url.deletingLastPathComponent().path == directory.path else { continue }
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
