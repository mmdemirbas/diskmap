import XCTest
import DiskMapCore
@testable import DiskMapCompare
@testable import DiskMapScan

/// Answering a comparison from a scan that already happened.
///
/// The whole point is that it changes nothing. These tests are mostly about
/// the cases where the copy would *not* be the same answer, because that is
/// where a shared scan turns from a saving into a wrong result on screen.
final class ScanReuseTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: fm.temporaryDirectory.path)
            .appendingPathComponent("dmreuse-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int, fill: UInt8 = 0) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    private func scan() -> NodeStore {
        DiskScanner().scan(ScanOptions(rootPath: root.path)).store
    }

    private func path(_ name: String) -> String {
        root.appendingPathComponent(name).path
    }

    // MARK: - The copy is the same tree

    func testACopiedSubtreeHoldsWhatAFreshWalkHolds() throws {
        try write("side/a.bin", 4_000)
        try write("side/deep/b.bin", 1_500)
        try write("side/deep/deeper/c.bin", 900)
        try write("elsewhere/d.bin", 700)

        let copied = try XCTUnwrap(reuse("side")).store
        let walked = DiskScanner().scan(ScanOptions(rootPath: path("side"))).store

        XCTAssertEqual(copied.count, walked.count)
        XCTAssertEqual(copied.totalPhysical[0], walked.totalPhysical[0])
        XCTAssertEqual(copied.totalLogical[0], walked.totalLogical[0])
        XCTAssertEqual(names(copied), names(walked))
    }

    /// The invariant every bottom-up pass in the app relies on.
    func testEveryChildComesAfterItsParentInTheCopy() throws {
        for i in 0..<8 { try write("side/l\(i)/m/n/f.bin", 100) }
        let copied = try XCTUnwrap(reuse("side")).store
        for id in 1..<copied.count {
            XCTAssertLessThan(copied.parent[id], Int32(id), "node \(id) precedes its parent")
        }
        XCTAssertEqual(copied.parent[0], -1, "the copied root kept a parent")
    }

    /// The comparison reads these, and a wrong count is a wrong figure under
    /// each side of the screen.
    func testTheCopyCountsWhatAWalkCounts() throws {
        try write("side/a.bin", 100)
        try write("side/b.bin", 100)
        try write("side/inner/c.bin", 100)

        let copied = try XCTUnwrap(reuse("side")).stats
        let walked = DiskScanner().scan(ScanOptions(rootPath: path("side"))).stats

        XCTAssertEqual(copied.files, walked.files)
        XCTAssertEqual(copied.directories, walked.directories)
        XCTAssertEqual(copied.totalPhysical, walked.totalPhysical)
    }

    /// The end of the road: a comparison run from the scan says exactly what
    /// one run from the disk says.
    func testAComparisonFromTheScanMatchesOneFromTheDisk() throws {
        try write("left/same.bin", 2_000)
        try write("left/only-left.bin", 300)
        try write("left/inner/deep.bin", 800)
        try write("right/same.bin", 2_000)
        try write("right/inner/deep.bin", 900)

        let store = scan()
        let supplier: FolderDiff.Supplier = { folder in
            try? ScanReuse.offer(store, folder: folder, watching: true).get()
        }
        guard case .success(let fromDisk) = FolderDiff.compare(left: path("left"),
                                                               right: path("right")),
              case .success(let fromScan) = FolderDiff.compare(left: path("left"),
                                                               right: path("right"),
                                                               alreadyScanned: supplier)
        else { return XCTFail("one of the comparisons was refused") }

        XCTAssertEqual(fromScan.summary.identical, fromDisk.summary.identical)
        XCTAssertEqual(fromScan.summary.differing, fromDisk.summary.differing)
        XCTAssertEqual(fromScan.summary.onlyLeft, fromDisk.summary.onlyLeft)
        XCTAssertEqual(fromScan.summary.onlyRight, fromDisk.summary.onlyRight)
        XCTAssertEqual(fromScan.leftTotal, fromDisk.leftTotal)
        XCTAssertEqual(fromScan.rightTotal, fromDisk.rightTotal)
        XCTAssertEqual(fromScan.entries.map(\.name), fromDisk.entries.map(\.name))
        XCTAssertEqual(fromScan.entries.map(\.kind), fromDisk.entries.map(\.kind))
    }

    // MARK: - When it must refuse

    /// A tree nobody is watching could be any age. The map is allowed to be a
    /// little behind; a comparison people delete from is not.
    func testAnUnwatchedTreeIsNotOffered() throws {
        try write("side/a.bin", 100)
        XCTAssertEqual(refusal(ScanReuse.offer(scan(), folder: path("side"), watching: false)),
                       .notWatching)
    }

    func testSomethingOutsideTheScanIsNotOffered() throws {
        try write("side/a.bin", 100)
        XCTAssertEqual(refusal(ScanReuse.offer(scan(), folder: "/usr/lib", watching: true)),
                       .notScanned)
    }

    func testAFileIsNotOffered() throws {
        try write("side/a.bin", 100)
        XCTAssertEqual(refusal(ScanReuse.offer(scan(), folder: path("side/a.bin"), watching: true)),
                       .notAFolder)
    }

    /// The case this exists for. A scan that stopped somewhere inside would
    /// hand over a folder missing files that are really there, and every one of
    /// them would be reported as a difference.
    func testASubtreeTheScanDidNotFinishIsNotOffered() throws {
        try write("side/inner/deep/a.bin", 100)
        let store = scan()
        let deep = try XCTUnwrap(store.find(path: path("side/inner/deep")))
        store.flags[Int(deep)] |= NodeFlags.unreadable.rawValue

        XCTAssertEqual(refusal(ScanReuse.offer(store, folder: path("side"), watching: true)),
                       .incomplete, "an unreadable folder ten levels down was offered anyway")
    }

    func testAMountPointInsideIsNotOffered() throws {
        try write("side/inner/a.bin", 100)
        let store = scan()
        let inner = try XCTUnwrap(store.find(path: path("side/inner")))
        store.flags[Int(inner)] |= NodeFlags.mountPoint.rawValue

        XCTAssertEqual(refusal(ScanReuse.offer(store, folder: path("side"), watching: true)),
                       .incomplete)
    }

    /// A scan counts an inode's bytes once, at the first link it meets, and
    /// zeroes every later one. That is right for the disk and wrong for a
    /// folder lifted out of it: if the first link was somewhere else, the copy
    /// carries a zero where a walk of this folder alone carries the real size,
    /// and the two sides of a comparison disagree by exactly those bytes.
    func testAFolderHoldingAnExtraLinkIsNotOffered() throws {
        try write("side/linked.bin", 100)
        let store = scan()
        let linked = try XCTUnwrap(store.find(path: path("side/linked.bin")))
        store.flags[Int(linked)] |= NodeFlags.hardlinkDuplicate.rawValue

        XCTAssertEqual(refusal(ScanReuse.offer(store, folder: path("side"), watching: true)),
                       .sharedInodes)
    }

    /// The real thing, rather than a flag set by hand: a file in the compared
    /// folder that is a second link to one the scan met first somewhere else.
    func testAnExtraLinkFoundByScanningIsCaught() throws {
        try write("aaa/shared.bin", 60_000)
        try fm.createDirectory(at: root.appendingPathComponent("side"),
                               withIntermediateDirectories: true)
        try fm.linkItem(at: root.appendingPathComponent("aaa/shared.bin"),
                        to: root.appendingPathComponent("side/shared.bin"))
        let store = scan()

        // Whichever of the two the walk reached first keeps the bytes; the
        // other is the extra link. One of the two folders must be refused.
        let sideOffer = ScanReuse.offer(store, folder: path("side"), watching: true)
        let aaaOffer = ScanReuse.offer(store, folder: path("aaa"), watching: true)
        let refusals = [refusal(sideOffer), refusal(aaaOffer)].compactMap { $0 }
        XCTAssertEqual(refusals, [.sharedInodes], "the extra link was handed over anyway")
    }

    /// A tombstone left by a live update is not part of the tree any more, and
    /// neither is anything under it.
    func testRemovedNodesAreLeftBehind() throws {
        try write("side/gone/a.bin", 100)
        try write("side/stays/b.bin", 100)
        let store = scan()
        let gone = try XCTUnwrap(store.find(path: path("side/gone")))
        store.flags[Int(gone)] |= NodeFlags.removed.rawValue

        let copied = try XCTUnwrap(try? ScanReuse.offer(store, folder: path("side"),
                                                        watching: true).get()).store
        XCTAssertFalse(names(copied).contains("gone"))
        XCTAssertFalse(names(copied).contains("a.bin"))
        XCTAssertTrue(names(copied).contains("b.bin"))
    }

    // MARK: -

    private func reuse(_ name: String) -> ScanResult? {
        try? ScanReuse.offer(scan(), folder: path(name), watching: true).get()
    }

    private func refusal(_ result: Result<ScanResult, ScanReuse.Refusal>) -> ScanReuse.Refusal? {
        if case .failure(let why) = result { return why }
        return nil
    }

    private func names(_ store: NodeStore) -> Set<String> {
        Set((0..<store.count).map { store.name(Int32($0)) })
    }
}
