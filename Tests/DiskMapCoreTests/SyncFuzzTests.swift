import XCTest
import DiskMapCore
@testable import DiskMapCompare
@testable import DiskMapScan

/// Every direction of a sync, run on pairs of folders that diverged at random,
/// checked against what each direction promises — by an independent listing
/// of the disk, not by the comparison's own account of itself.
///
/// The promises, per direction, are the ones the planner's comment makes:
/// a mirror leaves the target exactly like the source and the source as it
/// was; an update carries over only what the source has newer and removes
/// nothing; a merge gives each side what the other has, newest winning where
/// there is a newest, and removes nothing; removing duplicates takes from one
/// side only what the other holds identically. Every direction leaves the
/// folder next door untouched, and nothing goes to the Trash that was not
/// the thing the direction said would.
///
/// Every write carries its own second, so "newer" is always decidable and
/// two files agree on size and date only when they are the same file copied.
final class SyncFuzzTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default
    private var trashed: [URL] = []

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: fm.temporaryDirectory.path)
            .appendingPathComponent("dmsyncfuzz-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        base = URL(fileURLWithPath: canonicalPath(base.path) ?? base.path)
    }
    override func tearDownWithError() throws {
        for url in trashed { try? fm.removeItem(at: url) }
        if let base { try? fm.removeItem(at: base) }
    }

    func testEveryDirectionKeepsItsPromiseOnDivergedFolders() throws {
        for seed: UInt64 in 1...8 {
            var rng = SplitMix64(seed: seed)
            clock = 1_700_000_000
            let stage = base.appendingPathComponent("stage-\(seed)")
            try buildDivergedPair(at: stage, &rng)
            for direction in SyncDirection.allCases {
                let work = base.appendingPathComponent("work-\(seed)-\(direction.rawValue)")
                try clone(stage, to: work)
                try check(direction, in: work, seed: seed)
                try fm.removeItem(at: work)
            }
        }
    }

    // MARK: - One direction

    private func check(_ direction: SyncDirection, in work: URL, seed: UInt64) throws {
        let left = work.appendingPathComponent("left"), right = work.appendingPathComponent("right")
        let outside = work.appendingPathComponent("outside")
        let leftBefore = try listing(left), rightBefore = try listing(right)
        let outsideBefore = try listing(outside)

        let comparison: FolderComparison
        switch FolderDiff.compare(left: left.path, right: right.path) {
        case .success(let c): comparison = c
        case .failure(let f): XCTFail("seed \(seed) \(direction): comparison refused: \(f)"); return
        }
        let plan: SyncPlan
        switch SyncPlanner.plan(comparison, direction: direction) {
        case .success(let p): plan = p
        case .failure(.nothingToDo):
            // Legitimate: no duplicates to free, or two sides already alike.
            // Then nothing may have moved.
            XCTAssertEqual(try listing(left), leftBefore, "seed \(seed) \(direction): nothing to do, yet the left moved")
            XCTAssertEqual(try listing(right), rightBefore, "seed \(seed) \(direction): nothing to do, yet the right moved")
            return
        case .failure(let f): XCTFail("seed \(seed) \(direction): plan refused: \(f)"); return
        }
        let outcome = SyncRunner.run(plan)
        trashed += outcome.trashed.compactMap(\.trashURL)
        XCTAssertTrue(outcome.succeeded, "seed \(seed) \(direction): \(outcome.failures)")

        let leftAfter = try listing(left), rightAfter = try listing(right)
        XCTAssertEqual(try listing(outside), outsideBefore, "seed \(seed) \(direction): the folder next door was touched")
        let trashedRel = Set(outcome.trashed.map { rel($0.originalURL, in: work) })
        let ctx = "seed \(seed) \(direction)"

        switch direction {
        case .mirrorLeftToRight:
            expectEqual(rightAfter, leftBefore, "\(ctx): the target is not the source")
            expectEqual(leftAfter, leftBefore, "\(ctx): the source moved")
            for p in trashedRel {
                XCTAssertTrue(p.hasPrefix("right/"), "\(ctx): trashed \(p), not on the target side")
                let r = String(p.dropFirst("right/".count))
                XCTAssertFalse(same(leftBefore[r], rightBefore[r]), "\(ctx): trashed \(p), which was identical")
            }
        case .mirrorRightToLeft:
            expectEqual(leftAfter, rightBefore, "\(ctx): the target is not the source")
            expectEqual(rightAfter, rightBefore, "\(ctx): the source moved")
            for p in trashedRel {
                XCTAssertTrue(p.hasPrefix("left/"), "\(ctx): trashed \(p), not on the target side")
                let r = String(p.dropFirst("left/".count))
                XCTAssertFalse(same(leftBefore[r], rightBefore[r]), "\(ctx): trashed \(p), which was identical")
            }
        case .updateLeftToRight:
            expectUpdate(source: leftBefore, targetBefore: rightBefore, targetAfter: rightAfter, ctx)
            expectEqual(leftAfter, leftBefore, "\(ctx): the source moved")
        case .updateRightToLeft:
            expectUpdate(source: rightBefore, targetBefore: leftBefore, targetAfter: leftAfter, ctx)
            expectEqual(rightAfter, rightBefore, "\(ctx): the source moved")
        case .merge:
            expectMerge(leftBefore, rightBefore, leftAfter, rightAfter, ctx)
        case .removeLeftDuplicates:
            expectEqual(rightAfter, rightBefore, "\(ctx): the other side moved")
            expectDuplicatesRemoved(from: leftBefore, other: rightBefore, after: leftAfter, ctx)
        case .removeRightDuplicates:
            expectEqual(leftAfter, leftBefore, "\(ctx): the other side moved")
            expectDuplicatesRemoved(from: rightBefore, other: leftBefore, after: rightAfter, ctx)
        }
    }

    /// An update: every source file reaches the target unless the target's
    /// was touched more recently; the target's own files stay; nothing the
    /// target had is lost.
    private func expectUpdate(source: Listing, targetBefore: Listing, targetAfter: Listing, _ ctx: String) {
        let clashes = typeClashes(source, targetBefore)
        for (p, s) in source where !underAClash(p, clashes) {
            guard let t = targetBefore[p] else {
                XCTAssertEqual(targetAfter[p], s, "\(ctx): \(p) was not carried over"); continue
            }
            if same(s, t) { XCTAssertEqual(targetAfter[p], t, "\(ctx): \(p) was identical and moved") }
            else if s.isDirectory != t.isDirectory {
                // A folder on one side and a file on the other: replaced only
                // where the source is the newer, by the folder's own date,
                // which this listing does not hold. Either outcome is the
                // rule's; what is checked is that nothing else happened.
                XCTAssertTrue(targetAfter[p] == t || targetAfter[p] == s, "\(ctx): \(p) type clash became \(String(describing: targetAfter[p]))")
            } else if s.mtime > t.mtime { XCTAssertEqual(targetAfter[p], s, "\(ctx): \(p) newer on the source, not carried") }
            else { XCTAssertEqual(targetAfter[p], t, "\(ctx): \(p) newer on the target, overwritten") }
        }
        for (p, t) in targetBefore where source[p] == nil && !underAClash(p, clashes) {
            XCTAssertEqual(targetAfter[p], t, "\(ctx): \(p) was the target's own and is gone")
        }
    }

    /// Paths where one side holds a folder and the other a file. What sits
    /// under such a folder follows the folder's fate, not its own.
    private func typeClashes(_ a: Listing, _ b: Listing) -> [String] {
        a.compactMap { p, e in b[p].map { $0.isDirectory != e.isDirectory } == true ? p : nil }
    }
    private func underAClash(_ p: String, _ clashes: [String]) -> Bool {
        clashes.contains { p.hasPrefix($0 + "/") }
    }

    /// A merge: what is on one side reaches the other; where both have it
    /// and they differ, the newer one wins on both sides when there is a
    /// newer one; a file against a folder is left alone; nothing is lost.
    private func expectMerge(_ l0: Listing, _ r0: Listing, _ l1: Listing, _ r1: Listing, _ ctx: String) {
        let clashes = typeClashes(l0, r0)
        for p in Set(l0.keys).union(r0.keys) where !underAClash(p, clashes) {
            switch (l0[p], r0[p]) {
            case let (l?, nil):
                XCTAssertEqual(l1[p], l, "\(ctx): \(p) moved on the left"); XCTAssertEqual(r1[p], l, "\(ctx): \(p) did not reach the right")
            case let (nil, r?):
                XCTAssertEqual(r1[p], r, "\(ctx): \(p) moved on the right"); XCTAssertEqual(l1[p], r, "\(ctx): \(p) did not reach the left")
            case let (l?, r?):
                if same(l, r) || l.isDirectory != r.isDirectory || l.mtime == r.mtime {
                    XCTAssertEqual(l1[p], l, "\(ctx): \(p) left touched"); XCTAssertEqual(r1[p], r, "\(ctx): \(p) right touched")
                } else {
                    let newer = l.mtime > r.mtime ? l : r
                    XCTAssertEqual(l1[p], newer, "\(ctx): \(p) left is not the newer"); XCTAssertEqual(r1[p], newer, "\(ctx): \(p) right is not the newer")
                }
            default: break
            }
        }
    }

    /// Freeing space: exactly the files the other side holds identically go,
    /// and nothing else. Folders may stay behind empty.
    private func expectDuplicatesRemoved(from before: Listing, other: Listing, after: Listing, _ ctx: String) {
        for (p, e) in before where !e.isDirectory {
            if same(e, other[p]) { XCTAssertNil(after[p], "\(ctx): \(p) is held on the other side and stayed") }
            else { XCTAssertEqual(after[p], e, "\(ctx): \(p) is not a duplicate and went") }
        }
        for (p, e) in after where !e.isDirectory {
            XCTAssertEqual(before[p], e, "\(ctx): \(p) appeared or changed while freeing space")
        }
    }

    private func expectEqual(_ a: Listing, _ b: Listing, _ message: String) {
        guard a != b else { return }
        var lines: [String] = []
        for k in Set(a.keys).union(b.keys).sorted() where a[k] != b[k] {
            lines.append("  \(k): \(a[k].map(String.init(describing:)) ?? "-") vs \(b[k].map(String.init(describing:)) ?? "-")")
        }
        XCTFail(message + "\n" + lines.prefix(10).joined(separator: "\n"))
    }

    private func same(_ a: Entry?, _ b: Entry?) -> Bool {
        guard let a, let b else { return false }
        return a == b
    }

    // MARK: - The disk, independently

    struct Entry: Equatable, CustomStringConvertible {
        var isDirectory: Bool
        var size: Int
        var mtime: Int
        var digest: Int
        var description: String { isDirectory ? "dir@\(mtime)" : "\(size)b@\(mtime)#\(digest)" }
    }
    typealias Listing = [String: Entry]

    private func listing(_ dir: URL) throws -> Listing {
        var out: Listing = [:]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: Array(keys)) else { return out }
        for case let url as URL in walker {
            let v = try url.resourceValues(forKeys: keys)
            let mtime = Int(v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            if v.isDirectory == true {
                out[rel(url, in: dir)] = Entry(isDirectory: true, size: 0, mtime: 0, digest: 0)
            } else {
                let data = try Data(contentsOf: URL(fileURLWithPath: url.path))
                out[rel(url, in: dir)] = Entry(isDirectory: false, size: data.count, mtime: mtime, digest: data.hashValue)
            }
        }
        return out
    }

    private func rel(_ url: URL, in dir: URL) -> String {
        let p = canonicalPath(url.path) ?? url.path
        let d = canonicalPath(dir.path) ?? dir.path
        return p.hasPrefix(d + "/") ? String(p.dropFirst(d.count + 1)) : p
    }

    // MARK: - Building a pair

    private var clock = 1_700_000_000
    private var counter = 0
    private func freshName(_ stem: String) -> String {
        counter += 1
        return "\(stem)\(counter)" + (counter % 9 == 0 ? " ölçü" : "")
    }

    private func buildDivergedPair(at stage: URL, _ rng: inout SplitMix64) throws {
        let left = stage.appendingPathComponent("left"), right = stage.appendingPathComponent("right")
        let outside = stage.appendingPathComponent("outside")
        for d in [left, outside] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try write(outside.appendingPathComponent("keep.bin"), 40, &rng)

        // Shared history: the same files on both sides, byte for byte and
        // second for second.
        for _ in 0..<Int.random(in: 3...6, using: &rng) { try mutate(.mkdir, in: left, &rng) }
        for _ in 0..<Int.random(in: 2...5, using: &rng) { try mutate(.create, in: left, &rng) }
        try clone(left, to: right)

        // Then each side goes its own way.
        for side in [left, right] {
            for _ in 0..<Int.random(in: 1...5, using: &rng) {
                try mutate(Mutation.allCases.randomElement(using: &rng)!, in: side, &rng)
            }
        }
    }

    private enum Mutation: CaseIterable { case create, rewrite, delete, rename, mkdir, rmdir, fileToDir }

    private func mutate(_ kind: Mutation, in side: URL, _ rng: inout SplitMix64) throws {
        let (dirs, files) = contents(of: side)
        func pick(_ a: [URL]) -> URL? { a.isEmpty ? nil : a.randomElement(using: &rng) }
        switch kind {
        case .create:
            try write((pick(dirs) ?? side).appendingPathComponent(freshName("f")), Int.random(in: 1...300, using: &rng), &rng)
        case .rewrite:
            guard let f = pick(files) else { return }
            try write(f, Int.random(in: 1...300, using: &rng), &rng)
        case .delete:
            guard let f = pick(files) else { return }
            try fm.removeItem(at: f)
        case .rename:
            guard let f = pick(files) else { return }
            try fm.moveItem(at: f, to: f.deletingLastPathComponent().appendingPathComponent(freshName("r")))
        case .mkdir:
            let d = (pick(dirs) ?? side).appendingPathComponent(freshName("d"))
            try fm.createDirectory(at: d, withIntermediateDirectories: false)
            for _ in 0..<Int.random(in: 0...2, using: &rng) {
                try write(d.appendingPathComponent(freshName("f")), Int.random(in: 1...300, using: &rng), &rng)
            }
        case .rmdir:
            guard let d = pick(dirs) else { return }
            try fm.removeItem(at: d)
        case .fileToDir:
            guard let f = pick(files) else { return }
            try fm.removeItem(at: f)
            try fm.createDirectory(at: f, withIntermediateDirectories: false)
            try write(f.appendingPathComponent(freshName("f")), 20, &rng)
        }
    }

    /// Random bytes, and a second of its own.
    private func write(_ url: URL, _ size: Int, _ rng: inout SplitMix64) throws {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        try Data(bytes).write(to: url)
        clock += 1
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(clock))],
                             ofItemAtPath: url.path)
    }

    private func contents(of dir: URL) -> (dirs: [URL], files: [URL]) {
        var dirs: [URL] = [], files: [URL] = []
        if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walker {
                let u = URL(fileURLWithPath: url.path)
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { dirs.append(u) }
                else { files.append(u) }
            }
        }
        return (dirs.sorted { $0.path < $1.path }, files.sorted { $0.path < $1.path })
    }

    /// A copy that keeps every file's date, so what was copied is identical
    /// to what it was copied from by the comparison's own measure.
    private func clone(_ from: URL, to: URL) throws {
        try fm.copyItem(at: from, to: to)
        guard let walker = fm.enumerator(at: from, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for case let url as URL in walker {
            let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let target = to.appendingPathComponent(rel(url, in: from))
            if let date { try fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path) }
        }
    }
}
