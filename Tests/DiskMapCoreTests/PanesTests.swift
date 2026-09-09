import DiskMapCore
import SwiftUI
import XCTest
@testable import DiskMapApp

/// The views are not alternatives of each other.
///
/// Three pictures and four tables, and for the whole of this app's life
/// choosing one meant losing the others: a segmented picker in the toolbar
/// decided which picture existed, and another decided which table. The layout
/// code had that assumption baked into it — the cache key was built from
/// *the* visualization rather than from the one being asked for, so a request
/// for a sunburst while the treemap was current computed a treemap and filed
/// it under the sunburst's name.
@MainActor
final class PanesTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmpanes-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("a"),
                               withIntermediateDirectories: true)
        try Data(count: 800_000).write(to: root.appendingPathComponent("a/one.bin"))
        try Data(count: 300_000).write(to: root.appendingPathComponent("two.bin"))
        // Two copies over the duplicate pass's size floor, so the expensive
        // half of a report has something to find when it is asked for.
        try Data(count: 2_000_000).write(to: root.appendingPathComponent("a/copy.bin"))
        try Data(count: 2_000_000).write(to: root.appendingPathComponent("copy.bin"))
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func ready() -> AppModel {
        let model = AppModel()
        model.adopt(LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path))))
        return model
    }

    func testEveryPictureCanBeLaidOutAtOnce() async throws {
        let model = ready()
        let size = CGSize(width: 420, height: 320)
        // Whichever one the model thinks is current must not decide what the
        // other two are allowed to be.
        model.visualization = .treemap

        await model.relayout(.treemap, size: size)
        await model.relayout(.sunburst, size: size)
        await model.relayout(.icicle, size: size)

        XCTAssertNotNil(model.cachedLayout(for: size), "no treemap")
        XCTAssertNotNil(model.cachedSunburst(for: size), "no ring chart")
        XCTAssertNotNil(model.cachedIcicle(for: size), "no layer chart")
    }

    /// A pane in a background tab is not being looked at, and the copy pass is
    /// the most expensive thing in the app — a signature per folder over the
    /// whole tree. Whether it runs has to follow what is in front, which is
    /// what the segmented picker used to decide.
    func testOnlyThePaneInFrontAsksForTheExpensiveWalk() throws {
        let model = ready()

        model.showPane(.contents)
        model.refreshSummarySync()
        XCTAssertTrue(model.duplicates.isEmpty,
                      "the copy pass ran for a pane nobody is looking at")
        XCTAssertNotNil(model.summary, "the cheap half of the report should still run")

        model.showPane(.copies)
        model.refreshSummarySync()
        XCTAssertFalse(model.duplicates.isEmpty,
                       "the copy pass did not run for the pane that shows copies")
    }

    /// Closing a pane stops it costing anything, which is half the reason to be
    /// able to close one.
    func testClosingTheCopiesPaneStopsTheWalkThatFeedsIt() throws {
        let model = ready()
        model.showPane(.copies)
        model.refreshSummarySync()
        XCTAssertFalse(model.duplicates.isEmpty)

        model.closePane(.copies)
        model.refreshSummarySync()
        XCTAssertTrue(model.duplicates.isEmpty)
    }

    /// A drop can name a group that is no longer there — the layout may have
    /// changed under an in-flight drag. Recovering from that must not put the
    /// same pane in two places, which is the invariant every other operation
    /// relies on.
    func testADropOnAGroupThatIsGoneDoesNotDuplicateThePane() {
        var layout = DockLayout(root: .leaf([.treemap]))
        layout.move(.treemap, to: UUID(), edge: nil)

        let everywhere = layout.leaves.flatMap(\.panes)
        XCTAssertEqual(everywhere.filter { $0 == .treemap }.count, 1,
                       "the pane is in two places at once: \(everywhere)")
        XCTAssertEqual(Set(everywhere).count, everywhere.count, "some pane is duplicated")
    }

    /// Closing a pane brings another forward, and that one may need a report
    /// nobody has asked for yet.
    func testClosingAPaneAsksForWhateverTheNextOneNeeds() throws {
        let model = ready()
        // Copies behind Contents in the same group: no copy pass yet.
        model.showPane(.contents)
        model.refreshSummarySync()
        XCTAssertTrue(model.duplicates.isEmpty)

        model.closePane(.contents)
        model.refreshSummarySync()

        XCTAssertEqual(model.panel, .largest, "something else should have come forward")
        model.showPane(.copies)
        model.refreshSummarySync()
        XCTAssertFalse(model.duplicates.isEmpty)
    }

    /// Each picture is cached under its own name, so one does not answer for
    /// another at the same size.
    func testEachPictureIsKeyedByItsOwnKind() throws {
        let model = ready()
        let size = CGSize(width: 420, height: 320)
        let keys = Set(Visualization.allCases.map { model.layoutKey($0, size: size) })
        XCTAssertEqual(keys.count, Visualization.allCases.count)
    }
}

/// The layout the user builds, as algebra.
///
/// Every mistake a dock can make is in here rather than in the drawing:
/// removing the last pane of a group has to take the divider with it, a pane
/// has to exist in exactly one place, and a divider dragged to the end must
/// stop rather than leave a rectangle nobody can grab.
final class DockLayoutTests: XCTestCase {
    private func standard() -> DockLayout { .standard }

    private func leafID(_ layout: DockLayout, holding kind: PaneKind) -> UUID {
        layout.leafHolding(kind)!
    }

    // MARK: - What it starts as

    /// The layout on first run is the screen the app already had. Nobody has to
    /// build one to get back what they were used to.
    func testTheDefaultLayoutHoldsEveryPane() {
        let layout = standard()
        XCTAssertEqual(Set(layout.panes), Set(PaneKind.allCases))
        XCTAssertEqual(layout.leaves.count, 2)
        XCTAssertTrue(layout.missing.isEmpty)
    }

    // MARK: - Tabs and splits

    func testDroppingOnTheMiddleJoinsThatGroupAsATab() {
        var layout = standard()
        let tables = leafID(layout, holding: .contents)

        layout.move(.treemap, to: tables, edge: nil)

        XCTAssertEqual(layout.leafHolding(.treemap), tables)
        XCTAssertEqual(layout.leaves.count, 2, "a tab drop should not have split anything")
        // Dropped panes come forward: you moved it because you want to see it.
        XCTAssertEqual(layout.leaves.first { $0.id == tables }?.active, .treemap)
    }

    func testDroppingOnAnEdgeSplitsThatGroup() {
        var layout = standard()
        let tables = leafID(layout, holding: .contents)

        layout.move(.treemap, to: tables, edge: .bottom)

        XCTAssertEqual(layout.leaves.count, 3)
        XCTAssertNotEqual(layout.leafHolding(.treemap), tables)
        XCTAssertEqual(Set(layout.panes), Set(PaneKind.allCases), "a pane went missing")
    }

    /// The side the pane lands on is the side it was dropped on.
    func testTheEdgeDecidesWhichSideItLandsOn() {
        var layout = DockLayout(root: .leaf([.contents]))
        let only = leafID(layout, holding: .contents)
        layout.insert(.treemap, into: only, edge: .leading)

        guard case .split(_, let axis, _, let first, _) = layout.root else {
            return XCTFail("no split was made")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(first.panes, [.treemap])
    }

    // MARK: - Taking things away

    func testRemovingTheLastPaneOfAGroupTakesTheDividerWithIt() {
        var layout = standard()
        for pane in [PaneKind.treemap, .sunburst, .icicle] { layout.remove(pane) }

        XCTAssertEqual(layout.leaves.count, 1, "an empty group was left behind")
        XCTAssertEqual(Set(layout.panes), [.contents, .largest, .types, .copies])
    }

    /// Closing the tab that is in front has to leave a different one in front,
    /// or the group draws nothing.
    func testClosingTheActiveTabPromotesAnother() {
        var layout = standard()
        let pictures = leafID(layout, holding: .treemap)
        XCTAssertEqual(layout.leaves.first { $0.id == pictures }?.active, .treemap)

        layout.remove(.treemap)

        let group = layout.leaves.first { $0.id == pictures }
        XCTAssertEqual(group?.active, .sunburst)
    }

    /// Emptying the whole thing has to leave something to drop onto.
    func testTheLayoutNeverBecomesNothing() {
        var layout = standard()
        for pane in PaneKind.allCases { layout.remove(pane) }
        XCTAssertFalse(layout.panes.isEmpty, "there is nothing left to drag anything onto")
    }

    // MARK: - Moving

    /// A pane is a view of one shared state, so it exists in exactly one place.
    /// Every operation below rests on that.
    func testAPaneIsNeverInTwoPlaces() {
        var layout = standard()
        let tables = leafID(layout, holding: .contents)
        layout.move(.treemap, to: tables, edge: nil)
        layout.move(.treemap, to: tables, edge: .top)

        XCTAssertEqual(layout.panes.filter { $0 == .treemap }.count, 1)
    }

    /// Dragging a lone pane back onto its own group means nothing, and must not
    /// take the group away and rebuild it somewhere else.
    func testDroppingALonePaneOnItsOwnGroupChangesNothing() {
        var layout = DockLayout(root: .split(id: UUID(), axis: .horizontal, ratio: 0.5,
                                             first: .leaf([.treemap]),
                                             second: .leaf([.contents])))
        let before = layout
        layout.move(.treemap, to: leafID(layout, holding: .treemap), edge: .trailing)
        XCTAssertEqual(layout, before)
    }

    func testMovingTheLastPaneOutOfAGroupStillLandsSomewhere() {
        var layout = DockLayout(root: .split(id: UUID(), axis: .horizontal, ratio: 0.5,
                                             first: .leaf([.treemap]),
                                             second: .leaf([.contents])))
        layout.move(.treemap, to: leafID(layout, holding: .contents), edge: nil)

        XCTAssertEqual(layout.leaves.count, 1)
        XCTAssertEqual(Set(layout.panes), [.treemap, .contents])
    }

    // MARK: - Dividers

    func testADividerDraggedToTheEndStops() {
        var layout = standard()
        guard case .split(let id, _, _, _, _) = layout.root else { return XCTFail("no split") }

        layout.setRatio(id, 2.0)
        guard case .split(_, _, let high, _, _) = layout.root else { return XCTFail("no split") }
        XCTAssertLessThanOrEqual(high, 0.85)

        layout.setRatio(id, -1)
        guard case .split(_, _, let low, _, _) = layout.root else { return XCTFail("no split") }
        XCTAssertGreaterThanOrEqual(low, 0.15)
    }

    // MARK: - Adding one back

    func testAddingAPaneBackPutsItWithItsOwnKind() {
        var layout = standard()
        layout.remove(.types)
        XCTAssertEqual(layout.missing, [.types])

        layout.add(.types)
        XCTAssertEqual(layout.leafHolding(.types), layout.leafHolding(.contents))
        XCTAssertTrue(layout.missing.isEmpty)
    }

    func testAddingSomethingAlreadyThereJustBringsItForward() {
        var layout = standard()
        let before = layout.leaves.count
        layout.add(.icicle)
        XCTAssertEqual(layout.leaves.count, before)
        XCTAssertEqual(layout.leafHolding(.icicle).map { id in
            layout.leaves.first { $0.id == id }?.active
        }, .icicle)
    }

    // MARK: - Surviving a restart

    func testALayoutSurvivesBeingWrittenDownAndReadBack() {
        var layout = standard()
        let tables = leafID(layout, holding: .contents)
        layout.move(.sunburst, to: tables, edge: .bottom)

        XCTAssertEqual(DockLayout.decoded(from: layout.encoded), layout)
    }

    func testNonsenseOnDiskFallsBackToSomethingDrawable() {
        // Compared by shape rather than by value: every layout carries fresh
        // identifiers for its groups, so two standard layouts are the same
        // screen and not the same object.
        for stored in ["{ not json", "", "null", "[]"] {
            let layout = DockLayout.decoded(from: stored)
            XCTAssertEqual(layout.panes, DockLayout.standard.panes, stored)
            XCTAssertEqual(layout.leaves.count, 2, stored)
        }
    }

    // MARK: - Where a drop lands

    /// The middle is the easiest thing to hit, because joining a group is the
    /// commonest thing to want.
    func testTheMiddleOfAPaneMeansJoinItsTabs() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertNil(DockGeometry.edge(in: rect, at: CGPoint(x: 200, y: 150)))
    }

    func testEachSideOfAPaneMeansThatSide() {
        let rect = CGRect(x: 100, y: 50, width: 400, height: 300)
        XCTAssertEqual(DockGeometry.edge(in: rect, at: CGPoint(x: 110, y: 200)), .leading)
        XCTAssertEqual(DockGeometry.edge(in: rect, at: CGPoint(x: 490, y: 200)), .trailing)
        XCTAssertEqual(DockGeometry.edge(in: rect, at: CGPoint(x: 300, y: 60)), .top)
        XCTAssertEqual(DockGeometry.edge(in: rect, at: CGPoint(x: 300, y: 340)), .bottom)
    }

    /// A corner belongs to whichever edge it is closer to, rather than to
    /// whichever was tested first.
    func testACornerGoesToTheNearerEdge() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
        // 10pt from the left, 20pt from the top: in fractions that is 0.025
        // across and 0.1 down, so the left edge is nearer.
        XCTAssertEqual(DockGeometry.edge(in: rect, at: CGPoint(x: 10, y: 20)), .leading)
        XCTAssertEqual(DockGeometry.edge(in: rect, at: CGPoint(x: 60, y: 4)), .top)
    }

    /// What the preview covers is what the pane will take.
    func testThePreviewShowsTheHalfThePaneWouldTake() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertEqual(DockGeometry.preview(in: rect, edge: nil), rect)
        XCTAssertEqual(DockGeometry.preview(in: rect, edge: .leading),
                       CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(DockGeometry.preview(in: rect, edge: .bottom),
                       CGRect(x: 0, y: 100, width: 400, height: 100))
    }

    /// A rectangle with no area cannot say where a point is in it, and a drop
    /// there must mean nothing rather than an arbitrary edge.
    func testAnEmptyRectangleHasNoEdges() {
        XCTAssertNil(DockGeometry.edge(in: .zero, at: .zero))
    }

    /// A stored layout is just a string in the preferences, and an older
    /// version of the app could have written anything into it. Rather than
    /// trusting it, the invariants are re-established on the way in.
    func testAStoredLayoutIsRepairedRatherThanTrusted() {
        let doubled = DockNode.split(id: UUID(), axis: .horizontal, ratio: 9,
                                     first: .leaf(id: UUID(), panes: [.treemap, .treemap],
                                                  active: .copies),
                                     second: .leaf(id: UUID(), panes: [.treemap],
                                                   active: .treemap))
        let repaired = DockLayout.sanitised(doubled)

        XCTAssertEqual(repaired.panes, [.treemap], "a pane was left in two places")
        XCTAssertEqual(repaired.leaves.first?.active, .treemap,
                       "the tab in front was not one of the tabs")
    }
}
