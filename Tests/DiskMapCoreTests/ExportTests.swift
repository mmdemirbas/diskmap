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
