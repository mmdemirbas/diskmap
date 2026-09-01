import DiskMapCore
import XCTest

/// What a mirror or a merge would do, and what it refuses to do.
///
/// The refusals carry most of the weight here. A folder comparison is a
/// pleasant screen to read; the moment it can write, every rule that keeps it
/// from removing the only copy of something has to hold, and holding is
/// something a test can show and a careful reading cannot.
final class SyncPlanTests: XCTestCase {
    private var root: URL!
    private var left: URL!
    private var right: URL!
    private let fm = FileManager.default
    /// Everything this suite put in the Trash, emptied again in teardown so a
    /// test run does not leave litter in the user's Trash.
    private var trashed: [URL] = []

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmsync-\(UUID().uuidString)")
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
        for url in trashed { try? fm.removeItem(at: url) }
        trashed = []
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
        case .failure(let f): XCTFail("comparison refused: \(f)"); throw f
        }
    }

    private func plan(_ direction: SyncDirection, excluded: [String] = [],
                      syncRoots: SyncRoots = SyncRoots(roots: [])) throws -> SyncPlan {
        switch SyncPlanner.plan(try compare(), direction: direction,
                                syncRoots: syncRoots, excluded: excluded) {
        case .success(let p): return p
        case .failure(let f): XCTFail("plan refused: \(f)"); throw f
        }
    }

    private func refusal(_ direction: SyncDirection, excluded: [String] = []) throws -> CompareRefusal? {
        switch SyncPlanner.plan(try compare(), direction: direction, excluded: excluded) {
        case .success: return nil
        case .failure(let f): return f
        }
    }

    private func run(_ plan: SyncPlan) -> SyncOutcome {
        let outcome = SyncRunner.run(plan)
        trashed += outcome.trashed.compactMap(\.trashURL)
        return outcome
    }

    private func tree(_ base: URL) throws -> [String: Int] {
        var out: [String: Int] = [:]
        guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey])
        else { return out }
        let prefix = (canonicalPath(base.path) ?? base.path).count + 1
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            out[String(url.path.dropFirst(prefix))] =
                values.isDirectory == true ? -1 : (values.fileSize ?? 0)
        }
        return out
    }

    // MARK: - What a plan contains

    func testAMirrorCopiesReplacesAndRemoves() throws {
        try write(left, "keep.txt", bytes: 10)
        try write(right, "keep.txt", bytes: 10)
        try write(left, "new.txt", bytes: 20)
        try write(left, "changed.txt", bytes: 30)
        try write(right, "changed.txt", bytes: 31)
        try write(right, "stale.txt", bytes: 40)

        let plan = try plan(.mirrorLeftToRight)
        let byPath = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.relativePath, $0) })

        XCTAssertEqual(byPath["new.txt"]?.action, .copy)
        XCTAssertEqual(byPath["changed.txt"]?.action, .replace)
        XCTAssertEqual(byPath["stale.txt"]?.action, .remove)
        XCTAssertNil(byPath["keep.txt"], "an identical item is not a step")

        // Everything is written into the right-hand folder, and nothing else.
        for step in plan.steps {
            XCTAssertTrue(step.target.hasPrefix(right.path + "/"), step.target)
        }
        // Figures are on-disk bytes, so they are block-rounded rather than the
        // lengths written above; what matters is which items they add up over.
        let copy = try XCTUnwrap(byPath["new.txt"])
        let replace = try XCTUnwrap(byPath["changed.txt"])
        let remove = try XCTUnwrap(byPath["stale.txt"])
        XCTAssertEqual(plan.bytesToWrite, copy.bytes + replace.bytes)
        XCTAssertEqual(plan.bytesToTrash, replace.replacedBytes + remove.bytes,
                       "the version being replaced goes to the Trash too")
        XCTAssertGreaterThan(replace.replacedBytes, 0)
    }

    func testAMergeCopiesBothWaysAndNeverRemoves() throws {
        try write(left, "mine.txt", bytes: 10)
        try write(right, "yours.txt", bytes: 20)
        try write(right, "extra/deep.txt", bytes: 30)

        let plan = try plan(.merge)
        XCTAssertEqual(plan.removals, 0, "a merge must never remove anything")
        XCTAssertEqual(Set(plan.steps.map(\.relativePath)), ["mine.txt", "yours.txt", "extra"])
    }

    /// Two files of different lengths stamped with the same second: nothing in
    /// the metadata says which one is wanted, so the merge leaves both alone
    /// and says it did.
    func testAMergeLeavesAConflictItCannotDecideAlone() throws {
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try write(left, "notes.txt", bytes: 10, modified: stamp)
        try write(right, "notes.txt", bytes: 20, modified: stamp)
        try write(left, "other.txt", bytes: 5)

        let plan = try plan(.merge)
        XCTAssertEqual(plan.unresolved, ["notes.txt"])
        XCTAssertFalse(plan.steps.contains { $0.relativePath == "notes.txt" })
    }

    func testAMergeTakesTheNewerSideWhenThereIsOne() throws {
        try write(left, "notes.txt", bytes: 10,
                  modified: Date(timeIntervalSince1970: 1_700_000_000))
        try write(right, "notes.txt", bytes: 20,
                  modified: Date(timeIntervalSince1970: 1_600_000_000))

        let plan = try plan(.merge)
        let step = try XCTUnwrap(plan.steps.first)
        XCTAssertEqual(step.action, .replace)
        XCTAssertEqual(step.source, left.path + "/notes.txt")
        XCTAssertEqual(step.target, right.path + "/notes.txt")
    }

    /// On a case-insensitive volume `README` and `readme` are two entries in
    /// the comparison and one name on disk. Writing before removing would put
    /// the new file where the old one still sits.
    func testRemovalsAreOrderedBeforeAnythingIsWritten() throws {
        try write(left, "a.txt", bytes: 10)
        try write(right, "b.txt", bytes: 10)
        try write(left, "c.txt", bytes: 10)
        try write(right, "c.txt", bytes: 11)

        let plan = try plan(.mirrorLeftToRight)
        let lastRemoval = plan.steps.lastIndex { $0.action == .remove } ?? -1
        let firstWrite = plan.steps.firstIndex { $0.action != .remove } ?? plan.steps.count
        XCTAssertLessThan(lastRemoval, firstWrite,
                          "every removal must come before the first write")
    }

    // MARK: - Refusals

    func testAMirrorIsRefusedWhenTheComparisonCouldNotReadEverything() throws {
        try write(left, "a.txt", bytes: 10)
        try write(right, "b.txt", bytes: 10)
        var comparison = try compare()
        comparison.unreadable = 3

        switch SyncPlanner.plan(comparison, direction: .mirrorLeftToRight) {
        case .success: XCTFail("a mirror must not be built on a partial comparison")
        case .failure(let f): XCTAssertEqual(f, .someFoldersUnreadable(3))
        }
        // A merge only ever adds, so an unreadable folder cannot make it delete
        // something it never saw.
        switch SyncPlanner.plan(comparison, direction: .merge) {
        case .success: break
        case .failure(let f): XCTFail("a merge should still be allowed: \(f)")
        }
    }

    func testWritingIntoAWholeVolumeIsRefused() throws {
        try write(left, "a.txt", bytes: 10)
        // A real comparison with the target swapped afterwards, because the
        // one thing that cannot be done is comparing something against "/".
        var comparison = try compare()
        comparison.right = "/"
        switch SyncPlanner.plan(comparison, direction: .mirrorLeftToRight) {
        case .success: XCTFail("mirroring onto a volume root must be refused")
        case .failure(let f): XCTAssertEqual(f, CompareRefusal.wouldWriteToAVolumeRoot("/"))
        }
    }

    func testAnExcludedTargetIsRefused() throws {
        try write(left, "a.txt", bytes: 10)
        let refusal = try refusal(.mirrorLeftToRight, excluded: [right.path])
        XCTAssertEqual(refusal, .onTheNeverTouchList(right.path))

        // The other direction writes into the left folder, which is not on the
        // list, so it is still allowed.
        XCTAssertNil(try self.refusal(.mirrorRightToLeft, excluded: [right.path]))
    }

    func testTwoFoldersThatAlreadyMatchProduceNoPlan() throws {
        try write(left, "a.txt", bytes: 10)
        try write(right, "a.txt", bytes: 10)
        XCTAssertEqual(try refusal(.mirrorLeftToRight), .nothingToDo)
    }

    // MARK: - Removing a copy that has become redundant

    func testRemovingACopyIsRefusedWhileItHoldsSomethingUnique() throws {
        try write(left, "shared.txt", bytes: 10)
        try write(right, "shared.txt", bytes: 10)
        try write(left, "only-here.txt", bytes: 5)

        let comparison = try compare()
        switch SyncPlanner.removeRedundant(comparison, side: .left) {
        case .success: XCTFail("the left copy is not redundant")
        case .failure(let f): XCTAssertEqual(f, .notRedundant)
        }
        // The right one is: everything it holds, the left holds too.
        switch SyncPlanner.removeRedundant(comparison, side: .right) {
        case .success(let plan):
            XCTAssertEqual(plan.steps.count, 1)
            XCTAssertEqual(plan.steps[0].action, .remove)
            XCTAssertEqual(plan.steps[0].target, right.path)
        case .failure(let f): XCTFail("the right copy is redundant: \(f)")
        }
    }

    func testRemovingACopyIsRefusedWhenTheTwoDisagreeOnAnything() throws {
        try write(left, "a.txt", bytes: 10)
        try write(right, "a.txt", bytes: 11)
        for side in [Side.left, .right] {
            switch SyncPlanner.removeRedundant(try compare(), side: side) {
            case .success: XCTFail("neither side is redundant when they differ")
            case .failure(let f): XCTAssertEqual(f, .notRedundant)
            }
        }
    }

    // MARK: - Carrying it out

    func testAMirrorMakesTheTargetMatchTheSource() throws {
        try write(left, "keep.txt", bytes: 10)
        try write(right, "keep.txt", bytes: 10)
        try write(left, "new/deep/file.bin", bytes: 25)
        try write(left, "changed.txt", bytes: 30)
        try write(right, "changed.txt", bytes: 31)
        try write(right, "stale/old.bin", bytes: 40)

        let outcome = run(try plan(.mirrorLeftToRight))
        XCTAssertTrue(outcome.succeeded, "\(outcome.failures)")

        XCTAssertEqual(try tree(left), try tree(right),
                       "after a mirror the two folders hold the same names at the same sizes")
        let after = try compare()
        XCTAssertTrue(after.summary.inSync, "\(after.summary)")
    }

    func testAMergeLeavesBothSidesHoldingEverything() throws {
        try write(left, "mine/a.bin", bytes: 10)
        try write(right, "yours/b.bin", bytes: 20)

        let outcome = run(try plan(.merge))
        XCTAssertTrue(outcome.succeeded, "\(outcome.failures)")
        XCTAssertEqual(outcome.bytesTrashed, 0, "a merge removes nothing")
        XCTAssertEqual(try tree(left), try tree(right))
    }

    /// Nothing is deleted, ever. The file a mirror removes and the older
    /// version it replaces both land in the Trash, where Put Back still works.
    func testEverythingRemovedGoesToTheTrash() throws {
        try write(left, "changed.txt", bytes: 30)
        try write(right, "changed.txt", bytes: 31)
        let doomed = try write(right, "stale.txt", bytes: 40)

        let outcome = run(try plan(.mirrorLeftToRight))
        XCTAssertEqual(outcome.trashed.count, 2, "the replaced file counts too")
        XCTAssertFalse(fm.fileExists(atPath: doomed.path))

        for item in outcome.trashed {
            let url = try XCTUnwrap(item.trashURL, "\(item.originalURL.path) left no trash URL")
            XCTAssertTrue(fm.fileExists(atPath: url.path),
                          "\(item.originalURL.lastPathComponent) is not in the Trash")
        }
    }

    /// A copy that shifts every date makes the next comparison report the whole
    /// folder as changed, and a mirror that runs twice would then rewrite
    /// everything it just wrote.
    func testCopyingCarriesTheModificationDateAcross() throws {
        let stamp = Date(timeIntervalSince1970: 1_234_567_890)
        try write(left, "file.bin", bytes: 100, modified: stamp)
        try write(left, "folder/inner.bin", bytes: 50, modified: stamp)

        XCTAssertTrue(run(try plan(.mirrorLeftToRight)).succeeded)

        for relative in ["file.bin", "folder/inner.bin"] {
            let attrs = try fm.attributesOfItem(atPath: right.path + "/" + relative)
            let date = try XCTUnwrap(attrs[.modificationDate] as? Date)
            XCTAssertEqual(date.timeIntervalSince1970, stamp.timeIntervalSince1970,
                           accuracy: 1, "\(relative) lost its date")
        }
    }

    /// The last check before the filesystem. A step aimed anywhere but the two
    /// folders being compared is refused here as well as at planning time.
    func testAStepAimedOutsideTheComparedFoldersIsRefused() throws {
        let outsider = try write(root, "outsider.txt", bytes: 10)
        try write(left, "a.txt", bytes: 10)

        var plan = try plan(.mirrorLeftToRight)
        plan.steps = [SyncStep(id: 0, action: .remove, relativePath: "outsider.txt",
                               source: nil, target: outsider.path, isDirectory: false,
                               bytes: 10, replacedBytes: 0, syncProvider: nil, dataless: false)]
        let outcome = run(plan)
        XCTAssertEqual(outcome.completed, 0)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: outsider.path), "it must still be there")
    }

    func testARunReportsAFailureRatherThanOverwritingSomethingThatReappeared() throws {
        try write(left, "a.txt", bytes: 10)
        var plan = try plan(.mirrorLeftToRight)
        XCTAssertEqual(plan.steps.count, 1)
        // Someone else put a file there between planning and running.
        try write(right, "a.txt", bytes: 99)
        plan.steps[0].action = .copy

        let outcome = run(plan)
        XCTAssertEqual(outcome.failures.count, 1, "a copy must not take the place of a live file")
        let size = try fm.attributesOfItem(atPath: right.path + "/a.txt")[.size] as? Int
        XCTAssertEqual(size, 99, "the file that was there is untouched")
    }

    // MARK: - The rule itself

    /// Nothing that acts on a path the user chose may delete it. The only way
    /// out is the Trash, and this is the check that says so about the source
    /// rather than about one code path somebody remembered to read.
    func testNothingThatTouchesAChosenPathCanDelete() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DiskMapCore")
        let guarded = ["SyncPlan.swift", "FolderDiff.swift", "TrashPlan.swift",
                       "FileActions.swift", "Cleanup.swift"]

        var offenders: [String] = []
        for name in guarded {
            let text = try String(contentsOf: sources.appendingPathComponent(name),
                                  encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                for call in ["removeItem", "unlink(", "rmdir(", "remove(atPath"]
                where code.contains(call) {
                    offenders.append("\(name):\(i + 1)  \(code)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            these must go through FileManager.trashItem, not delete:
            \(offenders.joined(separator: "\n"))
            """)
    }
}
