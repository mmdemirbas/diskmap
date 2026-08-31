import DiskMapCore
import XCTest
@testable import DiskMapApp

@MainActor
final class TreeTableTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    private func makeModel() throws -> AppModel {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmtree-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("big/inner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("small"), withIntermediateDirectories: true)
        try Data(count: 900_000).write(to: root.appendingPathComponent("big/one.bin"))
        try Data(count: 400_000).write(to: root.appendingPathComponent("big/inner/two.bin"))
        try Data(count: 10_000).write(to: root.appendingPathComponent("small/three.bin"))

        let model = AppModel()
        model.adopt(LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path))))
        return model
    }

    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    /// A closed tree lists only direct children, largest first.
    func testCollapsedListsDirectChildrenBySize() throws {
        let model = try makeModel()
        XCTAssertEqual(model.rows.map(\.name), ["big", "small"])
        XCTAssertTrue(model.rows.allSatisfy { $0.depth == 0 })
        XCTAssertTrue(model.rows[0].hasChildren)
    }

    /// Opening a folder inserts its children beneath it without navigating.
    func testExpandingInsertsChildrenInPlace() throws {
        let model = try makeModel()
        let big = try XCTUnwrap(model.rows.first { $0.name == "big" })
        let directoryBefore = model.currentDirectory

        model.toggleExpanded(big.id)

        XCTAssertEqual(model.currentDirectory, directoryBefore, "expanding must not navigate")
        XCTAssertEqual(model.rows.map(\.name), ["big", "one.bin", "inner", "small"])
        XCTAssertEqual(model.rows.map(\.depth), [0, 1, 1, 0])
        XCTAssertTrue(model.rows[0].isExpanded)
    }

    /// Closing a folder also closes what was open inside it.
    func testCollapsingClosesDescendants() throws {
        let model = try makeModel()
        let big = try XCTUnwrap(model.rows.first { $0.name == "big" })
        model.toggleExpanded(big.id)
        let inner = try XCTUnwrap(model.rows.first { $0.name == "inner" })
        model.toggleExpanded(inner.id)
        XCTAssertEqual(model.rows.count, 5)

        model.toggleExpanded(big.id)
        XCTAssertEqual(model.rows.map(\.name), ["big", "small"])

        model.toggleExpanded(big.id)
        XCTAssertEqual(model.rows.map(\.name), ["big", "one.bin", "inner", "small"],
                       "reopening must not restore the deeper level")
    }

    func testBackAndForwardRetraceNavigation() throws {
        let model = try makeModel()
        let start = model.currentDirectory
        let big = try XCTUnwrap(model.rows.first { $0.name == "big" })

        XCTAssertFalse(model.canGoBack)
        model.enter(big.id)
        XCTAssertEqual(model.currentDirectory, big.id)
        XCTAssertTrue(model.canGoBack)

        model.goBack()
        XCTAssertEqual(model.currentDirectory, start)
        XCTAssertTrue(model.canGoForward)

        model.goForward()
        XCTAssertEqual(model.currentDirectory, big.id)
    }

    /// Going up records history too, so Back returns to where you were.
    func testGoUpIsUndoneByBack() throws {
        let model = try makeModel()
        let big = try XCTUnwrap(model.rows.first { $0.name == "big" })
        model.enter(big.id)
        model.goUp()
        XCTAssertEqual(model.breadcrumb.count, 1)
        model.goBack()
        XCTAssertEqual(model.currentDirectory, big.id)
    }

    func testBreadcrumbReachesEveryAncestor() throws {
        let model = try makeModel()
        let big = try XCTUnwrap(model.rows.first { $0.name == "big" })
        model.enter(big.id)
        let inner = try XCTUnwrap(model.rows.first { $0.name == "inner" })
        model.enter(inner.id)

        XCTAssertEqual(model.breadcrumb.count, 3)
        // Jumping to the first crumb must land on the scan root.
        model.enter(model.breadcrumb[0].id)
        XCTAssertEqual(model.currentDirectory, 0)
    }
}
