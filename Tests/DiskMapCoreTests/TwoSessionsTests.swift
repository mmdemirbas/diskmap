import DiskMapCore
import XCTest
@testable import DiskMapApp

/// Two sessions at once.
///
/// "Work on different disks at the same time" is two independent scans, each
/// with its own tools over it. One window is one session, so the thing to hold
/// still is that two models share nothing — and that the menu bar and the
/// Finder services talk to the one in front rather than to whichever was
/// built first.
@MainActor
final class TwoSessionsTests: XCTestCase {
    private var left: URL!
    private var right: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmtwo-\(UUID().uuidString)")
        left = base.appendingPathComponent("left")
        right = base.appendingPathComponent("right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        try Data(count: 4_000).write(to: left.appendingPathComponent("a.bin"))
        try Data(count: 9_000).write(to: right.appendingPathComponent("b.bin"))
        try Data(count: 9_000).write(to: right.appendingPathComponent("c.bin"))
    }
    override func tearDownWithError() throws {
        if let left { try? fm.removeItem(at: left.deletingLastPathComponent()) }
    }

    private func session(_ root: URL) -> AppModel {
        let m = AppModel()
        m.clearTargets()
        m.addTargets([root])
        m.scanSynchronously()
        return m
    }

    /// Nothing is shared: two scans, two trees, two sets of totals.
    func testTwoSessionsMeasureTheirOwnFolders() throws {
        let a = session(left)
        let b = session(right)

        XCTAssertNotNil(a.tree)
        XCTAssertNotNil(b.tree)
        XCTAssertEqual(a.stats?.files, 1)
        XCTAssertEqual(b.stats?.files, 2)
        XCTAssertNotEqual(a.tree?.roots, b.tree?.roots)
    }

    /// A tool opened in one window does not open in the other, which is the
    /// whole point: two copy hunts, two folders, at once.
    func testAToolOpenedInOneSessionStaysThere() {
        let a = session(left)
        let b = session(right)

        a.openTool(.duplicates)

        XCTAssertTrue(a.openTabs.contains(.duplicates))
        XCTAssertFalse(b.openTabs.contains(.duplicates))
    }

    /// A service lands in the window the user was last looking at.
    func testAServiceGoesToTheSessionInFront() {
        let a = session(left)
        let b = session(right)
        let provider = ServicesProvider.shared

        provider.use(a)
        provider.use(b)
        XCTAssertTrue(provider.model === b)

        provider.use(a)
        XCTAssertTrue(provider.model === a)
    }

    /// A closed window must not go on receiving services. The registry holds
    /// its sessions weakly for exactly this, and a stale entry would otherwise
    /// swallow every right-click in the Finder.
    func testAClosedSessionStopsReceivingThem() {
        let provider = ServicesProvider.shared
        let survivor = session(left)
        provider.use(survivor)

        var closing: AppModel? = session(right)
        provider.use(closing!)
        XCTAssertTrue(provider.model === closing)

        closing = nil
        XCTAssertTrue(provider.model === survivor)
    }
}
