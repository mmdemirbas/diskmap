import XCTest
@testable import DiskMapCore

final class RootSetTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmroots-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("parent/child"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("sibling"),
                               withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func p(_ rel: String) -> String { root.appendingPathComponent(rel).path }

    func testTheSameFolderTwiceIsKeptOnce() {
        let n = RootSet.normalize([p("sibling"), p("sibling")])
        XCTAssertEqual(n.roots.count, 1)
        XCTAssertEqual(n.rejected.count, 1)
        guard case .duplicate = n.rejected[0].reason else {
            return XCTFail("expected duplicate, got \(n.rejected[0].reason)")
        }
    }

    /// The important one: keeping both would count the child's bytes twice.
    func testAFolderInsideAnotherIsDropped() {
        let n = RootSet.normalize([p("parent"), p("parent/child")])
        XCTAssertEqual(n.roots.map { ($0 as NSString).lastPathComponent }, ["parent"])
        guard case .containedIn = n.rejected.first?.reason else {
            return XCTFail("expected containedIn, got \(String(describing: n.rejected.first?.reason))")
        }
    }

    /// Order must not matter: the child may well be listed first.
    func testNestingIsDetectedWhicheverOrderTheyArriveIn() {
        let n = RootSet.normalize([p("parent/child"), p("parent")])
        XCTAssertEqual(n.roots.map { ($0 as NSString).lastPathComponent }, ["parent"])
    }

    func testUnrelatedFoldersAreBothKept() {
        let n = RootSet.normalize([p("parent"), p("sibling")])
        XCTAssertEqual(n.roots.count, 2)
        XCTAssertTrue(n.rejected.isEmpty)
    }

    func testMissingAndNonFolderTargetsAreReported() throws {
        let file = root.appendingPathComponent("a-file.txt")
        try Data(count: 10).write(to: file)
        let n = RootSet.normalize([p("nope"), file.path, p("sibling")])
        XCTAssertEqual(n.roots.count, 1)
        XCTAssertEqual(Set(n.rejected.map(\.reason)), [.missing, .notADirectory])
    }

    /// A path is only "inside" another if the scan would actually reach it.
    func testSymlinkedDuplicateResolvesToTheSameFolder() throws {
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"),
                                  withDestinationURL: root.appendingPathComponent("sibling"))
        let n = RootSet.normalize([p("sibling"), p("link")])
        XCTAssertEqual(n.roots.count, 1, "a symlink to a chosen folder is the same folder")
    }
}

final class MultiRootScanTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmmulti-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("alpha/deep"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("beta"),
                               withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: root.appendingPathComponent("alpha/one.bin"))
        try Data(count: 250_000).write(to: root.appendingPathComponent("alpha/deep/two.bin"))
        try Data(count: 400_000).write(to: root.appendingPathComponent("beta/three.bin"))
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func p(_ rel: String) -> String { root.appendingPathComponent(rel).path }

    func testTwoFoldersAddUpToOneTotal() {
        let result = DiskScanner().scan(ScanOptions(roots: [p("alpha"), p("beta")]))
        XCTAssertTrue(result.isMultiRoot)
        XCTAssertEqual(result.roots.count, 2)
        XCTAssertEqual(result.store.totalLogical[0], 750_000)
        XCTAssertEqual(result.stats.files, 3)
        // The two roots are the children of the synthetic node.
        XCTAssertEqual(result.store.children(0).count, 2)
    }

    func testPathsResolveBothWaysAcrossRoots() throws {
        let result = DiskScanner().scan(ScanOptions(roots: [p("alpha"), p("beta")]))
        let store = result.store
        let wanted = try XCTUnwrap(canonicalPath(p("alpha/deep/two.bin")))

        let node = try XCTUnwrap(store.find(path: wanted), "should find a file under the first root")
        XCTAssertEqual(store.path(node), wanted)
        XCTAssertEqual(store.totalLogical[Int(node)], 250_000)

        let other = try XCTUnwrap(canonicalPath(p("beta/three.bin")))
        let otherNode = try XCTUnwrap(store.find(path: other), "should find a file under the second root")
        XCTAssertEqual(store.path(otherNode), other)
    }

    /// Choosing a folder and its parent must not double-count the child.
    func testNestedSelectionIsNotCountedTwice() {
        let both = DiskScanner().scan(ScanOptions(roots: [p("alpha"), p("alpha/deep")]))
        let alone = DiskScanner().scan(ScanOptions(rootPath: p("alpha")))
        XCTAssertFalse(both.isMultiRoot, "the nested folder should have been dropped")
        XCTAssertEqual(both.store.totalLogical[0], alone.store.totalLogical[0])
        XCTAssertEqual(both.rejectedRoots.count, 1)
    }

    func testHardLinkAcrossTwoRootsCountsOnce() throws {
        let original = root.appendingPathComponent("alpha/shared.bin")
        try Data(count: 500_000).write(to: original)
        try fm.linkItem(at: original, to: root.appendingPathComponent("beta/shared-link.bin"))

        let result = DiskScanner().scan(ScanOptions(roots: [p("alpha"), p("beta")]))
        XCTAssertEqual(result.stats.hardlinkDuplicates, 1,
                       "the second link is in a different root but the same inode")
        XCTAssertLessThan(result.store.totalPhysical[0], 1_300_000)
    }

    func testLiveUpdateReachesTheSyntheticRoot() throws {
        let live = LiveTree(result: DiskScanner().scan(ScanOptions(roots: [p("alpha"), p("beta")])))
        let before = live.withStore { $0.totalLogical[0] }
        try Data(count: 60_000).write(to: root.appendingPathComponent("beta/extra.bin"))
        live.refresh(directory: p("beta"))
        XCTAssertEqual(live.withStore { $0.totalLogical[0] } - before, 60_000)
    }

    func testEmptySelectionIsNotAScan() {
        let result = DiskScanner().scan(ScanOptions(roots: []))
        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertEqual(result.store.count, 0)
    }
}

final class AbbreviationTests: XCTestCase {
    func testRootPathsAreShortenedButStillDistinguishable() {
        XCTAssertEqual(abbreviatedName("/Users/md/dev/atolye"), "…/dev/atolye")
        XCTAssertEqual(abbreviatedName("/Users/md/dev/diskmap"), "…/dev/diskmap")
        // Two folders with the same leaf name stay distinct.
        XCTAssertNotEqual(abbreviatedName("/a/one/Documents"), abbreviatedName("/a/two/Documents"))
    }

    func testOrdinaryNamesAreUntouched() {
        XCTAssertEqual(abbreviatedName("Movies"), "Movies")
        XCTAssertEqual(abbreviatedName("file.txt"), "file.txt")
        XCTAssertEqual(abbreviatedName("/"), "/")
    }
}
