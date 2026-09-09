import DiskMapCore
import XCTest
@testable import DiskMapApp

/// The window arranged the way the user arranges it.
///
/// The tools were tabs — one on screen, the rest behind it — and the ask was to
/// put them side by side by dragging. They are now panes in the same dock the
/// map uses for its own views, so what needs holding still is the part that is
/// new at this level: two things cannot be closed, opening one from a group's
/// `+` has to fill it, and a layout with two tools in it is still one tool per
/// place.
@MainActor
final class ToolDockTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmdock-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(count: 4_000).write(to: root.appendingPathComponent("a.bin"))
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func scanned() -> AppModel {
        let m = AppModel()
        m.clearTargets()
        m.addTargets([root])
        m.scanSynchronously()
        return m
    }

    func testTheWindowOpensWithHomeAndTheMapAsTabsOfOneGroup() {
        let layout = ToolDock.standard
        XCTAssertEqual(layout.panes, [.home, .map])
        XCTAssertEqual(layout.leaves.count, 1, "a split window on first launch")
    }

    /// The whole ask: two tools side by side rather than one behind the other.
    func testATooDroppedOnAnEdgeSplitsTheWindow() throws {
        let m = scanned()
        m.openTool(.duplicates)
        let host = try XCTUnwrap(m.tools.leafHolding(.map))

        m.moveTool(.duplicates, to: host, edge: .trailing)

        XCTAssertEqual(m.tools.leaves.count, 2, "the drop did not split anything")
        XCTAssertNotEqual(m.tools.leafHolding(.duplicates), m.tools.leafHolding(.map))
        XCTAssertTrue(m.openTabs.contains(.duplicates))
        XCTAssertTrue(m.openTabs.contains(.map))
    }

    /// Dropped back into the middle of a group, it becomes a tab of it again.
    func testATooDroppedInTheMiddleJoinsThatGroup() throws {
        let m = scanned()
        m.openTool(.search)
        let host = try XCTUnwrap(m.tools.leafHolding(.map))
        m.moveTool(.search, to: host, edge: .bottom)
        XCTAssertEqual(m.tools.leaves.count, 2)

        let mapLeaf = try XCTUnwrap(m.tools.leafHolding(.map))
        m.moveTool(.search, to: mapLeaf, edge: nil)

        XCTAssertEqual(m.tools.leaves.count, 1, "the emptied group was left behind")
        XCTAssertEqual(m.tools.leafHolding(.search), m.tools.leafHolding(.map))
    }

    /// The map is the scan rather than a view of it, and home is where the
    /// window lands. Both can be moved anywhere; neither can be taken away.
    func testTheMapCanBeMovedButNotClosed() throws {
        let m = scanned()
        m.openTool(.files)
        let filesLeaf = try XCTUnwrap(m.tools.leafHolding(.files))

        m.moveTool(.map, to: filesLeaf, edge: .bottom)
        XCTAssertTrue(m.openTabs.contains(.map), "moving the map lost it")

        m.close(.map)
        m.close(.home)
        XCTAssertTrue(m.openTabs.contains(.map))
        XCTAssertTrue(m.openTabs.contains(.home))
    }

    /// A tool added from a group's `+` lands in that group — and is told to
    /// fetch what it shows, the same as one opened from the home screen.
    func testAddingFromAGroupPutsItThereAndFillsIt() throws {
        let m = scanned()
        m.openTool(.files)
        let mapLeaf = try XCTUnwrap(m.tools.leafHolding(.map))
        m.moveTool(.files, to: mapLeaf, edge: .trailing)

        let target = try XCTUnwrap(m.tools.leafHolding(.files))
        m.addTool(.space, to: target)

        XCTAssertEqual(m.tools.leafHolding(.space), target)
        XCTAssertTrue(m.suggestionsLoading, "the cleanup search was never started")
    }

    /// Closing a tool takes its group with it when it was the last one there,
    /// rather than leaving a divider with an empty rectangle behind it.
    func testClosingTheLastToolInAGroupCollapsesIt() throws {
        let m = scanned()
        m.openTool(.changes)
        m.moveTool(.changes, to: try XCTUnwrap(m.tools.leafHolding(.map)), edge: .trailing)
        XCTAssertEqual(m.tools.leaves.count, 2)

        m.close(.changes)

        XCTAssertEqual(m.tools.leaves.count, 1)
        XCTAssertFalse(m.openTabs.contains(.changes))
    }

    /// Bringing a tool forward is what `activeTab` has always meant, and it has
    /// to reach the layout now that the layout decides what is in front.
    func testBringingAToolForwardActivatesItInItsGroup() throws {
        let m = scanned()
        m.openTool(.compare)
        m.activeTab = .map

        let leaf = try XCTUnwrap(m.tools.leaves.first { $0.panes.contains(.map) })
        XCTAssertEqual(leaf.active, .map)
    }

    /// One tool per place. Opening one that is already somewhere brings it
    /// forward instead of adding a second.
    func testAToolIsNeverInTwoPlaces() {
        let m = scanned()
        m.openTool(.files)
        m.openTool(.files)
        XCTAssertEqual(m.openTabs.filter { $0 == .files }.count, 1)
    }
}
