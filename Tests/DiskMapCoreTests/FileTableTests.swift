import XCTest
@testable import DiskMapCore

/// The flat table: every file at once, ordered by whichever property is being
/// asked about, without walking down to any of them.
///
/// The tree table answers "what is inside this folder". This answers "show me
/// everything, biggest first" — and "only videos", and "only what I have not
/// touched since 2023" — which are the questions people open a disk analyser
/// with and previously had to reach by navigating.
@MainActor
final class FileTableTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var store: NodeStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmtable-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int, modified: Date? = nil) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        if let modified {
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func scan() { store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store }

    private func names(_ page: FileTablePage) -> [String] { page.rows.map(\.name) }

    private func page(sort: FileSort = .size, ascending: Bool = false,
                      filter: FileFilter = FileFilter(), limit: Int = 1_000) -> FileTablePage {
        FileTable.page(store: store, filter: filter, sort: sort,
                       ascending: ascending, limit: limit)
    }

    // MARK: - Flat

    /// The point of the screen: depth stops mattering.
    func testEveryFileAppearsWhateverItsDepth() throws {
        try write("top.txt", 1_000)
        try write("a/one.txt", 1_000)
        try write("a/b/c/deep.txt", 1_000)
        scan()

        XCTAssertEqual(Set(names(page())), ["top.txt", "one.txt", "deep.txt"])
    }

    func testFoldersAreNotRowsUntilAskedFor() throws {
        try write("a/b/one.txt", 1_000)
        scan()

        XCTAssertEqual(page().rows.filter(\.isDirectory).count, 0)

        var filter = FileFilter()
        filter.includeFolders = true
        XCTAssertEqual(Set(names(page(filter: filter))), ["a", "b", "one.txt"])
    }

    /// A flat list of eleven `config.json` says nothing without this.
    func testARowSaysWhereItLives() throws {
        try write("a/b/config.json", 1_000)
        scan()

        // Checked against the filesystem rather than against the path that was
        // written: a scan resolves its root, so the row correctly says
        // `/private/var/...` where the test said `/var/...`. What has to be
        // true is that the row names the file's real place.
        let row = try XCTUnwrap(page().rows.first)
        XCTAssertTrue(row.folder.hasSuffix("/a/b"), "got \(row.folder)")
        XCTAssertEqual(row.path, row.folder + "/config.json")
        XCTAssertTrue(fm.fileExists(atPath: row.path), "the row points somewhere there is no file")
    }

    // MARK: - Order

    func testBiggestFirstByDefaultAndSmallestWhenReversed() throws {
        try write("small.txt", 1_000)
        try write("big.txt", 900_000)
        scan()

        XCTAssertEqual(names(page()), ["big.txt", "small.txt"])
        XCTAssertEqual(names(page(ascending: true)), ["small.txt", "big.txt"])
    }

    /// The walk orders by the first eight bytes of a name, which is a key and
    /// not an answer. Names that agree that far have to come out in the right
    /// order anyway, and size must not be what decides it.
    func testNamesThatShareTheirFirstEightBytesStillSortProperly() throws {
        try write("aaaaaaaa-zzz.txt", 900_000)
        try write("aaaaaaaa-aaa.txt", 1_000)
        scan()

        XCTAssertEqual(names(page(sort: .name, ascending: true)),
                       ["aaaaaaaa-aaa.txt", "aaaaaaaa-zzz.txt"])
    }

    /// Sorting by name is how a person reads a list, so `file2` belongs before
    /// `file10` the way the Finder puts it.
    func testNamesSortTheWayTheFinderSortsThem() throws {
        try write("file10.txt", 1_000)
        try write("file2.txt", 1_000)
        scan()

        XCTAssertEqual(names(page(sort: .name, ascending: true)), ["file2.txt", "file10.txt"])
    }

    func testNewestFirstWhenSortingByDate() throws {
        try write("old.txt", 1_000, modified: Date(timeIntervalSince1970: 1_000_000))
        try write("new.txt", 1_000, modified: Date(timeIntervalSince1970: 1_700_000_000))
        scan()

        XCTAssertEqual(names(page(sort: .modified)), ["new.txt", "old.txt"])
        XCTAssertEqual(names(page(sort: .modified, ascending: true)), ["old.txt", "new.txt"])
    }

    /// Ordering by kind with a capped list is meaningless unless the biggest of
    /// each kind is what survives the cap.
    func testWithinOneKindTheBiggestIsKept() throws {
        try write("tiny.mp4", 1_000)
        try write("middling.mp4", 500_000)
        try write("huge.mp4", 900_000)
        try write("notes.txt", 900_000)
        scan()

        // Video sorts ahead of document, so a page of two is the two biggest
        // videos and not whichever two the walk happened to reach first.
        let rows = page(sort: .kind, ascending: true, limit: 2).rows
        XCTAssertEqual(rows.map(\.name), ["huge.mp4", "middling.mp4"],
                       "the cap kept an arbitrary member of a kind instead of the biggest")
    }

    // MARK: - What the footer may claim

    func testTheCapLimitsTheRowsAndNotTheCount() throws {
        for i in 0..<40 { try write("note\(i).txt", 1_000) }
        scan()

        let found = page(limit: 10)
        XCTAssertEqual(found.rows.count, 10)
        XCTAssertEqual(found.total, 40)
        XCTAssertGreaterThan(found.totalPhysical, found.rows.reduce(0) { $0 + $1.physical },
                             "the total only counted the rows that fit on screen")
    }

    /// A folder's size is its whole subtree, so counting folders into the byte
    /// total adds the same bytes once per level and the footer ends up claiming
    /// a disk several times its own size.
    func testTurningFoldersOnDoesNotInflateTheTotalBytes() throws {
        try write("a/b/one.txt", 900_000)
        scan()

        let filesOnly = page()
        var filter = FileFilter()
        filter.includeFolders = true
        let withFolders = page(filter: filter)

        XCTAssertEqual(withFolders.totalPhysical, filesOnly.totalPhysical)
        XCTAssertGreaterThan(withFolders.total, filesOnly.total)
    }

    /// The live tree marks a node removed rather than compacting the arrays, so
    /// a table that did not skip those would keep showing files that have been
    /// deleted since the scan — on the one screen whose rows lead to the Trash.
    func testSomethingDeletedSinceTheScanIsNotARow() throws {
        try write("staying.txt", 1_000)
        try write("going.txt", 1_000)
        let tree = LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path)))
        store = tree.withStore { $0 }
        let doomed = try XCTUnwrap(tree.withStore { $0.find(path: root.appendingPathComponent("going.txt").path) })

        XCTAssertEqual(Set(names(page())), ["staying.txt", "going.txt"])
        tree.markRemoved(doomed)
        XCTAssertEqual(names(page()), ["staying.txt"])
        XCTAssertEqual(page().total, 1)
    }

    // MARK: - Filters

    func testFilterBySizeWindow() throws {
        try write("small.txt", 1_000)
        try write("medium.txt", 200_000)
        try write("large.txt", 900_000)
        scan()

        var filter = FileFilter()
        filter.minBytes = 100_000
        XCTAssertEqual(Set(names(page(filter: filter))), ["medium.txt", "large.txt"])

        filter.maxBytes = 500_000
        XCTAssertEqual(names(page(filter: filter)), ["medium.txt"])
    }

    func testFilterByKind() throws {
        try write("clip.mp4", 1_000)
        try write("shot.png", 1_000)
        try write("notes.txt", 1_000)
        scan()

        var filter = FileFilter()
        filter.categories = [.video, .image]
        XCTAssertEqual(Set(names(page(filter: filter))), ["clip.mp4", "shot.png"])
    }

    func testFilterByDateWindow() throws {
        try write("ancient.txt", 1_000, modified: Date(timeIntervalSince1970: 1_000_000))
        try write("recent.txt", 1_000, modified: Date(timeIntervalSince1970: 1_700_000_000))
        scan()

        var filter = FileFilter()
        filter.modifiedBefore = 1_500_000_000
        XCTAssertEqual(names(page(filter: filter)), ["ancient.txt"])

        filter = FileFilter()
        filter.modifiedAfter = 1_500_000_000
        XCTAssertEqual(names(page(filter: filter)), ["recent.txt"])
    }

    func testFilterByNameIgnoresCase() throws {
        try write("Report.pdf", 1_000)
        try write("notes.txt", 1_000)
        scan()

        var filter = FileFilter()
        filter.text = "report"
        XCTAssertEqual(names(page(filter: filter)), ["Report.pdf"])
    }

    /// Names outside ASCII fold by the language's rules rather than by adding
    /// 32 to a byte, and the table must not quietly stop finding them.
    func testFilterByNameWorksBeyondAscii() throws {
        try write("Ödevler.txt", 1_000)
        scan()

        var filter = FileFilter()
        filter.text = "ödev"
        XCTAssertEqual(names(page(filter: filter)), ["Ödevler.txt"])
    }

    func testFiltersCombine() throws {
        try write("big.mp4", 900_000)
        try write("small.mp4", 1_000)
        try write("big.txt", 900_000)
        scan()

        var filter = FileFilter()
        filter.categories = [.video]
        filter.minBytes = 100_000
        XCTAssertEqual(names(page(filter: filter)), ["big.mp4"])
    }

    /// Empty answers and unfiltered answers are different answers.
    func testAFilterThatMatchesNothingSaysSo() throws {
        try write("notes.txt", 1_000)
        scan()

        var filter = FileFilter()
        filter.text = "nothing-like-this"
        let found = page(filter: filter)
        XCTAssertTrue(found.rows.isEmpty)
        XCTAssertEqual(found.total, 0)
        XCTAssertEqual(found.totalPhysical, 0)
    }
}
