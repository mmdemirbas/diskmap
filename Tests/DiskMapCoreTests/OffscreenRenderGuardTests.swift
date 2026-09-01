import XCTest

/// One mistake, made six times.
///
/// A `ScrollView` has no viewport when `ImageRenderer` draws it offscreen, so
/// it measures zero and its contents simply do not appear. Every screenshot
/// check then shows a title over a blank page, and the reader concludes the
/// screen is broken rather than the capture. `viewportScroller(renderMode:)`
/// exists so this is decided once, and this test is here because knowing about
/// the helper has repeatedly not been enough to remember to use it.
final class OffscreenRenderGuardTests: XCTestCase {
    /// Where the fallback itself lives, and is allowed to say `ScrollView`.
    private let home = "Theme.swift"

    func testEveryScrollViewGoesThroughTheOffscreenFallback() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // DiskMapCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Sources/DiskMapApp")

        let names = try FileManager.default.contentsOfDirectory(atPath: app.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(names.isEmpty, "no sources found at \(app.path)")

        var offenders: [String] = []
        for name in names where name != home {
            let lines = try String(contentsOf: app.appendingPathComponent(name), encoding: .utf8)
                .components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard code.contains("ScrollView"), !code.hasPrefix("//") else { continue }
                // A hand-rolled fallback is fine as long as there is one. The
                // widest legitimate gap in this codebase is 25 lines, where the
                // offscreen branch renders a fitted prefix rather than simply
                // the same content unscrolled; 30 leaves a little room without
                // reaching past the enclosing view builder.
                let window = lines[max(0, i - 30)...i].joined()
                if !window.contains("renderMode") {
                    offenders.append("\(name):\(i + 1)  \(code)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            ScrollView without an offscreen branch — use viewportScroller(renderMode:):
            \(offenders.joined(separator: "\n"))
            """)
    }
}
