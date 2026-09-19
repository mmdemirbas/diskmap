import XCTest
import DiskMapCore
@testable import DiskMapScan

/// The live tree against the only oracle there is: a fresh scan of the same
/// folder.
///
/// Every other live-update test writes down one shape of change and what it
/// expects. This one makes shapes up — a few hundred of them, from a seed, so
/// a failure is a seed and a step and not a story — and asks after each batch
/// whether the tree the updates built is the tree a scan would build. It is
/// the test that would have found the three defects the first watcher test
/// found, and it is here so the next one is found the same afternoon.
///
/// Events are the ones the watcher would hand over: the paths of the things
/// that changed, files and folders alike, old and new names both for a
/// rename. Hard links are in the mix: which link keeps a file's bytes is
/// whichever a walk met first, and two walks need not agree, so where the
/// tree holds any the comparison is on what does not depend on it — the
/// same files, the same logical size on each, the same bytes on disk at the
/// root. Twelve seeds here in the suite; run with more before trusting a
/// change to the hard-link path, which is where the subtle ones hide.

final class LiveTreeFuzzTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: fm.temporaryDirectory.path)
            .appendingPathComponent("dmfuzz-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: canonicalPath(root.path) ?? root.path)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    func testTheLiveTreeMatchesAFreshScanAfterRandomChanges() throws {
        for seed: UInt64 in 1...12 {
            try fm.removeItem(at: root)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            counter = 0
            try run(seed: seed, batches: 60)
        }
    }

    // MARK: - One run

    private func run(seed: UInt64, batches: Int) throws {
        var rng = SplitMix64(seed: seed)
        var log: [String] = []
        // A starting shape with something at every depth.
        for _ in 0..<Int.random(in: 4...9, using: &rng) {
            try mutate(.createDirWithFiles, &rng, &log)
        }
        let tree = LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.path)))

        for batch in 0..<batches {
            var events: [RawPath] = []
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let kind = Mutation.allCases.randomElement(using: &rng)!
                events += try mutate(kind, &rng, &log)
            }
            tree.flushNow(events: events)
            let live = tree.withStore { reachable($0) }
            let linked = tree.withStore { store in
                (0..<Int32(store.count)).contains { store.flagSet($0).contains(.hardlinkDuplicate) }
            }
            // A few dozen nodes; the sixteen workers a real scan starts cost
            // more than the walk here, two hundred times over.
            var oracle = ScanOptions(rootPath: root.path)
            oracle.threadCount = 2
            let fresh = DiskScanner().scan(oracle).store
            let scanned = reachable(fresh)
            let diff = linked ? differencesIgnoringWhoKeepsTheBytes(live, scanned) : differences(live, scanned)
            if !diff.isEmpty {
                XCTFail("""
                    seed \(seed), batch \(batch): the live tree and a fresh scan disagree
                    \(diff.prefix(12).joined(separator: "\n"))
                    last steps:
                    \(log.suffix(10).joined(separator: "\n"))
                    """)
                return
            }
            tree.withStore { assertWellFormed($0) }
        }
    }

    private func differencesIgnoringWhoKeepsTheBytes(_ live: [String: TreeEntry], _ scanned: [String: TreeEntry]) -> [String] {
        var lines: [String] = []
        for k in Set(live.keys).union(scanned.keys).sorted() {
            switch (live[k], scanned[k]) {
            case let (a?, b?) where a.logical != b.logical || a.isDirectory != b.isDirectory || a.children != b.children:
                lines.append("\(k): live \(a)  scan \(b)")
            case (nil, let b?): lines.append("\(k): only in scan \(b)")
            case (let a?, nil): lines.append("\(k): only in live \(a)")
            default: break
            }
        }
        if let a = live[root.path]?.physical, let b = scanned[root.path]?.physical, a != b {
            lines.append("bytes on disk: live \(a)  scan \(b)")
        }
        return lines
    }

    // MARK: - Mutations

    private enum Mutation: CaseIterable {
        case createFile, resizeFile, deleteFile, renameFile, moveFile
        case createDirWithFiles, deleteDir, renameDir
        case replaceFileWithDir, replaceDirWithFile
        case createSymlink, repointSymlink
        case hardLink
    }

    private var counter = 0
    /// Every seventh name reaches outside ASCII, since the disk spells such a
    /// name differently from the caller and both sides have to hold its form.
    private func freshName(_ stem: String) -> String {
        counter += 1
        return "\(stem)\(counter)" + (counter % 7 == 0 ? " ölçü" : "")
    }

    /// Applies one change to the disk and returns the events the watcher
    /// would report for it. A change with nothing to act on does nothing.
    @discardableResult
    private func mutate(_ kind: Mutation, _ rng: inout SplitMix64, _ log: inout [String]) throws -> [RawPath] {
        let (dirs, files, links) = listing()
        func pick(_ a: [URL]) -> URL? { a.isEmpty ? nil : a.randomElement(using: &rng) }
        func size() -> Int { Int.random(in: 1...5_000, using: &rng) }
        func ev(_ urls: URL...) -> [RawPath] { urls.map { RawPath($0.path) } }

        switch kind {
        case .createFile:
            let dir = pick(dirs) ?? root!
            let f = dir.appendingPathComponent(freshName("f"))
            try Data(count: size()).write(to: f)
            log.append("create \(rel(f))")
            return ev(f)
        case .resizeFile:
            guard let f = pick(files) else { return [] }
            try Data(count: size()).write(to: f)
            log.append("resize \(rel(f))")
            return ev(f)
        case .deleteFile:
            guard let f = pick(files) else { return [] }
            try fm.removeItem(at: f)
            log.append("delete \(rel(f))")
            return ev(f)
        case .renameFile:
            guard let f = pick(files) else { return [] }
            let to = f.deletingLastPathComponent().appendingPathComponent(freshName("r"))
            try fm.moveItem(at: f, to: to)
            log.append("rename \(rel(f)) -> \(rel(to))")
            return ev(f, to)
        case .moveFile:
            guard let f = pick(files) else { return [] }
            let dir = pick(dirs) ?? root!
            let to = dir.appendingPathComponent(f.lastPathComponent)
            guard !fm.fileExists(atPath: to.path) else { return [] }
            try fm.moveItem(at: f, to: to)
            log.append("move \(rel(f)) -> \(rel(to))")
            return ev(f, to)
        case .createDirWithFiles:
            let parent = pick(dirs) ?? root!
            let d = parent.appendingPathComponent(freshName("d"))
            try fm.createDirectory(at: d, withIntermediateDirectories: false)
            var events = ev(d)
            for _ in 0..<Int.random(in: 0...3, using: &rng) {
                let f = d.appendingPathComponent(freshName("f"))
                try Data(count: size()).write(to: f)
                events += ev(f)
            }
            if Bool.random(using: &rng) {
                let inner = d.appendingPathComponent(freshName("d"))
                try fm.createDirectory(at: inner, withIntermediateDirectories: false)
                let f = inner.appendingPathComponent(freshName("f"))
                try Data(count: size()).write(to: f)
                events += ev(inner, f)
            }
            log.append("mkdir \(rel(d)) (+\(events.count - 1))")
            return events
        case .deleteDir:
            guard let d = pick(dirs) else { return [] }
            let inside = everything(under: d)
            try fm.removeItem(at: d)
            log.append("rmdir \(rel(d)) (\(inside.count) inside)")
            return inside.map { RawPath($0.path) } + ev(d)
        case .renameDir:
            guard let d = pick(dirs) else { return [] }
            let to = d.deletingLastPathComponent().appendingPathComponent(freshName("m"))
            try fm.moveItem(at: d, to: to)
            log.append("rename dir \(rel(d)) -> \(rel(to))")
            return ev(d, to)
        case .replaceFileWithDir:
            guard let f = pick(files) else { return [] }
            try fm.removeItem(at: f)
            try fm.createDirectory(at: f, withIntermediateDirectories: false)
            let inner = f.appendingPathComponent(freshName("f"))
            try Data(count: size()).write(to: inner)
            log.append("file->dir \(rel(f))")
            return ev(f, f, inner)
        case .replaceDirWithFile:
            guard let d = pick(dirs) else { return [] }
            let inside = everything(under: d)
            try fm.removeItem(at: d)
            try Data(count: size()).write(to: d)
            log.append("dir->file \(rel(d))")
            return inside.map { RawPath($0.path) } + ev(d, d)
        case .createSymlink:
            guard let target = pick(files) else { return [] }
            let dir = pick(dirs) ?? root!
            let l = dir.appendingPathComponent(freshName("l"))
            try fm.createSymbolicLink(at: l, withDestinationURL: target)
            log.append("link \(rel(l)) -> \(rel(target))")
            return ev(l)
        case .repointSymlink:
            guard let l = pick(links), let target = pick(files) else { return [] }
            try fm.removeItem(at: l)
            try fm.createSymbolicLink(at: l, withDestinationURL: target)
            log.append("repoint \(rel(l)) -> \(rel(target))")
            return ev(l)
        case .hardLink:
            guard let target = pick(files) else { return [] }
            let dir = pick(dirs) ?? root!
            let l = dir.appendingPathComponent(freshName("h"))
            try fm.linkItem(at: target, to: l)
            log.append("hardlink \(rel(l)) = \(rel(target))")
            return ev(l)
        }
    }

    // MARK: - The disk as it is

    private func listing() -> (dirs: [URL], files: [URL], links: [URL]) {
        var dirs: [URL] = [], files: [URL] = [], links: [URL] = []
        for u in everything(under: root) {
            let v = try? u.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if v?.isSymbolicLink == true { links.append(u) }
            else if v?.isDirectory == true { dirs.append(u) }
            else { files.append(u) }
        }
        // Stable order, so the seed decides and not the directory hash.
        return (dirs.sorted { $0.path < $1.path }, files.sorted { $0.path < $1.path },
                links.sorted { $0.path < $1.path })
    }

    private func everything(under dir: URL) -> [URL] {
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                                    options: []) else { return [] }
        return e.compactMap { $0 as? URL }.map { URL(fileURLWithPath: $0.path) }
    }

    private func rel(_ u: URL) -> String {
        String(u.path.dropFirst(root.path.count + 1))
    }
}

/// Small, fast, and the same sequence for the same seed on every machine.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
