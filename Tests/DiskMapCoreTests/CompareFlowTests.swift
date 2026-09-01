import AppKit
import DiskMapCore
import SwiftUI
import XCTest
@testable import DiskMapApp

/// The comparison from the app's side: pick two folders, look at the
/// difference, read the plan, carry it out.
///
/// The core has its own tests for what a plan contains. This one exists because
/// the app layer hops between actors three times on the way — the walk, the
/// plan, the run — and a screen that never leaves "reading both folders…" is a
/// bug no core test can see.
@MainActor
final class CompareFlowTests: XCTestCase {
    private var root: URL!
    private var left: URL!
    private var right: URL!
    private let fm = FileManager.default
    private var trashed: [URL] = []

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmflow-\(UUID().uuidString)")
        left = root.appendingPathComponent("left")
        right = root.appendingPathComponent("right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        left = URL(fileURLWithPath: canonicalPath(left.path) ?? left.path)
        right = URL(fileURLWithPath: canonicalPath(right.path) ?? right.path)
    }

    override func tearDownWithError() throws {
        for url in trashed { try? fm.removeItem(at: url) }
        trashed = []
        if let root { try? fm.removeItem(at: root) }
    }

    private func write(_ base: URL, _ relative: String, bytes: Int) throws {
        let url = base.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    /// The model does its work on detached tasks, so a test has to wait for the
    /// state rather than for a call to return.
    private func waitFor(_ what: String, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func model() -> AppModel {
        let m = AppModel()
        m.compareLeft = left.path
        m.compareRight = right.path
        return m
    }

    func testTheWholeWayThroughFromPickingToWriting() async throws {
        try write(left, "keep.bin", bytes: 400)
        try write(right, "keep.bin", bytes: 400)
        try write(left, "new/deep.bin", bytes: 900)
        try write(right, "stale.bin", bytes: 700)

        let m = model()
        m.runComparison()
        try await waitFor("the comparison") { m.folderComparison != nil }

        let comparison = try XCTUnwrap(m.folderComparison)
        XCTAssertEqual(comparison.summary.onlyLeft, 2, "the folder and the file inside it")
        XCTAssertEqual(comparison.summary.onlyRight, 1)
        XCTAssertFalse(m.compareRows.isEmpty, "the list would be empty on screen")

        m.syncDirection = .mirrorLeftToRight
        m.previewSync()
        XCTAssertEqual(m.comparePage, .plan)
        let plan = try XCTUnwrap(m.syncPlan)
        XCTAssertEqual(plan.steps.count, 2)

        m.runSync()
        XCTAssertEqual(m.comparePage, .result)
        try await waitFor("the sync") { m.syncOutcome != nil }
        let outcome = try XCTUnwrap(m.syncOutcome)
        trashed += outcome.trashed.compactMap(\.trashURL)
        XCTAssertTrue(outcome.succeeded, "\(outcome.failures)")

        XCTAssertTrue(fm.fileExists(atPath: right.path + "/new/deep.bin"))
        XCTAssertFalse(fm.fileExists(atPath: right.path + "/stale.bin"))

        // And the screen no longer claims the old difference, because the
        // folders it described no longer exist in that shape.
        XCTAssertNil(m.folderComparison)
    }

    /// Ticking "show matching items too" must not go back to the disk: the
    /// comparison is already in hand and re-walking it would be seconds of
    /// nothing on a screen that was showing an answer a moment ago.
    func testShowingMatchesJustRebuildsTheRows() async throws {
        for base in [left!, right!] { try write(base, "same.bin", bytes: 100) }
        try write(left, "extra.bin", bytes: 50)

        let m = model()
        m.runComparison()
        try await waitFor("the comparison") { m.folderComparison != nil }
        XCTAssertEqual(m.compareRows.count, 1)

        m.showMatchingToo = true
        m.rebuildCompareRows()
        XCTAssertEqual(m.compareRows.count, 2)
        XCTAssertEqual(m.compareRowsOmitted, 0)
    }

    /// Rows are biggest first, because that is the order in which the decisions
    /// are worth making.
    func testRowsAreBiggestFirst() async throws {
        try write(left, "small.bin", bytes: 1_000)
        try write(left, "large.bin", bytes: 900_000)
        try write(left, "middle.bin", bytes: 60_000)
        try write(right, "placeholder.bin", bytes: 10)

        let m = model()
        m.runComparison()
        try await waitFor("the comparison") { m.folderComparison != nil }
        XCTAssertGreaterThan(m.compareRows.count, 3, "not enough rows to be a test")
        let sizes = m.compareRows.map { max($0.leftBytes, $0.rightBytes) }
        XCTAssertEqual(sizes, sizes.sorted(by: >))
    }

    func testARefusalReachesTheScreenRatherThanAnEmptyList() async throws {
        let m = AppModel()
        m.compareLeft = left.path
        m.compareRight = left.path
        m.runComparison()
        try await waitFor("the refusal") { m.compareRefusal != nil }
        XCTAssertEqual(m.compareRefusal, .sameFolder(left.path))
        XCTAssertNil(m.folderComparison)
    }

    // MARK: - The screen itself

    /// Every page draws at the same size — the outer frame sees to that — and
    /// each one draws something of its own.
    func testEveryPageDrawsItsOwnContent() async throws {
        try write(left, "a-long-enough-name-to-see.bin", bytes: 400_000)
        try write(right, "b-another-visible-name.bin", bytes: 500_000)

        let m = model()
        m.renderMode = true
        m.runComparison()
        try await waitFor("the comparison") { m.folderComparison != nil }

        m.comparePage = .diff
        let diff = try XCTUnwrap(render(CompareView(model: m)), "the difference page drew nothing")
        m.previewSync()
        m.comparePage = .plan
        let plan = try XCTUnwrap(render(CompareView(model: m)), "the plan page drew nothing")
        m.comparePage = .result
        let result = try XCTUnwrap(render(CompareView(model: m)), "the result page drew nothing")

        let sizes = [diff.size, plan.size, result.size]
        XCTAssertEqual(Set(sizes.map(\.height)).count, 1, "\(sizes)")
        XCTAssertEqual(Set(sizes.map(\.width)).count, 1, "\(sizes)")
        XCTAssertNotEqual(diff.data, plan.data, "two pages, one drawing")
        XCTAssertNotEqual(plan.data, result.data, "two pages, one drawing")
    }

    /// The list, drawn on its own.
    ///
    /// Asked of the whole sheet this question cannot be answered: the header
    /// above the list draws either way, so a list that renders nothing still
    /// changes the picture. Two different row sets must produce two different
    /// pictures, which a list drawing nothing cannot do.
    func testTheRowsThemselvesReachThePageOffscreen() async throws {
        for i in 0..<12 { try write(left, "difference-\(i).bin", bytes: 10_000 + i * 97) }

        let many = model()
        many.renderMode = true
        many.runComparison()
        try await waitFor("the wide comparison") { many.folderComparison != nil }
        XCTAssertGreaterThan(many.compareRows.count, 6, "not enough rows to be a test")

        // The same screen with one row in it.
        let few = AppModel()
        few.renderMode = true
        few.folderComparison = many.folderComparison
        few.rebuildCompareRows()
        few.folderComparison?.entries = Array(many.folderComparison!.entries.prefix(1))
        few.rebuildCompareRows()
        XCTAssertEqual(few.compareRows.count, 1)

        let wide = try XCTUnwrap(render(DiffRowList(model: many)), "the list drew nothing")
        let narrow = try XCTUnwrap(render(DiffRowList(model: few)), "the list drew nothing")
        XCTAssertNotEqual(wide.data, narrow.data,
                          "twelve rows and one row drew the same picture, so the rows are not there")
    }

    private func render<V: View>(_ view: V) -> (data: Data, size: CGSize)? {
        let renderer = ImageRenderer(content: view.frame(width: 900, height: 660))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, CGSize(width: cg.width, height: cg.height))
    }
}
