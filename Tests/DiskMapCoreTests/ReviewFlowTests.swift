import DiskMapCore
import XCTest
@testable import DiskMapApp
@testable import DiskMapCore

/// The path from ticking something to a plan on screen.
///
/// `TrashPlanner` has twenty-five tests and they are all about the rules. None
/// of them covers the code that decides what the planner is *given* — which
/// nodes are selected, which groups it is told about — and that is the half
/// living in the app. So the rules were well tested and their inputs were not
/// tested at all.
///
/// Nothing here moves a file. Every case stops at the plan, which is the
/// description of what would happen; carrying it out is a separate step with
/// its own re-check.
@MainActor
final class ReviewFlowTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmreview-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func ready() -> AppModel {
        let model = AppModel()
        model.adopt(LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path))))
        return model
    }

    private func node(_ model: AppModel, _ path: String) throws -> Int32 {
        try XCTUnwrap(model.tree?.withStore {
            $0.find(path: self.root.appendingPathComponent(path).path)
        })
    }

    // MARK: - Selecting

    func testTickingSomethingPutsItInThePlan() throws {
        try write("big.bin", 400_000)
        let model = ready()
        let victim = try node(model, "big.bin")

        model.toggleChecked(victim)
        model.requestBulkTrash()

        let plan = try XCTUnwrap(model.reviewPlan)
        XCTAssertEqual(plan.items.map(\.node), [victim])
        XCTAssertNil(model.reviewRefusal)
    }

    func testUntickingTakesItBackOut() throws {
        try write("big.bin", 400_000)
        let model = ready()
        let victim = try node(model, "big.bin")

        model.toggleChecked(victim)
        model.toggleChecked(victim)

        XCTAssertTrue(model.checked.isEmpty)
    }

    /// The total under the list is the total of what is ticked right now, so it
    /// has to follow a tick made while the list is already on screen.
    func testThePlanFollowsATickMadeWhileTheListIsOpen() throws {
        try write("one.bin", 400_000)
        try write("two.bin", 900_000)
        let model = ready()
        let one = try node(model, "one.bin"), two = try node(model, "two.bin")

        model.toggleChecked(one)
        model.requestBulkTrash()
        let before = try XCTUnwrap(model.reviewPlan).bytes

        model.toggleChecked(two)

        let after = try XCTUnwrap(model.reviewPlan).bytes
        XCTAssertGreaterThan(after, before, "the total did not follow the tick that changed it")
        XCTAssertEqual(Set(try XCTUnwrap(model.reviewPlan).items.map(\.node)), [one, two])
    }

    // MARK: - The guards

    /// Ticking every copy in a group would leave nothing behind. The planner
    /// refuses it; refusing the tick is better, because it says so before a
    /// selection has been built that cannot be used.
    func testTheLastCopyCannotBeTicked() throws {
        try write("a/photo.bin", 300_000)
        try write("b/photo.bin", 300_000)
        let model = ready()
        let left = try node(model, "a/photo.bin"), right = try node(model, "b/photo.bin")
        model.matchGroups = [[left, right]]

        model.toggleChecked(left)
        XCTAssertTrue(model.checked.contains(left))

        model.toggleChecked(right)
        XCTAssertFalse(model.checked.contains(right),
                       "both copies ticked leaves the group with nothing in it")
    }

    func testSelectExtrasKeepsTheFirstOne() throws {
        try write("a/photo.bin", 300_000)
        try write("b/photo.bin", 300_000)
        try write("c/photo.bin", 300_000)
        let model = ready()
        let nodes = [try node(model, "a/photo.bin"),
                     try node(model, "b/photo.bin"),
                     try node(model, "c/photo.bin")]
        model.matchGroups = [nodes]

        model.checkExtras(nodes.map { PathRef(id: $0, path: "") })

        XCTAssertFalse(model.checked.contains(nodes[0]), "the first copy is the one that stays")
        XCTAssertEqual(model.checked, Set(nodes.dropFirst()))
    }

    /// The copy report does not filter by the never-touch list, so a folder
    /// excluded in an earlier session can still be offered. It must not tick.
    func testSomethingOnTheNeverTouchListCannotBeTicked() throws {
        try write("keep/photo.bin", 300_000)
        let model = ready()
        let safe = try node(model, "keep")
        model.excludedPaths = [model.tree!.withStore { $0.path(safe) }]

        model.toggleChecked(safe)

        XCTAssertTrue(model.checked.isEmpty, "the never-touch list did not stop the tick")
        XCTAssertTrue(model.isNeverTouch(safe))
    }

    /// A selection made entirely of excluded things produces a review with
    /// nothing in it, and saying so is the difference between "nothing matched"
    /// and a screen that looks broken.
    func testASelectionThatIsEntirelyExcludedIsRefusedNotShownEmpty() throws {
        try write("keep/photo.bin", 300_000)
        let model = ready()
        let safe = try node(model, "keep")
        // Ticked before the exclusion exists, which is the only way in.
        model.toggleChecked(safe)
        model.excludedPaths = [model.tree!.withStore { $0.path(safe) }]

        model.requestBulkTrash()

        XCTAssertNil(model.reviewing, "a review with nothing in it should not stay on screen")
        XCTAssertNotNil(model.toast)
    }

    /// A scan root is not a candidate however it was reached — and the reason
    /// given has to be the real one. The review comes back empty for several
    /// different reasons and cancelling drops the refusal that says which, so
    /// every one of them reported the never-touch list.
    func testTheScanRootIsRefusedAndSaysWhy() throws {
        try write("one.bin", 400_000)
        let model = ready()

        model.toggleChecked(0)
        model.requestBulkTrash()

        XCTAssertNil(model.reviewPlan)
        XCTAssertEqual(model.toast, L10n.shared[.cannotRemoveScanRoot],
                       "told the user about the never-touch list for a scan root")
    }

    // MARK: - Letting go

    func testCancellingDropsThePlanButNotTheSelection() throws {
        try write("big.bin", 400_000)
        let model = ready()
        model.toggleChecked(try node(model, "big.bin"))
        model.requestBulkTrash()
        XCTAssertNotNil(model.reviewPlan)

        model.cancelBulkTrash()

        XCTAssertNil(model.reviewing)
        XCTAssertNil(model.reviewPlan)
        XCTAssertFalse(model.checked.isEmpty, "closing the list is not the same as unticking")
    }
}
