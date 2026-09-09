import XCTest
import DiskMapCore
@testable import DiskMapReports
@testable import DiskMapScan

/// The copy hunt has to say what it is doing while it does it.
///
/// The complaint these cover is "waiting blindly": three passes over the whole
/// tree, minutes on a full disk, and one spinner for all of it. What a screen
/// needs to name the running pass is that each pass announces itself, in order,
/// with a count that only moves forwards.
final class MatchProgressTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: fm.temporaryDirectory.path)
            .appendingPathComponent("dmprog-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    /// Collects what the passes reported. A lock because the callback is
    /// `@Sendable` and the real callers run it off the main thread.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var steps: [MatchProgress] = []
        var report: MatchProgress.Report {
            { step in self.lock.lock(); self.steps.append(step); self.lock.unlock() }
        }
    }

    private func scan() throws -> NodeStore {
        DiskScanner().scan(ScanOptions(rootPath: root.path)).store
    }

    func testEachPassSaysWhenItStarts() throws {
        try write("left/a.bin", 40_000)
        try write("left/b.bin", 20_000)
        try write("right/a.bin", 40_000)
        try write("right/b.bin", 20_000)
        let store = try scan()

        let recorder = Recorder()
        let folders = FolderMatches.find(store: store, root: 0, minimumSize: 1_000,
                                         onProgress: recorder.report)
        _ = Duplicates.find(store: store, root: 0, minimumSize: 1_000,
                            insideMatched: folders, onProgress: recorder.report)

        // Not "at least one message" — the order is the point. A screen that
        // shows the passes as a list draws the wrong one as running if these
        // arrive out of order.
        var seen: [MatchProgress.Phase] = []
        for step in recorder.steps where seen.last != step.phase { seen.append(step.phase) }
        XCTAssertEqual(seen, [.signing, .folders, .files])
    }

    func testTheCountOnlyMovesForwardsAndNeverPastTheTotal() throws {
        for index in 0..<40 { try write("folder-\(index)/a.bin", 2_000) }
        let store = try scan()

        let recorder = Recorder()
        _ = Duplicates.find(store: store, root: 0, minimumSize: 1_000,
                            onProgress: recorder.report)

        var previous = -1
        for step in recorder.steps {
            XCTAssertGreaterThanOrEqual(step.done, previous)
            XCTAssertLessThanOrEqual(step.done, step.total)
            previous = step.done
        }
        XCTAssertFalse(recorder.steps.isEmpty)
    }

    /// A pass that cannot say how much there is says so, rather than inventing
    /// a percentage. The screen draws that as a bar that moves instead of one
    /// that fills.
    func testAnUnknownTotalHasNoFraction() {
        XCTAssertNil(MatchProgress(phase: .folders, done: 0, total: 0).fraction)
        XCTAssertEqual(MatchProgress(phase: .signing, done: 5, total: 10).fraction, 0.5)
    }

    /// Reporting is throttled because a message per node would cost more than
    /// the work it reports on. The mask has to be all-ones, or the test above
    /// passes while the callback fires on a scattered subset of nodes.
    func testTheThrottleIsAContiguousMask() {
        XCTAssertEqual(MatchProgress.every & (MatchProgress.every + 1), 0)
    }

    /// Signing is the long pass and the one the count matters for. It walks
    /// every node, so the total is the whole walk — and it has to reach that
    /// total, or the bar stops short of the end and reads as a stall.
    func testSigningCountsTheWholeWalkAndReachesTheEnd() throws {
        for index in 0..<20 { try write("folder-\(index)/a.bin", 2_000) }
        let store = try scan()

        let recorder = Recorder()
        _ = FolderMatches.signatures(store, onProgress: recorder.report)
        let signing = recorder.steps.filter { $0.phase == .signing }
        XCTAssertEqual(signing.first?.done, 0)
        XCTAssertEqual(signing.first?.total, store.count)
        XCTAssertEqual(signing.last?.done, store.count)
    }
}
