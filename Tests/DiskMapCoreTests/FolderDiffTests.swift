import DiskMapCore
import XCTest

/// Two folders, and what the comparison says about them.
///
/// Every fixture is built on disk rather than in a fake store, because the
/// comparison walks the filesystem itself and a stubbed tree would prove
/// nothing about the walk.
final class FolderDiffTests: XCTestCase {
    private var root: URL!
    private var left: URL!
    private var right: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmdiff-\(UUID().uuidString)")
        left = root.appendingPathComponent("left")
        right = root.appendingPathComponent("right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        // Everything downstream works in resolved paths — /var is a symlink to
        // /private/var — so the fixtures do too, or every path assertion below
        // compares two spellings of the same folder.
        left = URL(fileURLWithPath: canonicalPath(left.path) ?? left.path)
        right = URL(fileURLWithPath: canonicalPath(right.path) ?? right.path)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    // MARK: - Fixtures

    @discardableResult
    private func write(_ base: URL, _ relative: String, bytes: Int,
                       fill: UInt8 = 0, modified: Date? = nil) throws -> URL {
        let url = base.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
        if let modified {
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private func compare() throws -> FolderComparison {
        switch FolderDiff.compare(left: left.path, right: right.path) {
        case .success(let c): return c
        case .failure(let f): XCTFail("refused: \(f)"); throw f
        }
    }

    private func kinds(_ c: FolderComparison) -> [String: DiffKind] {
        Dictionary(uniqueKeysWithValues: c.entries.map { ($0.relativePath, $0.kind) })
    }

    // MARK: - What the two sides each hold

    func testTwoCopiesOfTheSameTreeShowNoDifferences() throws {
        for base in [left!, right!] {
            try write(base, "notes.txt", bytes: 400)
            try write(base, "media/clip.mov", bytes: 5000)
            try write(base, "media/deep/inner.bin", bytes: 90)
        }
        let c = try compare()
        XCTAssertTrue(c.summary.inSync, "\(c.summary)")
        XCTAssertEqual(c.summary.differences, 0)
        XCTAssertGreaterThan(c.summary.identical, 0)
    }

    func testANameOnOneSideOnlyIsReportedOnThatSide() throws {
        try write(left, "shared.txt", bytes: 100)
        try write(right, "shared.txt", bytes: 100)
        try write(left, "mine.txt", bytes: 50)
        try write(right, "yours.txt", bytes: 60)

        let c = try compare()
        let k = kinds(c)
        XCTAssertEqual(k["mine.txt"], .onlyLeft)
        XCTAssertEqual(k["yours.txt"], .onlyRight)
        XCTAssertEqual(k["shared.txt"], .identical)
        XCTAssertEqual(c.summary.onlyLeft, 1)
        XCTAssertEqual(c.summary.onlyRight, 1)
    }

    func testDifferentLengthsMeanTheItemsDiffer() throws {
        try write(left, "report.pdf", bytes: 1000)
        try write(right, "report.pdf", bytes: 2000)
        let c = try compare()
        XCTAssertEqual(kinds(c)["report.pdf"], .differs)
        XCTAssertEqual(c.summary.differing, 1)
    }

    /// The rule the whole screen rests on, stated as a test so it cannot drift:
    /// a copy that shifted every date is still a copy. The deep check is what
    /// disagrees with this, and only when asked.
    func testTheSameLengthAtADifferentDateStillReadsAsIdentical() throws {
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        let recent = Date(timeIntervalSince1970: 1_700_000_000)
        try write(left, "photo.jpg", bytes: 900, modified: old)
        try write(right, "photo.jpg", bytes: 900, modified: recent)

        let c = try compare()
        let entry = try XCTUnwrap(c.entries.first { $0.relativePath == "photo.jpg" })
        XCTAssertEqual(entry.kind, .identical)
        XCTAssertEqual(entry.newerSide, .right, "the dates are still reported")
    }

    func testAFileFacingAFolderIsAClashRatherThanAMatch() throws {
        try write(left, "thing", bytes: 10)
        try fm.createDirectory(at: right.appendingPathComponent("thing"),
                               withIntermediateDirectories: true)
        try write(right, "thing/inside.txt", bytes: 10)

        let c = try compare()
        XCTAssertEqual(kinds(c)["thing"], .typeClash)
        XCTAssertEqual(c.summary.typeClashes, 1)
    }

    // MARK: - Not enumerating what does not need enumerating

    /// A folder the other side does not have at all is one decision, so it is
    /// one row. Listing its ten thousand files would bury the four differences
    /// the user came to look at.
    func testAFolderOnOneSideOnlyIsASingleEntry() throws {
        for i in 0..<40 { try write(left, "archive/file-\(i).bin", bytes: 100 + i) }
        try write(left, "shared.txt", bytes: 5)
        try write(right, "shared.txt", bytes: 5)

        let c = try compare()
        let inside = c.entries.filter { $0.relativePath.hasPrefix("archive/") }
        XCTAssertTrue(inside.isEmpty, "the subtree should not be enumerated: \(inside.map(\.relativePath))")

        let entry = try XCTUnwrap(c.entries.first { $0.relativePath == "archive" })
        XCTAssertEqual(entry.kind, .onlyLeft)
        XCTAssertTrue(entry.isDirectory)
        XCTAssertEqual(entry.items, 40)
        XCTAssertGreaterThan(entry.leftBytes, 0)
    }

    func testAFolderThatMatchesAllTheWayDownIsASingleEntry() throws {
        for base in [left!, right!] {
            for i in 0..<30 { try write(base, "same/file-\(i).bin", bytes: 100 + i) }
        }
        try write(left, "extra.txt", bytes: 7)

        let c = try compare()
        XCTAssertTrue(c.entries.allSatisfy { !$0.relativePath.hasPrefix("same/") },
                      "an identical subtree should collapse")
        XCTAssertEqual(kinds(c)["same"], .identical)
        XCTAssertEqual(kinds(c)["extra.txt"], .onlyLeft)
    }

    func testAFolderWithOneDifferenceInsideIsWalkedIntoRatherThanCollapsed() throws {
        for base in [left!, right!] {
            for i in 0..<10 { try write(base, "tree/file-\(i).bin", bytes: 100 + i) }
        }
        try write(right, "tree/late.bin", bytes: 42)

        let c = try compare()
        XCTAssertEqual(kinds(c)["tree/late.bin"], .onlyRight)
        XCTAssertNil(kinds(c)["tree"], "the folder itself is not a difference")
    }

    // MARK: - The merge itself

    /// Names are merged by byte order out of two separate stores. If that
    /// ordering ever disagreed between the two sides the merge would drop
    /// entries silently, which is the worst way for this to fail: a mirror
    /// would then delete what it did not notice.
    func testEveryNameIsAccountedForWhateverTheOrderOnDisk() throws {
        let names = ["a", "A", "z", "_x", "0", "é", "ünlü", "a b", "a-b", "a.b",
                     "ZZ", "zz", "~tilde", "file 10", "file 9", "İstanbul"]
        for (i, name) in names.enumerated() where i % 2 == 0 {
            try write(left, name, bytes: 10 + i)
        }
        for (i, name) in names.enumerated() where i % 3 == 0 {
            try write(right, name, bytes: 10 + i)
        }
        let c = try compare()
        let seen = Set(c.entries.map(\.relativePath))
        XCTAssertEqual(seen, Set(names.enumerated()
            .filter { $0.offset % 2 == 0 || $0.offset % 3 == 0 }
            .map(\.element)))

        // Anything on both sides was written at the same length, so it matches.
        for (i, name) in names.enumerated() where i % 2 == 0 && i % 3 == 0 {
            XCTAssertEqual(kinds(c)[name], .identical, name)
        }
    }

    // MARK: - What to leave out, and how exact to be about dates

    /// `.DS_Store` differs in every directory macOS has ever opened. Without
    /// this the screen is a list of them.
    func testIgnoredNamesAreLeftOutOfBothSidesAndCounted() throws {
        try write(left, ".DS_Store", bytes: 6000)
        try write(right, ".DS_Store", bytes: 8000)
        try write(left, "build/output.o", bytes: 200)
        try write(left, "real.txt", bytes: 10)
        try write(right, "real.txt", bytes: 10)

        var options = CompareOptions()
        options.ignore += ["build"]
        guard case .success(let c) = FolderDiff.compare(left: left.path, right: right.path,
                                                        options: options) else {
            return XCTFail("refused")
        }
        XCTAssertTrue(c.summary.inSync, "\(c.entries.map(\.relativePath))")
        XCTAssertGreaterThanOrEqual(c.summary.ignored, 3, "two .DS_Store and one build")
        XCTAssertFalse(c.entries.contains { $0.relativePath.hasPrefix("build") })
    }

    func testTurningTheIgnoreListOffBringsThemBack() throws {
        try write(left, ".DS_Store", bytes: 6000)
        try write(right, ".DS_Store", bytes: 8000)
        guard case .success(let c) = FolderDiff.compare(
            left: left.path, right: right.path,
            options: CompareOptions(ignore: [])) else { return XCTFail("refused") }
        XCTAssertEqual(kinds(c)[".DS_Store"], .differs)
        XCTAssertEqual(c.summary.ignored, 0)
    }

    /// A copy that went through exFAT or a network share comes back with every
    /// timestamp a second or two out. Without a tolerance every file on the
    /// disk reads as "newer on one side".
    func testDatesWithinTheToleranceAreTheSameMoment() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try write(left, "a.bin", bytes: 100, modified: base)
        try write(right, "a.bin", bytes: 100, modified: base.addingTimeInterval(2))
        try write(left, "b.bin", bytes: 100, modified: base)
        try write(right, "b.bin", bytes: 100, modified: base.addingTimeInterval(4000))

        guard case .success(let exact) = FolderDiff.compare(left: left.path, right: right.path)
        else { return XCTFail("refused") }
        XCTAssertEqual(exact.entries.first { $0.relativePath == "a.bin" }?.newerSide, .right)

        guard case .success(let loose) = FolderDiff.compare(
            left: left.path, right: right.path,
            options: CompareOptions(dateTolerance: 2)) else { return XCTFail("refused") }
        XCTAssertNil(loose.entries.first { $0.relativePath == "a.bin" }?.newerSide,
                     "two seconds apart is the same moment at this tolerance")
        XCTAssertEqual(loose.entries.first { $0.relativePath == "b.bin" }?.newerSide, .right,
                       "and an hour apart is still not")
    }

    // MARK: - Which decisions a row stands for

    /// Every row on screen has to be able to say which decisions ticking it
    /// off would remove, and a row the walk never entered belongs to the
    /// decision made above it.
    func testEveryRowResolvesToTheDecisionsItStandsFor() throws {
        for i in 0..<5 { try write(left, "archive/f\(i).bin", bytes: 100 + i) }
        try write(left, "Photos/one.jpg", bytes: 500)
        try write(right, "Photos/two.jpg", bytes: 600)

        let c = try compare()
        let tree = c.tree

        // The folder the walk stopped at is one decision, and so is everything
        // that turns up inside it when it is opened.
        let archive = try XCTUnwrap(tree.children(of: 0).first { tree.name($0) == "archive" })
        XCTAssertEqual(tree.decisions(archive).count, 1)
        let inside = try XCTUnwrap(tree.children(of: archive).first)
        XCTAssertEqual(tree.decisions(inside), tree.decisions(archive),
                       "a file inside a folder being copied whole is that same decision")

        // The folder the walk entered stands for everything it found there.
        let photos = try XCTUnwrap(tree.children(of: 0).first { tree.name($0) == "Photos" })
        XCTAssertEqual(tree.decisions(photos).count, 2)
        let ids = tree.decisions(photos).map { c.entries[$0].relativePath }
        XCTAssertEqual(Set(ids), ["Photos/one.jpg", "Photos/two.jpg"])
    }

    // MARK: - Refusals

    func testRefusesToCompareAFolderWithItself() throws {
        switch FolderDiff.compare(left: left.path, right: left.path) {
        case .success: XCTFail("should have refused")
        case .failure(let f): XCTAssertEqual(f, .sameFolder(left.path))
        }
    }

    func testRefusesToCompareAFolderWithSomethingInsideIt() throws {
        try fm.createDirectory(at: left.appendingPathComponent("inner"),
                               withIntermediateDirectories: true)
        switch FolderDiff.compare(left: left.path, right: left.path + "/inner") {
        case .success: XCTFail("should have refused")
        case .failure(let f):
            guard case .nested = f else { return XCTFail("wrong refusal: \(f)") }
        }
    }

    func testRefusesAPathThatIsNotAFolder() throws {
        let file = try write(left, "plain.txt", bytes: 4)
        switch FolderDiff.compare(left: file.path, right: right.path) {
        case .success: XCTFail("should have refused")
        case .failure(let f): XCTAssertEqual(f, .notAFolder(file.path))  // as given, since it never resolved
        }
    }

    // MARK: - Reading the bytes

    /// The one thing the metadata comparison cannot see, and the reason the
    /// deep check exists at all.
    func testVerifyFindsBytesThatDifferBehindAMatchingLength() throws {
        try write(left, "same.bin", bytes: 64, fill: 1)
        try write(right, "same.bin", bytes: 64, fill: 1)
        try write(left, "sneaky.bin", bytes: 64, fill: 7)
        try write(right, "sneaky.bin", bytes: 64, fill: 9)

        let c = try compare()
        XCTAssertTrue(c.summary.inSync, "metadata cannot tell these apart")

        let result = FolderDiff.verify(c)
        XCTAssertEqual(result.differing, ["sneaky.bin"])
        XCTAssertTrue(result.unreadable.isEmpty)
        XCTAssertGreaterThan(result.bytesRead, 0)
        XCTAssertFalse(result.agreed)
    }

    /// A collapsed folder is a metadata decision, and the deep check is the
    /// pass that doubts metadata — so it has to look inside one.
    func testVerifyLooksInsideAFolderTheComparisonCollapsed() throws {
        for i in 0..<5 {
            try write(left, "tree/f\(i).bin", bytes: 32, fill: UInt8(i))
            try write(right, "tree/f\(i).bin", bytes: 32, fill: UInt8(i == 3 ? 200 : i))
        }
        let c = try compare()
        XCTAssertEqual(kinds(c)["tree"], .identical)

        let result = FolderDiff.verify(c)
        XCTAssertEqual(result.differing, ["tree/f3.bin"])
        XCTAssertEqual(result.pairsChecked, 5)
    }

    func testVerifyAgreesWhenTheBytesReallyMatch() throws {
        for base in [left!, right!] {
            try write(base, "a.bin", bytes: 128, fill: 3)
            try write(base, "sub/b.bin", bytes: 256, fill: 4)
        }
        let c = try compare()
        let result = FolderDiff.verify(c)
        XCTAssertTrue(result.agreed, "differing: \(result.differing)")
    }
}
