import XCTest
@testable import DiskMapCore

final class ScannerTests: XCTestCase {
    /// Builds a known tree and asserts the aggregate equals the hand-computed sum.
    func testAggregatesMatchKnownTree() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmtest-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("c"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let sizes: [(String, Int)] = [("a/one.bin", 100_000), ("a/b/two.bin", 250_000), ("c/three.bin", 30_000)]
        for (rel, n) in sizes {
            try Data(count: n).write(to: root.appendingPathComponent(rel))
        }

        let result = DiskScanner().scan(ScanOptions(rootPath: root.path))
        let store = result.store

        XCTAssertEqual(result.stats.files, 3)
        XCTAssertEqual(result.stats.directories, 3)  // a, a/b, c
        XCTAssertEqual(store.totalLogical[0], Int64(sizes.reduce(0) { $0 + $1.1 }))
        // Physical is block-rounded, so it must be at least logical.
        XCTAssertGreaterThanOrEqual(store.totalPhysical[0], store.totalLogical[0])

        // Every child index must exceed its parent: the aggregation pass relies on it.
        for i in 1..<store.count {
            XCTAssertLessThan(Int(store.parent[i]), i)
        }
    }

    func testHardlinksCountedOnce() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmtest-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let original = root.appendingPathComponent("orig.bin")
        try Data(count: 400_000).write(to: original)
        try fm.linkItem(at: original, to: root.appendingPathComponent("link.bin"))

        let result = DiskScanner().scan(ScanOptions(rootPath: root.path))
        XCTAssertEqual(result.stats.files, 2)
        XCTAssertEqual(result.stats.hardlinkDuplicates, 1)
        // 400 KB on disk, not 800 KB, even though two names point at it.
        XCTAssertLessThan(result.store.totalPhysical[0], 500_000)
    }

    func testFirmlinksAreKnown() {
        let f = Firmlinks.mountPaths()
        XCTAssertTrue(f.contains("/Users"), "firmlink table should list /Users")
    }
}

final class LiveTreeTests: XCTestCase {
    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmlive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("keep/deep"),
                                                withIntermediateDirectories: true)
        try Data(count: 500_000).write(to: root.appendingPathComponent("keep/deep/big.bin"))
        try Data(count: 100_000).write(to: root.appendingPathComponent("top.bin"))
        return root
    }

    /// Adding a file must show up in every ancestor total, not just its folder.
    func testRelistPicksUpNewFileAndPropagates() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path)))
        let before = live.withStore { $0.totalLogical[0] }

        try Data(count: 250_000).write(to: root.appendingPathComponent("keep/added.bin"))
        live.refresh(directory: root.appendingPathComponent("keep").path)

        let after = live.withStore { $0.totalLogical[0] }
        XCTAssertEqual(after - before, 250_000)
    }

    /// A relist of one directory must not rescan or lose untouched subtrees.
    func testRelistReusesUntouchedSubtree() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path)))

        try Data(count: 1_000).write(to: root.appendingPathComponent("sibling.bin"))
        live.refresh(directory: root.path)

        let deepStillThere = live.withStore { store -> Bool in
            store.find(path: root.appendingPathComponent("keep/deep/big.bin").path) != nil
        }
        XCTAssertTrue(deepStillThere, "untouched subtree must survive a parent relist")
        XCTAssertEqual(live.withStore { $0.totalLogical[0] }, 601_000)
    }

    func testDeletionRemovesBytesFromAncestors() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path)))

        try FileManager.default.removeItem(at: root.appendingPathComponent("keep/deep/big.bin"))
        live.refresh(directory: root.appendingPathComponent("keep/deep").path)

        XCTAssertEqual(live.withStore { $0.totalLogical[0] }, 100_000)
    }

    func testMarkRemovedIsImmediate() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path)))
        let node = live.withStore { $0.find(path: root.appendingPathComponent("top.bin").path) }
        live.markRemoved(node!)
        XCTAssertEqual(live.withStore { $0.totalLogical[0] }, 500_000)
    }
}

final class IntegrationTests: XCTestCase {
    /// Trash must be the real Trash, or Finder's Put Back will not work.
    func testMoveToTrashUsesRealTrashAndCanRestore() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmtrash-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let victim = dir.appendingPathComponent("victim.bin")
        try Data(count: 12_345).write(to: victim)

        var seen = stat()
        XCTAssertEqual(lstat(victim.path, &seen), 0)
        let (trashed, failures) = try FileActions.moveToTrash(
            [FileActions.Target(url: victim, node: 1, bytes: 12_345, isFolder: false,
                                length: 12_345,
                                modified: Int32(truncatingIfNeeded: seen.st_mtimespec.tv_sec))])
        XCTAssertTrue(failures.isEmpty, "trash failed: \(failures)")
        XCTAssertEqual(trashed.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: victim.path), "original should be gone")

        let item = try XCTUnwrap(trashed.first)
        let inTrash = try XCTUnwrap(item.trashURL)
        XCTAssertTrue(fm.fileExists(atPath: inTrash.path), "should now be in Trash")

        try FileActions.restore(item)
        XCTAssertTrue(fm.fileExists(atPath: victim.path), "restore should put it back")
    }

    /// End-to-end: a write on disk must reach the tree through FSEvents alone.
    func testFSEventsUpdatesTreeWithoutRescan() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmwatch-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: root.appendingPathComponent("seed.bin"))
        defer { try? fm.removeItem(at: root) }

        // Deliberately the unresolved path: NSTemporaryDirectory() hands back
        // /var/folders/... while FSEvents reports /private/var/folders/...
        let live = LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path)))
        let resolved = URL(fileURLWithPath: live.rootPath)
        let before = live.withStore { $0.totalLogical[0] }
        XCTAssertEqual(before, 10_000)

        let changed = expectation(description: "tree observed the new file")
        changed.assertForOverFulfill = false
        live.onChange = { changed.fulfill() }
        live.startWatching()
        defer { live.stopWatching() }

        // FSEvents needs the stream to be live before the write lands.
        Thread.sleep(forTimeInterval: 0.6)
        try Data(count: 40_000).write(to: resolved.appendingPathComponent("late.bin"))

        wait(for: [changed], timeout: 15)
        XCTAssertEqual(live.withStore { $0.totalLogical[0] }, 50_000)
    }
}

final class NameInterningTests: XCTestCase {
    /// Interning shares one copy of each distinct name. If the table ever
    /// returned the wrong offset, names would silently swap between files.
    func testRepeatedNamesStillReadBackCorrectly() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmintern-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        // The same handful of names repeated across many folders, plus names
        // that differ only in their last byte.
        var expected = Set<String>()
        for i in 0..<40 {
            let dir = root.appendingPathComponent("pkg-\(i)/Contents/Resources")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in ["Info.plist", "package.json", ".DS_Store", "readme", "readmf"] {
                try Data(count: 16).write(to: dir.appendingPathComponent(name))
                expected.insert(name)
            }
            expected.formUnion(["pkg-\(i)", "Contents", "Resources"])
        }

        let store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        var seen = Set<String>()
        for id in 1..<Int32(store.count) { seen.insert(store.name(id)) }
        XCTAssertEqual(seen, expected)

        // Every file must still resolve by its full path.
        for i in 0..<40 {
            let path = root.appendingPathComponent("pkg-\(i)/Contents/Resources/readme").path
            let node = try XCTUnwrap(store.find(path: path), "missing \(path)")
            XCTAssertEqual(store.name(node), "readme")
        }
    }

    /// Names are compared against what the filesystem actually stored, not
    /// against what we asked for: Foundation normalises to NFD, so a 100-char
    /// "ä" name becomes 300 bytes and the filesystem truncates it at NAME_MAX
    /// (255). That truncation is also why one byte is the right width for the
    /// stored length.
    func testLongAndMultibyteNamesSurviveInterning() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmlong-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data(count: 8).write(to: root.appendingPathComponent(String(repeating: "a", count: 200)))
        try Data(count: 8).write(to: root.appendingPathComponent(String(repeating: "ä", count: 60)))
        try Data(count: 8).write(to: root.appendingPathComponent("üñïçø∂é-ﬁle"))

        let onDisk = Set(try fm.contentsOfDirectory(atPath: root.path))
        let store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        let scanned = Set((1..<Int32(store.count)).map { store.name($0) })
        XCTAssertEqual(scanned, onDisk)
        XCTAssertTrue(scanned.contains(String(repeating: "a", count: 200)))
    }

    /// A folder whose absolute path is longer than the system will accept in
    /// one `open`.
    ///
    /// Built the way npm, git and rsync build one - each level created relative
    /// to the one above, which has no length limit - and then walked from the
    /// top, which does.
    func testATreeDeeperThanPathMaxIsStillWalked() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmdeep-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let name = String(repeating: "d", count: 200)
        var fd = open(root.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var depth = 0
        while depth < 12 {
            let made = name.withCString { mkdirat(fd, $0, 0o755) }
            XCTAssertEqual(made, 0, "could not create level \(depth)")
            let next = name.withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY) }
            close(fd)
            XCTAssertGreaterThanOrEqual(next, 0, "could not open level \(depth)")
            fd = next
            depth += 1
        }
        let file = "buried.bin".withCString { openat(fd, $0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
        XCTAssertGreaterThanOrEqual(file, 0)
        var bytes = [UInt8](repeating: 7, count: 9_999)
        _ = bytes.withUnsafeMutableBytes { Darwin.write(file, $0.baseAddress, 9_999) }
        close(file)
        close(fd)

        // The case only exists if the path really is past the limit.
        let deepest = root.path + String(repeating: "/" + name, count: depth)
        XCTAssertGreaterThan(deepest.utf8.count, Int(PATH_MAX),
                             "the tree is not deep enough to reach the case")

        let result = DiskScanner().scan(ScanOptions(rootPath: root.path))
        XCTAssertEqual(result.stats.unreadableDirectories, 0,
                       "folders that can be opened are reported unreadable: "
                       + result.stats.unreadableSamples.joined(separator: ", "))
        XCTAssertEqual(result.stats.directories, depth)
        XCTAssertEqual(result.stats.files, 1, "the file at the bottom was never counted")
        XCTAssertEqual(result.store.totalLogical[0], 9_999)
    }

    /// An inode number only means something on the volume that issued it.
    ///
    /// Two freshly formatted volumes hand out the same low numbers, so a scan
    /// covering roots on both would see one file where there are two, and zero
    /// the second one's bytes. Measured on two 20 MB images holding six
    /// hardlinked pairs each: 17 extra links reported where there were 12.
    func testTheSameInodeOnTwoVolumesIsTwoFiles() {
        let inodes = InodeSet()
        XCTAssertTrue(inodes.isFirstSighting(onDevice: 100, 21))
        XCTAssertTrue(inodes.isFirstSighting(onDevice: 200, 21),
                      "inode 21 on a second volume is a different file")
        XCTAssertFalse(inodes.isFirstSighting(onDevice: 100, 21),
                       "the same inode on the same volume is the same file")
        XCTAssertFalse(inodes.isFirstSighting(onDevice: 200, 21))
        XCTAssertTrue(inodes.isFirstSighting(onDevice: 100, 22))
    }
}
