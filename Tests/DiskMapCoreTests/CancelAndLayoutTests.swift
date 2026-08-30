import XCTest
@testable import DiskMapCore

final class CancellationTests: XCTestCase {
    /// A token set before the scan starts must stop it immediately.
    func testPreCancelledScanReturnsAtOnce() {
        let scanner = DiskScanner()
        scanner.cancelToken.cancel()
        let result = scanner.scan(ScanOptions(rootPath: "/System/Library"))
        XCTAssertTrue(result.stats.cancelled)
        XCTAssertLessThan(result.stats.elapsed, 5)
    }

    /// Cancelling mid-flight must not require waiting out the whole scan.
    func testCancelMidScanStopsPromptly() {
        let scanner = DiskScanner()
        let done = expectation(description: "scan returned")
        var stats: ScanStats?
        DispatchQueue.global().async {
            stats = scanner.scan(ScanOptions(rootPath: "/System/Library")).stats
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        scanner.cancelToken.cancel()
        wait(for: [done], timeout: 20)
        XCTAssertEqual(stats?.cancelled, true)
    }
}

final class TreemapTests: XCTestCase {
    /// Squarify must tile the rectangle exactly, with no gaps or overflow.
    func testSquarifyFillsTheRectangle() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 250)
        let areas = [40_000.0, 25_000, 18_000, 9_000, 5_000, 3_000]
        let total = areas.reduce(0, +)
        let scaled = areas.map { $0 / total * Double(rect.width * rect.height) }
        let rects = Treemap.squarify(areas: scaled, in: rect)

        XCTAssertEqual(rects.count, areas.count)
        let covered = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        XCTAssertEqual(covered, Double(rect.width * rect.height), accuracy: 1.0)
        for r in rects {
            XCTAssertGreaterThanOrEqual(r.minX, rect.minX - 0.001)
            XCTAssertGreaterThanOrEqual(r.minY, rect.minY - 0.001)
            XCTAssertLessThanOrEqual(r.maxX, rect.maxX + 0.001)
            XCTAssertLessThanOrEqual(r.maxY, rect.maxY + 0.001)
        }
    }

    /// A folder of many tiny files must not produce a cell per file: the ones
    /// too small to see collapse into a single labelled remainder.
    func testTinyEntriesCollapseIntoOneTailCell() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmtile-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // The fold is relative: an entry collapses when its share of the
        // rectangle falls below one visible cell. One dominant file plus many
        // small ones is the shape that produces it.
        try Data(count: 40_000_000).write(to: root.appendingPathComponent("big.bin"))
        for i in 0..<300 {
            try Data(count: 512).write(to: root.appendingPathComponent("tiny-\(i).bin"))
        }

        let result = DiskScanner().scan(ScanOptions(rootPath: root.path))
        let cells = Treemap.layout(store: result.store, root: 0,
                                   in: CGRect(x: 0, y: 0, width: 300, height: 200))

        XCTAssertLessThan(cells.count, 60, "tiny files should not each get a cell")
        XCTAssertEqual(cells.filter { $0.aggregatedCount > 0 }.count, 1,
                       "the invisible remainder should be exactly one cell")
        XCTAssertTrue(cells.contains { $0.node >= 0 }, "the large file must still be drawn")
    }

    /// Every child must stay inside its parent's rectangle.
    func testChildCellsStayInsideTheirParent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmnest-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(count: 2_000_000).write(to: root.appendingPathComponent("a/b/deep.bin"))
        try Data(count: 1_000_000).write(to: root.appendingPathComponent("a/mid.bin"))

        let result = DiskScanner().scan(ScanOptions(rootPath: root.path))
        let frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        let cells = Treemap.layout(store: result.store, root: 0, in: frame)
        for c in cells {
            XCTAssertTrue(frame.insetBy(dx: -1, dy: -1).contains(c.rect),
                          "cell \(c.rect) escaped the frame")
        }
    }
}

final class TreemapFilterTests: XCTestCase {
    /// The map and the list describe the same folder, so a filter has to apply
    /// to both or the two panels contradict each other.
    func testFilterAppliesAtTheLevelBeingViewed() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmfilter-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data(count: 3_000_000).write(to: root.appendingPathComponent("keep-me.bin"))
        try Data(count: 3_000_000).write(to: root.appendingPathComponent("other.bin"))

        let store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)

        let all = Treemap.layout(store: store, root: 0, in: frame)
        XCTAssertEqual(all.filter { $0.node >= 0 }.count, 2)

        let filtered = Treemap.layout(store: store, root: 0, in: frame,
                                      includeAtRoot: { store.name($0).contains("keep") })
        let names = filtered.filter { $0.node >= 0 }.map { store.name($0.node) }
        XCTAssertEqual(names, ["keep-me.bin"])
    }
}
