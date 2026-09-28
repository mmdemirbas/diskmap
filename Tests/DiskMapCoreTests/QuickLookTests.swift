import DiskMapCore
import XCTest
@testable import DiskMapApp

/// What Quick Look is asked to show. The panel itself is the system's; the
/// app's part is the URL it hands over, and when.
@MainActor
final class QuickLookTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmql-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt"] { try Data(count: 100).write(to: root.appendingPathComponent(name)) }
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func scanned() -> AppModel {
        let m = AppModel()
        m.clearTargets()
        m.addTargets([root])
        m.scanSynchronously()
        return m
    }

    private func node(_ m: AppModel, _ name: String) throws -> Int32 {
        try XCTUnwrap(m.tree?.withStore { $0.find(path: root.appendingPathComponent(name).path) })
    }

    /// The same key opens and closes it, as the space bar does in the Finder.
    func testTheSameCommandOpensAndClosesIt() throws {
        let m = scanned()
        let a = try node(m, "a.txt")
        m.quickLook(a)
        XCTAssertEqual(m.quickLookURL?.lastPathComponent, "a.txt")
        m.quickLook(a)
        XCTAssertNil(m.quickLookURL)
    }

    /// Open, it follows the selection; closed, a selection does not open it.
    func testAnOpenPanelFollowsTheSelectionAndAClosedOneStaysClosed() throws {
        let m = scanned()
        let a = try node(m, "a.txt"), b = try node(m, "b.txt")
        m.select(b)
        XCTAssertNil(m.quickLookURL, "a selection opened the panel")

        m.select(a)
        m.quickLook(a)
        m.select(b)
        XCTAssertEqual(m.quickLookURL?.lastPathComponent, "b.txt", "the panel kept the old file")

        m.select(nil)
        XCTAssertNil(m.quickLookURL, "nothing selected, and the panel still showed a file")
    }
}
