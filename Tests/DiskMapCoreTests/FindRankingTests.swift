import XCTest
@testable import DiskMapCore

/// What comes back, and in what order.
///
/// Searching used to be substring-only and ordered by size alone, so a file
/// whose name *is* what you typed could sit below one that merely contains it
/// and happens to be bigger. And a name you half-remember — typing `rprt` for
/// `report` — found nothing at all.
@MainActor
final class FindRankingTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var store: NodeStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmfind-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func scan() { store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store }

    private func names(_ needle: String, limit: Int = 300) -> [String] {
        Find.search(store: store, needle: needle, limit: limit).items.map {
            URL(fileURLWithPath: $0.path).lastPathComponent
        }
    }

    // MARK: - Order

    /// The exact name first, even when something bigger merely contains it.
    /// Size decides between equals; it does not outrank being the thing asked
    /// for.
    func testTheExactNameOutranksABiggerNameThatContainsIt() throws {
        try write("report", 1_000)
        try write("quarterly-report-final", 900_000)
        scan()

        XCTAssertEqual(names("report").first, "report",
                       "a bigger partial match came above the name that was typed")
    }

    func testAPrefixOutranksAMatchInTheMiddle() throws {
        try write("report-2026.pdf", 1_000)
        try write("old-report.pdf", 900_000)
        scan()

        XCTAssertEqual(names("report").first, "report-2026.pdf")
    }

    /// Within one kind, the biggest is still the one being looked for far more
    /// often than the alphabetically first.
    func testAmongEqualMatchesTheBiggestComesFirst() throws {
        try write("a/notes.txt", 1_000)
        try write("b/notes.txt", 900_000)
        scan()

        let found = Find.search(store: store, needle: "notes.txt", limit: 10).items
        XCTAssertEqual(found.count, 2)
        XCTAssertGreaterThan(found[0].physical, found[1].physical)
    }

    // MARK: - Typing loosely

    func testLettersInOrderFindAName() throws {
        try write("report.pdf", 5_000)
        scan()

        XCTAssertEqual(names("rprt"), ["report.pdf"])
    }

    /// When what you typed matched something, that is the answer. A loose match
    /// is allowed to be a fallback and not a supplement: ranking would keep it
    /// below the real results, but it would still be a row that means nothing.
    func testALooseMatchDoesNotJoinAGoodAnswer() throws {
        try write("report.pdf", 5_000)
        try write("r-e-port-x.txt", 900_000)
        scan()

        let found = Find.search(store: store, needle: "report", limit: 300).items
        XCTAssertEqual(found.map(\.kind), [.prefix],
                       "a loose match joined an answer that already had one")
    }

    /// And a long answer is certainly left alone.
    func testAFullStrictAnswerSkipsTheLoosePass() throws {
        for i in 0..<25 { try write("report\(i).pdf", 1_000) }
        scan()

        let found = Find.search(store: store, needle: "report", limit: 300).items
        XCTAssertEqual(found.count, 25)
        XCTAssertTrue(found.allSatisfy { $0.kind == .prefix })
    }

    /// Without a bound on how far the letters may spread, a short needle
    /// matches almost every name on a disk and the answer means nothing.
    func testLettersScatteredTooFarApartAreNotAMatch() throws {
        try write("a-very-long-name-with-r-and-p-and-t-somewhere-in-it.txt", 5_000)
        scan()

        XCTAssertTrue(names("rpt").isEmpty,
                      "letters spread across a whole sentence counted as a match")
    }

    /// Two characters say nothing loosely: every name has an e before an s.
    func testTwoCharactersDoNotMatchLoosely() throws {
        try write("respectable.txt", 5_000)
        scan()

        XCTAssertTrue(names("es").contains("respectable.txt"), "substring still works")
        XCTAssertTrue(names("ez").isEmpty, "two letters matched loosely")
    }

    // MARK: - What it reports

    /// The list is capped and the count is not, and the caller gets both from
    /// one search rather than running it twice.
    func testTheCountCoversMoreThanTheRowsReturned() throws {
        for i in 0..<40 { try write("note\(i).txt", 1_000) }
        scan()

        let found = Find.search(store: store, needle: "note", limit: 10)
        XCTAssertEqual(found.items.count, 10)
        XCTAssertEqual(found.total, 40)
    }

    /// Path segments still narrow where to look.
    func testAPathNeedleStillNarrowsByFolder() throws {
        try write("keep/notes.txt", 1_000)
        try write("other/notes.txt", 1_000)
        scan()

        XCTAssertEqual(names("keep/notes"), ["notes.txt"])
        XCTAssertEqual(names("notes").count, 2)
    }

    func testShorterThanTwoCharactersFindsNothing() throws {
        try write("a.txt", 1_000)
        scan()
        XCTAssertTrue(names("a").isEmpty)
    }
}
