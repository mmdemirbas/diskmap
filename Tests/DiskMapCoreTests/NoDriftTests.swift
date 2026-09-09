import DiskMapCore
import SwiftUI
import XCTest
@testable import DiskMapApp

/// The details panel must be exactly as tall with nothing selected as with
/// anything selected, and the same height for every selection.
///
/// A panel that grows when you click something pushes the list underneath it
/// down, so the row under the pointer is no longer the row under the pointer.
/// This measures the rendered height directly rather than trusting that the
/// rows look reserved in the source.
@MainActor
final class NoDriftTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmdrift-\(UUID().uuidString)")
        let deep = root.appendingPathComponent(
            "a-directory-with-a-long-name/and-another-one-inside-it/going-deeper-still")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: root.appendingPathComponent("s.bin"))
        try Data(count: 120_000).write(to: deep.appendingPathComponent(
            "a-file-whose-name-runs-on-well-past-what-one-line-of-the-panel-can-show.bin"))
        // Sparse: apparent size far ahead of the blocks it occupies, which is
        // what puts the mark next to the apparent figure.
        let sparse = root.appendingPathComponent("sparse.bin")
        fm.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 64 << 20)
        try handle.close()
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func model() -> AppModel {
        let m = AppModel()
        m.adopt(LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path))))
        return m
    }

    /// Rendered height of the panel at the narrowest width the side panel can
    /// take, where wrapping is most likely to differ between items.
    private func panelHeight(_ m: AppModel) -> CGFloat {
        measure(DetailsPanel(model: m))
    }

    /// What the panel would take if it were not pinned.
    private func naturalHeight(_ m: AppModel) -> CGFloat {
        measure(DetailsPanel(model: m).content)
    }

    private func measure<V: View>(_ view: V) -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: 340))
        renderer.scale = 2
        return renderer.nsImage?.size.height ?? -1
    }

    private func allNodes(_ m: AppModel) -> [Int32] {
        m.tree!.withStore { store in
            var out: [Int32] = []
            var stack: [Int32] = [0]
            while let n = stack.popLast() {
                out.append(n)
                for c in store.children(n) { stack.append(c) }
            }
            return out
        }
    }

    func testTheDetailsPanelIsTheSameHeightWhateverIsSelected() throws {
        let m = model()

        m.selection = nil
        m.selectedInfo = nil
        let empty = panelHeight(m)
        XCTAssertGreaterThan(empty, 0, "the panel did not render")

        var heights: [String: CGFloat] = ["<nothing selected>": empty]
        for node in allNodes(m) {
            m.select(node)
            guard let info = m.selectedInfo else { continue }
            heights[info.name.isEmpty ? "<root>" : info.name] = panelHeight(m)
        }
        XCTAssertGreaterThan(heights.count, 4, "not enough distinct selections to be a test")

        let distinct = Set(heights.values)
        XCTAssertEqual(distinct.count, 1, """
            the panel changes height between selections, so everything under it moves:
            \(heights.sorted { $0.value < $1.value }
                     .map { "  \($0.value)  \($0.key)" }.joined(separator: "\n"))
            """)
    }

    /// The fixed height has to be big enough for every selection, or the
    /// panel stops drifting by clipping its own last row instead.
    func testNothingIsClipped() throws {
        let m = model()
        var worst: (name: String, height: CGFloat) = ("<nothing selected>", 0)
        m.selection = nil
        m.selectedInfo = nil
        worst = ("<nothing selected>", naturalHeight(m))
        for node in allNodes(m) {
            m.select(node)
            guard let info = m.selectedInfo else { continue }
            let h = naturalHeight(m)
            if h > worst.height { worst = (info.name, h) }
        }
        XCTAssertLessThanOrEqual(worst.height, DetailsPanel.height, """
            \"\(worst.name)\" needs \(worst.height)pt but the panel is pinned to \
            \(DetailsPanel.height)pt, so its last row is being cut off
            """)
    }

    /// The line that says what the file is — dimensions, length, when it was
    /// taken — arrives after the panel has already been drawn, because it comes
    /// from Spotlight rather than from the scan. A row that appears when the
    /// answer arrives would move everything under it at that moment, which is
    /// the worst possible time for the panel to move.
    func testTheIndexLineNeverChangesThePanelsHeight() throws {
        let m = model()
        let file = try XCTUnwrap(allNodes(m).first { node in
            m.select(node)
            return m.selectedInfo?.isDirectory == false
        })
        m.select(file)
        let waiting = panelHeight(m)

        var absurd = ContentProperties()
        absurd.indexed = true
        absurd.contentType = "com.apple.quicktime-movie"
        absurd.pixelWidth = 999_999
        absurd.pixelHeight = 999_999
        absurd.durationSeconds = 36_000
        absurd.created = Date()
        absurd.codecs = ["H.264", "AAC", "ProRes 4444 XQ", "something with a very long name"]
        m.map.selectedContent = absurd

        XCTAssertEqual(panelHeight(m), waiting, "the panel moved when the answer arrived")
        XCTAssertLessThanOrEqual(naturalHeight(m), DetailsPanel.height,
                                 "the line is being cut off rather than fitting")
    }

    /// The sparse file is the one that used to add a whole row to the panel.
    /// If the fixture stops being sparse the test above still passes while
    /// having quietly stopped covering the case that caused the bug.
    func testTheSparseFixtureReallyIsSparse() throws {
        let m = model()
        let node = try XCTUnwrap(m.tree!.withStore {
            $0.find(path: root.appendingPathComponent("sparse.bin").path)
        })
        m.select(node)
        let info = try XCTUnwrap(m.selectedInfo)
        XCTAssertGreaterThan(info.logical, info.physical * 2,
                             "fixture no longer triggers the apparent-size note")
    }
}
