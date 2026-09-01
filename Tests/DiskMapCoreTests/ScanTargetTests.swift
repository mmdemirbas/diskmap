import DiskMapCore
import XCTest
@testable import DiskMapApp

/// A disk and a folder are the same kind of scan target.
///
/// They used to be two mechanisms: a picker that chose exactly one volume, and
/// a separate list of folders that hid the picker as soon as it had anything in
/// it. Between them there was no way to measure two disks at once.
@MainActor
final class ScanTargetTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmtarget-\(UUID().uuidString)")
        for name in ["one", "two", "one/inside"] {
            try fm.createDirectory(at: root.appendingPathComponent(name),
                                   withIntermediateDirectories: true)
        }
        try Data(count: 40_000).write(to: root.appendingPathComponent("one/a.bin"))
        try Data(count: 70_000).write(to: root.appendingPathComponent("two/b.bin"))
        try Data(count: 10_000).write(to: root.appendingPathComponent("one/inside/c.bin"))
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    func testSeveralLocationsAreMeasuredAsOneTotal() throws {
        let m = AppModel()
        m.clearTargets()
        m.addTargets([url("one"), url("two")])
        XCTAssertEqual(m.scanTargets.count, 2)
        XCTAssertTrue(m.canScan)

        m.scanSynchronously()
        XCTAssertEqual(m.phase, .ready)
        // 40k + 10k under one, 70k under two.
        XCTAssertEqual(m.tree?.withStore { $0.totalLogical[0] }, 120_000)
        XCTAssertEqual(m.tree?.roots.count, 2)
    }

    /// Adding a folder no longer hides the disks, which is what made two disks
    /// impossible to ask for.
    func testDisksAndFoldersCoexistInOneList() throws {
        let m = AppModel()
        m.clearTargets()
        m.addTargets([url("one")])
        guard let disk = m.volumes.first(where: { $0.path == "/" }) else {
            throw XCTSkip("no startup volume in the mounted list")
        }
        m.toggle(disk)
        XCTAssertTrue(m.isTargeted(disk))
        XCTAssertTrue(m.scanTargets.contains("/"))
        XCTAssertTrue(m.scanTargets.contains { $0.hasSuffix("/one") },
                      "choosing a disk threw away the folders")

        m.toggle(disk)
        XCTAssertFalse(m.isTargeted(disk))
        XCTAssertTrue(m.scanTargets.contains { $0.hasSuffix("/one") })
    }

    /// The rule that keeps a total honest: a folder inside another chosen
    /// target is dropped rather than counted twice.
    func testAFolderInsideAnotherTargetIsNotCountedTwice() throws {
        let m = AppModel()
        m.clearTargets()
        m.addTargets([url("one"), url("one/inside")])
        XCTAssertEqual(m.scanTargets.count, 1)
        XCTAssertEqual(m.rejectedRoots.count, 1)
        m.scanSynchronously()
        XCTAssertEqual(m.tree?.withStore { $0.totalLogical[0] }, 50_000)
    }

    /// There is no hidden fallback any more: an empty list means the button is
    /// off, not that some volume nobody chose gets measured instead.
    func testAnEmptyListScansNothing() throws {
        let m = AppModel()
        m.clearTargets()
        XCTAssertFalse(m.canScan)
        m.scan()
        XCTAssertEqual(m.phase, .idle)
    }

    /// Opening the app with nothing to do would be a worse default than the
    /// picker it replaced.
    func testTheAppOpensWithSomethingChosen() throws {
        let m = AppModel()
        XCTAssertTrue(m.canScan)
        XCTAssertFalse(m.scanTargets.isEmpty)
    }

    /// One capacity bar per disk in the total.
    func testEachMeasuredDiskGetsItsOwnCapacityBar() throws {
        let m = AppModel()
        m.clearTargets()
        m.addTargets([url("one"), url("two")])
        // Both fixtures are on the same volume, so they describe one disk.
        XCTAssertEqual(m.targetedVolumes.count, 1)
        XCTAssertFalse(m.targetedVolumes.isEmpty)
    }

    /// The default has to be one of the rows the disk list actually shows, or
    /// it appears nowhere and reads as a stray folder instead.
    func testTheDefaultTargetIsTickedInTheDiskList() throws {
        let m = AppModel()
        guard let startup = m.volumes.first(where: { $0.path == "/" }) else {
            throw XCTSkip("no startup volume in the mounted list")
        }
        XCTAssertTrue(m.isTargeted(startup),
                      "the app opens with a target that is not shown as chosen")
        let diskPaths = Set(m.volumes.map(\.path))
        XCTAssertTrue(m.scanTargets.allSatisfy { diskPaths.contains($0) },
                      "a default target is showing up in the folder section")
    }
}
