import DiskMapCore
import XCTest
@testable import DiskMapApp

/// The home screen and the one entry point behind it.
///
/// Two of the tools — the flat table and the copies list — had no way in from
/// anywhere in the interface: no menu item, no button, nothing. They were
/// built, tested, and unreachable. These tests are about the wiring rather than
/// the drawing, because that is where the gap was.
@MainActor
final class HomeTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmhome-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("inner"),
                               withIntermediateDirectories: true)
        try Data(count: 4_000).write(to: root.appendingPathComponent("inner/a.bin"))
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func scanned() -> AppModel {
        let m = AppModel()
        m.clearTargets()
        m.addTargets([root])
        m.scanSynchronously()
        return m
    }

    /// The whole point of the screen. Adding a tool and forgetting to show it
    /// is the failure this catches, and it is the failure that happened.
    func testHomeOffersEveryToolThereIs() {
        XCTAssertEqual(Set(ModuleTab.tools).union([.home]), Set(ModuleTab.allCases))
        XCTAssertFalse(ModuleTab.tools.contains(.home))
        XCTAssertEqual(ModuleTab.tools.count, ModuleTab.allCases.count - 1)
    }

    /// Every tool is reachable by keyboard too, and no two share a shortcut —
    /// a clash means one of them silently never fires.
    func testEveryToolHasItsOwnShortcutAndItsOwnBlurb() {
        let shortcuts = ModuleTab.allCases.map { String($0.shortcut.character) }
        XCTAssertEqual(Set(shortcuts).count, ModuleTab.allCases.count, "duplicate shortcut")
        let blurbs = ModuleTab.allCases.map(\.blurb)
        XCTAssertEqual(Set(blurbs).count, ModuleTab.allCases.count, "duplicate blurb")
    }

    /// Home is where the app lands, and it cannot be closed out from under the
    /// user — closing the last tool would otherwise leave nothing on screen.
    func testTheAppOpensOnHomeAndHomeStays() {
        let m = AppModel()
        XCTAssertEqual(m.activeTab, .home)
        XCTAssertTrue(m.openTabs.contains(.home))
        XCTAssertFalse(ModuleTab.home.isClosable)

        m.close(.home)
        XCTAssertTrue(m.openTabs.contains(.home))
    }

    /// A card that opens an empty screen is worse than no card. Opening the
    /// table from anywhere has to fill it, and `open` alone does not — which is
    /// why there is a second entry point that does.
    func testOpeningTheTableFromHomeFillsIt() throws {
        let m = scanned()
        m.openTool(.files)

        XCTAssertEqual(m.activeTab, .files)
        // The page loads on a debounce, so this asserts the request was made
        // rather than that the rows have landed.
        XCTAssertTrue(m.files.loading || !m.files.page.rows.isEmpty,
                      "the table opened without asking for a page")
    }

    /// Same for the cleanup search: opening it starts it.
    func testOpeningCleanupFromHomeStartsTheSearch() {
        let m = scanned()
        m.openTool(.space)

        XCTAssertEqual(m.activeTab, .space)
        XCTAssertTrue(m.suggestionsLoading)
    }

    /// Opening a tool never closes another. That was the complaint that turned
    /// the sheets into tabs, and the home screen is a new way to trip over it.
    func testOpeningToolsFromHomeStacksThemUp() {
        let m = scanned()
        for tab in ModuleTab.tools { m.openTool(tab) }
        for tab in ModuleTab.tools {
            XCTAssertTrue(m.openTabs.contains(tab), "\(tab) closed when the next one opened")
        }
    }

    /// The strip is ordered by the enum, so home is first and the map second
    /// however the tools were opened.
    func testTheStripKeepsHomeFirst() {
        let m = scanned()
        m.openTool(.changes)
        m.openTool(.compare)
        XCTAssertEqual(m.openTabs.first, .home)
    }
}