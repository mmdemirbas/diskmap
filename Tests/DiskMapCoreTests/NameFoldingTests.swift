import XCTest
import DiskMapCore
@testable import DiskMapReports
@testable import DiskMapScan

/// Two names the filesystem cannot tell apart are one name.
///
/// macOS volumes are case-insensitive by default and treat a name composed two
/// ways as one name. A copy hunt that matches raw bytes therefore walks past
/// the copies it exists to find — `Photo.jpg` beside `photo.jpg`, or an
/// accented name that arrived from something storing it decomposed. The folder
/// comparison already worked this way; these cover the two places that hunt for
/// copies.
final class NameFoldingTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: fm.temporaryDirectory.path)
            .appendingPathComponent("dmfold-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    private func store() -> NodeStore {
        DiskScanner().scan(ScanOptions(rootPath: root.path)).store
    }

    // MARK: - The rule itself

    private func hash(_ name: String) -> UInt64 {
        let bytes = Array(name.utf8)
        return bytes.withUnsafeBufferPointer {
            NameKey.hash($0, offset: 0, length: $0.count)
        }
    }

    func testCaseDoesNotChangeTheKey() {
        XCTAssertEqual(hash("Photo.JPG"), hash("photo.jpg"))
        XCTAssertNotEqual(hash("photo.jpg"), hash("photos.jpg"))
    }

    /// The same name written two ways. Nothing on this volume produces the
    /// composed form — Foundation decomposes on the way in — so the bytes are
    /// built here rather than round-tripped through a file.
    func testHowTheNameIsComposedDoesNotChangeTheKey() {
        let composed = "cafe\u{0301}".precomposedStringWithCanonicalMapping
        let decomposed = "cafe\u{0301}".decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8), "the test is not testing")
        XCTAssertEqual(hash(composed + ".txt"), hash(decomposed + ".txt"))
        XCTAssertEqual(hash("CAFÉ.txt"), hash(decomposed + ".txt"))
    }

    /// Composing before lowercasing and lowercasing before composing are not
    /// the same operation, and doing it the wrong way round leaves one name in
    /// two forms.
    func testTheFoldedFormIsStable() {
        let once = NameKey.folded("Café.TXT")
        XCTAssertEqual(NameKey.folded(once), once)
        XCTAssertEqual(NameKey.folded("cafe\u{0301}.txt"), once)
    }

    func testAnEmptyNameIsNotACrash() {
        XCTAssertEqual(hash(""), NameKey.seed)
    }

    // MARK: - What it finds

    func testFilesDifferingOnlyInCaseAreOneSetOfCopies() throws {
        try write("one/Photo.jpg", 2_000_000)
        try write("two/photo.jpg", 2_000_000)

        let found = Duplicates.find(store: store(), root: 0, minimumSize: 1_000)
        XCTAssertEqual(found.count, 1, "two spellings of one name were read as two files")
        XCTAssertEqual(found.first?.nodes.count, 2)
    }

    /// Different names still are. Folding must widen the net, not empty it.
    func testDifferentNamesAreStillDifferent() throws {
        try write("one/photo.jpg", 2_000_000)
        try write("two/picture.jpg", 2_000_000)
        XCTAssertTrue(Duplicates.find(store: store(), root: 0, minimumSize: 1_000).isEmpty)
    }

    /// The same for whole folders: the signature is what decides two folders
    /// hold the same thing, and it is built from the names inside them.
    func testFoldersWhoseFilesDifferOnlyInCaseStillMatch() throws {
        try write("left/Report.pdf", 40_000)
        try write("left/notes.txt", 20_000)
        try write("right/report.pdf", 40_000)
        try write("right/NOTES.txt", 20_000)

        let found = FolderMatches.find(store: store(), root: 0, minimumSize: 1_000)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].exact)
    }

    func testFoldersHoldingDifferentThingsStillDoNotMatch() throws {
        try write("left/report.pdf", 40_000)
        try write("right/summary.pdf", 40_000)
        XCTAssertTrue(FolderMatches.find(store: store(), root: 0, minimumSize: 1_000).isEmpty)
    }
}
