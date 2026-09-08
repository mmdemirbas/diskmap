import Foundation

/// A scan, in a form another program can read.
///
/// The tree itself is not a useful export: nine million nodes is gigabytes of
/// JSON that nothing wants to parse. What another program almost always wants
/// is the same thing a person wants — where the space is — so the document
/// carries the totals, the volumes involved, every folder above a size floor,
/// and the largest files, with the floor and the cut-off reported alongside so
/// a consumer can tell what was left out rather than assuming it saw
/// everything.
public enum Export {
    /// Bumped when a field changes meaning or disappears. Consumers should
    /// refuse a major version they do not know.
    public static let schema = "diskmap.export/1"

    public struct Options: Sendable {
        /// Folders smaller than this are summarised by their nearest listed
        /// ancestor rather than listed themselves. Zero lists everything.
        public var folderMinimumBytes: Int64 = 10_000_000
        /// How many of the largest files to include. Zero omits the section.
        public var largestFiles: Int = 1000
        /// Copies cost a second analysis pass, so they are opt-in.
        public var includeDuplicates = false
        /// As do cleanup suggestions.
        public var includeSuggestions = false
        public var prettyPrinted = true
        public init() {}
    }

    // MARK: - The document

    public struct Document: Codable, Sendable {
        public var schema: String
        public var generatedAt: Date
        public var roots: [String]
        public var totals: Totals
        public var volumes: [Volume]
        public var limits: Limits
        public var folders: [Entry]
        public var largestFiles: [Entry]
        public var duplicateGroups: [DuplicateGroupOut]?
        public var suggestions: [SuggestionOut]?
    }

    public struct Totals: Codable, Sendable {
        public var physical: Int64
        public var logical: Int64
        public var files: Int
        public var directories: Int
        public var symlinks: Int
        public var datalessFiles: Int
        public var datalessLogical: Int64
        public var hardlinkDuplicates: Int
        public var hardlinkDuplicateLogical: Int64
        public var unreadableDirectories: Int
        public var elapsedSeconds: Double
        public var cancelled: Bool
    }

    public struct Volume: Codable, Sendable {
        public var path: String
        public var name: String
        public var capacity: Int64
        public var used: Int64
        /// What can be written right now.
        public var freeWritable: Int64
        /// What Finder reports, which counts purgeable space as free.
        public var freeAsFinderShows: Int64
        public var purgeable: Int64
    }

    /// What the document does not contain. Present so a reader never has to
    /// guess whether a missing folder is absent or merely below the floor.
    public struct Limits: Codable, Sendable {
        public var folderMinimumBytes: Int64
        public var foldersListed: Int
        public var foldersOmitted: Int
        public var largestFilesLimit: Int
        public var largestFilesListed: Int
    }

    public struct Entry: Codable, Sendable {
        public var path: String
        public var physical: Int64
        public var logical: Int64
        public var isDirectory: Bool
        /// Direct children, for a folder.
        public var items: Int?
        public var modified: Date
        /// An iCloud placeholder: its apparent size is not on this disk.
        public var dataless: Bool?
        /// A hard link to a file already counted somewhere else in this scan.
        public var hardlinkDuplicate: Bool?
    }

    public struct DuplicateGroupOut: Codable, Sendable {
        public var kind: String           // "folder" or "file"
        public var exact: Bool
        /// Freed by keeping one copy and removing the rest.
        public var reclaimable: Int64
        public var paths: [String]
    }

    public struct SuggestionOut: Codable, Sendable {
        public var kind: String
        public var safety: String
        public var bytes: Int64
        public var itemCount: Int
        public var omitted: Int
        public var paths: [String]
    }

    // MARK: - Building it

    public static func document(store: NodeStore, stats: ScanStats,
                                volumes: [VolumeInfo] = [],
                                options: Options = Options(),
                                now: Date = Date()) -> Document {
        var folders: [Entry] = []
        var omitted = 0
        var files: [(node: Int32, bytes: Int64)] = []

        var stack: [Int32] = [0]
        while let node = stack.popLast() {
            for child in store.children(node) {
                let flags = store.flagSet(child)
                guard !flags.contains(.removed) else { continue }
                if store.isDirectory(child) {
                    stack.append(child)
                    let bytes = store.totalPhysical[Int(child)]
                    guard bytes >= options.folderMinimumBytes else { omitted += 1; continue }
                    folders.append(entry(store, child))
                } else if options.largestFiles > 0 {
                    files.append((child, store.totalPhysical[Int(child)]))
                }
            }
        }
        folders.sort { $0.physical > $1.physical }

        // Sorting nine million files to take a thousand is wasteful but honest,
        // and a scan of that size has already cost fifty seconds. A partial
        // selection would be the optimisation if this ever shows up.
        files.sort { $0.bytes > $1.bytes }
        let largest = files.prefix(options.largestFiles).map { entry(store, $0.node) }

        return Document(
            schema: schema,
            generatedAt: now,
            roots: store.roots,
            totals: Totals(
                physical: store.totalPhysical[0], logical: store.totalLogical[0],
                files: stats.files, directories: stats.directories, symlinks: stats.symlinks,
                datalessFiles: stats.datalessCount, datalessLogical: stats.datalessLogical,
                hardlinkDuplicates: stats.hardlinkDuplicates,
                hardlinkDuplicateLogical: stats.hardlinkDuplicateLogical,
                unreadableDirectories: stats.unreadableDirectories,
                elapsedSeconds: stats.elapsed, cancelled: stats.cancelled),
            volumes: volumes.map {
                Volume(path: $0.path, name: $0.name, capacity: $0.total, used: $0.used,
                       freeWritable: $0.trueAvailable, freeAsFinderShows: $0.finderAvailable,
                       purgeable: $0.purgeable)
            },
            limits: Limits(folderMinimumBytes: options.folderMinimumBytes,
                           foldersListed: folders.count, foldersOmitted: omitted,
                           largestFilesLimit: options.largestFiles,
                           largestFilesListed: largest.count),
            folders: folders,
            largestFiles: largest,
            duplicateGroups: nil,
            suggestions: nil)
    }

    private static func entry(_ store: NodeStore, _ node: Int32) -> Entry {
        let flags = store.flagSet(node)
        let isDirectory = store.isDirectory(node)
        return Entry(
            path: store.path(node),
            physical: store.totalPhysical[Int(node)],
            logical: store.totalLogical[Int(node)],
            isDirectory: isDirectory,
            items: isDirectory ? store.children(node).count : nil,
            modified: Date(timeIntervalSince1970: TimeInterval(store.mtime[Int(node)])),
            dataless: flags.contains(.dataless) ? true : nil,
            hardlinkDuplicate: flags.contains(.hardlinkDuplicate) ? true : nil)
    }

    /// Copies, when the caller asked for them. Separate from `document` because
    /// finding them is a second pass over the tree, not a formatting step.
    public static func addCopies(to doc: inout Document, store: NodeStore,
                                 folderMatches: [FolderMatch], fileGroups: [DuplicateGroup]) {
        var out: [DuplicateGroupOut] = []
        for match in folderMatches where match.nodes.count > 1 {
            out.append(DuplicateGroupOut(kind: "folder", exact: match.exact,
                                         reclaimable: match.reclaimable,
                                         paths: match.nodes.map { store.path($0) }))
        }
        for group in fileGroups where group.nodes.count > 1 {
            out.append(DuplicateGroupOut(kind: "file", exact: true,
                                         reclaimable: group.reclaimable,
                                         paths: group.nodes.map { store.path($0) }))
        }
        doc.duplicateGroups = out
    }

    public static func addSuggestions(to doc: inout Document, store: NodeStore,
                                      suggestions: [CleanupSuggestion]) {
        doc.suggestions = suggestions.map { s in
            SuggestionOut(kind: s.kind.rawValue, safety: s.safety.name,
                          bytes: s.bytes, itemCount: s.itemCount, omitted: s.omitted,
                          paths: s.nodes.map { store.path($0) })
        }
    }

    // MARK: - Asking the index a question

    /// One row of the flat table, for a reader that is a program.
    ///
    /// The same fields the screen shows, with the kind as a stable token rather
    /// than the translated label: a script that greps for "Disk image" breaks
    /// the day somebody runs the app in Turkish.
    public struct TableRow: Codable, Sendable {
        public var path: String
        public var name: String
        public var folder: String
        public var kind: String
        public var directory: Bool
        public var physical: Int64
        public var logical: Int64
        public var modified: Date
        /// Only what is true of this row: `dataless`, `hardlink`, `symlink`,
        /// `compressed`, `unreadable`. Absent rather than false.
        public var marks: [String]
    }

    /// A page of the flat table, and what it is a page of.
    ///
    /// `matched` against `shown` is the field that matters: the rows are capped
    /// and the answer is not, and a consumer that reads `rows.count` as the
    /// count has been given enough to know better.
    public struct TableDocument: Codable, Sendable {
        public var schema: String
        public var generatedAt: Date
        public var roots: [String]
        public var sortedBy: String
        public var ascending: Bool
        public var matched: Int
        public var shown: Int
        /// Over everything that matched, not over the rows returned. Files
        /// only, even when folders are rows: a folder's size is its subtree.
        public var physical: Int64
        public var logical: Int64
        public var rows: [TableRow]
    }

    public static let tableSchema = "diskmap.table/1"

    public static func table(store: NodeStore, roots: [String], page: FileTablePage,
                             sort: FileSort, ascending: Bool,
                             now: Date = Date()) -> TableDocument {
        TableDocument(schema: tableSchema, generatedAt: now, roots: roots,
                      sortedBy: sort.rawValue, ascending: ascending,
                      matched: page.total, shown: page.rows.count,
                      physical: page.totalPhysical, logical: page.totalLogical,
                      rows: page.rows.map(row))
    }

    public static func row(_ r: FileRow) -> TableRow {
        var marks: [String] = []
        if r.flags.contains(.dataless) { marks.append("dataless") }
        if r.flags.contains(.hardlinkDuplicate) { marks.append("hardlink") }
        if r.flags.contains(.symlink) { marks.append("symlink") }
        if r.flags.contains(.compressed) { marks.append("compressed") }
        if r.flags.contains(.unreadable) { marks.append("unreadable") }
        return TableRow(path: r.path, name: r.name, folder: r.folder,
                        kind: r.category.token, directory: r.isDirectory,
                        physical: r.physical, logical: r.logical,
                        modified: Date(timeIntervalSince1970: TimeInterval(r.mtime)),
                        marks: marks)
    }

    /// What a search found. `matched` and `shown` carry the same warning the
    /// table's do, and `how` says why a row is in the answer at all — a
    /// subsequence hit means the needle matched nothing outright and was read
    /// as an abbreviation instead.
    public struct SearchHit: Codable, Sendable {
        public var path: String
        public var name: String
        public var directory: Bool
        public var physical: Int64
        public var logical: Int64
        public var how: String
    }

    public struct SearchDocument: Codable, Sendable {
        public var schema: String
        public var generatedAt: Date
        public var roots: [String]
        public var needle: String
        public var matched: Int
        public var shown: Int
        public var hits: [SearchHit]
    }

    public static let searchSchema = "diskmap.search/1"

    public static func search(roots: [String], needle: String, results: FindResults,
                              now: Date = Date()) -> SearchDocument {
        SearchDocument(schema: searchSchema, generatedAt: now, roots: roots,
                       needle: needle, matched: results.total, shown: results.items.count,
                       hits: results.items.map { item in
                           SearchHit(path: item.path,
                                     name: (item.path as NSString).lastPathComponent,
                                     directory: item.isDirectory,
                                     physical: item.physical, logical: item.logical,
                                     how: item.kind.token)
                       })
    }

    public static func encode<T: Encodable>(_ doc: T, prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted so two exports of the same disk diff cleanly.
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(doc)
    }
}

public extension CleanupSuggestion.Safety {
    /// A stable name for the export, independent of anything on screen.
    var name: String {
        switch self {
        case .comesBack: "comesBack"
        case .aCopyRemains: "aCopyRemains"
        case .yourCall: "yourCall"
        }
    }
}
