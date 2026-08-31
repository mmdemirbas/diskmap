import CoreGraphics
import XCTest
@testable import DiskMapCore

final class IcicleTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    private func makeStore() throws -> NodeStore {
        root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("dmice-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("a/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try Data(count: 600_000).write(to: root.appendingPathComponent("a/deep/one.bin"))
        try Data(count: 300_000).write(to: root.appendingPathComponent("a/two.bin"))
        try Data(count: 100_000).write(to: root.appendingPathComponent("b/three.bin"))
        return DiskScanner().scan(ScanOptions(rootPath: root.path)).store
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private var frame: CGRect { CGRect(x: 0, y: 0, width: 600, height: 300) }

    func testRootSpansTheFullWidthOnTheTopRow() throws {
        let cells = Icicle.layout(store: try makeStore(), root: 0, in: frame)
        let head = try XCTUnwrap(cells.first { $0.depth == 0 })
        XCTAssertEqual(head.rect.minX, frame.minX)
        XCTAssertEqual(head.rect.width, frame.width, accuracy: 1e-9)
        XCTAssertEqual(head.rect.minY, frame.minY)
    }

    /// A row must account for the whole parent, or the picture understates how
    /// much of it a child takes.
    func testEachRowCoversItsParentsWidth() throws {
        let store = try makeStore()
        let cells = Icicle.layout(store: store, root: 0, in: frame)
        let firstRow = cells.filter { $0.depth == 1 }
        XCTAssertFalse(firstRow.isEmpty)
        let covered = firstRow.reduce(0.0) { $0 + $1.rect.width }
        XCTAssertEqual(covered, frame.width, accuracy: 0.5)
    }

    func testDeeperCellsSitLowerByExactlyOneRow() throws {
        let cells = Icicle.layout(store: try makeStore(), root: 0, in: frame)
        for cell in cells {
            XCTAssertEqual(cell.rect.minY,
                           frame.minY + CGFloat(cell.depth) * Icicle.rowHeight, accuracy: 1e-9)
            XCTAssertEqual(cell.rect.height, Icicle.rowHeight, accuracy: 1e-9)
        }
    }

    func testChildrenStayInsideTheirParentsSpan() throws {
        let store = try makeStore()
        let cells = Icicle.layout(store: store, root: 0, in: frame)
        let byNode = Dictionary(cells.filter { $0.node >= 0 }.map { ($0.node, $0) },
                                uniquingKeysWith: { a, _ in a })
        for cell in cells where cell.node > 0 {
            let parent = store.parent[Int(cell.node)]
            guard parent >= 0, let box = byNode[parent] else { continue }
            XCTAssertGreaterThanOrEqual(cell.rect.minX, box.rect.minX - 0.5)
            XCTAssertLessThanOrEqual(cell.rect.maxX, box.rect.maxX + 0.5)
        }
    }

    /// A bigger sibling must be drawn wider; that is the whole claim the view makes.
    func testWidthFollowsSize() throws {
        let store = try makeStore()
        let cells = Icicle.layout(store: store, root: 0, in: frame)
        let firstRow = cells.filter { $0.depth == 1 && $0.node >= 0 }
        for (left, right) in zip(firstRow, firstRow.dropFirst()) {
            if store.totalPhysical[Int(left.node)] > store.totalPhysical[Int(right.node)] {
                XCTAssertGreaterThanOrEqual(left.rect.width, right.rect.width - 0.5)
            }
        }
    }

    /// Depth is bounded by the window, not by a constant, so a short view must
    /// draw fewer rows rather than overflowing.
    func testDepthIsLimitedByAvailableHeight() throws {
        let store = try makeStore()
        let short = Icicle.layout(store: store, root: 0,
                                  in: CGRect(x: 0, y: 0, width: 600, height: Icicle.rowHeight * 2))
        XCTAssertLessThanOrEqual(short.map(\.depth).max() ?? 0, 1)
        let tall = Icicle.layout(store: store, root: 0, in: frame)
        XCTAssertGreaterThan(tall.map(\.depth).max() ?? 0, 1)
    }

    func testHitTestFindsTheCellUnderThePoint() throws {
        let cells = Icicle.layout(store: try makeStore(), root: 0, in: frame)
        let target = try XCTUnwrap(cells.first { $0.depth == 1 && $0.rect.width > 20 })
        let hit = Icicle.hitTest(cells, point: CGPoint(x: target.rect.midX, y: target.rect.midY))
        XCTAssertEqual(hit?.node, target.node)
        XCTAssertNil(Icicle.hitTest(cells, point: CGPoint(x: 300, y: frame.maxY + 40)))
    }
}

final class DuplicateTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("dmdup-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("one"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("two"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func scan() -> NodeStore { DiskScanner().scan(ScanOptions(rootPath: root.path)).store }

    private func write(_ path: String, _ bytes: Int) throws {
        try Data(count: bytes).write(to: root.appendingPathComponent(path))
    }

    func testSameNameAndSizeInDifferentFoldersIsAGroup() throws {
        try write("one/video.mov", 4_000_000)
        try write("two/video.mov", 4_000_000)
        let groups = Duplicates.find(store: scan(), root: 0)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "video.mov")
        XCTAssertEqual(groups[0].nodes.count, 2)
        // Two copies of one file: keeping one frees the other, not both.
        XCTAssertEqual(groups[0].reclaimable, groups[0].bytes)
    }

    func testSameNameDifferentSizeIsNotAGroup() throws {
        try write("one/notes.pdf", 4_000_000)
        try write("two/notes.pdf", 4_000_001)
        XCTAssertTrue(Duplicates.find(store: scan(), root: 0).isEmpty)
    }

    func testSameSizeDifferentNameIsNotAGroup() throws {
        try write("one/a.bin", 4_000_000)
        try write("two/b.bin", 4_000_000)
        XCTAssertTrue(Duplicates.find(store: scan(), root: 0).isEmpty)
    }

    func testFilesBelowTheThresholdAreIgnored() throws {
        try write("one/small.txt", 4_096)
        try write("two/small.txt", 4_096)
        XCTAssertTrue(Duplicates.find(store: scan(), root: 0).isEmpty)
        XCTAssertEqual(Duplicates.find(store: scan(), root: 0, minimumSize: 1_000).count, 1)
    }

    /// A hard link is one set of bytes under two names, so deleting one frees
    /// nothing. Listing it would promise space that does not exist.
    func testHardLinksAreNotReportedAsDuplicates() throws {
        try write("one/linked.bin", 4_000_000)
        try fm.linkItem(at: root.appendingPathComponent("one/linked.bin"),
                        to: root.appendingPathComponent("two/linked.bin"))
        XCTAssertTrue(Duplicates.find(store: scan(), root: 0).isEmpty)
    }

    func testGroupsAreOrderedByWhatTheyWouldFree() throws {
        try write("one/big.bin", 8_000_000)
        try write("two/big.bin", 8_000_000)
        try write("one/small.bin", 2_000_000)
        try write("two/small.bin", 2_000_000)
        let groups = Duplicates.find(store: scan(), root: 0)
        XCTAssertEqual(groups.map(\.name), ["big.bin", "small.bin"])
    }

    func testThreeCopiesFreeTwoOfThem() throws {
        try fm.createDirectory(at: root.appendingPathComponent("three"), withIntermediateDirectories: true)
        for dir in ["one", "two", "three"] { try write("\(dir)/img.png", 3_000_000) }
        let group = try XCTUnwrap(Duplicates.find(store: scan(), root: 0).first)
        XCTAssertEqual(group.nodes.count, 3)
        XCTAssertEqual(group.reclaimable, group.bytes * 2)
    }

    /// The search is scoped to the folder on screen, not the whole scan.
    func testSearchIsScopedToTheGivenSubtree() throws {
        try write("one/dup.bin", 4_000_000)
        try write("two/dup.bin", 4_000_000)
        let store = scan()
        let one = try XCTUnwrap(store.find(path: root.appendingPathComponent("one").path))
        XCTAssertTrue(Duplicates.find(store: store, root: one).isEmpty)
        XCTAssertEqual(Duplicates.find(store: store, root: 0).count, 1)
    }
}
