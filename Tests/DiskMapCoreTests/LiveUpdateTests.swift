import XCTest
@testable import DiskMapCore

/// Regressions from the live-update path, where a relist re-points untouched
/// subtrees at freshly appended parents.
final class LiveUpdateTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("dmlive-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func tree() -> LiveTree {
        LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path)))
    }

    private func signature(_ tree: LiveTree, _ path: String) -> UInt64 {
        tree.withStore { store in
            guard let node = store.find(path: root.appendingPathComponent(path).path) else { return 0 }
            return FolderMatches.signatures(store)[Int(node)]
        }
    }

    /// After a relist, a reattached folder's children sit at a LOWER index than
    /// the folder itself. Hashing by descending index therefore hashed parents
    /// before their children, and every reattached folder with the same number
    /// of children came out with the same hash — a flood of "identical" folders
    /// that hold completely different things.
    func testFolderHashesSurviveARelist() throws {
        try write("a/x.bin", 10_000)
        try write("a/y.bin", 20_000)
        try write("b/p.bin", 30_000)
        try write("b/q.bin", 40_000)

        let tree = tree()
        let beforeA = signature(tree, "a"), beforeB = signature(tree, "b")
        XCTAssertNotEqual(beforeA, 0)
        XCTAssertNotEqual(beforeA, beforeB)

        // A new name in the folder forces the append path, which is what
        // re-points a/ and b/ at new nodes.
        try write("newcomer.bin", 5_000)
        XCTAssertTrue(tree.refresh(directory: root.path))

        XCTAssertEqual(signature(tree, "a"), beforeA)
        XCTAssertEqual(signature(tree, "b"), beforeB)
        XCTAssertNotEqual(signature(tree, "a"), signature(tree, "b"))
    }

    /// The same defect seen from the outside: two folders holding different
    /// things must not be reported as copies of each other after a relist.
    func testDifferentFoldersAreNotCopiesAfterARelist() throws {
        try write("a/x.bin", 10_000)
        try write("a/y.bin", 20_000)
        try write("b/p.bin", 30_000)
        try write("b/q.bin", 40_000)

        let tree = tree()
        try write("newcomer.bin", 5_000)
        tree.refresh(directory: root.path)

        let matches = tree.withStore { FolderMatches.find(store: $0, root: 0, minimumSize: 1_000) }
        XCTAssertTrue(matches.isEmpty, "reported \(matches.count) bogus folder matches")
    }

    /// A file changing size is the most common event there is. Appending a new
    /// row for every entry each time grew the store without bound over a
    /// working day, since the old rows are only marked removed.
    func testAFileChangingSizeDoesNotGrowTheStore() throws {
        try write("logs/output.log", 4_000)
        try write("logs/other.log", 4_000)
        let tree = tree()
        let before = tree.withStore { $0.count }

        for size in [8_000, 16_000, 32_000] {
            try write("logs/output.log", size)
            XCTAssertTrue(tree.refresh(directory: root.appendingPathComponent("logs").path))
        }

        XCTAssertEqual(tree.withStore { $0.count }, before)
        let totals = tree.withStore { store -> (Int64, Int64) in
            let node = store.find(path: root.appendingPathComponent("logs").path)!
            return (store.totalLogical[Int(node)], store.totalLogical[0])
        }
        XCTAssertEqual(totals.0, 36_000)
        // The change has to reach the ancestors, not just the folder itself.
        XCTAssertEqual(totals.1, 36_000)
    }

    /// An unchanged folder is not a change, however often the event arrives.
    func testRelistingAnUnchangedFolderReportsNoChange() throws {
        try write("stuff/a.bin", 4_000)
        let tree = tree()
        XCTAssertFalse(tree.refresh(directory: root.appendingPathComponent("stuff").path))
        XCTAssertFalse(tree.refresh(directory: root.path))
    }

    func testVerifyingNothingIsNotACrash() throws {
        let store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        let plan = DeepVerify.plan(store: store, nodes: [])
        XCTAssertEqual(plan.files, 0)
        let outcome = DeepVerify.run(plan)
        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertFalse(outcome.identical)
    }
}

extension LiveUpdateTests {
    /// Caches keyed on the tree must see a change when the tree changes, and
    /// must not see one when it does not.
    func testChangeCountTracksTheTreeOnly() throws {
        try write("dir/a.bin", 4_000)
        let tree = tree()
        let start = tree.changeCount

        XCTAssertFalse(tree.refresh(directory: root.appendingPathComponent("dir").path))
        XCTAssertEqual(tree.changeCount, start, "an unchanged folder is not a change")

        try write("dir/a.bin", 9_000)
        tree.refresh(directory: root.appendingPathComponent("dir").path)
        XCTAssertEqual(tree.changeCount, start + 1, "a resize is a change")

        try write("dir/b.bin", 4_000)
        tree.refresh(directory: root.appendingPathComponent("dir").path)
        XCTAssertEqual(tree.changeCount, start + 2, "a new file is a change")

        let node = tree.withStore { $0.find(path: root.appendingPathComponent("dir/b.bin").path)! }
        tree.markRemoved(node)
        XCTAssertEqual(tree.changeCount, start + 3, "a trashed item is a change")
    }
}
