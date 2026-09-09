import Foundation

/// Which property the flat table is ordered by.
///
/// Every column that is a property of the node itself is a sort key. The
/// enclosing folder is not: ordering by path means building a path for every
/// one of nine million nodes to compare them, which is the eighty-second cost
/// `Find` documents and then avoids.
public enum FileSort: String, Sendable, CaseIterable, Identifiable {
    case name, size, apparent, kind, modified
    public var id: String { rawValue }
}

/// What to leave out.
///
/// Everything here is answered from the index — name, size, date, extension —
/// so a filter costs one pass over memory and never opens a file. Filters that
/// need the file's contents are a separate tier and are deliberately not mixed
/// in with these: the difference between "instant over ten million" and "reads
/// every file" must stay visible in the type, not be discovered at runtime.
public struct FileFilter: Sendable, Equatable {
    /// Case-insensitive substring of the name. Not the path: the path is not
    /// in the index either.
    public var text = ""
    /// Empty means every kind. A set rather than one value, because "video or
    /// image" is the question people actually have.
    public var categories: Set<FileCategory> = []
    /// On-disk size, inclusive. `maxBytes` of 0 means no upper bound.
    public var minBytes: Int64 = 0
    public var maxBytes: Int64 = 0
    /// Unix seconds, inclusive. 0 on either side means no bound there.
    public var modifiedAfter: Int32 = 0
    public var modifiedBefore: Int32 = 0
    /// Folders are rows too when asked for, sized by their whole subtree the
    /// way the map sizes them.
    public var includeFolders = false

    /// The answer to a content question, already asked.
    ///
    /// Deliberately a set of results rather than a question: this type is about
    /// what the index can answer for free, and a question about what is *in*
    /// files is a query somebody else has to run first. Keeping the query out
    /// here is what stops a filter that costs a tenth of a second and a filter
    /// that costs nine seconds looking the same at the call site.
    public var content: ContentMatches?

    public init() {}

    public var isEmpty: Bool {
        text.isEmpty && categories.isEmpty && minBytes == 0 && maxBytes == 0
            && modifiedAfter == 0 && modifiedBefore == 0 && !includeFolders
            && content == nil
    }
}

/// One line of the table, with every property it can show already in it.
public struct FileRow: Sendable, Identifiable, Equatable {
    public var id: Int32 { node }
    public var node: Int32
    public var name: String
    /// Where it lives. Shown on every row, because a flat list without it says
    /// there are eleven `config.json` and nothing about which is which.
    public var folder: String
    public var physical: Int64
    public var logical: Int64
    public var mtime: Int32
    public var category: FileCategory
    public var flags: NodeFlags
    public var isDirectory: Bool

    public var path: String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }
}

/// The rows asked for, and what they are a slice of.
///
/// Returned together for the same reason `FindResults` carries its total: the
/// list is capped and the answer is not, and a reader must never take the rows
/// on screen for the whole of it.
public struct FileTablePage: Sendable {
    /// In sorted order, at most `limit` of them.
    public var rows: [FileRow]
    /// How many rows matched altogether.
    public var total: Int
    /// Bytes over every matching **file**, not only the returned rows.
    ///
    /// Files only, even when folders are included as rows: a folder's size is
    /// its subtree, so adding folders to this would count the same bytes once
    /// per level of depth and the footer would claim a disk several times its
    /// own size.
    public var totalPhysical: Int64
    public var totalLogical: Int64

    public init(rows: [FileRow] = [], total: Int = 0,
                totalPhysical: Int64 = 0, totalLogical: Int64 = 0) {
        self.rows = rows
        self.total = total
        self.totalPhysical = totalPhysical
        self.totalLogical = totalLogical
    }
}

/// Every file at once, as a flat list.
///
/// The tree table answers "what is inside this folder" and makes you walk down
/// to it. This answers "show me everything, ordered by the thing I care about"
/// — the question behind *what are my biggest files*, *what have I not touched
/// since 2023*, *where did all these disk images come from* — without
/// navigating anywhere at all.
///
/// It is a single pass over the index, keeping only the best `limit` rows as it
/// goes, so re-sorting ten million files does not mean sorting ten million
/// files. Nothing is materialised as a string until the surviving rows are
/// handed back: names are compared as interned bytes and paths are built for
/// the thousand rows that will be shown, never for the ten million that were
/// looked at.
public enum FileTable {
    /// The rows for one screen, in order.
    ///
    /// `root` scopes it to a subtree; 0 is the whole scan, which is what the
    /// flat table is for.
    public static func page(store: NodeStore, root: Int32 = 0,
                            filter: FileFilter = FileFilter(),
                            sort: FileSort = .size, ascending: Bool = false,
                            limit: Int = 1_000) -> FileTablePage {
        var page = FileTablePage()
        guard root >= 0, root < Int32(store.count), limit > 0 else { return page }
        let span = Telemetry.begin("filetable")

        // Nil when the text is empty or is not plain ASCII. Empty means no
        // filter; non-ASCII means the slow path, which folds case the way the
        // language does rather than by adding 32 to a byte.
        let pattern = filter.text.isEmpty ? nil : Find.asciiLowered(filter.text)
        let slowText = (pattern == nil && !filter.text.isEmpty)
            ? filter.text.lowercased() : nil
        // Worked out per surviving row rather than per node, unless something
        // actually needs it for all ten million.
        let needsCategory = !filter.categories.isEmpty || sort == .kind

        var kept: [Entry] = []
        kept.reserveCapacity(limit + 1)
        var stack: [Int32] = [root]
        var total = 0
        var totalPhysical: Int64 = 0
        var totalLogical: Int64 = 0

        store.nameBytes.withUnsafeBufferPointer { buffer in
            guard let names = buffer.baseAddress else { return }
            while let node = stack.popLast() {
                for child in store.children(node) {
                    let index = Int(child)
                    let flags = NodeFlags(rawValue: store.flags[index])
                    if flags.contains(.removed) { continue }

                    let isDirectory = flags.contains(.directory)
                    if isDirectory { stack.append(child) }
                    if isDirectory && !filter.includeFolders { continue }

                    let physical = store.totalPhysical[index]
                    if physical < filter.minBytes { continue }
                    if filter.maxBytes > 0 && physical > filter.maxBytes { continue }

                    let mtime = store.mtime[index]
                    if filter.modifiedAfter > 0 && mtime < filter.modifiedAfter { continue }
                    if filter.modifiedBefore > 0 && mtime > filter.modifiedBefore { continue }

                    let offset = Int(store.nameOffset[index])
                    let length = Int(store.nameLen[index])

                    if let pattern {
                        guard length >= pattern.count,
                              Find.matchStart(buffer, offset, length, pattern) >= 0 else { continue }
                    } else if let slowText {
                        guard store.name(child).lowercased().contains(slowText) else { continue }
                    }

                    // Two tests, cheap one first. The name hash prunes to the
                    // few nodes that could be a match; only those pay for a
                    // path, which is the cost this walk exists to avoid.
                    if let content = filter.content {
                        guard content.mightHold(
                                nameHash: ContentMatches.hash(bytes: names, offset: offset,
                                                              length: length)),
                              content.holds(path: store.path(child)) else { continue }
                    }

                    var category = FileCategory.folder
                    if needsCategory {
                        category = Categorizer.category(bytes: names + offset, length: length,
                                                        isDirectory: isDirectory)
                        if !filter.categories.isEmpty,
                           !filter.categories.contains(category) { continue }
                    }

                    total += 1
                    if !isDirectory {
                        totalPhysical += physical
                        totalLogical += store.totalLogical[index]
                    }

                    let key: UInt64
                    switch sort {
                    case .size:     key = UInt64(max(0, physical))
                    case .apparent: key = UInt64(max(0, store.totalLogical[index]))
                    case .modified: key = UInt64(Int64(mtime) + 2_147_483_648)
                    case .kind:     key = UInt64(category.rawValue)
                    case .name:     key = namePrefix(names, offset, length)
                    }
                    let entry = Entry(key: key, bytes: physical, node: child)
                    guard kept.count < limit
                            || before(entry, kept[kept.count - 1], ascending) else { continue }
                    // From the back: an entry that only just beat the worst one
                    // kept belongs near the end, which is where most of them
                    // are once the list is full.
                    var at = kept.count
                    while at > 0 && before(entry, kept[at - 1], ascending) { at -= 1 }
                    kept.insert(entry, at: at)
                    if kept.count > limit { kept.removeLast() }
                }
            }
            // Built here rather than after the walk so a row's kind is the
            // same function that the kind filter just ran. The two spellings
            // of the classifier do not agree on every folder name, and a row
            // labelled Document in a list filtered to Cache is the kind of
            // quiet contradiction nobody reports and everybody notices.
            page.rows = kept.map { entry in
                let index = Int(entry.node)
                let parent = store.parent[index]
                let isDirectory = store.isDirectory(entry.node)
                return FileRow(node: entry.node,
                               name: store.name(entry.node),
                               folder: parent >= 0 ? store.path(parent) : "",
                               physical: store.totalPhysical[index],
                               logical: store.totalLogical[index],
                               mtime: store.mtime[index],
                               category: Categorizer.category(
                                   bytes: names + Int(store.nameOffset[index]),
                                   length: Int(store.nameLen[index]),
                                   isDirectory: isDirectory),
                               flags: store.flagSet(entry.node),
                               isDirectory: isDirectory)
            }
        }

        page.total = total
        page.totalPhysical = totalPhysical
        page.totalLogical = totalLogical
        // Names longer than the eight bytes the key holds are only ordered
        // correctly once there are real strings to compare, and there are at
        // most `limit` of those.
        if sort == .name {
            page.rows.sort {
                let order = $0.name.localizedStandardCompare($1.name)
                if order != .orderedSame { return ascending == (order == .orderedAscending) }
                return $0.physical > $1.physical
            }
        }
        span.end(["nodes": .int(Int64(store.count)), "matched": .int(Int64(total)),
                  "returned": .int(Int64(page.rows.count))], minMilliseconds: 100)
        return page
    }

    private struct Entry {
        var key: UInt64
        var bytes: Int64
        var node: Int32
    }

    /// The order the table is in.
    ///
    /// Size breaks a tie whatever the column, and biggest-first whichever way
    /// the column is pointing: in a tool about space, two files that are equal
    /// on the property being sorted are still not equally interesting. The node
    /// id last, so the order is the same on every run.
    @inline(__always)
    private static func before(_ a: Entry, _ b: Entry, _ ascending: Bool) -> Bool {
        if a.key != b.key { return ascending ? a.key < b.key : a.key > b.key }
        if a.bytes != b.bytes { return a.bytes > b.bytes }
        return a.node < b.node
    }

    /// The first eight bytes of the name, case-folded, packed so that comparing
    /// two of them as integers orders them as text. A name shorter than eight
    /// bytes pads with zeroes, so `report` sorts before `report.pdf`.
    ///
    /// Eight bytes decide the ordering during the walk, and the rows that
    /// survive are sorted again properly. The only thing the prefix can get
    /// wrong is *which* rows survive at the exact boundary of a full page —
    /// among names sharing eight leading bytes, the largest is kept.
    @inline(__always)
    private static func namePrefix(_ base: UnsafePointer<UInt8>,
                                   _ offset: Int, _ length: Int) -> UInt64 {
        var key: UInt64 = 0
        for i in 0..<8 {
            var byte: UInt8 = 0
            if i < length {
                byte = base[offset + i]
                if byte >= 65 && byte <= 90 { byte += 32 }
            }
            key = (key << 8) | UInt64(byte)
        }
        return key
    }
}
