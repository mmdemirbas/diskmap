import CoreGraphics
import XCTest
import DiskMapCore
@testable import DiskMapScan

final class SunburstTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    private func makeStore() throws -> NodeStore {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmsun-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("a/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try Data(count: 600_000).write(to: root.appendingPathComponent("a/deep/one.bin"))
        try Data(count: 300_000).write(to: root.appendingPathComponent("a/two.bin"))
        try Data(count: 100_000).write(to: root.appendingPathComponent("b/three.bin"))
        return DiskScanner().scan(ScanOptions(rootPath: root.path)).store
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private var frame: CGRect { CGRect(x: 0, y: 0, width: 400, height: 400) }

    func testRootDiscIsAtTheCentreAndFullCircle() throws {
        let segments = Sunburst.layout(store: try makeStore(), root: 0, in: frame)
        let hub = try XCTUnwrap(segments.first { $0.depth == 0 })
        XCTAssertEqual(hub.innerRadius, 0)
        XCTAssertEqual(hub.sweep, 2 * .pi, accuracy: 1e-9)
    }

    /// Each ring must account for the whole circle, or the picture lies about
    /// how much of the parent a child occupies.
    func testEachRingCoversTheFullCircle() throws {
        let segments = Sunburst.layout(store: try makeStore(), root: 0, in: frame)
        let firstRing = segments.filter { $0.depth == 1 }
        XCTAssertFalse(firstRing.isEmpty)
        let total = firstRing.reduce(0.0) { $0 + $1.sweep }
        XCTAssertEqual(total, 2 * .pi, accuracy: 1e-6)
    }

    /// Depth is radius: a child ring sits strictly outside its parent's.
    func testDeeperSegmentsSitFurtherOut() throws {
        let segments = Sunburst.layout(store: try makeStore(), root: 0, in: frame)
        for depth in 1..<4 {
            let inner = segments.filter { $0.depth == depth }
            let outer = segments.filter { $0.depth == depth + 1 }
            guard let i = inner.first, let o = outer.first else { continue }
            XCTAssertGreaterThanOrEqual(o.innerRadius, i.outerRadius - 0.001)
        }
    }

    /// A child's arc must lie inside its parent's arc.
    func testChildArcsStayWithinTheirParent() throws {
        let store = try makeStore()
        let segments = Sunburst.layout(store: store, root: 0, in: frame)
        let byNode = Dictionary(segments.filter { $0.node >= 0 }.map { ($0.node, $0) },
                                uniquingKeysWith: { a, _ in a })
        for segment in segments where segment.node > 0 {
            let parent = store.parent[Int(segment.node)]
            guard parent > 0, let parentSegment = byNode[parent] else { continue }
            XCTAssertGreaterThanOrEqual(segment.startAngle, parentSegment.startAngle - 1e-6)
            XCTAssertLessThanOrEqual(segment.endAngle, parentSegment.endAngle + 1e-6)
        }
    }

    func testHitTestFindsTheSegmentUnderAPoint() throws {
        let segments = Sunburst.layout(store: try makeStore(), root: 0, in: frame)
        let centre = CGPoint(x: 200, y: 200)
        let target = try XCTUnwrap(segments.first { $0.depth == 1 && $0.node >= 0 })
        let radius = (target.innerRadius + target.outerRadius) / 2
        let angle = target.midAngle
        let point = CGPoint(x: centre.x + CGFloat(sin(angle) * radius),
                            y: centre.y - CGFloat(cos(angle) * radius))
        XCTAssertEqual(Sunburst.hitTest(segments, point: point, centre: centre)?.node, target.node)
    }

    func testHitTestOutsideTheWheelIsNil() throws {
        let segments = Sunburst.layout(store: try makeStore(), root: 0, in: frame)
        XCTAssertNil(Sunburst.hitTest(segments, point: CGPoint(x: 399, y: 399),
                                      centre: CGPoint(x: 200, y: 200)))
    }
}

final class AggregateTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    private func makeStore() throws -> NodeStore {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmagg-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("media/nested"),
                               withIntermediateDirectories: true)
        try Data(count: 900_000).write(to: root.appendingPathComponent("media/nested/movie.mov"))
        try Data(count: 500_000).write(to: root.appendingPathComponent("media/photo.jpg"))
        try Data(count: 300_000).write(to: root.appendingPathComponent("archive.zip"))
        try Data(count: 10_000).write(to: root.appendingPathComponent("notes.md"))
        return DiskScanner().scan(ScanOptions(rootPath: root.path)).store
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    /// The point of the view: biggest files from anywhere below, not just the
    /// folder you happen to be looking at.
    func testLargestFilesReachIntoSubfolders() throws {
        let store = try makeStore()
        let summary = Aggregate.summarize(store: store, root: 0)
        let names = summary.largestFiles.map { store.name($0) }
        XCTAssertEqual(names, ["movie.mov", "photo.jpg", "archive.zip", "notes.md"])
        XCTAssertEqual(summary.files, 4)
        XCTAssertEqual(summary.directories, 2)
    }

    func testCategoriesAreSummedBySize() throws {
        let store = try makeStore()
        let summary = Aggregate.summarize(store: store, root: 0)
        XCTAssertEqual(summary.byCategory.first?.category, .video)
        let kinds = Set(summary.byCategory.map(\.category))
        XCTAssertEqual(kinds, [.video, .image, .archive, .document])
    }

    func testAgeBucketsAccountForEveryFile() throws {
        let store = try makeStore()
        let summary = Aggregate.summarize(store: store, root: 0)
        XCTAssertEqual(summary.byAge.reduce(0) { $0 + $1.files }, 4)
        // Files were just written, so they land in the newest bucket.
        XCTAssertEqual(summary.byAge.first { $0.bucket == .week }?.files, 4)
    }

    /// The allocation-free classifier must agree with the String one, or the
    /// type report and the treemap colours would disagree.
    func testByteClassifierMatchesTheStringClassifier() {
        for name in ["a.mov", "IMG.JPG", "x.tar.gz", "Info.plist", "noext",
                     "model.safetensors", ".hidden", "weird.", "UPPER.PNG", "a.b.c.mp4"] {
            let bytes = Array(name.utf8)
            let viaBytes = bytes.withUnsafeBufferPointer {
                Categorizer.category(bytes: $0.baseAddress!, length: $0.count, isDirectory: false)
            }
            XCTAssertEqual(viaBytes, Categorizer.of(name: name, isDirectory: false), "for \(name)")
        }
    }
}
