import XCTest
@testable import DiskMapCore

final class SnapshotTests: XCTestCase {
    private var dir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("dmsnap-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let dir { try? fm.removeItem(at: dir) } }

    private func digest(_ folders: [String: Int64], at seconds: TimeInterval,
                        total: Int64? = nil) -> DiskDigest {
        DiskDigest(takenAt: Date(timeIntervalSince1970: seconds), roots: ["/x"],
                   totalPhysical: total ?? folders.values.reduce(0, +), totalLogical: 0,
                   files: 0, directories: folders.count, folders: folders)
    }

    // MARK: - Attributing a change to the folder that caused it

    /// A download shows up in Downloads, in the home folder, and in every
    /// folder between. Reporting all of them is the same fact five times, with
    /// the least useful statement of it at the top because it is the biggest.
    func testAChangeIsAttributedToTheDeepestFolderThatExplainsIt() {
        let before = digest(["/x": 1_000_000_000, "/x/a": 500_000_000, "/x/a/b": 100_000_000], at: 0)
        let after = digest(["/x": 3_000_000_000, "/x/a": 2_500_000_000, "/x/a/b": 2_100_000_000], at: 100)
        let diff = DiskDigest.diff(from: before, to: after)
        XCTAssertEqual(diff.changes.map(\.path), ["/x/a/b"])
        XCTAssertEqual(diff.changes[0].ownDelta, 2_000_000_000)
        XCTAssertEqual(diff.changes[0].kind, .grew)
    }

    /// Two siblings each growing are two findings, and the parent is neither.
    func testSeparateChangesAreReportedSeparately() {
        let before = digest(["/x": 0, "/x/a": 0, "/x/b": 0], at: 0)
        let after = digest(["/x": 300_000_000, "/x/a": 100_000_000, "/x/b": 200_000_000], at: 100)
        let diff = DiskDigest.diff(from: before, to: after, floor: 50_000_000)
        XCTAssertEqual(diff.changes.map(\.path), ["/x/b", "/x/a"])
        XCTAssertFalse(diff.changes.contains { $0.path == "/x" })
    }

    /// A folder that grew while its child shrank by the same amount is a real
    /// change in the folder itself, not a wash.
    func testAParentsOwnGrowthSurvivesAChildShrinking() {
        let before = digest(["/x": 1_000_000_000, "/x/a": 900_000_000], at: 0)
        let after = digest(["/x": 1_000_000_000, "/x/a": 100_000_000], at: 100)
        let diff = DiskDigest.diff(from: before, to: after)
        let byPath = Dictionary(uniqueKeysWithValues: diff.changes.map { ($0.path, $0) })
        XCTAssertEqual(byPath["/x/a"]?.ownDelta, -800_000_000)
        XCTAssertEqual(byPath["/x"]?.ownDelta, 800_000_000)
    }

    func testAppearedAndVanishedAreDistinctFromGrewAndShrank() {
        let before = digest(["/x/gone": 900_000_000], at: 0)
        let after = digest(["/x/new": 900_000_000], at: 100)
        let diff = DiskDigest.diff(from: before, to: after)
        let kinds = Dictionary(uniqueKeysWithValues: diff.changes.map { ($0.path, $0.kind) })
        XCTAssertEqual(kinds["/x/new"], .appeared)
        XCTAssertEqual(kinds["/x/gone"], .vanished)
    }

    /// A digest holds only folders above its floor, so one that shrank past it
    /// looks exactly like one that was deleted. Saying "vanished" about a
    /// folder that is still there is a much stronger claim than the data
    /// supports.
    func testAFolderThatOnlyShrankPastTheFloorIsNotCalledVanished() {
        let before = digest(["/x/a": 900_000_000, "/x/b": 900_000_000], at: 0)
        let after = digest([:], at: 100)
        let raw = DiskDigest.diff(from: before, to: after)
        XCTAssertEqual(Set(raw.changes.map(\.kind)), [.vanished])

        let fixed = raw.resolvingVanished { $0 == "/x/a" }
        let kinds = Dictionary(uniqueKeysWithValues: fixed.changes.map { ($0.path, $0.kind) })
        XCTAssertEqual(kinds["/x/a"], .shrank)
        XCTAssertEqual(kinds["/x/b"], .vanished)
    }

    func testSmallMovementIsNotAChangeWorthListing() {
        let before = digest(["/x/a": 1_000_000_000], at: 0)
        let after = digest(["/x/a": 1_000_100_000], at: 100)
        XCTAssertTrue(DiskDigest.diff(from: before, to: after).isEmpty)
    }

    func testTheHeadlineIsTheWholeVolumeNotTheSumOfChanges() {
        let before = digest([:], at: 0, total: 5_000_000_000)
        let after = digest([:], at: 100, total: 4_000_000_000)
        XCTAssertEqual(DiskDigest.diff(from: before, to: after).totalDelta, -1_000_000_000)
    }

    // MARK: - Keeping them on disk

    func testADigestSurvivesTheRoundTrip() throws {
        let store = SnapshotStore(directory: dir)
        let original = digest(["/x/a": 123_456_789, "/x/b with spaces/ünicode": 42], at: 1_700_000_000)
        try store.write(original)
        let entries = store.list()
        XCTAssertEqual(entries.count, 1)
        let back = try store.read(try XCTUnwrap(entries.first).url)
        XCTAssertEqual(back.folders, original.folders)
        XCTAssertEqual(back.takenAt.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    func testTheFileIsCompressed() throws {
        let store = SnapshotStore(directory: dir)
        var folders: [String: Int64] = [:]
        for i in 0..<2_000 { folders["/Users/md/some/deep/shared/prefix/project-\(i)"] = Int64(i) }
        let url = try store.write(digest(folders, at: 0))
        let onDisk = try Data(contentsOf: url).count
        let raw = try JSONEncoder().encode(digest(folders, at: 0)).count
        XCTAssertLessThan(onDisk, raw / 3, "long shared prefixes should compress well")
    }

    func testOnlyTheNewestAreKept() throws {
        let store = SnapshotStore(directory: dir, keep: 3)
        for i in 0..<6 { try store.write(digest(["/x": Int64(i)], at: Double(i) * 86_400)) }
        let entries = store.list()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map { $0.takenAt.timeIntervalSince1970 },
                       [3.0 * 86_400, 4.0 * 86_400, 5.0 * 86_400])
    }

    /// Pruning must never look at anything it did not write.
    func testPruningLeavesForeignFilesAlone() throws {
        let bystander = dir.appendingPathComponent("important.txt")
        try Data("do not touch".utf8).write(to: bystander)
        let store = SnapshotStore(directory: dir, keep: 1)
        for i in 0..<4 { try store.write(digest(["/x": Int64(i)], at: Double(i) * 86_400)) }
        XCTAssertTrue(fm.fileExists(atPath: bystander.path))
        XCTAssertEqual(store.list().count, 1)
    }

    func testAnUnreadableFileIsSkippedRatherThanFatal() throws {
        let store = SnapshotStore(directory: dir)
        try store.write(digest(["/x": 1], at: 0))
        try Data("not a digest".utf8)
            .write(to: dir.appendingPathComponent("scan-broken.dmsnap"))
        XCTAssertEqual(store.list().count, 1)
    }

    // MARK: - Built from a real scan

    func testADigestKeepsTheFoldersThatMatterAndDropsTheRest() throws {
        let root = dir.appendingPathComponent("tree")
        try fm.createDirectory(at: root.appendingPathComponent("big"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("small"), withIntermediateDirectories: true)
        try Data(count: 400_000).write(to: root.appendingPathComponent("big/blob.bin"))
        try Data(count: 1_000).write(to: root.appendingPathComponent("small/note.txt"))

        let result = DiskScanner().scan(ScanOptions(rootPath: root.path))
        let made = DiskDigest.of(store: result.store, stats: result.stats, floor: 100_000)
        XCTAssertTrue(made.folders.keys.contains { $0.hasSuffix("/big") })
        XCTAssertFalse(made.folders.keys.contains { $0.hasSuffix("/small") })
        XCTAssertEqual(made.totalPhysical, result.store.totalPhysical[0])
    }
}
