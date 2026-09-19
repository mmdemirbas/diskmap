import XCTest
import DiskMapCore
@testable import DiskMapScan

/// The copies report against an independent reading of what a copy is.
///
/// A folder match means: the same names at the same sizes in the same shape,
/// recursively, whatever the folder itself is called. That is checkable
/// without the report: list every folder's files as (relative path, size),
/// and two folders with the same list are copies. Random trees with copies
/// planted in them — and near-copies, one file resized — are scanned, and
/// the report is held to two things: every exact match it names really has
/// one shape, and every pair of copies that exists is named, itself or
/// through a folder above it that was.
///
/// This is the report the Trash flow acts on, which is why it is held to an
/// oracle rather than to examples.
final class FolderMatchFuzzTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: fm.temporaryDirectory.path)
            .appendingPathComponent("dmmatch-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: canonicalPath(root.path) ?? root.path)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    func testEveryExactMatchIsOneShapeAndEveryCopyIsFound() throws {
        var exactMatches = 0, partialMatches = 0
        for seed: UInt64 in 1...10 {
            try fm.removeItem(at: root)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            counter = 0
            let found = try run(seed: seed)
            exactMatches += found.exact; partialMatches += found.partial
        }
        // The checks above are vacuous on a report that finds nothing.
        XCTAssertGreaterThan(exactMatches, 10, "hardly any copies were found across ten seeds")
        XCTAssertGreaterThan(partialMatches, 3, "hardly any near-copies were found across ten seeds")
    }

    private func run(seed: UInt64) throws -> (exact: Int, partial: Int) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<Int.random(in: 4...8, using: &rng) { try makeFolder(&rng) }

        // Plant copies: whole folders copied elsewhere, and a couple of
        // near-copies with one file resized so the shape differs by one.
        let candidates = folders().filter { !files(under: $0).isEmpty }
        for _ in 0..<Int.random(in: 2...4, using: &rng) {
            guard let src = candidates.randomElement(using: &rng) else { break }
            let dest = (folders().filter { !$0.path.hasPrefix(src.path) }.randomElement(using: &rng) ?? root!)
                .appendingPathComponent(freshName("copy"))
            try fm.copyItem(at: src, to: dest)
            if Bool.random(using: &rng), let f = files(under: dest).randomElement(using: &rng) {
                try Data(count: 12_345).write(to: f)   // no longer the same shape
            }
        }

        let store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        let matches = FolderMatches.find(store: store, root: 0, minimumSize: 1,
                                         similarity: 0.6, limit: 10_000)
        let shapes = Dictionary(uniqueKeysWithValues: folders().map { ($0.path, shape(of: $0)) })

        // Every exact match names folders of one shape.
        var reportedExact: [String] = []
        for m in matches {
            let paths = m.nodes.map { store.path($0) }
            let kinds = Set(paths.compactMap { shapes[$0] })
            if m.exact {
                XCTAssertEqual(kinds.count, 1, "seed \(seed): exact match over different shapes: \(paths)")
                reportedExact += paths
            } else {
                XCTAssertGreaterThan(kinds.count, 1, "seed \(seed): a partial match over one shape: \(paths)")
            }
        }

        // Every group of copies is named, itself or through a folder above.
        let groups = Dictionary(grouping: shapes.keys.filter { !shapes[$0]!.isEmpty }, by: { shapes[$0]! })
            .values.filter { $0.count >= 2 }
        for group in groups {
            for member in group {
                let named = reportedExact.contains { member == $0 || member.hasPrefix($0 + "/") }
                XCTAssertTrue(named, "seed \(seed): \(member) has a copy and neither it nor a folder above it was reported; copies: \(group)")
            }
        }
        return (matches.filter(\.exact).count, matches.filter { !$0.exact }.count)
    }

    // MARK: - Shapes, independently

    /// Every file under the folder as (relative path, size), sorted. Two
    /// folders with the same shape are what the report calls copies.
    private func shape(of dir: URL) -> [String] {
        files(under: dir).map { f in
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return "\(f.path.dropFirst(dir.path.count + 1))=\(size)"
        }.sorted()
    }

    private func folders() -> [URL] {
        walk(root).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }
    private func files(under dir: URL) -> [URL] {
        walk(dir).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true }
    }
    private func walk(_ dir: URL) -> [URL] {
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return [] }
        return e.compactMap { $0 as? URL }.map { URL(fileURLWithPath: $0.path) }.sorted { $0.path < $1.path }
    }

    // MARK: - Building

    private var counter = 0
    private func freshName(_ stem: String) -> String {
        counter += 1
        return "\(stem)\(counter)" + (counter % 8 == 0 ? " ölçü" : "")
    }

    /// A folder with a few files and maybe a subfolder, somewhere in the tree.
    private func makeFolder(_ rng: inout SplitMix64) throws {
        let parent = folders().randomElement(using: &rng) ?? root!
        let d = parent.appendingPathComponent(freshName("d"))
        try fm.createDirectory(at: d, withIntermediateDirectories: false)
        for _ in 0..<Int.random(in: 1...4, using: &rng) {
            try Data(count: Int.random(in: 1...9_000, using: &rng)).write(to: d.appendingPathComponent(freshName("f")))
        }
        if Bool.random(using: &rng) {
            let inner = d.appendingPathComponent(freshName("d"))
            try fm.createDirectory(at: inner, withIntermediateDirectories: false)
            try Data(count: Int.random(in: 1...9_000, using: &rng)).write(to: inner.appendingPathComponent(freshName("f")))
        }
    }
}
