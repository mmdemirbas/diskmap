import DiskMapCore
import XCTest
@testable import DiskMapApp

/// Picking two folders one at a time.
///
/// The Finder hands over what is selected, and two folders in different places
/// cannot be selected together — so the only way to compare them is a
/// right-click each. The app has to remember the first pick and know that the
/// second one is the other side rather than a new question.
@MainActor
final class CompareHandoffTests: XCTestCase {
    private var base: URL!
    private var a: URL!
    private var b: URL!
    private var c: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmhand-\(UUID().uuidString)")
        a = base.appendingPathComponent("one/left")
        b = base.appendingPathComponent("two/right")
        c = base.appendingPathComponent("three/other")
        for url in [a, b, c] {
            try fm.createDirectory(at: url!, withIntermediateDirectories: true)
            try Data(count: 1_000).write(to: url!.appendingPathComponent("f.bin"))
        }
    }
    override func tearDownWithError() throws { if let base { try? fm.removeItem(at: base) } }

    func testTheFirstPickWaitsAndTheSecondStartsTheComparison() {
        let m = AppModel()

        XCTAssertEqual(m.offerToCompare(a), .left)
        XCTAssertEqual(m.compareLeft, a.path)
        XCTAssertTrue(m.compareRight.isEmpty, "one pick already claimed both sides")

        XCTAssertEqual(m.offerToCompare(b), .right)
        XCTAssertEqual(m.compareLeft, a.path)
        XCTAssertEqual(m.compareRight, b.path)
    }

    /// A third pick is the next question, not a third answer to this one.
    func testAThirdPickStartsOver() {
        let m = AppModel()
        m.offerToCompare(a)
        m.offerToCompare(b)

        XCTAssertEqual(m.offerToCompare(c), .left)
        XCTAssertEqual(m.compareLeft, c.path)
        XCTAssertTrue(m.compareRight.isEmpty, "the old right side was left standing")
    }

    /// Right-clicking the same folder twice is a slip. Taking it as the other
    /// side would compare a folder with itself, which the comparison refuses —
    /// so the user would be told off for a double click.
    func testTheSameFolderTwiceIsNotTwoSides() {
        let m = AppModel()
        m.offerToCompare(a)

        XCTAssertEqual(m.offerToCompare(a), .left)
        XCTAssertEqual(m.compareLeft, a.path)
        XCTAssertTrue(m.compareRight.isEmpty)
    }

    /// A file means the folder holding it, the same way a file dropped onto a
    /// well does. Somebody who right-clicked a file inside the folder they meant
    /// has made a near miss, not a mistake worth refusing.
    func testAFileMeansItsFolder() {
        let m = AppModel()
        m.offerToCompare(a.appendingPathComponent("f.bin"))
        XCTAssertEqual(m.compareLeft, a.path)
    }

    /// Something that is not there at all leaves the sides alone rather than
    /// filling one with a path that cannot be walked.
    func testSomethingThatIsNotThereChangesNothing() {
        let m = AppModel()
        m.offerToCompare(a)
        XCTAssertNil(m.offerToCompare(base.appendingPathComponent("gone")))
        XCTAssertEqual(m.compareLeft, a.path)
        XCTAssertTrue(m.compareRight.isEmpty)
    }
}
