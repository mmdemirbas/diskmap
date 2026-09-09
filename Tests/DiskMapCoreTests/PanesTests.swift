import DiskMapCore
import SwiftUI
import XCTest
@testable import DiskMapApp

/// The views are not alternatives of each other.
///
/// Three pictures and four tables, and for the whole of this app's life
/// choosing one meant losing the others: a segmented picker in the toolbar
/// decided which picture existed, and another decided which table. The layout
/// code had that assumption baked into it — the cache key was built from
/// *the* visualization rather than from the one being asked for, so a request
/// for a sunburst while the treemap was current computed a treemap and filed
/// it under the sunburst's name.
@MainActor
final class PanesTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmpanes-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("a"),
                               withIntermediateDirectories: true)
        try Data(count: 800_000).write(to: root.appendingPathComponent("a/one.bin"))
        try Data(count: 300_000).write(to: root.appendingPathComponent("two.bin"))
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func ready() -> AppModel {
        let model = AppModel()
        model.adopt(LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path))))
        return model
    }

    func testEveryPictureCanBeLaidOutAtOnce() async throws {
        let model = ready()
        let size = CGSize(width: 420, height: 320)
        // Whichever one the model thinks is current must not decide what the
        // other two are allowed to be.
        model.visualization = .treemap

        await model.relayout(.treemap, size: size)
        await model.relayout(.sunburst, size: size)
        await model.relayout(.icicle, size: size)

        XCTAssertNotNil(model.cachedLayout(for: size), "no treemap")
        XCTAssertNotNil(model.cachedSunburst(for: size), "no ring chart")
        XCTAssertNotNil(model.cachedIcicle(for: size), "no layer chart")
    }

    /// Each picture is cached under its own name, so one does not answer for
    /// another at the same size.
    func testEachPictureIsKeyedByItsOwnKind() throws {
        let model = ready()
        let size = CGSize(width: 420, height: 320)
        let keys = Set(Visualization.allCases.map { model.layoutKey($0, size: size) })
        XCTAssertEqual(keys.count, Visualization.allCases.count)
    }
}
