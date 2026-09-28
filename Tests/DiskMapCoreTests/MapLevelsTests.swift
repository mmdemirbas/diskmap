import DiskMapCore
import XCTest
@testable import DiskMapApp

/// How many levels the map draws: the setting reaches the layout, the
/// layout is asked for again when it changes, and it stays in its range.
@MainActor
final class MapLevelsTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var stored: Int?

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmlevels-\(UUID().uuidString)")
        // Five folders deep, with a file at every level so each has a size.
        var dir = root!
        for depth in 0..<5 {
            dir = dir.appendingPathComponent("level\(depth)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(count: 50_000).write(to: dir.appendingPathComponent("f\(depth).bin"))
            try Data(count: 40_000).write(to: dir.deletingLastPathComponent().appendingPathComponent("g\(depth).bin"))
        }
        stored = UserDefaults.standard.object(forKey: "mapLevels") as? Int
    }
    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        UserDefaults.standard.set(stored, forKey: "mapLevels")
    }

    private func scanned() -> AppModel {
        let m = AppModel()
        m.clearTargets()
        m.addTargets([root])
        m.scanSynchronously()
        return m
    }

    private func deepest(_ m: AppModel) throws -> Int {
        let layout = try XCTUnwrap(m.map.computeLayoutSync(size: CGSize(width: 1200, height: 900)))
        return layout.cells.map(\.depth).max() ?? -1
    }

    func testTheLayoutDrawsAsManyLevelsAsAskedAndNoMore() throws {
        let m = scanned()
        // A cell's depth counts from the folder being looked at: its own
        // children are depth 1, so one level draws only them.
        m.map.levels = 1
        XCTAssertEqual(try deepest(m), 1)
        m.map.levels = 3
        XCTAssertEqual(try deepest(m), 3)
        // The view paints a folder at the cut-off as a named box; it knows the
        // cut-off from the layout, not from the setting.
        XCTAssertEqual(m.map.computeLayoutSync(size: CGSize(width: 1200, height: 900))?.levels, 3)
        m.map.levels = 12
        XCTAssertGreaterThanOrEqual(try deepest(m), 5, "a five-deep tree drawn only partly at twelve levels")
    }

    /// The views lay out again when the key changes; a key without the level
    /// count would keep showing the old picture.
    func testChangingTheLevelsAsksForANewLayout() {
        let m = scanned()
        m.map.levels = 4
        let before = m.map.layoutKey(.treemap, size: CGSize(width: 800, height: 600))
        m.map.showMoreLevels()
        XCTAssertNotEqual(m.map.layoutKey(.treemap, size: CGSize(width: 800, height: 600)), before)
    }

    func testTheLevelsStayInTheirRange() {
        let m = scanned()
        m.map.levels = MapModule.levelRange.lowerBound
        m.map.showFewerLevels()
        XCTAssertEqual(m.map.levels, MapModule.levelRange.lowerBound)
        XCTAssertFalse(m.map.canShowFewerLevels)
        m.map.levels = MapModule.levelRange.upperBound
        m.map.showMoreLevels()
        XCTAssertEqual(m.map.levels, MapModule.levelRange.upperBound)
        XCTAssertFalse(m.map.canShowMoreLevels)
    }
}
