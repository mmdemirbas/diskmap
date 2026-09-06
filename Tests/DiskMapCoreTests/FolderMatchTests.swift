import XCTest
@testable import DiskMapCore

final class FolderMatchTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("dmfold-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int, fill: UInt8 = 0) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    private func matches(minimum: Int64 = 1_000) -> [FolderMatch] {
        let store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        return FolderMatches.find(store: store, root: 0, minimumSize: minimum)
    }

    private func node(_ path: String) throws -> Int32 {
        let store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        return try XCTUnwrap(store.find(path: root.appendingPathComponent(path).path))
    }

    func testFoldersWithTheSameContentsMatchExactly() throws {
        try write("left/a.bin", 40_000)
        try write("left/b.bin", 20_000)
        try write("right/a.bin", 40_000)
        try write("right/b.bin", 20_000)
        let found = matches()
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].exact)
        XCTAssertEqual(found[0].nodes.count, 2)
        XCTAssertEqual(found[0].reclaimable, found[0].bytes)
    }

    /// A folder's own name is left out of its hash, so a renamed copy is still
    /// a copy — which is the case a name-based search would miss.
    func testARenamedCopyStillMatches() throws {
        try write("photos-2024/a.bin", 40_000)
        try write("photos-2024/b.bin", 20_000)
        try write("backup-of-photos/a.bin", 40_000)
        try write("backup-of-photos/b.bin", 20_000)
        XCTAssertEqual(matches().count, 1)
    }

    func testDifferentSizesDoNotMatch() throws {
        try write("left/a.bin", 40_000)
        try write("right/a.bin", 40_001)
        XCTAssertTrue(matches().isEmpty)
    }

    func testDifferentNamesDoNotMatch() throws {
        try write("left/a.bin", 40_000)
        try write("right/b.bin", 40_000)
        XCTAssertTrue(matches().isEmpty)
    }

    /// Nesting is where a naive version drowns the user: inside two identical
    /// folders, every subfolder is identical too.
    func testOnlyTheOutermostIdenticalFolderIsReported() throws {
        for side in ["left", "right"] {
            try write("\(side)/media/clips/a.bin", 40_000)
            try write("\(side)/media/clips/b.bin", 20_000)
            try write("\(side)/notes.txt", 5_000)
        }
        let found = matches().filter(\.exact)
        XCTAssertEqual(found.count, 1)
        let names = found[0].nodes.map { $0 }
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(found[0].sharedItems, 2)  // media + notes.txt, the top level
    }

    /// A subtree shared by folders that are otherwise different must survive
    /// the outermost-only rule.
    func testASharedSubfolderIsReportedWhenItsParentsDiffer() throws {
        try write("left/media/a.bin", 40_000)
        try write("left/only-here.bin", 90_000)
        try write("right/media/a.bin", 40_000)
        try write("right/different.bin", 7_000)
        let found = matches().filter(\.exact)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].sharedItems, 1)
    }

    func testFoldersBelowTheSizeThresholdAreIgnored() throws {
        try write("left/a.bin", 40_000)
        try write("right/a.bin", 40_000)
        XCTAssertTrue(matches(minimum: 10_000_000).isEmpty)
    }

    func testEmptyFoldersDoNotMatchEachOther() throws {
        try fm.createDirectory(at: root.appendingPathComponent("one"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("two"), withIntermediateDirectories: true)
        XCTAssertTrue(matches(minimum: 0).isEmpty)
    }

    /// The case the exact match misses and the user cares about: one copy has
    /// a few more files in it.
    func testNearlyIdenticalFoldersAreReportedAsPartial() throws {
        for name in ["a", "b", "c", "d"] {
            try write("left/\(name).bin", 40_000)
            try write("right/\(name).bin", 40_000)
        }
        try write("right/extra.bin", 40_000)
        let found = matches()
        XCTAssertEqual(found.count, 1)
        XCTAssertFalse(found[0].exact)
        XCTAssertEqual(found[0].sharedItems, 4)
        XCTAssertEqual(found[0].comparedItems, 5)
        XCTAssertEqual(found[0].reclaimable, 4 * 40_960)  // shared bytes, on disk
    }

    func testFoldersSharingTooLittleAreNotReported() throws {
        for name in ["a", "b", "c", "d"] { try write("left/\(name).bin", 40_000) }
        try write("right/a.bin", 40_000)
        for name in ["x", "y", "z"] { try write("right/\(name).bin", 40_000) }
        XCTAssertTrue(matches().isEmpty)
    }

    /// If A and B are the same folder, "A is like C" and "B is like C" are one
    /// finding. Reporting both is the same sentence twice.
    func testAPairIsNotRepeatedForEachIdenticalTwin() throws {
        for side in ["left", "right", "third"] {
            for name in ["a", "b", "c", "d"] { try write("\(side)/\(name).bin", 40_000) }
        }
        try write("third/extra.bin", 40_000)
        let found = matches()
        XCTAssertEqual(found.filter(\.exact).count, 1)      // left and right
        XCTAssertEqual(found.filter { !$0.exact }.count, 1)  // that pair, versus third
    }

    /// Files inside folders already reported as copies would otherwise fill the
    /// file list with a restatement of the folder list.
    func testFilesInsideMatchedFoldersAreNotListedAgain() throws {
        try write("left/clip.mov", 40_000)
        try write("left/other.mov", 40_000)
        try write("right/clip.mov", 40_000)
        try write("right/other.mov", 40_000)
        // These two hold a copy of the same file but are not copies of each
        // other, which is exactly the case the file list must still report.
        try write("loose/apart.bin", 60_000)
        try write("loose/only-here.bin", 10_000)
        try write("elsewhere/apart.bin", 60_000)
        try write("elsewhere/different.bin", 20_000)

        let store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        let folders = FolderMatches.find(store: store, root: 0, minimumSize: 1_000)
        XCTAssertEqual(folders.count, 1)

        let all = Duplicates.find(store: store, root: 0, minimumSize: 1_000)
        XCTAssertEqual(Set(all.map(\.name)), ["clip.mov", "other.mov", "apart.bin"])

        let kept = Duplicates.find(store: store, root: 0, minimumSize: 1_000,
                                   insideMatched: folders)
        XCTAssertEqual(kept.map(\.name), ["apart.bin"])
    }

    /// One changed file deep inside a subtree must change exactly one entry at
    /// the top: the parents stop matching exactly, but still match partially,
    /// and the untouched subfolder is still found.
    func testAChangeDeepInsideBreaksTheExactMatch() throws {
        for side in ["left", "right"] {
            try write("\(side)/keep/a.bin", 40_000)
            try write("\(side)/one.bin", 10_000)
            try write("\(side)/two.bin", 10_000)
            try write("\(side)/other/b.bin", 40_000)
        }
        try write("right/other/b.bin", 41_000)
        let found = matches()
        XCTAssertEqual(found.filter(\.exact).map(\.sharedItems), [1])  // keep/ alone
        let partial = found.filter { !$0.exact }
        XCTAssertEqual(partial.count, 1)
        XCTAssertEqual(partial[0].sharedItems, 3)   // keep, one.bin, two.bin
        XCTAssertEqual(partial[0].comparedItems, 4)
    }

    /// Two deploy trees whose `current` link points at different releases.
    ///
    /// A symlink is hashed by the length of the path it holds, and release
    /// names are usually the same length, so the two folders hash identically
    /// and are offered as copies of each other. The deep check cannot
    /// contradict it either: it reads regular files, so it never opens a link.
    func testAFolderIsNotACopyWhenItsLinkPointsSomewhereElse() throws {
        let a = root.appendingPathComponent("backup-a/app")
        let b = root.appendingPathComponent("backup-b/app")
        for base in [a, b] {
            try fm.createDirectory(at: base.appendingPathComponent("releases"),
                                   withIntermediateDirectories: true)
            try Data(repeating: 1, count: 400_000).write(to: base.appendingPathComponent("bundle.bin"))
        }
        try fm.createSymbolicLink(atPath: a.appendingPathComponent("current").path,
                                  withDestinationPath: "releases/2026-01")
        try fm.createSymbolicLink(atPath: b.appendingPathComponent("current").path,
                                  withDestinationPath: "releases/2026-02")
        defer { try? fm.removeItem(at: root) }

        let result = DiskScanner().scan(ScanOptions(rootPath: root.path))
        let matches = FolderMatches.find(store: result.store, root: 0, minimumSize: 100_000)
        let exact = matches.filter { $0.exact && $0.nodes.count == 2 }
        XCTAssertTrue(exact.isEmpty,
                      "two folders whose link points somewhere different are being offered as "
                      + "copies of each other, with \(exact.first?.reclaimable ?? 0) bytes to "
                      + "reclaim")
    }
}

final class DeepVerifyTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("dmverify-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int, fill: UInt8 = 0) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    private func store() -> NodeStore { DiskScanner().scan(ScanOptions(rootPath: root.path)).store }

    private func nodes(_ paths: [String], in store: NodeStore) throws -> [Int32] {
        try paths.map { try XCTUnwrap(store.find(path: root.appendingPathComponent($0).path)) }
    }

    func testIdenticalFoldersVerifyAsIdentical() throws {
        try write("left/a.bin", 40_000, fill: 7)
        try write("left/sub/b.bin", 20_000, fill: 9)
        try write("right/a.bin", 40_000, fill: 7)
        try write("right/sub/b.bin", 20_000, fill: 9)
        let store = store()
        let plan = DeepVerify.plan(store: store, nodes: try nodes(["left", "right"], in: store))
        XCTAssertEqual(plan.files, 4)
        XCTAssertEqual(plan.bytes, 120_000)
        let outcome = DeepVerify.run(plan)
        XCTAssertTrue(outcome.identical)
        XCTAssertEqual(outcome.distinct, 1)
    }

    /// The whole reason deep verification exists: same names, same sizes,
    /// different bytes. The metadata match cannot tell these apart.
    func testSameNamesAndSizesButDifferentBytesAreNotIdentical() throws {
        try write("left/a.bin", 40_000, fill: 1)
        try write("right/a.bin", 40_000, fill: 2)
        let store = store()
        let plan = DeepVerify.plan(store: store, nodes: try nodes(["left", "right"], in: store))
        let outcome = DeepVerify.run(plan)
        XCTAssertFalse(outcome.identical)
        XCTAssertEqual(outcome.distinct, 2)
    }

    /// Position inside the folder is part of the digest, so the same file in a
    /// different place is a different folder.
    func testAFileInADifferentPlaceIsNotIdentical() throws {
        try write("left/sub/a.bin", 40_000, fill: 3)
        try write("right/a.bin", 40_000, fill: 3)
        let store = store()
        let outcome = DeepVerify.run(DeepVerify.plan(store: store,
                                                     nodes: try nodes(["left", "right"], in: store)))
        XCTAssertEqual(outcome.distinct, 2)
    }

    func testIndividualFilesCanBeVerifiedToo() throws {
        try write("one/v.mov", 40_000, fill: 5)
        try write("two/v.mov", 40_000, fill: 5)
        let store = store()
        let plan = DeepVerify.plan(store: store, nodes: try nodes(["one/v.mov", "two/v.mov"], in: store))
        XCTAssertEqual(plan.files, 2)
        XCTAssertTrue(DeepVerify.run(plan).identical)
    }

    func testSymlinksAreNotFollowed() throws {
        try write("left/a.bin", 40_000)
        try fm.createSymbolicLink(at: root.appendingPathComponent("left/link"),
                                  withDestinationURL: root.appendingPathComponent("left/a.bin"))
        let store = store()
        let plan = DeepVerify.plan(store: store, nodes: try nodes(["left"], in: store))
        XCTAssertEqual(plan.files, 1)
    }

    func testCancellingStopsAndSaysSo() throws {
        try write("left/a.bin", 40_000)
        try write("right/a.bin", 40_000)
        let store = store()
        let plan = DeepVerify.plan(store: store, nodes: try nodes(["left", "right"], in: store))
        let token = CancelToken()
        token.cancel()
        let outcome = DeepVerify.run(plan, cancel: token)
        XCTAssertTrue(outcome.cancelled)
        XCTAssertFalse(outcome.identical)
    }

    func testProgressReportsEveryByteRead() throws {
        try write("left/a.bin", 40_000)
        try write("right/a.bin", 40_000)
        let store = store()
        let plan = DeepVerify.plan(store: store, nodes: try nodes(["left", "right"], in: store))
        let lock = NSLock()
        var seen: Int64 = 0
        _ = DeepVerify.run(plan) { total in lock.lock(); seen = max(seen, total); lock.unlock() }
        XCTAssertEqual(seen, plan.bytes)
    }
}
