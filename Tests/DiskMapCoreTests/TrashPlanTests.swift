import XCTest
@testable import DiskMapCore

/// These tests never delete anything. The planner only decides; the deleting is
/// a separate step, and every rule here exists so that step cannot be asked to
/// do something unrecoverable.
final class TrashPlanTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var store: NodeStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("dmtrash-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    private func write(_ path: String, _ bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func scan() { store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store }

    /// Temporary directories are reached through a symlink, and the store
    /// stores the resolved form. Comparisons have to use the same one.
    private func real(_ path: String) -> String {
        let url = path.isEmpty ? root! : root.appendingPathComponent(path)
        return canonicalPath(url.path) ?? url.path
    }

    private func node(_ path: String) throws -> Int32 {
        try XCTUnwrap(store.find(path: root.appendingPathComponent(path).path))
    }

    private func plan(_ selected: [Int32], groups: [[Int32]] = [],
                      sync: SyncRoots = SyncRoots(roots: [])) -> Result<TrashPlan, TrashRefusal> {
        TrashPlanner.plan(store: store, selected: Set(selected), groups: groups, syncRoots: sync)
    }

    private func success(_ result: Result<TrashPlan, TrashRefusal>) throws -> TrashPlan {
        switch result {
        case .success(let plan): return plan
        case .failure(let refusal): XCTFail("refused: \(refusal)"); throw refusal
        }
    }

    private func refusal(_ result: Result<TrashPlan, TrashRefusal>) throws -> TrashRefusal {
        switch result {
        case .success(let plan): XCTFail("planned \(plan.items.count) items instead of refusing")
            throw TrashRefusal.nothingSelected
        case .failure(let refusal): return refusal
        }
    }

    // MARK: - The ordinary case

    func testPlansWhatWasSelectedWithItsSize() throws {
        try write("a/one.bin", 40_000)
        try write("b/one.bin", 40_000)
        scan()
        let plan = try success(plan([try node("a/one.bin")]))
        XCTAssertEqual(plan.items.count, 1)
        let only = try XCTUnwrap(plan.items.first)
        XCTAssertEqual(only.name, "one.bin")
        XCTAssertEqual(plan.bytes, 40_960)
        XCTAssertNil(only.syncProvider)
    }

    func testNothingSelectedIsARefusal() throws {
        try write("a/one.bin", 40_000)
        scan()
        XCTAssertEqual(try refusal(plan([])), .nothingSelected)
    }

    // MARK: - Never leave nothing behind

    /// "Delete the duplicates" never meant "delete the original too". A group
    /// the app itself called copies must keep a member.
    func testSelectingEveryCopyIsRefused() throws {
        try write("a/clip.mov", 40_000)
        try write("b/clip.mov", 40_000)
        scan()
        let copies = [try node("a/clip.mov"), try node("b/clip.mov")]
        XCTAssertEqual(try refusal(plan(copies, groups: [copies])), .wouldRemoveEveryCopy("clip.mov"))
    }

    func testSelectingAllButOneCopyIsAllowed() throws {
        try write("a/clip.mov", 40_000)
        try write("b/clip.mov", 40_000)
        try write("c/clip.mov", 40_000)
        scan()
        let copies = [try node("a/clip.mov"), try node("b/clip.mov"), try node("c/clip.mov")]
        let plan = try success(plan(Array(copies.prefix(2)), groups: [copies]))
        XCTAssertEqual(plan.items.count, 2)
    }

    /// The subtle one. Selecting one copy and the *folder holding* the other
    /// destroys both, and neither selection looks dangerous on its own.
    func testAFolderThatSwallowsTheLastCopyIsRefused() throws {
        try write("keep/clip.mov", 40_000)
        try write("other/clip.mov", 40_000)
        scan()
        let copies = [try node("keep/clip.mov"), try node("other/clip.mov")]
        let selection = [try node("keep"), try node("other/clip.mov")]
        XCTAssertEqual(try refusal(plan(selection, groups: [copies])),
                       .wouldRemoveEveryCopy("clip.mov"))
    }

    /// A group whose members are already gone cannot be protected by keeping
    /// one of them, and must not be silently ignored either.
    func testAGroupWithNoLivingMemberIsRefused() throws {
        try write("a/clip.mov", 40_000)
        try write("b/clip.mov", 40_000)
        try write("c/other.bin", 40_000)
        scan()
        let copies = [try node("a/clip.mov"), try node("b/clip.mov")]
        store.flags[Int(copies[0])] |= NodeFlags.removed.rawValue
        let selection = [copies[1]]
        XCTAssertEqual(try refusal(plan(selection, groups: copies.map { _ in copies })),
                       .wouldRemoveEveryCopy("clip.mov"))
    }

    // MARK: - Never trash the ground you are standing on

    func testAScanRootIsRefused() throws {
        try write("a/one.bin", 40_000)
        scan()
        XCTAssertEqual(try refusal(plan([0])), .includesAScanRoot(real("")))
    }

    /// The containment rule the plan leans on, on its own. Getting this wrong
    /// is how a folder appears to swallow its neighbour.
    func testContainmentIsByWholePathComponents() {
        XCTAssertTrue(TrashPlanner.isInside("/a/b", "/a/b"))
        XCTAssertTrue(TrashPlanner.isInside("/a/b/c", "/a/b"))
        XCTAssertTrue(TrashPlanner.isInside("/a", "/"))
        XCTAssertFalse(TrashPlanner.isInside("/a/bc", "/a/b"))
        XCTAssertFalse(TrashPlanner.isInside("/a/b", "/a/b/c"))
        XCTAssertFalse(TrashPlanner.isInside("/other", "/a"))
    }

    // MARK: - Do not ask the filesystem to do the same work twice

    func testAnItemInsideASelectedFolderIsDroppedFromThePlan() throws {
        try write("bundle/inner/file.bin", 40_000)
        try write("bundle/other.bin", 10_000)
        scan()
        let plan = try success(plan([try node("bundle"),
                                     try node("bundle/inner/file.bin"),
                                     try node("bundle/other.bin")]))
        XCTAssertEqual(plan.items.map(\.name), ["bundle"])
        XCTAssertEqual(plan.coveredByAnAncestor, 2)
        // The folder's own total, counted once.
        XCTAssertEqual(plan.bytes, 53_248)
    }

    /// A sibling whose name merely starts with the same letters is not inside.
    func testASimilarlyNamedSiblingIsNotTreatedAsContained() throws {
        try write("dev/a.bin", 40_000)
        try write("development/b.bin", 40_000)
        scan()
        let plan = try success(plan([try node("dev"), try node("development")]))
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertEqual(plan.coveredByAnAncestor, 0)
    }

    func testItemsTheTreeAlreadyCallsGoneAreDropped() throws {
        try write("a/one.bin", 40_000)
        try write("a/two.bin", 40_000)
        scan()
        let gone = try node("a/one.bin")
        store.flags[Int(gone)] |= NodeFlags.removed.rawValue
        let plan = try success(plan([gone, try node("a/two.bin")]))
        XCTAssertEqual(plan.items.map(\.name), ["two.bin"])
        XCTAssertEqual(plan.alreadyGone, 1)
    }

    // MARK: - Say when a deletion leaves the machine

    func testItemsInsideASyncRootCarryTheProviderName() throws {
        try write("Library/CloudStorage/GoogleDrive-someone@example.com/work/big.mov", 40_000)
        try write("local/big.mov", 40_000)
        scan()
        let sync = SyncRoots.detected(home: root.path)
        XCTAssertEqual(sync.roots.count, 1)

        let plan = try success(plan([
            try node("Library/CloudStorage/GoogleDrive-someone@example.com/work/big.mov"),
            try node("local/big.mov"),
        ], sync: sync))
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertEqual(plan.synced.count, 1)
        XCTAssertEqual(plan.synced.first?.syncProvider, "Google Drive")
    }

    func testProviderNamesDropTheAccount() {
        XCTAssertEqual(SyncRoots.providerName("GoogleDrive-someone@example.com"), "Google Drive")
        XCTAssertEqual(SyncRoots.providerName("Dropbox-Personal"), "Dropbox")
        XCTAssertEqual(SyncRoots.providerName("OneDrive-Personal"), "OneDrive")
        XCTAssertEqual(SyncRoots.providerName("Box-Box"), "Box")
    }

    func testICloudDriveCountsAsASyncRoot() throws {
        try fm.createDirectory(at: root.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"),
                               withIntermediateDirectories: true)
        try write("Library/Mobile Documents/com~apple~CloudDocs/note.txt", 1_000)
        scan()
        let sync = SyncRoots.detected(home: root.path)
        XCTAssertEqual(sync.provider(for: real("Library/Mobile Documents/com~apple~CloudDocs/note.txt")),
                       "iCloud Drive")
        XCTAssertNil(sync.provider(for: real("elsewhere/note.txt")))
    }
}

/// The review is what the user is shown before anything moves. It has to carry
/// the whole decision, not just the half that gets deleted.
extension TrashPlanTests {
    private func review(_ selected: [Int32], groups: [[Int32]] = [],
                        sync: SyncRoots = SyncRoots(roots: [])) -> [ReviewGroup] {
        TrashPlanner.review(store: store, selected: Set(selected),
                            groups: groups, syncRoots: sync)
    }

    /// Picking one copy has to show the others, or the choice is being made
    /// blind: "delete this one" means nothing without "and keep that one".
    func testSelectingOneCopyShowsTheWholeGroup() throws {
        try write("a/clip.mov", 40_000)
        try write("b/clip.mov", 40_000)
        try write("c/clip.mov", 40_000)
        scan()
        let copies = [try node("a/clip.mov"), try node("b/clip.mov"), try node("c/clip.mov")]
        let groups = review([copies[0]], groups: [copies])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isCopyGroup)
        XCTAssertEqual(Set(groups[0].members.map(\.node)), Set(copies))
    }

    func testAnItemThatIsNotACopyStandsAlone() throws {
        try write("downloads/installer.dmg", 40_000)
        scan()
        let groups = review([try node("downloads/installer.dmg")])
        XCTAssertEqual(groups.count, 1)
        XCTAssertFalse(groups[0].isCopyGroup)
        XCTAssertEqual(groups[0].members.count, 1)
    }

    func testTheBiggestDecisionComesFirst() throws {
        try write("small/a.bin", 10_000)
        try write("big/b.bin", 400_000)
        scan()
        let groups = review([try node("small/a.bin"), try node("big/b.bin")])
        XCTAssertEqual(groups.map(\.name), ["b.bin", "a.bin"])
    }

    func testAMemberInsideASyncRootIsMarkedInTheReview() throws {
        try write("Library/CloudStorage/GoogleDrive-someone@example.com/x/clip.mov", 40_000)
        try write("local/clip.mov", 40_000)
        scan()
        let copies = [
            try node("Library/CloudStorage/GoogleDrive-someone@example.com/x/clip.mov"),
            try node("local/clip.mov"),
        ]
        let groups = review([copies[0]], groups: [copies],
                            sync: SyncRoots.detected(home: root.path))
        let providers = groups[0].members.compactMap(\.syncProvider)
        XCTAssertEqual(providers, ["Google Drive"])
    }

    /// A group nobody selected anything from is not a decision being made.
    func testUntouchedGroupsAreNotShown() throws {
        try write("a/clip.mov", 40_000)
        try write("b/clip.mov", 40_000)
        try write("elsewhere/other.bin", 40_000)
        scan()
        let copies = [try node("a/clip.mov"), try node("b/clip.mov")]
        let groups = review([try node("elsewhere/other.bin")], groups: [copies])
        XCTAssertEqual(groups.map(\.name), ["other.bin"])
    }

    func testAGroupIsIdentifiedByItsMembersNotByOneOfThem() {
        XCTAssertEqual(TrashPlanner.key([1, 2, 3]), TrashPlanner.key([3, 2, 1]))
        XCTAssertNotEqual(TrashPlanner.key([1, 2, 3]), TrashPlanner.key([1, 2, 4]))
    }
}

/// Paths the user has put on the never-touch list.
extension TrashPlanTests {
    func testAnExcludedPathIsDroppedFromThePlanNotRefused() throws {
        try write("keep-out/big.bin", 40_000)
        try write("ordinary/big.bin", 40_000)
        scan()
        let result = TrashPlanner.plan(
            store: store,
            selected: [try node("keep-out/big.bin"), try node("ordinary/big.bin")],
            excluded: [real("keep-out")])
        let plan = try success(result)
        XCTAssertEqual(plan.items.map(\.name), ["big.bin"])
        XCTAssertEqual(plan.items[0].path, real("ordinary/big.bin"))
        XCTAssertEqual(plan.excluded, 1)
    }

    /// Excluding a folder covers what is inside it, but not a sibling whose
    /// name merely starts the same way.
    func testExclusionCoversContentsAndNotSimilarSiblings() throws {
        try write("drive/inner/big.bin", 40_000)
        try write("drivers/big.bin", 40_000)
        scan()
        let plan = try success(TrashPlanner.plan(
            store: store,
            selected: [try node("drive/inner/big.bin"), try node("drivers/big.bin")],
            excluded: [real("drive")]))
        XCTAssertEqual(plan.items.map(\.path), [real("drivers/big.bin")])
    }

    /// An excluded copy still counts as a survivor: it is not being removed, so
    /// the group is not being emptied.
    func testAnExcludedCopyStillCountsAsSurviving() throws {
        try write("archive/clip.mov", 40_000)
        try write("working/clip.mov", 40_000)
        scan()
        let copies = [try node("archive/clip.mov"), try node("working/clip.mov")]
        let plan = try success(TrashPlanner.plan(
            store: store, selected: Set(copies), groups: [copies],
            excluded: [real("archive")]))
        XCTAssertEqual(plan.items.map(\.path), [real("working/clip.mov")])
        XCTAssertEqual(plan.excluded, 1)
    }

    func testAnExcludedItemIsNotEvenShownAsADecision() throws {
        try write("keep-out/big.bin", 40_000)
        scan()
        let groups = TrashPlanner.review(store: store,
                                         selected: [try node("keep-out/big.bin")],
                                         excluded: [real("keep-out")])
        XCTAssertTrue(groups.isEmpty)
    }
}
