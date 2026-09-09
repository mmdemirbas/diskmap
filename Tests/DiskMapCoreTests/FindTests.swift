import XCTest
import DiskMapCore
@testable import DiskMapScan

/// Locating one thing in a tree, which is a different question from filtering
/// the folder you happen to be looking at.
final class FindTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmfind-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("Projects/Report"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Archive/report-2019"),
                               withIntermediateDirectories: true)
        try Data(count: 900_000).write(to: root.appendingPathComponent("Projects/Report/final.pdf"))
        try Data(count: 40_000).write(to: root.appendingPathComponent("Archive/report-2019/notes.txt"))
        try Data(count: 10_000).write(to: root.appendingPathComponent("Projects/README.md"))
        try Data(count: 5_000).write(to: root.appendingPathComponent("Şirket-Raporu.txt"))
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func store() -> NodeStore {
        DiskScanner().scan(ScanOptions(rootPath: root.path)).store
    }

    private func names(_ items: [FoundItem]) -> [String] {
        items.map { ($0.path as NSString).lastPathComponent }
    }

    func testItMatchesAnywhereInTheNameAndIgnoresCase() throws {
        let found = Find.search(store: store(), needle: "report").items
        XCTAssertEqual(Set(names(found)), ["Report", "report-2019"])
    }

    /// Biggest first *within a kind of match*. Size used to be the only key,
    /// which put a big partial match above the name that was actually typed;
    /// it now decides between equals rather than outranking being the answer.
    func testResultsAreBiggestFirstWithinAKind() throws {
        let found = Find.search(store: store(), needle: "re").items
        XCTAssertGreaterThan(found.count, 2, "too few matches for the order to mean anything")
        XCTAssertEqual(found.map(\.kind), found.map(\.kind).sorted(),
                       "a worse kind of match came above a better one")
        for run in Dictionary(grouping: found, by: \.kind).values {
            let sizes = run.map(\.physical)
            XCTAssertEqual(sizes, sizes.sorted(by: >))
        }
    }

    /// A needle with a separator names a path: the last segment is the thing
    /// being looked for, the ones before it say where to look. So this finds
    /// the folder, not the five hundred files inside it.
    func testASlashNarrowsByAncestor() throws {
        let found = Find.search(store: store(), needle: "Archive/report").items
        XCTAssertEqual(names(found), ["report-2019"])

        // The same leaf without the ancestor matches both.
        XCTAssertEqual(Set(names(Find.search(store: store(), needle: "report").items)),
                       ["Report", "report-2019"])
    }

    /// The segments need not be adjacent. People remember roughly where a
    /// thing lives, not the exact chain of folders above it.
    func testAncestorSegmentsNeedNotBeAdjacent() throws {
        let found = Find.search(store: store(), needle: "Projects/final").items
        XCTAssertEqual(names(found), ["final.pdf"], "final.pdf is two levels under Projects")
    }

    /// And they have to be in order, or the constraint means nothing.
    func testAncestorSegmentsMustBeInOrder() throws {
        XCTAssertTrue(Find.search(store: store(), needle: "Report/Projects").items.isEmpty)
    }

    /// The fast path folds ASCII case by hand; a needle that is not ASCII has
    /// to take the slower path rather than quietly failing to match.
    func testANonAsciiNeedleStillMatches() throws {
        let found = Find.search(store: store(), needle: "raporu").items
        XCTAssertEqual(names(found), ["Şirket-Raporu.txt"])
    }

    func testAShortNeedleFindsNothingRatherThanEverything() throws {
        XCTAssertTrue(Find.search(store: store(), needle: "r").items.isEmpty)
        XCTAssertTrue(Find.search(store: store(), needle: " ").items.isEmpty)
        XCTAssertTrue(Find.search(store: store(), needle: "").items.isEmpty)
    }

    func testTheLimitCapsTheListWithoutHidingTheCount() throws {
        let s = store()
        let all = Find.search(store: s, needle: "re", limit: .max)
        let capped = Find.search(store: s, needle: "re", limit: 1)
        XCTAssertEqual(capped.items.count, 1)
        XCTAssertGreaterThan(all.total, 1)
        XCTAssertEqual(capped.total, all.total, "the cap must not change the count")
        XCTAssertEqual(capped.items.first, all.items.first,
                       "the cap must keep the best match, not any one")
    }

    /// A trashed item is gone from the tree and must not come back in a search.
    func testRemovedNodesAreNotFound() throws {
        let result = DiskScanner().scan(ScanOptions(rootPath: root.path))
        let tree = LiveTree(result: result)
        let node = try XCTUnwrap(tree.withStore {
            $0.find(path: root.appendingPathComponent("Projects/README.md").path)
        })
        tree.markRemoved(node)
        let found = tree.withStore { Find.search(store: $0, needle: "readme") }
        XCTAssertTrue(found.items.isEmpty)
    }

    func testItFindsFoldersAndFilesAlike() throws {
        let found = Find.search(store: store(), needle: "Report").items
        XCTAssertTrue(found.contains { $0.isDirectory })
        let pdf = Find.search(store: store(), needle: "final").items
        XCTAssertEqual(pdf.count, 1)
        XCTAssertFalse(pdf[0].isDirectory)
        XCTAssertEqual(pdf[0].logical, 900_000)
    }
}
