import DiskMapCore
import XCTest
@testable import DiskMapApp

/// What a folder dropped onto a screen means.
///
/// Three screens take this drop and each wrote the two lines itself, which is
/// how the flat table and the copies list came to take no drop at all — there
/// was nothing to notice was missing. One method now, and the screens call it.
@MainActor
final class DropTargetTests: XCTestCase {
    private var base: URL!
    private var first: URL!
    private var second: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmdrop-\(UUID().uuidString)")
        first = base.appendingPathComponent("one")
        second = base.appendingPathComponent("two")
        for url in [first, second] {
            try fm.createDirectory(at: url!, withIntermediateDirectories: true)
            try Data(count: 2_000).write(to: url!.appendingPathComponent("f.bin"))
        }
    }
    override func tearDownWithError() throws { if let base { try? fm.removeItem(at: base) } }

    func testDroppingAFolderMeasuresItAlongsideWhatIsAlreadyThere() {
        let m = AppModel()
        m.clearTargets()
        m.addTargets([first])
        m.scanSynchronously()
        let before = m.stats?.files ?? 0

        XCTAssertTrue(m.measureAlso([second]))
        m.scanSynchronously()

        XCTAssertGreaterThan(m.stats?.files ?? 0, before)
        XCTAssertEqual(m.tree?.roots.count, 2)
    }

    /// A drop that carried nothing is refused, so the drop target says no
    /// rather than throwing away the scan that is already on screen.
    func testAnEmptyDropIsRefused() {
        let m = AppModel()
        m.clearTargets()
        m.addTargets([first])
        m.scanSynchronously()

        XCTAssertFalse(m.measureAlso([]))
        XCTAssertEqual(m.tree?.roots.count, 1)
    }

    /// The chooser is deliberately not one of these screens: dropping onto a
    /// list of things to scan adds to the list, and starting the scan there
    /// would take the choice away.
    func testTheChooserAddsWithoutStarting() {
        let m = AppModel()
        m.clearTargets()

        m.addTargets([first, second])

        XCTAssertNil(m.tree, "the chooser started a scan on its own")
        XCTAssertEqual(m.scanTargets.count, 2)
    }
}
