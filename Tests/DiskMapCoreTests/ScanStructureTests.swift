import XCTest
import DiskMapCore
@testable import DiskMapScan

/// What the walk builds, checked the way everything else reads it.
///
/// Sixteen workers append into one store, a directory's children as one
/// block each under the lock. Every view, every report and every live update
/// reads the result through `children(_:)`, which is only meaningful if the
/// blocks came out whole and in place. The single-threaded walk is the
/// oracle for the parallel one, and the invariant is checked on both.
final class ScanStructureTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: fm.temporaryDirectory.path)
            .appendingPathComponent("dmstruct-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: canonicalPath(root.path) ?? root.path)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    /// A wide, deep tree: hundreds of folders at four levels, so the
    /// workers are genuinely interleaved rather than taking turns.
    private func grow(_ rng: inout SplitMix64) throws -> Int {
        var made = 0
        func level(_ dir: URL, depth: Int) throws {
            for i in 0..<Int.random(in: 2...6, using: &rng) {
                try Data(count: Int.random(in: 0...2_000, using: &rng))
                    .write(to: dir.appendingPathComponent("f\(depth)-\(i)\(i % 3 == 0 ? " ölçü" : "")"))
                made += 1
            }
            guard depth < 4 else { return }
            for i in 0..<Int.random(in: 2...5, using: &rng) {
                let d = dir.appendingPathComponent("d\(depth)-\(i)")
                try fm.createDirectory(at: d, withIntermediateDirectories: false)
                made += 1
                try level(d, depth: depth + 1)
            }
        }
        try level(root, depth: 0)
        return made
    }

    func testTheParallelWalkBuildsWhatTheSerialWalkBuilds() throws {
        for seed: UInt64 in 1...3 {
            var rng = SplitMix64(seed: seed)
            try fm.removeItem(at: root)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let made = try grow(&rng)

            var serial = ScanOptions(rootPath: root.path); serial.threadCount = 1
            var parallel = ScanOptions(rootPath: root.path); parallel.threadCount = 16
            let a = DiskScanner().scan(serial), b = DiskScanner().scan(parallel)
            XCTAssertEqual(a.store.count, made + 1, "seed \(seed): the serial walk missed something")
            XCTAssertEqual(differences(reachable(a.store), reachable(b.store), labels: ("serial", "parallel")), [],
                           "seed \(seed)")
            assertWellFormed(a.store)
            assertWellFormed(b.store)
            XCTAssertEqual(a.stats.files, b.stats.files)
            XCTAssertEqual(a.stats.directories, b.stats.directories)
            XCTAssertEqual(a.stats.totalLogical, b.stats.totalLogical)
            XCTAssertEqual(a.stats.totalPhysical, b.stats.totalPhysical)
        }
    }

    /// A subtree copied out of a scan is the scan of that subtree.
    func testASubtreeCopyIsTheScanOfThatFolder() throws {
        var rng = SplitMix64(seed: 7)
        _ = try grow(&rng)
        let whole = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        let inner = root.appendingPathComponent("d0-1")
        let node = try XCTUnwrap(whole.find(path: inner.path))

        let copy = whole.subtree(root: node)
        let alone = DiskScanner().scan(ScanOptions(rootPath: inner.path)).store
        XCTAssertEqual(differences(reachable(copy), reachable(alone), labels: ("copy", "scan")), [])
        assertWellFormed(copy)
        XCTAssertEqual(copy.count, alone.count)
    }
}
