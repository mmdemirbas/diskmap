import DiskMapCore
import XCTest

/// The cases where a wrong answer costs somebody a file.
///
/// Separate from the tests that describe what the comparison does, because
/// these are not about behaviour anybody asked for — they are the shapes on
/// disk that make a metadata comparison say "these are the same" when they are
/// not, and the question is only ever whether the destructive paths still
/// refuse.
final class SyncSafetyTests: XCTestCase {
    private var root: URL!
    private var left: URL!
    private var right: URL!
    private let fm = FileManager.default
    private var trashed: [URL] = []

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmsafe-\(UUID().uuidString)")
        left = root.appendingPathComponent("left")
        right = root.appendingPathComponent("right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        left = URL(fileURLWithPath: canonicalPath(left.path) ?? left.path)
        right = URL(fileURLWithPath: canonicalPath(right.path) ?? right.path)
    }

    override func tearDownWithError() throws {
        for url in trashed { try? fm.removeItem(at: url) }
        trashed = []
        if let root { try? fm.removeItem(at: root) }
    }

    private func write(_ base: URL, _ relative: String, bytes: Int, fill: UInt8 = 0) throws {
        let url = base.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    /// Writes a file whose name keeps exactly the bytes given.
    ///
    /// `URL` and `FileManager` both run a path through the file-system
    /// representation, which on Darwin decomposes it, so neither can create a
    /// precomposed name.
    private func writeRaw(_ base: URL, _ name: String, bytes: Int, fill: UInt8) throws {
        let path = base.path + "/" + name
        let fd = path.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
        try XCTUnwrap(fd >= 0 ? true : nil, "could not create \(name)")
        var data = [UInt8](repeating: fill, count: bytes)
        _ = data.withUnsafeMutableBytes { Darwin.write(fd, $0.baseAddress, bytes) }
        close(fd)
    }

    private func link(_ base: URL, _ relative: String, to target: String) throws {
        let url = base.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    private func compare(_ options: CompareOptions = CompareOptions()) throws -> FolderComparison {
        switch FolderDiff.compare(left: left.path, right: right.path, options: options) {
        case .success(let c): return c
        case .failure(let f): XCTFail("refused: \(f)"); throw f
        }
    }

    // MARK: - Symlinks

    /// Two links of the same name pointing at different places are the same
    /// length on disk, so nothing in the metadata separates them — and the
    /// content check reads regular files, so it cannot separate them either.
    /// Whatever the screen offers, it must not offer to delete one of them as
    /// a copy of the other.
    func testTwoLinksToDifferentPlacesAreNotCopiesOfEachOther() throws {
        try link(left, "shortcut", to: "/Users/aaaa")
        try link(right, "shortcut", to: "/Users/bbbb")

        let c = try compare()
        let entry = try XCTUnwrap(c.entries.first { $0.relativePath == "shortcut" })
        XCTAssertNotEqual(entry.kind, .identical, """
            two links pointing somewhere different are being called the same \
            thing, and the content check never reads a link, so nothing \
            downstream can catch it
            """)
    }

    func testLinksToTheSamePlaceStillMatch() throws {
        try link(left, "shortcut", to: "/Users/same")
        try link(right, "shortcut", to: "/Users/same")
        let c = try compare()
        XCTAssertEqual(c.entries.first { $0.relativePath == "shortcut" }?.kind, .identical)
    }

    /// A link facing a real file of the same length is not a match either, and
    /// this is the worse direction: mirroring would replace the real file with
    /// a link, or the link with a copy, on the strength of a size.
    func testALinkFacingARealFileIsNotAMatch() throws {
        try link(left, "thing", to: "/Users/aaaa")
        try write(right, "thing", bytes: 11)
        let c = try compare()
        XCTAssertNotEqual(c.entries.first { $0.relativePath == "thing" }?.kind, .identical)
    }

    // MARK: - What the ignore patterns must not change

    /// Ignoring `.DS_Store` has to mean the two folders match, or the whole
    /// point of ignoring it is lost: the folder stays "different", the tree
    /// walks into it for nothing, and freeing space passes it over.
    func testAFolderThatDiffersOnlyByAnIgnoredNameIsAMatch() throws {
        for side in [left!, right!] { try write(side, "album/photo.jpg", bytes: 5000, fill: 3) }
        try write(left, "album/.DS_Store", bytes: 6000)

        let c = try compare()
        XCTAssertEqual(c.entries.first { $0.relativePath == "album" }?.kind, .identical, """
            the ignored file is still deciding whether the folder matches: \
            \(c.entries.map { "\($0.kind.rawValue) \($0.relativePath)" })
            """)
        XCTAssertTrue(c.summary.inSync)
    }

    func testFreeingSpaceSeesAFolderThatOnlyDifferedByIgnoredNames() throws {
        for side in [left!, right!] { try write(side, "album/photo.jpg", bytes: 5000, fill: 3) }
        try write(left, "album/.DS_Store", bytes: 6000)

        switch SyncPlanner.plan(try compare(), direction: .removeLeftDuplicates) {
        case .success(let plan):
            XCTAssertEqual(plan.steps.map(\.relativePath), ["album"])
        case .failure(let f):
            XCTFail("the folder is a copy and freeing space should say so: \(f)")
        }
    }

    // MARK: - The content check must bind every way of deleting

    /// The most prominent delete on the screen is "move this copy to the
    /// Trash", and it takes a whole folder. Once the content check has said
    /// two things that look alike are not alike, that offer is no longer true.
    func testRemovingAWholeCopyIsRefusedOnceTheContentCheckDisagrees() throws {
        try write(left, "twin.bin", bytes: 64, fill: 7)
        try write(right, "twin.bin", bytes: 64, fill: 9)
        try write(left, "extra.bin", bytes: 10)

        let c = try compare()
        XCTAssertTrue(c.summary.isCoveredByTheOtherSide(.right),
                      "metadata says the right side holds nothing unique")

        let checked = FolderDiff.verify(c)
        XCTAssertEqual(checked.differing, ["twin.bin"])

        switch SyncPlanner.removeRedundant(c, side: .right,
                                           contentCheck: checked) {
        case .success:
            XCTFail("the only copy of twin.bin on the right is not a copy of anything")
        case .failure(let f):
            XCTAssertEqual(f, .notRedundant)
        }
    }

    // MARK: - Between planning and running

    /// A plan is read, and then carried out a moment later. If what it points
    /// at is no longer what it described, the step is not the step that was
    /// approved, and it must not run.
    func testAStepWhoseTargetChangedSincePlanningIsRefused() throws {
        try write(left, "doomed.bin", bytes: 400, fill: 1)
        try write(right, "doomed.bin", bytes: 400, fill: 1)

        let plan: SyncPlan
        switch SyncPlanner.plan(try compare(), direction: .removeLeftDuplicates) {
        case .success(let p): plan = p
        case .failure(let f): return XCTFail("refused: \(f)")
        }
        XCTAssertEqual(plan.steps.count, 1)

        // Somebody replaces it with something else entirely in between.
        try fm.removeItem(atPath: left.path + "/doomed.bin")
        try write(left, "doomed.bin", bytes: 90_000, fill: 2)

        let outcome = SyncRunner.run(plan)
        trashed += outcome.trashed.compactMap(\.trashURL)
        XCTAssertTrue(fm.fileExists(atPath: left.path + "/doomed.bin"), """
            the file at that path is not the one the plan described, and it \
            has been moved to the Trash anyway
            """)
        XCTAssertEqual(outcome.failures.count, 1)
    }

    // MARK: - How a name is spelled

    /// The same Turkish name written two ways.
    ///
    /// APFS stores the bytes it is given and only folds them when it looks a
    /// name up, so a folder that arrived from a zip, a Linux box or an older
    /// Mac can hold "ş" as one code point where its copy holds "s" plus a
    /// combining cedilla. The two are the same name to every person and every
    /// `open(2)` on the volume, and a different byte string to `memcmp`.
    func testTheSameNameSpelledTwoWaysIsOneFileNotTwo() throws {
        // Written through POSIX, because Foundation decomposes every path it
        // is handed — which is itself why the two spellings meet in the first
        // place: a folder this app copied holds the decomposed name, and the
        // folder it came from, unzipped or pulled off another system, holds
        // the composed one.
        try writeRaw(left, "sef\u{015F}e.txt", bytes: 700, fill: 7)
        try writeRaw(right, "sefs\u{0327}e.txt", bytes: 700, fill: 7)

        // Both spellings must actually survive on disk, or the case is moot.
        let leftNames = try fm.contentsOfDirectory(atPath: left.path)
        let rightNames = try fm.contentsOfDirectory(atPath: right.path)
        try XCTSkipUnless(Array(leftNames.first?.utf8 ?? "".utf8).count
                          != Array(rightNames.first?.utf8 ?? "".utf8).count,
                          "this volume normalises names, so the case cannot arise here")

        let c = try compare()
        XCTAssertEqual(c.summary.onlyLeft, 0,
                       "one file spelled two ways is being counted as two files: "
                       + c.entries.map { "\($0.kind) \($0.relativePath)" }.joined(separator: ", "))

        // And the consequence: a mirror would take the right-hand spelling to
        // the Trash as something the left does not have. A refusal here means
        // the mirror found nothing to do, which is the right answer.
        if let plan = try? SyncPlanner.plan(c, direction: .mirrorLeftToRight,
                                            syncRoots: SyncRoots(roots: []), excluded: []).get() {
            XCTAssertTrue(plan.steps.filter { $0.action == .remove }.isEmpty,
                          "a file that is on both sides is being moved to the Trash because "
                          + "the two sides spell its name differently")
        }
    }

    // MARK: - A replacement that cannot be completed

    /// The old file goes to the Trash before the new one is written, so a copy
    /// that fails leaves the path empty.
    func testAReplacementThatCannotBeWrittenLeavesTheOldFileInPlace() throws {
        try write(left, "report.txt", bytes: 2_000, fill: 1)
        try write(right, "report.txt", bytes: 900, fill: 2)
        // The left is the newer side, so an update wants to replace the right.
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: left.path + "/report.txt")

        let c = try compare()
        let plan = try SyncPlanner.plan(c, direction: .mirrorLeftToRight,
                                        syncRoots: SyncRoots(roots: []), excluded: []).get()
        XCTAssertEqual(plan.replacements, 1)

        // Whatever makes the write fail — a full disk, a permission, a vanished
        // source — the question is what is left at the target afterwards.
        try fm.removeItem(atPath: left.path + "/report.txt")

        let outcome = SyncRunner.run(plan)
        for item in outcome.trashed { if let url = item.trashURL { trashed.append(url) } }
        XCTAssertEqual(outcome.failures.count, 1, "the copy should have failed")
        XCTAssertTrue(fm.fileExists(atPath: right.path + "/report.txt"),
                      "the file that was going to be replaced is gone and nothing took its "
                      + "place: the replacement was not written, and the original was already "
                      + "in the Trash")
    }

    // MARK: - What the plan says it will write

    /// Two names for one file on the left, nothing on the right.
    ///
    /// The scanner counts the bytes once, which is the honest answer for "how
    /// much room is this taking". A copy makes two independent files, so the
    /// same tree needs twice that at the far end.
    func testACopyOfTwoNamesForOneFileNeedsRoomForBoth() throws {
        try write(left, "video.mov", bytes: 120_000, fill: 3)
        try fm.linkItem(atPath: left.path + "/video.mov", toPath: left.path + "/video-copy.mov")

        let c = try compare()
        let plan = try SyncPlanner.plan(c, direction: .mirrorLeftToRight,
                                        syncRoots: SyncRoots(roots: []), excluded: []).get()
        XCTAssertEqual(plan.copies, 2)

        let outcome = SyncRunner.run(plan)
        for item in outcome.trashed { if let url = item.trashURL { trashed.append(url) } }
        XCTAssertEqual(outcome.failures.count, 0)

        var written: Int64 = 0
        for name in try fm.contentsOfDirectory(atPath: right.path) {
            written += Int64((try fm.attributesOfItem(atPath: right.path + "/" + name)[.size]
                              as? Int) ?? 0)
        }
        XCTAssertEqual(plan.bytesToWrite, written,
                       "the plan promises \(plan.bytesToWrite) bytes and writes \(written): "
                       + "two names for one file are counted once, but copying them makes two")
    }

    // MARK: - Folders that could not be read

    /// A folder the scan could not open holds an unknown number of files, so
    /// "the other side has everything this one does" is not a claim anybody
    /// can make about it.
    func testAFolderThatCouldNotBeReadStopsAnythingBeingRemoved() throws {
        try write(left, "shared/a.txt", bytes: 100, fill: 1)
        try write(right, "shared/a.txt", bytes: 100, fill: 1)
        try write(left, "locked/secret.txt", bytes: 50, fill: 2)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: left.path + "/locked")
        defer { try? fm.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: left.path + "/locked") }

        let c = try compare()
        try XCTSkipUnless(c.unreadable > 0, "running as a user that can read anything")

        for direction in SyncDirection.allCases where direction.removesThings {
            let result = SyncPlanner.plan(c, direction: direction,
                                          syncRoots: SyncRoots(roots: []), excluded: [])
            switch result {
            case .failure: continue
            case .success(let plan):
                XCTAssertTrue(plan.removals == 0,
                              "\(direction) moves \(plan.removals) things to the Trash from a "
                              + "comparison that could not read \(c.unreadable) folders")
            }
        }
    }

    // MARK: - The two sides being the same folder

    /// The same folder reached by two spellings.
    func testAFolderIsNotComparedWithItself() throws {
        try write(left, "a.txt", bytes: 100, fill: 1)
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: left.path)

        switch FolderDiff.compare(left: left.path, right: alias.path) {
        case .failure: return                       // refused, which is the answer
        case .success(let c):
            let result = SyncPlanner.plan(c, direction: .mirrorLeftToRight,
                                          syncRoots: SyncRoots(roots: []), excluded: [])
            if case .success(let plan) = result {
                XCTAssertTrue(plan.isEmpty,
                              "a folder is being synced against itself: \(plan.steps.count) steps")
            }
        }
    }

    // MARK: - What the content check did not settle

    /// A file the check could not open settles nothing about that file, and a
    /// check that was stopped settles nothing about the files it never reached.
    /// Both leave the plan free to say the contents were read and agree.
    func testAFileTheCheckCouldNotOpenIsNotTreatedAsAgreeing() throws {
        try write(left, "readable.bin", bytes: 400, fill: 1)
        try write(right, "readable.bin", bytes: 400, fill: 1)
        try write(left, "sealed.bin", bytes: 400, fill: 2)
        try write(right, "sealed.bin", bytes: 400, fill: 9)      // same length, other bytes
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: left.path + "/sealed.bin")
        defer { try? fm.setAttributes([.posixPermissions: 0o644],
                                      ofItemAtPath: left.path + "/sealed.bin") }

        var c = try compare()
        let check = FolderDiff.verify(c)
        try XCTSkipUnless(check.unreadable.contains("sealed.bin"),
                          "running as a user that can read anything")
        c.verifiedAt = Date()

        let result = SyncPlanner.removeRedundant(
            c, side: .left, contentCheck: check)
        if case .success(let plan) = result {
            XCTFail("the whole left side is being moved to the Trash on a check that could not "
                    + "read \(check.unreadable) - \(plan.removals) removals")
        }
    }

    func testACheckThatWasStoppedIsNotAFinishedCheck() throws {
        try write(left, "a.bin", bytes: 400, fill: 1)
        try write(right, "a.bin", bytes: 400, fill: 1)

        var c = try compare()
        let cancel = CancelToken()
        cancel.cancel()
        let check = FolderDiff.verify(c, cancel: cancel)
        XCTAssertTrue(check.cancelled)
        c.verifiedAt = Date()

        let plan = try SyncPlanner.plan(c, direction: .removeLeftDuplicates,
                                        syncRoots: SyncRoots(roots: []), excluded: [],
                                        contentCheck: check).get()
        XCTAssertFalse(plan.contentWasChecked,
                       "the plan says the contents were read and agree, and the check was "
                       + "stopped after \(check.pairsChecked > 0 ? "some" : "none") of them")
    }

    // MARK: - A folder that is no longer there

    /// An ejected disk leaves its mount point behind as an ordinary empty
    /// folder on the boot disk, and a mirror pointed at one would rebuild the
    /// whole tree there without a word.
    func testAMirrorRefusesWhenTheFolderItWritesIntoHasGone() throws {
        try write(left, "a/one.txt", bytes: 400, fill: 1)
        try write(left, "a/two.txt", bytes: 400, fill: 2)

        let c = try compare()
        let plan = try SyncPlanner.plan(c, direction: .mirrorLeftToRight,
                                        syncRoots: SyncRoots(roots: []), excluded: []).get()
        XCTAssertEqual(plan.copies, 1)

        try fm.removeItem(at: right)                 // the disk goes away

        let outcome = SyncRunner.run(plan)
        for item in outcome.trashed { if let url = item.trashURL { trashed.append(url) } }
        XCTAssertNotNil(outcome.refused, "the destination is gone and the run went ahead anyway")
        XCTAssertEqual(outcome.completed, 0)
        XCTAssertFalse(fm.fileExists(atPath: right.path),
                       "the destination was recreated where the disk used to be mounted")
    }

    /// The most destructive thing the app offers, end to end: the whole of one
    /// side to the Trash. It goes through the same re-check as every other
    /// step, so this is also the test that the re-check does not refuse the
    /// plan it was handed.
    func testRemovingAWholeCopyRunsAndTheFolderEndsUpInTheTrash() throws {
        try write(left, "album/one.jpg", bytes: 4_000, fill: 1)
        try write(left, "album/two.jpg", bytes: 4_000, fill: 2)
        try write(right, "album/one.jpg", bytes: 4_000, fill: 1)
        try write(right, "album/two.jpg", bytes: 4_000, fill: 2)

        var c = try compare()
        let check = FolderDiff.verify(c)
        XCTAssertTrue(check.agreed, "the two sides hold the same bytes")
        c.verifiedAt = Date()

        let plan = try SyncPlanner.removeRedundant(c, side: .left,
                                                   contentCheck: check).get()
        XCTAssertTrue(plan.contentWasChecked)

        let outcome = SyncRunner.run(plan)
        for item in outcome.trashed { if let url = item.trashURL { trashed.append(url) } }
        XCTAssertNil(outcome.refused)
        XCTAssertEqual(outcome.failures.count, 0,
                       "\(outcome.failures.map(\.message))")
        XCTAssertFalse(fm.fileExists(atPath: left.path), "the left side is still there")
        XCTAssertTrue(fm.fileExists(atPath: right.path + "/album/one.jpg"),
                      "the side that was being kept is gone")
    }

    /// A comparison that was stopped describes part of two folders, and the
    /// part it never reached reads as absent from that side.
    func testAComparisonThatWasStoppedCannotBeMirrored() throws {
        try write(left, "a.txt", bytes: 400, fill: 1)
        try write(right, "a.txt", bytes: 400, fill: 1)
        try write(right, "b.txt", bytes: 400, fill: 2)

        let cancel = CancelToken()
        cancel.cancel()
        guard case .success(let c) = FolderDiff.compare(left: left.path, right: right.path,
                                                        cancel: cancel) else { return }
        try XCTSkipUnless(c.cancelled, "the comparison finished before the token was read")

        for direction in SyncDirection.allCases where direction.removesThings {
            guard case .failure = SyncPlanner.plan(c, direction: direction,
                                                   syncRoots: SyncRoots(roots: []),
                                                   excluded: []) else {
                XCTFail("\(direction) was planned from a comparison that never finished")
                continue
            }
        }
        if case .success = SyncPlanner.removeRedundant(c, side: .left) {
            XCTFail("a whole side was offered for the Trash on a comparison that never finished")
        }
    }

    // MARK: - Placeholders

    /// A file whose bytes live in iCloud is a file the check did not read,
    /// because reading one is what fetches it. Leaving it alone is right;
    /// counting that as agreement is not.
    func testPlaceholdersLeftInTheCloudAreNotAgreement() throws {
        try write(left, "album/one.jpg", bytes: 4_000, fill: 1)
        try write(right, "album/one.jpg", bytes: 4_000, fill: 1)

        var c = try compare()
        c.verifiedAt = Date()

        // What `verify` returns when it walked past a placeholder rather than
        // pulling it down.
        let check = VerifyDifferences(pairsChecked: 0, bytesRead: 0, differing: [],
                                      unreadable: [], notDownloaded: ["album/one.jpg"],
                                      cancelled: false)
        XCTAssertFalse(check.agreed)

        if case .success = SyncPlanner.removeRedundant(c, side: .left, contentCheck: check) {
            XCTFail("a whole side is being offered for the Trash on a check that never read "
                    + "the files, because they were still in iCloud")
        }

        // The decision here is the folder `album`, collapsed as identical - the
        // check answers about the file inside it. Nothing may be removed, so
        // there is nothing left to do.
        switch SyncPlanner.plan(c, direction: .removeLeftDuplicates,
                                syncRoots: SyncRoots(roots: []), excluded: [],
                                contentCheck: check) {
        case .failure(let refusal):
            XCTAssertEqual(refusal, .nothingToDo)
        case .success(let plan):
            XCTFail("a folder holding a placeholder is being removed as a proven duplicate: "
                    + "\(plan.removals) removals")
        }
    }
}
