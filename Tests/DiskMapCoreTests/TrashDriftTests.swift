import XCTest
import DiskMapCore
@testable import DiskMapScan

/// What happens between the review screen appearing and the button being
/// pressed. Everything here goes to the Trash, so nothing is unrecoverable —
/// but a plan is a description of the files that were there.
final class TrashDriftTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var trashed: [URL] = []

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmdrift-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in trashed { try? fm.removeItem(at: url) }
        trashed = []
        if let root { try? fm.removeItem(at: root) }
    }

    func testAnItemThatChangedSincePlanningIsNotTrashed() throws {
        let doomed = root.appendingPathComponent("doomed.bin")
        try Data(repeating: 1, count: 400).write(to: doomed)

        // What the plan saw.
        var seen = stat()
        XCTAssertEqual(lstat(doomed.path, &seen), 0)
        let target = FileActions.Target(
            url: doomed, node: 7, bytes: 400, isFolder: false, length: 400,
            modified: Int32(truncatingIfNeeded: seen.st_mtimespec.tv_sec))

        // Something else takes its place while the screen is up.
        try fm.removeItem(at: doomed)
        try Data(repeating: 9, count: 90_000).write(to: doomed)

        let (done, failures) = try FileActions.moveToTrash([target])
        for item in done { if let url = item.trashURL { trashed.append(url) } }
        XCTAssertTrue(fm.fileExists(atPath: doomed.path),
                      "the file at that path is not the one the plan described, and it has "
                      + "been moved to the Trash anyway")
        XCTAssertEqual(failures.count, 1)
    }

    /// The ordinary case still has to work: an item that is what it was still
    /// goes to the Trash.
    func testAnItemThatIsStillItselfGoes() throws {
        let doomed = root.appendingPathComponent("doomed.bin")
        try Data(repeating: 1, count: 400).write(to: doomed)
        var seen = stat()
        XCTAssertEqual(lstat(doomed.path, &seen), 0)

        let (done, failures) = try FileActions.moveToTrash([
            FileActions.Target(url: doomed, node: 7, bytes: 400, isFolder: false, length: 400,
                               modified: Int32(truncatingIfNeeded: seen.st_mtimespec.tv_sec))])
        for item in done { if let url = item.trashURL { trashed.append(url) } }
        XCTAssertEqual(failures.count, 0, "\(failures)")
        XCTAssertEqual(done.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: doomed.path))
    }

    /// A folder is checked on its kind and its date; its size is a subtree
    /// total that cannot be re-read for the price of one `lstat`.
    func testAFolderThatGainedAFileSincePlanningIsNotTrashed() throws {
        let album = root.appendingPathComponent("album")
        try fm.createDirectory(at: album, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: album.appendingPathComponent("one.bin"))
        var seen = stat()
        XCTAssertEqual(lstat(album.path, &seen), 0)
        let target = FileActions.Target(
            url: album, node: 3, bytes: 100, isFolder: true, length: -1,
            modified: Int32(truncatingIfNeeded: seen.st_mtimespec.tv_sec))

        // Anything landing in the folder moves its date.
        Thread.sleep(forTimeInterval: 1.1)
        try Data(repeating: 2, count: 100).write(to: album.appendingPathComponent("two.bin"))

        let (done, failures) = try FileActions.moveToTrash([target])
        for item in done { if let url = item.trashURL { trashed.append(url) } }
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: album.path),
                      "a folder that gained a file since the plan was made went to the Trash "
                      + "with the new file inside it")
    }

    /// Undo reports what it restored, and the caller counts a success per item
    /// that did not throw. So a restore that quietly does nothing is a restore
    /// that gets counted — "restored 12 items" with twelve items still in the
    /// Trash, and no way to tell from the screen.
    func testARestoreWithNowhereToRestoreFromIsAFailure() throws {
        let item = TrashedItem(originalURL: root.appendingPathComponent("gone.bin"),
                               trashURL: nil, bytesFreed: 400, node: 7)
        XCTAssertThrowsError(try FileActions.restore(item),
                             "reported success without moving anything")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("gone.bin").path))
    }

    /// The ordinary round trip, which nothing covered on its own.
    func testTrashThenRestorePutsItBack() throws {
        let doomed = root.appendingPathComponent("doomed.bin")
        try Data(repeating: 1, count: 400).write(to: doomed)
        var seen = stat()
        XCTAssertEqual(lstat(doomed.path, &seen), 0)
        let (done, failures) = try FileActions.moveToTrash([
            FileActions.Target(url: doomed, node: 7, bytes: 400, isFolder: false, length: 400,
                               modified: Int32(truncatingIfNeeded: seen.st_mtimespec.tv_sec))])
        XCTAssertEqual(failures.count, 0, "\(failures)")
        let item = try XCTUnwrap(done.first)
        XCTAssertFalse(fm.fileExists(atPath: doomed.path))

        try FileActions.restore(item)
        XCTAssertTrue(fm.fileExists(atPath: doomed.path), "undo did not put it back")
        XCTAssertEqual(try Data(contentsOf: doomed).count, 400)
    }


    /// Undo puts a file back at a path it no longer owns. Something else can be
    /// standing there — the point of the check is that undo is not allowed to
    /// be the thing that destroys it.
    func testARestoreOntoAnOccupiedPathDoesNotOverwriteIt() throws {
        let doomed = root.appendingPathComponent("doomed.bin")
        try Data(repeating: 1, count: 400).write(to: doomed)
        var seen = stat()
        XCTAssertEqual(lstat(doomed.path, &seen), 0)
        let (done, _) = try FileActions.moveToTrash([
            FileActions.Target(url: doomed, node: 7, bytes: 400, isFolder: false, length: 400,
                               modified: Int32(truncatingIfNeeded: seen.st_mtimespec.tv_sec))])
        let item = try XCTUnwrap(done.first)
        if let url = item.trashURL { trashed.append(url) }

        // Somebody else takes the name while the item sits in the Trash.
        try Data(repeating: 9, count: 12_345).write(to: doomed)

        XCTAssertThrowsError(try FileActions.restore(item))
        XCTAssertEqual(try Data(contentsOf: doomed).count, 12_345,
                       "undo overwrote the file that was standing there")
    }

}
