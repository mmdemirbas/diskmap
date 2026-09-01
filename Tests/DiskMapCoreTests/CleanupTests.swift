import XCTest
@testable import DiskMapCore

final class CleanupTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var store: NodeStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("dmclean-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int, ageDays: Int? = nil) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        if let ageDays {
            let when = Date().addingTimeInterval(-Double(ageDays) * 24 * 3600)
            try fm.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
        }
    }

    private var small: Cleanup.Thresholds {
        var t = Cleanup.Thresholds()
        t.suggestion = 10_000
        t.installer = 10_000
        t.staleFile = 10_000
        return t
    }

    private func suggest(folders: [[Int32]] = [], files: [[Int32]] = [],
                         thresholds: Cleanup.Thresholds? = nil) -> [CleanupSuggestion] {
        store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        return Cleanup.suggest(store: store, root: 0, folderCopies: folders,
                               fileCopies: files, thresholds: thresholds ?? small)
    }

    private func node(_ path: String) throws -> Int32 {
        try XCTUnwrap(store.find(path: root.appendingPathComponent(path).path))
    }

    func testBuildOutputIsFoundAndCountedOnce() throws {
        try write("project/node_modules/pkg/index.js", 40_000)
        try write("project/node_modules/other/big.bin", 40_000)
        try write("project/src/main.swift", 1_000)
        let found = suggest()
        let build = try XCTUnwrap(found.first { $0.kind == .buildOutput })
        // The folder, not everything under it.
        XCTAssertEqual(build.itemCount, 1)
        XCTAssertEqual(build.nodes, [try node("project/node_modules")])
        XCTAssertEqual(build.safety, .comesBack)
    }

    /// A folder called `build` is an ordinary word and may be someone's work.
    /// Only names that essentially never hold typed-in content are proposed.
    func testAmbiguousFolderNamesAreNotProposed() throws {
        try write("project/build/artifact.bin", 40_000)
        try write("project/target/artifact.bin", 40_000)
        XCTAssertNil(suggest().first { $0.kind == .buildOutput })
    }

    func testAppCachesAreListedPerAppNotAsOneLump() throws {
        try write("Library/Caches/com.example.one/blob.bin", 40_000)
        try write("Library/Caches/com.example.two/blob.bin", 40_000)
        let caches = try XCTUnwrap(suggest().first { $0.kind == .appCaches })
        XCTAssertEqual(caches.itemCount, 2)
        XCTAssertEqual(caches.safety, .comesBack)
    }

    /// Nothing the app can do to the Trash is recoverable, so it reports the
    /// size and proposes no deletion at all.
    func testTheTrashIsReportedButNeverProposedForDeletion() throws {
        try write(".Trash/old.bin", 40_000)
        let trash = try XCTUnwrap(suggest().first { $0.kind == .trash })
        XCTAssertTrue(trash.nodes.isEmpty)
        XCTAssertGreaterThan(trash.bytes, 0)
    }

    func testInstallersAreFoundByExtension() throws {
        try write("Downloads/thing.dmg", 40_000)
        try write("Downloads/notes.txt", 40_000)
        let installers = try XCTUnwrap(suggest().first { $0.kind == .installers })
        XCTAssertEqual(installers.nodes, [try node("Downloads/thing.dmg")])
        XCTAssertEqual(installers.safety, .yourCall)
    }

    func testOldBigFilesAreProposedAndRecentOnesAreNot() throws {
        try write("archive/ancient.mov", 40_000, ageDays: 900)
        try write("archive/recent.mov", 40_000, ageDays: 10)
        let stale = try XCTUnwrap(suggest().first { $0.kind == .stale })
        XCTAssertEqual(stale.nodes, [try node("archive/ancient.mov")])
    }

    func testCopiesKeepOneAndProposeTheRest() throws {
        try write("a/clip.mov", 40_000)
        try write("b/clip.mov", 40_000)
        try write("c/clip.mov", 40_000)
        store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        let group = [try node("a/clip.mov"), try node("b/clip.mov"), try node("c/clip.mov")]
        let found = Cleanup.suggest(store: store, root: 0, fileCopies: [group], thresholds: small)
        let copies = try XCTUnwrap(found.first { $0.kind == .duplicateFiles })
        XCTAssertEqual(copies.itemCount, 2, "one of the three must survive")
        XCTAssertFalse(copies.nodes.contains(try node("a/clip.mov")))
    }

    /// What comes back on its own is offered before what needs a decision.
    func testTheSafestSuggestionsComeFirst() throws {
        try write("project/node_modules/big.bin", 90_000)
        try write("Downloads/thing.dmg", 90_000)
        try write("archive/ancient.mov", 90_000, ageDays: 900)
        let found = suggest()
        let safeties = found.map(\.safety)
        XCTAssertEqual(safeties, safeties.sorted())
        XCTAssertEqual(found.first?.kind, .buildOutput)
    }

    func testSmallFindingsAreNotWorthSuggesting() throws {
        try write("project/node_modules/tiny.bin", 100)
        XCTAssertTrue(suggest().isEmpty)
    }

    func testExtensionParsing() {
        XCTAssertEqual(Cleanup.extensionOf("thing.DMG"), "dmg")
        XCTAssertEqual(Cleanup.extensionOf("no-extension"), "")
        XCTAssertEqual(Cleanup.extensionOf(".hidden"), "")
        XCTAssertEqual(Cleanup.extensionOf("a.b.pkg"), "pkg")
    }
}
