import DiskMapCore
import XCTest
@testable import DiskMapApp
import DiskMapCore
@testable import DiskMapScan

/// Starting, cancelling and replacing a scan, and the state that has to go with
/// each of those.
@MainActor
final class ScanLifecycleTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmscan-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        try Data(count: 500_000).write(to: root.appendingPathComponent("a/one.bin"))
        try Data(count: 20_000).write(to: root.appendingPathComponent("two.bin"))
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func cancelledResult() -> ScanResult {
        var stats = ScanStats()
        stats.cancelled = true
        return ScanResult(store: NodeStore(), stats: stats, roots: [], rejectedRoots: [])
    }

    private func ready() -> AppModel {
        let model = AppModel()
        model.adopt(LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path))))
        return model
    }

    /// Cancelling is cooperative: the walk keeps going until it notices, then
    /// delivers a partial result and calls back. That callback used to answer
    /// for whoever was listening at the time, so a scan started afterwards had
    /// its scanner handle cleared and the screen pushed back to the chooser
    /// while it was still running.
    func testACancelledScanCannotSpeakForTheOneThatReplacedIt() throws {
        let model = ready()
        model.scanTargets = [root.path]

        model.scan()                        // A
        XCTAssertTrue(model.isScanning)
        let stale = model.scanGeneration

        model.cancelScan()                  // A is now nobody's scan
        XCTAssertNotEqual(model.scanGeneration, stale)

        model.scan()                        // B
        let live = model.scanGeneration
        XCTAssertTrue(model.isScanning)

        // A finishes late, cancelled, and must be ignored entirely.
        model.applyResult(cancelledResult(), from: stale)
        XCTAssertTrue(model.isScanning, "a superseded scan pushed the UI back to the chooser")
        XCTAssertEqual(model.scanGeneration, live)

        // B's own cancellation still counts.
        model.applyResult(cancelledResult(), from: live)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.phase, .idle)
    }

    /// The same for progress: a stale scan reporting its path made the screen
    /// show one volume's progress while another was being measured.
    func testAStaleScanCannotReportProgress() throws {
        let model = ready()
        model.scan()
        let stale = model.scanGeneration
        model.cancelScan()
        model.scan()

        model.applyProgress(ScanProgressSnapshot(nodes: 1, directories: 1, bytes: 1,
                                                 path: "/stale/volume", fraction: 0.5),
                            from: stale)
        if case .scanning(let p) = model.phase {
            XCTAssertNotEqual(p.path, "/stale/volume")
        } else {
            XCTFail("expected to still be scanning")
        }
        model.cancelScan()
    }

    /// Measuring something else must not carry anything over. Node indices mean
    /// nothing across two scans, and the tick list is the one that feeds the
    /// Trash — a stale index there is a wrong file moved.
    func testANewScanDropsEverythingTiedToTheOldTree() throws {
        let model = ready()
        model.toggleChecked(model.rows[0].id)
        model.expanded.insert(model.rows[0].id)
        model.filterText = "one"
        XCTAssertFalse(model.checked.isEmpty)
        XCTAssertFalse(model.rows.isEmpty)

        model.newScan()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.checked.isEmpty, "a tick list outliving its tree can trash the wrong file")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.expanded.isEmpty)
        XCTAssertTrue(model.breadcrumb.isEmpty)
        XCTAssertTrue(model.undoStack.isEmpty)
        XCTAssertEqual(model.filterText, "")
        XCTAssertEqual(model.currentDirectory, 0)
        XCTAssertNil(model.stats)
        XCTAssertNil(model.selection)
        XCTAssertNil(model.reconciliation)
        XCTAssertFalse(model.liveActive)
    }

    /// Going back to the chooser must leave it usable: the targets the user
    /// picked are still there to be changed, not silently re-run.
    func testANewScanKeepsTheChosenTargetsToEdit() throws {
        let model = ready()
        model.scanTargets = [root.path]
        model.newScan()
        XCTAssertEqual(model.scanTargets, [root.path])
    }

    /// Stopping from the progress screen goes to the chooser, not to a blank
    /// results view.
    func testStoppingAScanReturnsToTheChooser() throws {
        let model = AppModel()
        model.scanTargets = [root.path]
        model.scan()
        XCTAssertTrue(model.isScanning)
        model.stopScanning()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.isScanning)
    }

    // MARK: - What must not survive a rescan

    private func write(_ path: String, _ bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func scanned() -> AppModel {
        let model = AppModel()
        model.clearTargets()
        model.addTargets([root])
        model.scanSynchronously()
        return model
    }

    /// A node id means nothing across two scans: index 4,000 in the new tree is
    /// whatever now happens to sit there. Measuring again is not measuring
    /// something else, so most of the screen is kept — but anything holding
    /// node ids has to go, and the flat table's rows lead to Reveal, to the
    /// map, and to the Trash.
    func testRescanningDropsRowsThatNameNodesFromTheOldTree() throws {
        let model = scanned()
        model.open(.files)
        model.files.reloadSynchronously(in: try XCTUnwrap(model.tree))
        XCTAssertFalse(model.files.page.rows.isEmpty, "nothing to go stale")

        // The disk moves on, and the tree is measured again.
        try fm.removeItem(at: root.appendingPathComponent("two.bin"))
        try write("c/three.bin", 900_000)
        model.scanSynchronously()

        XCTAssertTrue(model.files.page.rows.isEmpty,
                      "the table still lists rows built from the previous tree")
    }

    /// The tick list is the one that feeds the bulk Trash, so a stale entry
    /// there is a stale entry pointed at a delete.
    func testRescanningClearsTheTickList() throws {
        let model = scanned()
        let node = try XCTUnwrap(model.tree?.withStore {
            $0.find(path: root.appendingPathComponent("two.bin").path)
        })
        model.checked = [node]

        model.scanSynchronously()

        XCTAssertTrue(model.checked.isEmpty,
                      "a tick from the previous tree survived into this one")
    }

    /// Cleanup suggestions name nodes too, and every one of them is a proposal
    /// to remove something.
    func testRescanningDropsSuggestionsFromTheOldTree() throws {
        // Build output is the cheapest suggestion to produce: a folder the
        // toolchain rebuilds, recognised by name.
        try write("project/node_modules/pkg/index.js", 40_000)
        try write("project/node_modules/other/big.bin", 40_000)
        let model = scanned()
        // A fixture is smaller than anything worth suggesting in real life.
        var floor = Cleanup.Thresholds()
        floor.suggestion = 1_000; floor.installer = 1_000; floor.staleFile = 1_000
        model.cleanupThresholds = floor
        model.space.loadSynchronously(tree: try XCTUnwrap(model.tree),
                                      root: 0, cache: SignatureCache())
        XCTAssertFalse(model.suggestions.isEmpty, "no suggestions to go stale")

        model.scanSynchronously()

        XCTAssertTrue(model.suggestions.isEmpty,
                      "a proposal to delete survived, naming nodes of a tree that is gone")
    }
}
