import DiskMapCore
import XCTest
@testable import DiskMapApp

/// The flat table as the user drives it: which way a column sorts, what a
/// filter does to the page you are on, and what happens to it when the tree it
/// is a view of goes away.
@MainActor
final class FilesTableTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmfiles-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("inner"),
                               withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int) throws {
        try Data(count: bytes).write(to: root.appendingPathComponent(path))
    }

    /// A model with a scanned tree and the table filled in, without any of the
    /// async phases a real window would go through.
    private func loaded() throws -> AppModel {
        let m = AppModel()
        m.clearTargets()
        m.addTargets([root])
        m.scanSynchronously()
        m.open(.files)
        m.files.reloadSynchronously(in: try XCTUnwrap(m.tree))
        return m
    }

    private func reload(_ m: AppModel) throws {
        m.files.reloadSynchronously(in: try XCTUnwrap(m.tree))
    }

    // MARK: - The headings are the controls

    /// Clicking a heading that is already sorted reverses it. Clicking a
    /// different one starts it the way that column is read: names from A, sizes
    /// and dates from the top, because nobody opens a disk analyser to find
    /// their smallest file.
    func testAColumnStartsTheWayItIsReadAndReversesOnASecondClick() throws {
        try write("a.bin", 1_000)
        let m = try loaded()

        XCTAssertEqual(m.files.sort, .size)
        XCTAssertFalse(m.files.ascending)

        m.sortFiles(by: .size)
        XCTAssertTrue(m.files.ascending, "clicking the sorted column did not reverse it")

        m.sortFiles(by: .name)
        XCTAssertEqual(m.files.sort, .name)
        XCTAssertTrue(m.files.ascending, "names should start at A")

        m.sortFiles(by: .modified)
        XCTAssertFalse(m.files.ascending, "dates should start at the newest")
    }

    // MARK: - Paging

    func testShowMoreGrowsTheListAndAFilterPutsItBack() throws {
        for i in 0..<(FilesModule.pageSize + 20) { try write("f\(i).bin", 1_000) }
        let m = try loaded()

        XCTAssertEqual(m.files.page.rows.count, FilesModule.pageSize)
        XCTAssertGreaterThan(m.files.page.total, FilesModule.pageSize)

        m.files.showMore(in: m.tree)
        try reload(m)
        XCTAssertEqual(m.files.page.rows.count, m.files.page.total)

        // Rows already fetched are not rows in the new answer, so growing past
        // them would be growing past something that is no longer there.
        m.filesSize = .mb1
        m.resetFiles()
        XCTAssertEqual(m.files.limit, FilesModule.pageSize)
    }

    // MARK: - Filters

    func testFilteringNarrowsTheRowsAndClearingBringsThemBack() throws {
        try write("clip.mp4", 900_000)
        try write("notes.txt", 1_000)
        let m = try loaded()
        XCTAssertEqual(m.files.page.total, 2)

        m.filesKinds = [.video]
        try reload(m)
        XCTAssertEqual(m.files.page.rows.map(\.name), ["clip.mp4"])
        XCTAssertTrue(m.files.isFiltered)

        m.clearFileFilters()
        try reload(m)
        XCTAssertEqual(m.files.page.total, 2)
        XCTAssertFalse(m.files.isFiltered)
    }

    /// "Untouched for a year" has to mean a year before now, not a year before
    /// whenever the menu was built.
    func testATimeBandIsMeasuredFromNow() throws {
        try write("a.bin", 1_000)
        let m = try loaded()
        m.filesTime = .overAYear

        let cutoff = m.files.filter.modifiedBefore
        let expected = Int32(Date().timeIntervalSince1970 - 365 * 86_400)
        XCTAssertEqual(Double(cutoff), Double(expected), accuracy: 5)
        XCTAssertEqual(m.files.filter.modifiedAfter, 0)
    }

    func testTurningFoldersOnCountsAsAFilterSoItCanBeCleared() throws {
        try write("inner/a.bin", 1_000)
        let m = try loaded()

        m.filesShowFolders = true
        try reload(m)
        XCTAssertTrue(m.files.page.rows.contains { $0.name == "inner" })

        m.clearFileFilters()
        try reload(m)
        XCTAssertFalse(m.files.page.rows.contains { $0.name == "inner" },
                       "clearing the filters left the folders switched on")
    }

    // MARK: - It is a view of a tree

    /// Node ids mean nothing across two scans, so a row left over from the
    /// previous tree would point at whatever now sits at that index.
    func testMeasuringSomethingElseEmptiesTheTable() throws {
        try write("a.bin", 1_000)
        let m = try loaded()
        XCTAssertFalse(m.files.page.rows.isEmpty)

        m.newScan()
        XCTAssertTrue(m.files.page.rows.isEmpty)
        XCTAssertEqual(m.files.page.total, 0)
    }

    /// Opening a tool no longer closes the one that was there, and closing this
    /// one stops it holding a page of a tree nobody is looking at.
    func testTheTableIsATabLikeTheRestAndClosesCleanly() throws {
        try write("a.bin", 1_000)
        let m = try loaded()
        m.open(.search)

        XCTAssertTrue(m.openTabs.contains(.files), "opening another tool closed this one")
        XCTAssertEqual(m.activeTab, .search)

        m.close(.files)
        XCTAssertFalse(m.openTabs.contains(.files))
        XCTAssertTrue(m.files.page.rows.isEmpty)
    }

    /// A row is a way into the map, not a dead end: showing it opens the folder
    /// it lives in and puts the selection on it.
    func testARowLeadsBackIntoTheMap() throws {
        try write("inner/a.bin", 1_000)
        let m = try loaded()
        let row = try XCTUnwrap(m.files.page.rows.first { $0.name == "a.bin" })

        m.focus(node: row.node)

        XCTAssertEqual(m.activeTab, .map)
        XCTAssertEqual(m.selection, row.node)
        XCTAssertEqual(m.tree?.withStore { $0.name(m.currentDirectory) }, "inner")
    }
}
