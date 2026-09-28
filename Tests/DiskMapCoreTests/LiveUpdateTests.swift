import XCTest
import DiskMapCore
@testable import DiskMapScan

/// Regressions from the live-update path, where a relist re-points untouched
/// subtrees at freshly appended parents.
final class LiveUpdateTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("dmlive-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func tree() -> LiveTree {
        LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path)))
    }

    private func signature(_ tree: LiveTree, _ path: String) -> UInt64 {
        tree.withStore { store in
            guard let node = store.find(path: root.appendingPathComponent(path).path) else { return 0 }
            return FolderMatches.signatures(store)[Int(node)]
        }
    }

    /// After a relist, a reattached folder's children sit at a LOWER index than
    /// the folder itself. Hashing by descending index therefore hashed parents
    /// before their children, and every reattached folder with the same number
    /// of children came out with the same hash — a flood of "identical" folders
    /// that hold completely different things.
    func testFolderHashesSurviveARelist() throws {
        try write("a/x.bin", 10_000)
        try write("a/y.bin", 20_000)
        try write("b/p.bin", 30_000)
        try write("b/q.bin", 40_000)

        let tree = tree()
        let beforeA = signature(tree, "a"), beforeB = signature(tree, "b")
        XCTAssertNotEqual(beforeA, 0)
        XCTAssertNotEqual(beforeA, beforeB)

        // A new name in the folder forces the append path, which is what
        // re-points a/ and b/ at new nodes.
        try write("newcomer.bin", 5_000)
        XCTAssertTrue(tree.refresh(directory: root.path))

        XCTAssertEqual(signature(tree, "a"), beforeA)
        XCTAssertEqual(signature(tree, "b"), beforeB)
        XCTAssertNotEqual(signature(tree, "a"), signature(tree, "b"))
    }

    /// The same defect seen from the outside: two folders holding different
    /// things must not be reported as copies of each other after a relist.
    func testDifferentFoldersAreNotCopiesAfterARelist() throws {
        try write("a/x.bin", 10_000)
        try write("a/y.bin", 20_000)
        try write("b/p.bin", 30_000)
        try write("b/q.bin", 40_000)

        let tree = tree()
        try write("newcomer.bin", 5_000)
        tree.refresh(directory: root.path)

        let matches = tree.withStore { FolderMatches.find(store: $0, root: 0, minimumSize: 1_000) }
        XCTAssertTrue(matches.isEmpty, "reported \(matches.count) bogus folder matches")
    }

    /// A file changing size is the most common event there is. Appending a new
    /// row for every entry each time grew the store without bound over a
    /// working day, since the old rows are only marked removed.
    func testAFileChangingSizeDoesNotGrowTheStore() throws {
        try write("logs/output.log", 4_000)
        try write("logs/other.log", 4_000)
        let tree = tree()
        let before = tree.withStore { $0.count }

        for size in [8_000, 16_000, 32_000] {
            try write("logs/output.log", size)
            XCTAssertTrue(tree.refresh(directory: root.appendingPathComponent("logs").path))
        }

        XCTAssertEqual(tree.withStore { $0.count }, before)
        let totals = tree.withStore { store -> (Int64, Int64) in
            let node = store.find(path: root.appendingPathComponent("logs").path)!
            return (store.totalLogical[Int(node)], store.totalLogical[0])
        }
        XCTAssertEqual(totals.0, 36_000)
        // The change has to reach the ancestors, not just the folder itself.
        XCTAssertEqual(totals.1, 36_000)
    }

    /// An unchanged folder is not a change, however often the event arrives.
    func testRelistingAnUnchangedFolderReportsNoChange() throws {
        try write("stuff/a.bin", 4_000)
        let tree = tree()
        XCTAssertFalse(tree.refresh(directory: root.appendingPathComponent("stuff").path))
        XCTAssertFalse(tree.refresh(directory: root.path))
    }

    func testVerifyingNothingIsNotACrash() throws {
        let store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        let plan = DeepVerify.plan(store: store, nodes: [])
        XCTAssertEqual(plan.files, 0)
        let outcome = DeepVerify.run(plan)
        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertFalse(outcome.identical)
    }
}

extension LiveUpdateTests {
    /// Caches keyed on the tree must see a change when the tree changes, and
    /// must not see one when it does not.
    func testChangeCountTracksTheTreeOnly() throws {
        try write("dir/a.bin", 4_000)
        let tree = tree()
        let start = tree.changeCount

        XCTAssertFalse(tree.refresh(directory: root.appendingPathComponent("dir").path))
        XCTAssertEqual(tree.changeCount, start, "an unchanged folder is not a change")

        try write("dir/a.bin", 9_000)
        tree.refresh(directory: root.appendingPathComponent("dir").path)
        XCTAssertEqual(tree.changeCount, start + 1, "a resize is a change")

        try write("dir/b.bin", 4_000)
        tree.refresh(directory: root.appendingPathComponent("dir").path)
        XCTAssertEqual(tree.changeCount, start + 2, "a new file is a change")

        let node = tree.withStore { $0.find(path: root.appendingPathComponent("dir/b.bin").path)! }
        tree.markRemoved(node)
        XCTAssertEqual(tree.changeCount, start + 3, "a trashed item is a change")
    }


    // MARK: - What a live update costs

    /// The scanner sizes its arrays from the volume's used-inode count, which
    /// `statfs` reports for the whole volume whatever path it is given. A live
    /// update scans every directory that has just appeared — thousands an hour,
    /// nearly all of them empty — and each one was reserving room for the entire
    /// disk. Handing the scanner a figure must not change a single byte of what
    /// it finds; it only changes what it allocates to find it.
    func testACallerSuppliedCapacityFindsExactlyTheSameTree() throws {
        try write("a/b/one.bin", 4_000)
        try write("a/b/two.bin", 6_000)
        try write("a/c/three.bin", 9_000)
        try write("loose.bin", 1_000)

        let full = DiskScanner().scan(ScanOptions(rootPath: root.path))
        var hinted = ScanOptions(rootPath: root.path)
        hinted.expectedNodes = 8
        hinted.threadCount = 2
        let small = DiskScanner().scan(hinted)

        XCTAssertEqual(small.store.count, full.store.count)
        XCTAssertEqual(small.store.totalLogical[0], full.store.totalLogical[0])
        XCTAssertEqual(small.stats.files, full.stats.files)
        XCTAssertEqual(small.stats.directories, full.stats.directories)
        XCTAssertEqual(FolderMatches.signatures(small.store)[0],
                       FolderMatches.signatures(full.store)[0])
    }

    /// The figure is a starting size, not a limit. A folder that appears with
    /// far more in it than the hint allowed for must still be measured whole,
    /// or the total on screen quietly understates the disk.
    func testTheCapacityHintIsAStartingSizeNotACap() throws {
        for i in 0..<400 { try write("big/f\(i).bin", 100) }
        var options = ScanOptions(rootPath: root.appendingPathComponent("big").path)
        options.expectedNodes = 8
        let result = DiskScanner().scan(options)
        XCTAssertEqual(result.stats.files, 400)
        XCTAssertEqual(result.store.totalLogical[0], 40_000)
    }

    /// A relist scans folders that have just appeared with a small hint. The
    /// bytes it reports have to match a plain scan of the same tree, otherwise
    /// the optimisation buys speed by lying.
    func testAFolderAppearingAfterTheScanIsMeasuredCorrectly() throws {
        try write("keep.bin", 1_000)
        let tree = self.tree()
        let before = tree.withStore { $0.totalLogical[0] }

        for i in 0..<50 { try write("fresh/deep/f\(i).bin", 500) }
        XCTAssertTrue(tree.refresh(directory: root.path))

        let plain = DiskScanner().scan(ScanOptions(rootPath: root.path))
        XCTAssertEqual(tree.withStore { $0.totalLogical[0] }, plain.store.totalLogical[0])
        XCTAssertGreaterThan(tree.withStore { $0.totalLogical[0] }, before)
    }

    /// A fixed debounce means a machine doing steady work keeps the tree busy
    /// permanently: the flush costs what it costs, and the next one is queued a
    /// third of a second later regardless. The wait now follows the cost, so a
    /// quiet disk stays responsive and a busy one settles into a duty cycle.
    func testTheDebounceFollowsWhatTheLastFlushCost() throws {
        let tree = self.tree()
        XCTAssertEqual(tree.flushDelay, 0.35, accuracy: 0.001)

        tree.lastFlushSeconds = 0.5
        XCTAssertEqual(tree.flushDelay, 2.5, accuracy: 0.001)

        // However expensive things get, an update still lands eventually.
        tree.lastFlushSeconds = 60
        XCTAssertEqual(tree.flushDelay, 8, accuracy: 0.001)
    }

    /// Suspension slows updates for a window nobody can see; it never stops
    /// them, because a tree that stopped following the disk is the one thing
    /// this app must not show when the window comes back.
    func testSuspendingSlowsUpdatesRatherThanStoppingThem() throws {
        let tree = self.tree()
        tree.setSuspended(true)
        XCTAssertTrue(tree.suspended)
        XCTAssertEqual(tree.flushDelay, 30, accuracy: 0.001)

        try write("added.bin", 2_000)
        XCTAssertTrue(tree.refresh(directory: root.path))
        XCTAssertEqual(tree.withStore { $0.totalLogical[0] }, 2_000)

        tree.setSuspended(false)
        XCTAssertFalse(tree.suspended)
        XCTAssertEqual(tree.flushDelay, 0.35, accuracy: 0.001)
    }

    /// A directory that cannot be opened right now is not a directory that has
    /// been deleted. Reading every failure as a deletion drops the folder's
    /// bytes out of every total above it and leaves it with no known children,
    /// so the next event on it rescans the whole subtree from scratch.
    func testAnUnreadableFolderIsNotTreatedAsDeleted() throws {
        try write("locked/inside.bin", 30_000)
        try write("other.bin", 1_000)
        let tree = self.tree()
        let locked = root.appendingPathComponent("locked")
        let total = tree.withStore { $0.totalLogical[0] }
        XCTAssertEqual(total, 31_000)

        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        // Running as root defeats the point of the fixture; nothing to assert.
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: locked.path))

        XCTAssertFalse(tree.refresh(directory: locked.path))
        XCTAssertEqual(tree.withStore { $0.totalLogical[0] }, total)
        let node = tree.withStore { $0.find(path: locked.path) }
        XCTAssertNotNil(node)
        XCTAssertFalse(tree.withStore { $0.flagSet(node!).contains(.removed) })
        XCTAssertEqual(tree.withStore { $0.children(node!).count }, 1)
    }

    /// The other half of the same decision: a folder that really is gone must
    /// still leave the totals, by both routes that reach it. A real deletion
    /// event resolves to the parent, because the deleted path no longer exists
    /// to be identified as a directory; relisting the folder itself only finds
    /// it when the path was already canonical, since realpath fails on it.
    func testADeletedFolderStillLeavesTheTotals() throws {
        try write("going/inside.bin", 30_000)
        try write("staying.bin", 1_000)
        let tree = self.tree()
        // In whatever form the store itself holds it: realpath fails once the
        // folder is gone, so a caller-supplied path is used verbatim and only
        // matches if it was already the stored form.
        let stored = tree.withStore { ($0.roots.first ?? "") + "/going" }
        XCTAssertEqual(tree.withStore { $0.totalLogical[0] }, 31_000)

        try fm.removeItem(at: root.appendingPathComponent("going"))
        XCTAssertTrue(tree.refresh(directory: stored))
        XCTAssertEqual(tree.withStore { $0.totalLogical[0] }, 1_000)
        let node = try XCTUnwrap(tree.withStore { $0.find(path: stored) })
        XCTAssertTrue(tree.withStore { $0.flagSet(node).contains(.removed) })
    }

    /// What an actual deletion event does: FSEvents reports a path that is no
    /// longer a directory, so it reduces to the parent and the folder goes when
    /// the parent is relisted.
    func testDeletingAFolderIsCaughtByRelistingItsParent() throws {
        try write("going/inside.bin", 30_000)
        try write("staying.bin", 1_000)
        let tree = self.tree()
        try fm.removeItem(at: root.appendingPathComponent("going"))
        XCTAssertTrue(tree.refresh(directory: root.path))
        XCTAssertEqual(tree.withStore { $0.totalLogical[0] }, 1_000)
    }

    /// A folder that costs a lot to relist is held off in proportion to what it
    /// cost, so one enormous churning directory cannot monopolise the update
    /// loop. The hold-off is a delay, never a refusal: the directory stays
    /// queued and is relisted as soon as its own wait is up.
    func testAnExpensiveFolderIsHeldOffInProportionToItsCost() throws {
        let tree = self.tree()
        let now = DispatchTime.now()

        // Nothing known about it yet: go ahead.
        XCTAssertNil(tree.holdOff("/somewhere", now: now))

        // A tenth of a second to relist buys a second of quiet.
        tree.noteRelist("/somewhere", cost: 0.1, at: now)
        let wait = try XCTUnwrap(tree.holdOff("/somewhere", now: now))
        XCTAssertEqual(wait, 1.0, accuracy: 0.05)

        // And the wait runs down rather than restarting.
        let later = DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + 600_000_000)
        XCTAssertEqual(try XCTUnwrap(tree.holdOff("/somewhere", now: later)), 0.4, accuracy: 0.05)
        let after = DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + 1_100_000_000)
        XCTAssertNil(tree.holdOff("/somewhere", now: after))
    }

    /// However expensive a folder is, the tree never goes more than the ceiling
    /// out of date on it.
    func testTheHoldOffIsCapped() throws {
        let tree = self.tree()
        let now = DispatchTime.now()
        tree.noteRelist("/enormous", cost: 60, at: now)
        XCTAssertEqual(try XCTUnwrap(tree.holdOff("/enormous", now: now)), 30, accuracy: 0.05)
    }

    /// The table cannot grow without bound on a machine that touches tens of
    /// thousands of directories.
    func testTheHoldOffTableStaysBounded() throws {
        let tree = self.tree()
        for i in 0..<5000 {
            tree.noteRelist("/d\(i)", cost: 0.001,
                            at: DispatchTime(uptimeNanoseconds: UInt64(i + 1) * 1_000_000))
        }
        XCTAssertLessThanOrEqual(tree.lastRelistCount, 4096)
        // What survived is the recently seen end, not an arbitrary slice.
        XCTAssertNotNil(tree.holdOff("/d4999", now: DispatchTime(uptimeNanoseconds: 5_000_000_000)))
    }

    /// A tick refers to a node. A relist appends new nodes for every entry in
    /// the folder and marks the old ones removed, so anything else changing in
    /// that folder silently invalidates the tick — and the planner then calls
    /// the file "already gone" while it is sitting right there.
    func testATickSurvivesSomethingElseChangingInTheSameFolder() throws {
        try write("album/doomed.bin", 4_000)
        try write("album/bystander.bin", 4_000)
        let tree = self.tree()
        let doomed = try XCTUnwrap(tree.withStore { $0.find(
            path: root.appendingPathComponent("album/doomed.bin").path) })

        // Something unrelated lands in the same folder.
        try write("album/arrived.bin", 500)
        XCTAssertTrue(tree.refresh(directory: root.appendingPathComponent("album").path))

        let stillThere = FileManager.default.fileExists(
            atPath: root.appendingPathComponent("album/doomed.bin").path)
        XCTAssertTrue(stillThere, "the ticked file is still on disk")

        tree.withStore { store in
            XCTAssertFalse(store.flagSet(store.current(doomed)).contains(.removed),
                           "the ticked file cannot be followed to where it went when a "
                           + "different file arrived beside it")
            switch TrashPlanner.plan(store: store, selected: [doomed]) {
            case .failure(let refusal):
                XCTFail("refused: \(refusal)")
            case .success(let plan):
                XCTAssertEqual(plan.alreadyGone, 0,
                               "the planner calls a file that is right there already gone")
                XCTAssertEqual(plan.items.count, 1)
            }
        }
    }

    /// Following is only safe while the entry is the same entry. A name reused
    /// by different bytes must not inherit a tick made about the old ones.
    func testATickDoesNotFollowANameOnToDifferentBytes() throws {
        try write("album/doomed.bin", 4_000)
        try write("album/bystander.bin", 4_000)
        let tree = self.tree()
        let doomed = try XCTUnwrap(tree.withStore { $0.find(
            path: root.appendingPathComponent("album/doomed.bin").path) })

        // Same name, different file, and something else changes too so the
        // folder is rebuilt rather than resized in place.
        try fm.removeItem(at: root.appendingPathComponent("album/doomed.bin"))
        try write("album/doomed.bin", 90_000)
        try write("album/arrived.bin", 500)
        XCTAssertTrue(tree.refresh(directory: root.appendingPathComponent("album").path))

        tree.withStore { store in
            XCTAssertEqual(store.current(doomed), doomed,
                           "a tick followed a name on to bytes it was never made about")
            XCTAssertTrue(store.flagSet(doomed).contains(.removed))
        }
    }

    /// The listing hands the relist bytes, and the relist writes bytes back.
    /// Decoding in between — which is what the old path did — would have
    /// re-appended every name in this folder through a String, and a name
    /// the String could not carry would have come back as U+FFFD.
    ///
    /// The disk refuses to create a name outside UTF-8, so the check is made
    /// on names outside ASCII, where the bytes on disk are already not the
    /// bytes of the String: Foundation decomposes "ö" on the way in, and what
    /// the store must hold is the disk's form, not the caller's.
    func testARelistKeepsNamesAsTheListingGaveThem() throws {
        let name = "ölçüm–2026 🎞.bin"
        try write("albüm/\(name)", 4_000)
        try write("albüm/bystander.bin", 4_000)
        let tree = self.tree()
        let before = try XCTUnwrap(tree.withStore { $0.find(
            RawPath(root.appendingPathComponent("albüm").path).appending(Array(name.utf8))) })
        let bytes = tree.withStore { $0.nameBytes(of: before) }

        // Something else changes, so the folder is rebuilt rather than resized.
        try write("albüm/arrived.bin", 500)
        // And a folder appears whose name is outside ASCII, so the fresh
        // subtree is measured through the byte path too.
        try write("albüm/yeni klasör 🎞/içerik.bin", 7_000)
        XCTAssertTrue(tree.refresh(directory: root.appendingPathComponent("albüm").path))

        tree.withStore { store in
            let after = store.current(before)
            XCTAssertNotEqual(after, before, "the folder was not rebuilt, so nothing was checked")
            XCTAssertEqual(store.nameBytes(of: after), bytes)
            XCTAssertEqual(store.find(RawPath(root.appendingPathComponent("albüm").path)
                                          .appending(Array(name.utf8))), after)
            let freshURL = root.appendingPathComponent("albüm/yeni klasör 🎞")
            let fresh = store.find(path: freshURL.path)
            XCTAssertEqual(fresh.map { store.totalLogical[Int($0)] }, 7_000)
            XCTAssertEqual(fresh.map { store.nameBytes(of: $0) },
                           canonicalPath(RawPath(freshURL.path)).map { Array($0.lastComponent) },
                           "the fresh folder's name is not the disk's form of it")
            XCTAssertEqual(store.find(path: root.appendingPathComponent("albüm").path)
                               .map { store.totalLogical[Int($0)] }, 15_500)
        }
    }

    /// A folder that appears is announced by an event naming the folder,
    /// which the store has never seen. Reducing that event to "relist the
    /// folder" found nothing and added nothing: the folder, and everything
    /// written into it since, stayed out of the tree until something else
    /// happened to touch its parent. Found by the watcher test below; kept
    /// here without the watcher so it runs in a millisecond.
    func testAFolderTheStoreHasNeverSeenIsReachedThroughItsParent() throws {
        try write("albüm/bystander.bin", 100)
        let tree = self.tree()
        try write("yeni klasör/derin/içerik.bin", 7_000)
        try write("albüm/ölçüm.bin", 4_000)

        // What the watcher hands over: the new folders and files themselves,
        // in the same batch as a change inside a folder the store knows.
        tree.flushNow(events: ["yeni klasör", "yeni klasör/derin", "yeni klasör/derin/içerik.bin",
                               "albüm/ölçüm.bin"].map { RawPath(root.appendingPathComponent($0).path) })

        tree.withStore { store in
            XCTAssertEqual(store.find(path: root.appendingPathComponent("yeni klasör/derin/içerik.bin").path)
                               .map { store.totalLogical[Int($0)] }, 7_000)
            XCTAssertEqual(store.find(path: root.appendingPathComponent("albüm").path)
                               .map { store.totalLogical[Int($0)] }, 4_100,
                           "the known sibling's change was dropped from the batch")
            XCTAssertEqual(store.find(path: root.path).map { store.totalLogical[Int($0)] }, 11_100)
            assertWellFormed(store)
        }
    }

    /// A folder that appeared with things in it is listed with those things.
    /// `graft` set the child ranges of every node it copied except the one it
    /// was grafting under, so the folder carried its total and listed nothing;
    /// and grafted in the middle of its parent's rebuild, its nodes landed
    /// inside the parent's child run, which then listed the subtree's nodes
    /// as its own and lost every sibling appended after. Listing order on
    /// APFS is not alphabetical, so which sibling vanished depended on the
    /// hash of its name.
    func testAFolderThatAppearsWithContentsListsThem() throws {
        for n in ["a", "b", "c", "d", "e", "f", "g", "h"] { try write("\(n)/x.bin", 10) }
        let tree = self.tree()
        try write("fresh/deep/one.bin", 500)
        try write("fresh/two.bin", 300)
        XCTAssertTrue(tree.refresh(directory: root.path))

        tree.withStore { store in
            let rootNode = store.find(path: root.path)!
            XCTAssertEqual(store.children(rootNode).count, 9)
            for n in ["a", "b", "c", "d", "e", "f", "g", "h"] {
                XCTAssertNotNil(store.find(path: root.appendingPathComponent("\(n)/x.bin").path),
                                "\(n) fell out of the tree")
            }
            let fresh = store.find(path: root.appendingPathComponent("fresh").path)!
            XCTAssertEqual(store.children(fresh).count, 2)
            XCTAssertEqual(store.totalLogical[Int(fresh)], 800)
            XCTAssertNotNil(store.find(path: root.appendingPathComponent("fresh/deep/one.bin").path))
            XCTAssertEqual(store.totalLogical[Int(rootNode)], 880)
            assertWellFormed(store)
        }
    }

    /// A tree unpacked in one go, then deleted in one go: thousands of
    /// events naming folders the store has never seen, then thousands naming
    /// folders that no longer exist. Each batch is one relist of the folder
    /// that held them — measured, a burst of twelve thousand events costs
    /// under a fifth of a second in a release build — and the tree agrees
    /// with a fresh scan after both.
    func testABurstOfNewFoldersAndTheirDeletionKeepTheTreeRight() throws {
        try write("known/a.bin", 1)
        let tree = self.tree()
        var events: [RawPath] = []
        for d in 0..<300 {
            let dir = root.appendingPathComponent("fresh/pkg\(d)/lib")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            events += [RawPath(dir.deletingLastPathComponent().path), RawPath(dir.path)]
            for f in 0..<3 {
                let file = dir.appendingPathComponent("m\(f).js")
                try Data(count: 10).write(to: file)
                events.append(RawPath(file.path))
            }
        }
        events.append(RawPath(root.appendingPathComponent("fresh").path))
        tree.flushNow(events: events)
        XCTAssertEqual(tree.changeCount, 1, "one folder held all of it; one relist should have done")
        var oracle = ScanOptions(rootPath: root.path); oracle.threadCount = 2
        XCTAssertEqual(differences(tree.withStore { reachable($0) },
                                   reachable(DiskScanner().scan(oracle).store)), [])

        let inside = fm.enumerator(at: root.appendingPathComponent("fresh"),
                                   includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
        try fm.removeItem(at: root.appendingPathComponent("fresh"))
        tree.flushNow(events: inside.map { RawPath($0.path) }
                      + [RawPath(root.appendingPathComponent("fresh").path)])
        XCTAssertEqual(tree.changeCount, 2)
        XCTAssertEqual(differences(tree.withStore { reachable($0) },
                                   reachable(DiskScanner().scan(oracle).store)), [])
        tree.withStore { assertWellFormed($0) }
    }

    /// A second link to a file the scan already counted. The walk gives the
    /// bytes to the first link it meets and flags the rest; a relist that
    /// re-appends the flagged link from the listing, where it is just a
    /// file, would count the bytes again — pnpm lays a whole node_modules
    /// out as hard links, so this is not exotic.
    ///
    /// Which link keeps the bytes is whichever the walk met first, and two
    /// walks need not agree, so the check is on what does not depend on it:
    /// the same files, the same logical size on every one of them, and the
    /// same physical total at the root.
    func testARelistDoesNotCountAHardLinkTwice() throws {
        try write("data/big.bin", 50_000)
        try write("data/other.bin", 1_000)
        try fm.createDirectory(at: root.appendingPathComponent("links"), withIntermediateDirectories: true)
        try fm.linkItem(at: root.appendingPathComponent("data/big.bin"),
                        to: root.appendingPathComponent("links/big-link.bin"))
        let tree = self.tree()
        func agree(_ why: String) {
            var oracle = ScanOptions(rootPath: root.path); oracle.threadCount = 2
            let fresh = reachable(DiskScanner().scan(oracle).store)
            let live = tree.withStore { reachable($0) }
            XCTAssertEqual(Set(live.keys), Set(fresh.keys), why)
            for (k, e) in live { XCTAssertEqual(e.logical, fresh[k]?.logical, "\(why): \(k)") }
            XCTAssertEqual(live[root.path]?.physical, fresh[root.path]?.physical, "\(why): the bytes on disk")
        }
        agree("before anything moved")

        // The folder holding the flagged link is rebuilt.
        try write("links/arrived.bin", 10)
        tree.flushNow(events: [RawPath(root.appendingPathComponent("links/arrived.bin").path)])
        agree("after the link's folder was rebuilt")

        // A new link to a counted file appears in a folder the store knows.
        try fm.linkItem(at: root.appendingPathComponent("data/big.bin"),
                        to: root.appendingPathComponent("data/again.bin"))
        tree.flushNow(events: [RawPath(root.appendingPathComponent("data/again.bin").path)])
        agree("after a new link appeared")

        // And in a folder that appears with the link inside it.
        try fm.createDirectory(at: root.appendingPathComponent("fresh"), withIntermediateDirectories: true)
        try fm.linkItem(at: root.appendingPathComponent("data/big.bin"),
                        to: root.appendingPathComponent("fresh/third.bin"))
        tree.flushNow(events: [RawPath(root.appendingPathComponent("fresh").path),
                               RawPath(root.appendingPathComponent("fresh/third.bin").path)])
        agree("after a folder with a link appeared")

        // The link that keeps the bytes goes; another must take them over,
        // since the file is still on disk under its other names.
        let links = ["data/big.bin", "data/again.bin", "links/big-link.bin", "fresh/third.bin"]
        let keeper = try XCTUnwrap(tree.withStore { store in
            links.first { store.find(path: root.appendingPathComponent($0).path)
                .map { !store.flagSet($0).contains(.hardlinkDuplicate) } == true }
        })
        try fm.removeItem(at: root.appendingPathComponent(keeper))
        tree.flushNow(events: [RawPath(root.appendingPathComponent(keeper).path)])
        agree("after the keeper \(keeper) was deleted")
        XCTAssertEqual(tree.withStore { $0.totalPhysical[0] }, 53_248 + 4_096 + 4_096,
                       "the bytes are still on disk under the other names")

        // And when the keeper goes with its whole folder.
        let keeper2 = try XCTUnwrap(tree.withStore { store in
            links.first { store.find(path: root.appendingPathComponent($0).path)
                .map { !store.flagSet($0).contains(.hardlinkDuplicate) } == true }
        })
        let folder = root.appendingPathComponent(keeper2).deletingLastPathComponent()
        let inside = fm.enumerator(at: folder, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
        try fm.removeItem(at: folder)
        tree.flushNow(events: inside.map { RawPath($0.path) } + [RawPath(folder.path)])
        agree("after the keeper's folder \(folder.lastPathComponent) was deleted")
    }

    /// The app's own ways into the tree — `markRemoved` after a trash,
    /// `refresh` after an undo — run on the main thread, outside any flush.
    /// A hard link either of them puts in question is settled straight after
    /// on the apply queue, not whenever some later event brings a flush:
    /// no events are delivered here, and the bytes still have to move.
    func testTrashingOrRestoringAHardLinkSettlesItsBytesWithoutAnEvent() throws {
        try write("a/big.bin", 50_000)
        try fm.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try fm.linkItem(at: root.appendingPathComponent("a/big.bin"),
                        to: root.appendingPathComponent("b/big.bin"))
        let tree = self.tree()
        let bytes = tree.withStore { $0.totalPhysical[0] }
        func node(_ rel: String) -> Int32? {
            tree.withStore { $0.find(path: root.appendingPathComponent(rel).path) }
        }
        func duplicate(_ rel: String) -> Bool? {
            tree.withStore { store in node(rel).map { store.flagSet($0).contains(.hardlinkDuplicate) } }
        }
        func eventually(_ why: String, _ holds: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !holds(), Date() < deadline { usleep(10_000) }
            XCTAssertTrue(holds(), why)
        }
        // Which name keeps the bytes is whichever the walk met first.
        let keeper = duplicate("a/big.bin") == false ? "a/big.bin" : "b/big.bin"
        let other = keeper == "a/big.bin" ? "b/big.bin" : "a/big.bin"

        // Trashed: moved out of the tree, and the tree told directly.
        let trashed = try XCTUnwrap(node(keeper))
        let aside = URL(fileURLWithPath: fm.temporaryDirectory.path)
            .appendingPathComponent("dmaside-\(UUID().uuidString)")
        try fm.moveItem(at: root.appendingPathComponent(keeper), to: aside)
        defer { try? fm.removeItem(at: aside) }
        tree.markRemoved(trashed)
        eventually("the name left behind takes the bytes over") {
            duplicate(other) == false && tree.withStore { $0.totalPhysical[0] } == bytes
        }

        // Restored: moved back, and its folder refreshed.
        try fm.moveItem(at: aside, to: root.appendingPathComponent(keeper))
        tree.refresh(directory: root.appendingPathComponent(keeper).deletingLastPathComponent().path)
        eventually("two names again, one file, counted once") {
            [keeper, other].compactMap(duplicate).filter { $0 }.count == 1
                && tree.withStore { $0.totalPhysical[0] } == bytes
        }
    }

    /// A folder and one of its subfolders, both known, both changed within
    /// one debounce window. The parent's relist keeps the child's subtree as
    /// it was, so the child's own relist must still happen.
    func testAChangedSubfolderIsNotCoveredByItsParentsRelist() throws {
        try write("top.bin", 100)
        try write("iç/old.bin", 100)
        let tree = self.tree()
        try write("top2.bin", 1_000)
        try write("iç/new.bin", 5_000)

        tree.flushNow(events: ["top2.bin", "iç/new.bin"].map { RawPath(root.appendingPathComponent($0).path) })

        tree.withStore { store in
            XCTAssertEqual(store.find(path: root.appendingPathComponent("iç").path)
                               .map { store.totalLogical[Int($0)] }, 5_100)
            XCTAssertEqual(store.find(path: root.path).map { store.totalLogical[Int($0)] }, 6_200)
        }
    }

    /// The same road with the file system driving it: FSEvents hands the
    /// watcher C strings, the watcher hands the tree bytes, the tree relists.
    /// Every other test here calls `refresh` by hand, so a watcher whose
    /// callback read the wrong pointer type would pass all of them and update
    /// nothing in the app. Polled with a deadline: the stream's latency is
    /// 0.4 s and the flush waits 0.35 s more, so it normally lands in two.
    func testTheWatcherCarriesNamesThroughToTheStore() throws {
        try write("albüm/bystander.bin", 100)
        let tree = self.tree()
        tree.startWatching()
        defer { tree.stopWatching() }
        XCTAssertTrue(tree.liveUpdatesActive)

        try write("albüm/ölçüm–2026 🎞.bin", 4_000)
        try write("yeni klasör 🎞/içerik.bin", 7_000)

        let deadline = Date().addingTimeInterval(20)
        while tree.changeCount == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        // Two folders changed; they may land in one flush or two.
        let secondDeadline = Date().addingTimeInterval(5)
        while Date() < secondDeadline,
              tree.withStore({ $0.find(path: root.appendingPathComponent("yeni klasör 🎞").path) == nil
                  || $0.find(path: root.appendingPathComponent("albüm/ölçüm–2026 🎞.bin").path) == nil }) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertGreaterThan(tree.changeCount, 0, "no event reached the tree in 20 s")

        tree.withStore { store in
            let fresh = store.find(path: root.appendingPathComponent("yeni klasör 🎞").path)
            XCTAssertEqual(fresh.map { store.totalLogical[Int($0)] }, 7_000)
            XCTAssertEqual(fresh.map { store.nameBytes(of: $0) },
                           canonicalPath(RawPath(root.appendingPathComponent("yeni klasör 🎞").path))
                               .map { Array($0.lastComponent) })
            let file = store.find(path: root.appendingPathComponent("albüm/ölçüm–2026 🎞.bin").path)
            XCTAssertEqual(file.map { store.totalLogical[Int($0)] }, 4_000)
            XCTAssertEqual(store.find(path: root.path).map { store.totalLogical[Int($0)] }, 11_100)
        }
    }

    /// A folder's hash is not a function of the store alone: a symlink
    /// contributes where it points, which is read from disk at hashing time and
    /// never stored. So the report cache — keyed on the tree's change counter —
    /// has to be invalidated by a relist that saw a symlink move, and the only
    /// thing in the store that moves with it is the date.
    ///
    /// Re-pointing `current` from one release to another of the same length is
    /// the ordinary shape of a deploy tree, and it changes no size at all.
    ///
    /// The date is stored to the second, so the re-point is given a date the
    /// store cannot mistake for the old one. Two changes inside one second are
    /// invisible here for the same reason they are invisible to the re-check
    /// before a deletion, and that limit is the subject of its own note rather
    /// than something this test can hide by sleeping.
    func testRepointingASymlinkCountsAsAChange() throws {
        try write("releases/2026-01/app.bin", 10_000)
        try write("releases/2026-02/app.bin", 20_000)
        let link = root.appendingPathComponent("live/current")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../releases/2026-01")

        let tree = tree()
        let before = signature(tree, "live")
        let revisionBefore = tree.changeCount

        try fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../releases/2026-02")
        setLinkDate(link, secondsAgo: 3600)

        XCTAssertTrue(tree.refresh(directory: link.deletingLastPathComponent().path),
                      "the relist reported nothing happened, so nothing downstream re-reads")
        XCTAssertGreaterThan(tree.changeCount, revisionBefore,
                             "the folder now points somewhere else and the revision did not move, "
                             + "so every cache keyed on it keeps the answer for where it used to point")
        XCTAssertNotEqual(signature(tree, "live"), before)
    }

    /// Sets a symlink's own date without following it.
    private func setLinkDate(_ url: URL, secondsAgo: Int) {
        var times = [timeval(tv_sec: time(nil) - secondsAgo, tv_usec: 0),
                     timeval(tv_sec: time(nil) - secondsAgo, tv_usec: 0)]
        XCTAssertEqual(url.path.withCString { lutimes($0, &times) }, 0)
    }

}
