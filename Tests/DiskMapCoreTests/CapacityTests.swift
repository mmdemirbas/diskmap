import DiskMapCore
import XCTest
@testable import DiskMapApp
@testable import DiskMapScan

/// The capacity screen, and the rule that one disk's numbers are its own.
///
/// Two disks measured together produced a single reconciliation built from both
/// and shown for either, so the bytes found on one disk were reconciled against
/// the used figure of the other — two unrelated quantities in one sentence,
/// presented as an accounting.
@MainActor
final class CapacityTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmcap-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    /// The piece the separation rests on: what a root holds must cover that
    /// root and nothing else.
    func testEachRootReportsOnlyItsOwnSubtree() throws {
        try write("left/big.bin", 800_000)
        try write("left/inner/small.bin", 100_000)
        try write("right/only.bin", 300_000)
        let model = AppModel()
        model.clearTargets()
        model.addTargets([root.appendingPathComponent("left"),
                          root.appendingPathComponent("right")])
        model.scanSynchronously()
        let tree = try XCTUnwrap(model.tree)

        let (left, right, whole) = tree.withStore { store -> (Int64, Int64, Int64) in
            let l = store.find(path: self.root.appendingPathComponent("left").path)!
            let r = store.find(path: self.root.appendingPathComponent("right").path)!
            return (Aggregate.totals(store: store, root: l).physical,
                    Aggregate.totals(store: store, root: r).physical,
                    store.totalPhysical[0])
        }

        XCTAssertEqual(left + right, whole, "the two roots do not add up to the scan")
        XCTAssertGreaterThan(left, right, "the bigger root is not the bigger number")
        XCTAssertLessThan(left, whole, "one root's figure includes the other's")
        XCTAssertLessThan(right, whole, "one root's figure includes the other's")
    }

    /// A volume nobody scanned has nothing to reconcile. Answering "zero" would
    /// put a number where there should be an absence.
    func testAVolumeWithNoRootsInTheScanHasNoBreakdown() throws {
        try write("left/big.bin", 800_000)
        let model = AppModel()
        model.clearTargets()
        model.addTargets([root.appendingPathComponent("left")])
        model.scanSynchronously()

        guard var elsewhere = VolumeInfo.forPath("/") else {
            throw XCTSkip("no startup volume to borrow a shape from")
        }
        elsewhere.path = "/nowhere-at-all"
        XCTAssertNil(model.reconciliation(for: elsewhere))
    }

    /// And the volume that *was* scanned reports the bytes that were found on
    /// it, rather than the bytes found everywhere.
    func testTheScannedVolumeReportsWhatWasFoundOnIt() throws {
        try write("left/big.bin", 800_000)
        let model = AppModel()
        model.clearTargets()
        model.addTargets([root.appendingPathComponent("left")])
        model.scanSynchronously()

        let volume = try XCTUnwrap(model.targetedVolumes.first)
        let found = try XCTUnwrap(model.reconciliation(for: volume))
        XCTAssertEqual(found.scannedPhysical, model.tree?.withStore { $0.totalPhysical[0] })
        XCTAssertEqual(found.volumeUsed, volume.used)
        // A folder is not a volume, so its total may not be set against one.
        XCTAssertFalse(found.comparesToVolume)
    }
}
