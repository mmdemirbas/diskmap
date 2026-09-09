import DiskMapCore
import XCTest
@testable import DiskMapApp

/// Tools that read the tree, when the tree moves under them.
///
/// A result list that stopped following the disk is worse than an empty one,
/// because it looks like an answer. The map and the flat table already
/// followed; the search results and the change history did not, and stood
/// there naming files that were no longer where they said.
@MainActor
final class LiveToolsTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmlive-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    /// `changes` is made on first use and holds the store it was made with, so
    /// a test that wants its own snapshot directory has to say so before the
    /// scan — which is what writes the first snapshot.
    private func scanned(snapshots: SnapshotStore? = nil) -> AppModel {
        let m = AppModel()
        if let snapshots { m.snapshots = snapshots }
        m.clearTargets()
        m.addTargets([root])
        m.scanSynchronously()
        return m
    }

    /// The search is over the scanned index, so a file that has just appeared
    /// is only findable once the index has caught up — and a file that has just
    /// gone must stop being offered.
    func testTheSearchFollowsTheTree() throws {
        try write("aardvark-one.bin", 1_000)
        let m = scanned()
        m.openTool(.search)
        m.findText = "aardvark"
        m.runFind()
        try waitUntil("the first search landed") { m.findResults.count == 1 }

        try write("aardvark-two.bin", 1_000)
        let tree = try XCTUnwrap(m.tree)
        XCTAssertTrue(tree.refresh(directory: root.path))

        m.refreshLiveViews()
        // The search debounces its own typing, so the answer lands shortly
        // after being asked for rather than in the same turn.
        try waitUntil("the search caught up") { m.findResults.count == 2 }
    }

    /// A search nobody has typed into is not re-run — there is nothing to
    /// re-run — and a closed one is not either.
    func testAnEmptyOrClosedSearchIsNotReRun() throws {
        try write("thing.bin", 1_000)
        let m = scanned()
        m.openTool(.search)
        m.findText = ""

        m.refreshLiveViews()
        XCTAssertTrue(m.findResults.isEmpty)
        XCTAssertFalse(m.findSearching, "an empty search was started anyway")
    }

    /// Live refreshing must not write a snapshot. A snapshot is the record of a
    /// scan; one per filesystem event would fill the history with entries
    /// nobody asked for, and leave the list comparing the scan against itself.
    func testRefreshingTheChangeHistoryWritesNoNewSnapshot() throws {
        try write("a.bin", 1_000)
        let store = SnapshotStore(directory: root.appendingPathComponent(".snapshots"))
        let m = scanned(snapshots: store)
        m.changes.record(try XCTUnwrap(m.tree))
        try waitUntil("the first snapshot was written") { !store.list().isEmpty }
        let before = store.list().count

        m.openTool(.changes)
        try write("b.bin", 2_000)
        let tree = try XCTUnwrap(m.tree)
        XCTAssertTrue(tree.refresh(directory: root.path))
        m.refreshLiveViews()

        // Give any write that was going to happen the chance to happen.
        try waitFor(0.4)
        XCTAssertEqual(store.list().count, before, "a snapshot was written by a refresh")
    }

    /// The snapshot directory can be pointed somewhere else, and the module
    /// has to be the one that hears about it.
    ///
    /// It was a stored property on the model that the module read once, at
    /// construction — and the model's own initialiser builds the module, so
    /// every assignment afterwards was a no-op. The offscreen renderer's
    /// history override had been silently reading the real history.
    func testPointingTheHistorySomewhereElseIsHeard() {
        let elsewhere = SnapshotStore(directory: root.appendingPathComponent(".elsewhere"))
        let m = AppModel()
        m.snapshots = elsewhere
        XCTAssertEqual(m.changes.snapshots.directory, elsewhere.directory)
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting until \(what)")
    }

    private func waitFor(_ seconds: TimeInterval) throws {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
