import XCTest
@testable import DiskMapCore

final class RootSetTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmroots-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("parent/child"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("sibling"),
                               withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func p(_ rel: String) -> String { root.appendingPathComponent(rel).path }

    func testTheSameFolderTwiceIsKeptOnce() {
        let n = RootSet.normalize([p("sibling"), p("sibling")])
        XCTAssertEqual(n.roots.count, 1)
        XCTAssertEqual(n.rejected.count, 1)
        guard case .duplicate = n.rejected[0].reason else {
            return XCTFail("expected duplicate, got \(n.rejected[0].reason)")
        }
    }

    /// The important one: keeping both would count the child's bytes twice.
    func testAFolderInsideAnotherIsDropped() {
        let n = RootSet.normalize([p("parent"), p("parent/child")])
        XCTAssertEqual(n.roots.map { ($0 as NSString).lastPathComponent }, ["parent"])
        guard case .containedIn = n.rejected.first?.reason else {
            return XCTFail("expected containedIn, got \(String(describing: n.rejected.first?.reason))")
        }
    }

    /// Order must not matter: the child may well be listed first.
    func testNestingIsDetectedWhicheverOrderTheyArriveIn() {
        let n = RootSet.normalize([p("parent/child"), p("parent")])
        XCTAssertEqual(n.roots.map { ($0 as NSString).lastPathComponent }, ["parent"])
    }

    func testUnrelatedFoldersAreBothKept() {
        let n = RootSet.normalize([p("parent"), p("sibling")])
        XCTAssertEqual(n.roots.count, 2)
        XCTAssertTrue(n.rejected.isEmpty)
    }

    func testMissingAndNonFolderTargetsAreReported() throws {
        let file = root.appendingPathComponent("a-file.txt")
        try Data(count: 10).write(to: file)
        let n = RootSet.normalize([p("nope"), file.path, p("sibling")])
        XCTAssertEqual(n.roots.count, 1)
        XCTAssertEqual(Set(n.rejected.map(\.reason)), [.missing, .notADirectory])
    }

    /// A path is only "inside" another if the scan would actually reach it.
    func testSymlinkedDuplicateResolvesToTheSameFolder() throws {
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"),
                                  withDestinationURL: root.appendingPathComponent("sibling"))
        let n = RootSet.normalize([p("sibling"), p("link")])
        XCTAssertEqual(n.roots.count, 1, "a symlink to a chosen folder is the same folder")
    }
}

final class MultiRootScanTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmmulti-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("alpha/deep"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("beta"),
                               withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: root.appendingPathComponent("alpha/one.bin"))
        try Data(count: 250_000).write(to: root.appendingPathComponent("alpha/deep/two.bin"))
        try Data(count: 400_000).write(to: root.appendingPathComponent("beta/three.bin"))
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func p(_ rel: String) -> String { root.appendingPathComponent(rel).path }

    func testTwoFoldersAddUpToOneTotal() {
        let result = DiskScanner().scan(ScanOptions(roots: [p("alpha"), p("beta")]))
        XCTAssertTrue(result.isMultiRoot)
        XCTAssertEqual(result.roots.count, 2)
        XCTAssertEqual(result.store.totalLogical[0], 750_000)
        XCTAssertEqual(result.stats.files, 3)
        // The two roots are the children of the synthetic node.
        XCTAssertEqual(result.store.children(0).count, 2)
    }

    func testPathsResolveBothWaysAcrossRoots() throws {
        let result = DiskScanner().scan(ScanOptions(roots: [p("alpha"), p("beta")]))
        let store = result.store
        let wanted = try XCTUnwrap(canonicalPath(p("alpha/deep/two.bin")))

        let node = try XCTUnwrap(store.find(path: wanted), "should find a file under the first root")
        XCTAssertEqual(store.path(node), wanted)
        XCTAssertEqual(store.totalLogical[Int(node)], 250_000)

        let other = try XCTUnwrap(canonicalPath(p("beta/three.bin")))
        let otherNode = try XCTUnwrap(store.find(path: other), "should find a file under the second root")
        XCTAssertEqual(store.path(otherNode), other)
    }

    /// Choosing a folder and its parent must not double-count the child.
    func testNestedSelectionIsNotCountedTwice() {
        let both = DiskScanner().scan(ScanOptions(roots: [p("alpha"), p("alpha/deep")]))
        let alone = DiskScanner().scan(ScanOptions(rootPath: p("alpha")))
        XCTAssertFalse(both.isMultiRoot, "the nested folder should have been dropped")
        XCTAssertEqual(both.store.totalLogical[0], alone.store.totalLogical[0])
        XCTAssertEqual(both.rejectedRoots.count, 1)
    }

    func testHardLinkAcrossTwoRootsCountsOnce() throws {
        let original = root.appendingPathComponent("alpha/shared.bin")
        try Data(count: 500_000).write(to: original)
        try fm.linkItem(at: original, to: root.appendingPathComponent("beta/shared-link.bin"))

        let result = DiskScanner().scan(ScanOptions(roots: [p("alpha"), p("beta")]))
        XCTAssertEqual(result.stats.hardlinkDuplicates, 1,
                       "the second link is in a different root but the same inode")
        XCTAssertLessThan(result.store.totalPhysical[0], 1_300_000)
    }

    func testLiveUpdateReachesTheSyntheticRoot() throws {
        let live = LiveTree(result: DiskScanner().scan(ScanOptions(roots: [p("alpha"), p("beta")])))
        let before = live.withStore { $0.totalLogical[0] }
        try Data(count: 60_000).write(to: root.appendingPathComponent("beta/extra.bin"))
        live.refresh(directory: p("beta"))
        XCTAssertEqual(live.withStore { $0.totalLogical[0] } - before, 60_000)
    }

    func testEmptySelectionIsNotAScan() {
        let result = DiskScanner().scan(ScanOptions(roots: []))
        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertEqual(result.store.count, 0)
    }
}

final class FirmlinkTests: XCTestCase {
    func testUserPathsMapOntoTheDataVolumeAndBack() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/usr/share/firmlinks"))
        XCTAssertEqual(Firmlinks.onDataVolume("/Users/md/Desktop"),
                       "/System/Volumes/Data/Users/md/Desktop")
        XCTAssertEqual(Firmlinks.displayPath("/System/Volumes/Data/Users/md/Desktop"),
                       "/Users/md/Desktop")
    }

    func testNonFirmlinkedPathsAreLeftAlone() {
        XCTAssertNil(Firmlinks.onDataVolume("/System/Library/Frameworks"))
        XCTAssertEqual(Firmlinks.displayPath("/System/Library/Frameworks"),
                       "/System/Library/Frameworks")
    }

    /// /usr/local is firmlinked but /usr is not, so the longer prefix must win.
    func testNestedFirmlinkWinsOverShorterPrefix() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/usr/share/firmlinks"))
        XCTAssertEqual(Firmlinks.onDataVolume("/usr/local/bin"),
                       "/System/Volumes/Data/usr/local/bin")
    }
}

final class AbbreviationTests: XCTestCase {
    func testRootPathsAreShortenedButStillDistinguishable() {
        XCTAssertEqual(abbreviatedName("/Users/md/dev/atolye"), "…/dev/atolye")
        XCTAssertEqual(abbreviatedName("/Users/md/dev/diskmap"), "…/dev/diskmap")
        // Two folders with the same leaf name stay distinct.
        XCTAssertNotEqual(abbreviatedName("/a/one/Documents"), abbreviatedName("/a/two/Documents"))
    }

    func testOrdinaryNamesAreUntouched() {
        XCTAssertEqual(abbreviatedName("Movies"), "Movies")
        XCTAssertEqual(abbreviatedName("file.txt"), "file.txt")
        XCTAssertEqual(abbreviatedName("/"), "/")
    }
}

/// Walking "/" alone measures only the read-only System volume, because every
/// firmlinked path is skipped to avoid double counting. The user's data lives
/// on the Data volume, so "scan the startup disk" has to mean both.
final class StartupVolumeTests: XCTestCase {
    func testScanningRootAlsoCoversTheDataVolume() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: RootSet.startupDataVolume))
        let expanded = RootSet.expandStartupVolume(["/"])
        XCTAssertEqual(expanded, ["/", RootSet.startupDataVolume])
    }

    /// The two volumes are separate devices, so neither is "inside" the other.
    func testBothStartupVolumesSurviveNormalisation() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: RootSet.startupDataVolume))
        let normalized = RootSet.normalize(RootSet.expandStartupVolume(["/"]))
        XCTAssertEqual(Set(normalized.roots), ["/", RootSet.startupDataVolume],
                       "rejected: \(normalized.rejected.map { "\($0.path): \($0.reason)" })")
    }

    func testAPlainFolderIsNotExpanded() {
        XCTAssertEqual(RootSet.expandStartupVolume(["/Users/md"]), ["/Users/md"])
    }

    func testWholeVolumeDetection() {
        XCTAssertTrue(RootSet.coversWholeVolume(["/", RootSet.startupDataVolume]))
        XCTAssertTrue(RootSet.coversWholeVolume([RootSet.startupDataVolume]))
        XCTAssertFalse(RootSet.coversWholeVolume(["/Users/md"]))
    }

    /// The bug the user hit, at speed: a tree rooted on the Data volume must
    /// accept and return the firmlinked paths everything else on the system
    /// uses. A full-disk scan proves the same thing but costs 80 seconds and
    /// several gigabytes, so it lives behind DM_SLOW_TESTS=1.
    func testDataVolumeTreeSpeaksFirmlinkedPaths() throws {
        let fm = FileManager.default
        let visible = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("dmfirm-\(UUID().uuidString)")
        try fm.createDirectory(at: visible, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: visible) }
        try Data(count: 120_000).write(to: visible.appendingPathComponent("payload.bin"))

        // Scan it by its Data-volume name, the way a whole-disk scan reaches it.
        let onData = try XCTUnwrap(Firmlinks.onDataVolume(visible.path))
        let result = DiskScanner().scan(ScanOptions(rootPath: onData))

        let wanted = visible.appendingPathComponent("payload.bin").path
        let node = try XCTUnwrap(result.store.find(path: wanted),
                                 "a /Users/... path must resolve in a Data-volume tree")
        XCTAssertEqual(result.store.path(node), wanted,
                       "paths must come back as /Users/..., not /System/Volumes/Data/Users/...")
        XCTAssertEqual(result.store.totalLogical[Int(node)], 120_000)
    }

    /// The real thing. Slow and memory-hungry; opt in with DM_SLOW_TESTS=1.
    func testWholeDiskScanFindsHomeFolder() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DM_SLOW_TESTS"] == "1")
        let result = DiskScanner().scan(ScanOptions(rootPath: "/"))
        XCTAssertTrue(result.isMultiRoot, "roots were \(result.roots)")
        let home = NSHomeDirectory()
        let node = try XCTUnwrap(result.store.find(path: home),
                                 "home folder missing from a startup-disk scan")
        XCTAssertGreaterThan(result.store.totalPhysical[Int(node)], 0,
                             "home folder measured as zero bytes")
        XCTAssertEqual(result.store.path(node), home)
    }
}

final class RootShadowingTests: XCTestCase {
    /// "/" is a prefix of every path. When it is one of several roots it must
    /// not shadow a more specific root, or lookups stop at an excluded stub.
    func testLongerRootWinsOverSlashRoot() throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("dmshadow-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try Data(count: 90_000).write(to: home.appendingPathComponent("f.bin"))

        let onData = try XCTUnwrap(Firmlinks.onDataVolume(home.path))
        // "/usr" stands in for the shallow root; the deep one holds the file.
        let result = DiskScanner().scan(ScanOptions(roots: ["/usr/share/firmlinks", onData]))
        let store = result.store
        let wanted = home.appendingPathComponent("f.bin").path
        XCTAssertNotNil(store.find(path: wanted),
                        "roots were \(result.roots)")
    }
}
