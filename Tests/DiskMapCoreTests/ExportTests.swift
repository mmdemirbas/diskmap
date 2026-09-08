import XCTest
@testable import DiskMapCore

/// The document another program reads. Its job is to be honest about what it
/// does and does not contain.
final class ExportTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmexport-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("big/inner"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("tiny"),
                               withIntermediateDirectories: true)
        try Data(count: 900_000).write(to: root.appendingPathComponent("big/one.bin"))
        try Data(count: 400_000).write(to: root.appendingPathComponent("big/inner/two.bin"))
        try Data(count: 500).write(to: root.appendingPathComponent("tiny/three.bin"))
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func scan() -> ScanResult {
        DiskScanner().scan(ScanOptions(rootPath: root.path))
    }

    private func document(_ options: Export.Options) -> Export.Document {
        let r = scan()
        return Export.document(store: r.store, stats: r.stats, options: options)
    }

    // MARK: - Answering a question rather than describing a disk

    /// The field that stops a caller reading `rows.count` as the count.
    func testTheTableDocumentSaysHowMuchItIsNotShowing() throws {
        let r = scan()
        let page = FileTable.page(store: r.store, sort: .size, limit: 1)
        let doc = Export.table(store: r.store, roots: r.store.roots, page: page,
                               sort: .size, ascending: false)

        XCTAssertEqual(doc.schema, "diskmap.table/1")
        XCTAssertEqual(doc.shown, 1)
        XCTAssertEqual(doc.matched, 3)
        XCTAssertEqual(doc.sortedBy, "size")
        XCTAssertFalse(doc.ascending)
        // Over every match, not over the one row returned.
        XCTAssertEqual(doc.logical, 1_300_500)
        XCTAssertEqual(doc.rows.first?.name, "one.bin")
        XCTAssertEqual(doc.rows.first?.kind, "other")
        XCTAssertTrue(doc.rows.first?.marks.isEmpty ?? false)
    }

    /// A translated label in machine output breaks the day somebody runs the
    /// app in another language, so the kind travels as a token — and the token
    /// has to be the one the command line accepts back.
    func testEveryKindHasATokenThatParsesBackToIt() throws {
        for category in FileCategory.allCases {
            XCTAssertEqual(FileCategory.named(category.token), category, category.token)
        }
        XCTAssertEqual(FileCategory.named("DISKIMAGE"), .diskImage)
        XCTAssertNil(FileCategory.named("nonsense"))
    }

    func testASearchDocumentSaysHowEachRowMatched() throws {
        let r = scan()
        let found = Find.search(store: r.store, needle: "one.bin", limit: 10)
        let doc = Export.search(roots: r.store.roots, needle: "one.bin", results: found)

        XCTAssertEqual(doc.schema, "diskmap.search/1")
        XCTAssertEqual(doc.needle, "one.bin")
        XCTAssertEqual(doc.hits.first?.how, "exact")
        XCTAssertEqual(doc.hits.first?.name, "one.bin")

        // A needle that matched nothing outright is read as an abbreviation,
        // and the document has to say that is what happened.
        let loose = Find.search(store: r.store, needle: "onbn", limit: 10)
        let looseDoc = Export.search(roots: r.store.roots, needle: "onbn", results: loose)
        XCTAssertEqual(looseDoc.hits.first?.how, "subsequence")
    }

    func testTheTotalsMatchTheScan() throws {
        let r = scan()
        let doc = Export.document(store: r.store, stats: r.stats)
        XCTAssertEqual(doc.schema, "diskmap.export/1")
        XCTAssertEqual(doc.totals.logical, 1_300_500)
        XCTAssertEqual(doc.totals.files, 3)
        XCTAssertEqual(doc.roots, r.store.roots)
    }

    /// The point of the limits block: a folder missing from the list must be
    /// distinguishable from a folder that does not exist.
    func testWhatWasLeftOutIsCounted() throws {
        let doc = document({ var o = Export.Options(); o.folderMinimumBytes = 500_000; return o }())
        XCTAssertEqual(doc.limits.folderMinimumBytes, 500_000)
        XCTAssertEqual(doc.limits.foldersListed, doc.folders.count)
        XCTAssertGreaterThan(doc.limits.foldersOmitted, 0, "tiny/ and inner/ are under the floor")
        XCTAssertFalse(doc.folders.contains { $0.path.hasSuffix("/tiny") })
        XCTAssertTrue(doc.folders.contains { $0.path.hasSuffix("/big") })
    }

    func testAZeroFloorListsEveryFolder() throws {
        let doc = document({ var o = Export.Options(); o.folderMinimumBytes = 0; return o }())
        XCTAssertEqual(doc.limits.foldersOmitted, 0)
        XCTAssertEqual(doc.folders.count, 3)   // big, big/inner, tiny
    }

    func testTheLargestFilesAreTheLargestAndAreCapped() throws {
        let doc = document({ var o = Export.Options(); o.largestFiles = 2; return o }())
        XCTAssertEqual(doc.largestFiles.count, 2)
        XCTAssertEqual(doc.limits.largestFilesLimit, 2)
        XCTAssertEqual(doc.limits.largestFilesListed, 2)
        XCTAssertEqual(doc.largestFiles.map(\.logical), [900_000, 400_000])
        XCTAssertTrue(doc.largestFiles.allSatisfy { !$0.isDirectory })
    }

    func testAskingForNoFilesOmitsThem() throws {
        let doc = document({ var o = Export.Options(); o.largestFiles = 0; return o }())
        XCTAssertTrue(doc.largestFiles.isEmpty)
        XCTAssertEqual(doc.limits.largestFilesLimit, 0)
    }

    /// It has to survive the round trip, or it is not an interchange format.
    func testItDecodesBackToWhatWasEncoded() throws {
        let doc = document(Export.Options())
        let data = try Export.encode(doc)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(Export.Document.self, from: data)
        XCTAssertEqual(back.schema, doc.schema)
        XCTAssertEqual(back.totals.logical, doc.totals.logical)
        XCTAssertEqual(back.folders.map(\.path), doc.folders.map(\.path))
        XCTAssertEqual(back.limits.foldersOmitted, doc.limits.foldersOmitted)
    }

    /// Two exports of the same unchanged scan must differ only in the
    /// timestamp, or nothing can diff them.
    func testTheEncodingIsStable() throws {
        let r = scan()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try Export.encode(Export.document(store: r.store, stats: r.stats, now: stamp))
        let b = try Export.encode(Export.document(store: r.store, stats: r.stats, now: stamp))
        XCTAssertEqual(a, b)
    }

    func testCopiesAndSuggestionsAreAbsentUntilAskedFor() throws {
        var doc = document(Export.Options())
        XCTAssertNil(doc.duplicateGroups)
        XCTAssertNil(doc.suggestions)

        let r = scan()
        Export.addSuggestions(to: &doc, store: r.store, suggestions: [])
        XCTAssertEqual(doc.suggestions?.count, 0, "asked for and empty is not the same as absent")
    }

    /// A folder listed in the export is a folder, and its size is the size the
    /// tree has for it — the export must not invent a second opinion.
    func testEntriesAgreeWithTheTree() throws {
        let r = scan()
        let doc = Export.document(store: r.store, stats: r.stats,
                                  options: { var o = Export.Options()
                                             o.folderMinimumBytes = 0; return o }())
        for entry in doc.folders {
            let node = try XCTUnwrap(r.store.find(path: entry.path))
            XCTAssertTrue(entry.isDirectory)
            XCTAssertEqual(entry.physical, r.store.totalPhysical[Int(node)])
            XCTAssertEqual(entry.logical, r.store.totalLogical[Int(node)])
            XCTAssertEqual(entry.items, r.store.children(node).count)
        }
    }
}
