import AppKit
import Combine
import DiskMapCore
import SwiftUI

/// Comparing two folders, and everything that follows from it: the plan, the
/// content check, and which decisions are in.
///
/// **The module that needs no scan.** It walks the two folders it is given and
/// reads nothing else, which is why it should open from a cold launch rather
/// than behind a disk scan. The one thing it cannot do for itself is start
/// from a folder in the scanned tree — that handoff stays with the shell,
/// which is the object that has a tree.
///
/// Member names are unchanged from when this was part of `AppModel`, prefix
/// and all. A pure move is a diff a reader can check; renaming inside it is a
/// separate change and can be made on its own.
@MainActor
final class CompareModule: ObservableObject {
    @Published var compareLeft = ""
    @Published var compareRight = ""
    @Published var folderComparison: FolderComparison?
    @Published private(set) var comparing = false
    @Published private(set) var compareRefusal: CompareRefusal?
    @Published var comparePage: ComparePage = .diff
    @Published var compareFilter: CompareFilter = .differences
    @Published var dateFilter: DateFilter = .any
    @Published var syncDirection: SyncDirection = .mirrorLeftToRight
    @Published private(set) var syncPlan: SyncPlan?
    @Published private(set) var syncOutcome: SyncOutcome?
    @Published private(set) var syncRunning = false
    @Published private(set) var syncProgress: SyncProgress?
    @Published private(set) var compareVerification: VerifyDifferences?
    @Published private(set) var compareVerifying = false
    @Published private(set) var compareVerifyBytes: Int64 = 0
    /// The rows on screen, as tree nodes. Held rather than derived: walking the
    /// tree inside `body` would do it again on every redraw.
    @Published private(set) var compareRows: [Int32] = []
    @Published private(set) var compareRowsOmitted = 0
    @Published private(set) var compareExpanded: Set<Int32> = []
    /// Decisions the user has unticked. Empty means everything is in, which is
    /// what a comparison starts as — narrowing is the deliberate act, not
    /// widening.
    @Published private(set) var compareSkipped: Set<Int> = []
    /// Running count of unticked decisions, so a row can say whether its own
    /// run of them is all in, all out or mixed without counting a set every
    /// time it draws.
    private var skippedPrefix: [Int] = []
    private var compareCancel: CancelToken?
    private var compareGeneration = 0

    let settings: CompareSettings

    init(settings: CompareSettings) {
        self.settings = settings
    }

    /// Which of the three screens the comparison sheet is showing.
    ///
    /// Pages rather than nested sheets: all three are the same size, so moving
    /// between them moves nothing on screen.
    enum ComparePage { case diff, plan, result }

    func openCompare(left: String? = nil, right: String? = nil) {
        if let left { compareLeft = left }
        if let right { compareRight = right }
        comparePage = .diff
        if !compareLeft.isEmpty, !compareRight.isEmpty { runComparison() }
    }

    func chooseCompareSide(_ side: Side) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.shared[.compareChoose]
        panel.message = L10n.shared[.compareChooseMessage]
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        if side == .left { compareLeft = url.path } else { compareRight = url.path }
        if !compareLeft.isEmpty, !compareRight.isEmpty { runComparison() }
    }

    func swapCompareSides() {
        let held = compareLeft
        compareLeft = compareRight
        compareRight = held
        if !compareLeft.isEmpty, !compareRight.isEmpty { runComparison() }
    }

    var canCompare: Bool { !compareLeft.isEmpty && !compareRight.isEmpty && !comparing }

    /// Where an already-measured copy of a folder can be had.
    ///
    /// Set by the app whenever the tree it holds changes, and nil for the CLI
    /// and the tests, which have no scan to share. It is asked from a
    /// background thread, so it closes over the tree rather than over anything
    /// belonging to a screen.
    var alreadyScanned: FolderDiff.Supplier?

    func runComparison() {
        guard !compareLeft.isEmpty, !compareRight.isEmpty else { return }
        cancelComparison()
        compareGeneration += 1
        let generation = compareGeneration
        let left = compareLeft, right = compareRight
        let token = CancelToken()
        compareCancel = token

        folderComparison = nil
        compareRefusal = nil
        compareVerification = nil
        syncPlan = nil
        syncOutcome = nil
        comparing = true
        comparePage = .diff

        let options = settings.options
        Task { [weak self] in
            let reuse = self?.alreadyScanned
            let outcome = await Task.detached(priority: .userInitiated) {
                FolderDiff.compare(left: left, right: right, options: options, cancel: token,
                                   alreadyScanned: reuse)
            }.value
            guard let self, self.compareGeneration == generation else { return }
            self.comparing = false
            self.compareCancel = nil
            switch outcome {
            case .success(let comparison):
                self.folderComparison = comparison
                self.compareLeft = comparison.left
                self.compareRight = comparison.right
                self.openTheDifferences(comparison.tree)
                self.compareSkipped = []
                self.rebuildSkippedPrefix(comparison)
                self.rebuildCompareRows()
                self.settings.remember(comparison.left, comparison.right)
            case .failure(let refusal):
                self.compareRefusal = refusal
            }
        }
    }

    /// At most this many rows reach the screen. A folder pair can disagree
    /// about a million names and no one reads a million rows, but the count of
    /// what is not shown has to be on screen or the list reads as the whole
    /// answer. The plan is always built from every entry, never from these.
    static let compareRowLimit = 2000

    func rebuildCompareRows() {
        guard let tree = folderComparison?.tree else {
            compareRows = []; compareRowsOmitted = 0; return
        }
        var rows: [Int32] = []
        appendCompareRows(tree, 0, into: &rows)
        compareRowsOmitted = max(0, rows.count - Self.compareRowLimit)
        compareRows = Array(rows.prefix(Self.compareRowLimit))
    }

    /// The visible frontier: the children of the root, and of everything open
    /// below it, in the order the tree holds them — biggest first within each
    /// folder.
    private func appendCompareRows(_ tree: DiffTree, _ id: Int32, into rows: inout [Int32]) {
        for child in tree.children(of: id) {
            guard compareExpanded.contains(child), tree.isExpandable(child) else {
                if showsCompareRow(tree, child) { rows.append(child) }
                continue
            }
            // An open folder is judged on what is under it: if the filter
            // emptied it and the folder is not itself a match, it goes too,
            // rather than sitting there as a row that leads nowhere.
            let start = rows.count
            rows.append(child)
            appendCompareRows(tree, child, into: &rows)
            if rows.count == start + 1, !showsCompareRow(tree, child) { rows.removeLast() }
        }
    }

    /// A closed folder is judged on itself; the kind filter keeps it when its
    /// subtree could hold a match, so the way in is never hidden. The date
    /// filter has no such escape — what is under a closed folder was never
    /// paired up, so there are no two dates to compare — and judging it on its
    /// own pair of dates is the honest reading of the row on screen.
    private func showsCompareRow(_ tree: DiffTree, _ id: Int32) -> Bool {
        guard !compareFilter.mask.isDisjoint(with: tree.contains(id)) else { return false }
        return dateFilter.accepts(tree, id)
    }

    // MARK: - Which decisions are in

    private func rebuildSkippedPrefix(_ comparison: FolderComparison) {
        skippedPrefix = [Int](repeating: 0, count: comparison.entries.count + 1)
        for index in comparison.entries.indices {
            skippedPrefix[index + 1] = skippedPrefix[index] + (compareSkipped.contains(index) ? 1 : 0)
        }
    }

    /// Whether a row is all in, all out, or somewhere between.
    ///
    /// Counted from a prefix sum rather than by walking the run, because a
    /// folder can stand for a hundred thousand decisions and this is asked once
    /// per visible row on every redraw.
    enum RowInclusion { case all, none, some }

    func compareInclusion(_ tree: DiffTree, _ id: Int32) -> RowInclusion {
        let range = tree.decisions(id)
        guard !range.isEmpty, range.upperBound < skippedPrefix.count else { return .all }
        let out = skippedPrefix[range.upperBound] - skippedPrefix[range.lowerBound]
        if out == 0 { return .all }
        return out == range.count ? .none : .some
    }

    /// Ticking a folder takes everything it stands for with it, which is the
    /// only reading that makes sense: the row is the decision.
    func toggleCompareInclusion(_ tree: DiffTree, _ id: Int32) {
        guard let comparison = folderComparison else { return }
        let range = tree.decisions(id)
        guard !range.isEmpty else { return }
        let putBackIn = compareInclusion(tree, id) != .all
        for decision in range {
            if putBackIn { compareSkipped.remove(decision) } else { compareSkipped.insert(decision) }
        }
        rebuildSkippedPrefix(comparison)
    }

    func includeEveryDecision() {
        guard let comparison = folderComparison else { return }
        compareSkipped = []
        rebuildSkippedPrefix(comparison)
    }

    func includeNoDecision() {
        guard let comparison = folderComparison else { return }
        compareSkipped = Set(comparison.entries.indices)
        rebuildSkippedPrefix(comparison)
    }

    var compareIncludedCount: Int {
        (folderComparison?.entries.count ?? 0) - compareSkipped.count
    }

    func toggleCompareExpanded(_ id: Int32) {
        if compareExpanded.contains(id) { compareExpanded.remove(id) }
        else { compareExpanded.insert(id) }
        rebuildCompareRows()
    }

    func isCompareExpanded(_ id: Int32) -> Bool { compareExpanded.contains(id) }

    /// Opens the folders the comparison itself had to walk into — the ones that
    /// differ — so the screen starts on the differences instead of on a closed
    /// root. Everything it stopped at stays shut, which is the point of having
    /// stopped.
    func openTheDifferences(_ tree: DiffTree) {
        var open = Set<Int32>()
        for id in 0..<Int32(tree.count) where tree.isOpen(id) && tree.isExpandable(id) {
            open.insert(id)
        }
        compareExpanded = open
    }

    /// What each chip would show, in items rather than rows — the same measure
    /// the key has always used.
    func compareCount(_ filter: CompareFilter) -> Int? {
        guard let s = folderComparison?.summary else { return nil }
        switch filter {
        case .differences: return s.differences
        case .all: return s.differences + s.identical
        case .identical: return s.identical
        case .differs: return s.differing
        case .onlyLeft: return s.onlyLeft
        case .onlyRight: return s.onlyRight
        case .typeClash: return s.typeClashes
        }
    }

    /// True when one side holds nothing the other does not, which is the only
    /// state in which "delete the redundant copy" is a safe sentence.
    func isRedundant(_ side: Side) -> Bool {
        guard let comparison = folderComparison else { return false }
        return comparison.summary.isCoveredByTheOtherSide(side)
    }

    func cancelComparison() {
        compareCancel?.cancel()
        compareCancel = nil
        comparing = false
    }

    /// The check the comparison itself will not do: reads both sides of
    /// everything it called identical, because the same length is not the same
    /// bytes.
    func verifyComparison() {
        guard let comparison = folderComparison, !compareVerifying else { return }
        let token = CancelToken()
        compareCancel = token
        compareVerifying = true
        compareVerifyBytes = 0
        compareVerification = nil

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                FolderDiff.verify(comparison, cancel: token) { read in
                    Task { @MainActor [weak self] in self?.compareVerifyBytes = read }
                }
            }.value
            guard let self else { return }
            self.compareVerifying = false
            self.compareCancel = nil
            self.compareVerification = result
            self.folderComparison?.verifiedAt = Date()
        }
    }

    func cancelCompareVerify() {
        compareCancel?.cancel()
        compareCancel = nil
        compareVerifying = false
    }

    /// Builds the plan and shows it. Nothing is written until it is read.
    func previewSync(syncRoots: SyncRoots, excluded: [String]) {
        guard let comparison = folderComparison else { return }
        apply(SyncPlanner.plan(comparison, direction: syncDirection,
                               syncRoots: syncRoots, excluded: excluded,
                               skipping: compareSkipped,
                               contentCheck: compareVerification))
    }

    /// The whole of one side to the Trash, once the other holds everything it
    /// does. The planner refuses when that is not true.
    func previewRemoveRedundant(_ side: Side, syncRoots: SyncRoots, excluded: [String]) {
        guard let comparison = folderComparison else { return }
        apply(SyncPlanner.removeRedundant(
            comparison, side: side, syncRoots: syncRoots, excluded: excluded,
            contentCheck: compareVerification))
    }

    private func apply(_ result: Result<SyncPlan, CompareRefusal>) {
        switch result {
        case .success(let plan):
            syncPlan = plan
            compareRefusal = nil
            comparePage = .plan
        case .failure(let refusal):
            syncPlan = nil
            compareRefusal = refusal
        }
    }

    func backToComparison() {
        comparePage = .diff
        syncPlan = nil
        syncOutcome = nil
    }

    func runSync() {
        guard let plan = syncPlan, !syncRunning else { return }
        let token = CancelToken()
        compareCancel = token
        syncRunning = true
        syncOutcome = nil
        syncProgress = SyncProgress(stepsDone: 0, stepsTotal: plan.steps.count,
                                    bytesWritten: 0, currentPath: "")
        comparePage = .result

        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                SyncRunner.run(plan, cancel: token) { progress in
                    Task { @MainActor [weak self] in self?.syncProgress = progress }
                }
            }.value
            guard let self else { return }
            self.syncRunning = false
            self.compareCancel = nil
            self.syncOutcome = outcome
            // The folders are as they are now, so anything on screen about how
            // they used to differ is stale. Measure again rather than let the
            // old figures stand.
            self.folderComparison = nil
            self.compareVerification = nil
        }
    }

    func cancelSync() {
        compareCancel?.cancel()
        compareCancel = nil
    }

    func revealTrashedBySync() {
        guard let outcome = syncOutcome else { return }
        FileActions.revealInFinder(outcome.trashed.compactMap(\.trashURL))
    }

    /// The offscreen renderer has no async phase, so it compares in one call
    /// rather than starting a task and drawing an empty sheet.
    ///
    /// It goes through the same steps as the real path rather than assigning
    /// the result and stopping, which is what the harness used to do — it
    /// skipped the skipped-decision prefix, so the render was showing a
    /// slightly different screen from the one the app draws.
    func compareSynchronously() {
        guard case .success(let comparison) = FolderDiff.compare(
            left: compareLeft, right: compareRight, options: settings.options,
            alreadyScanned: alreadyScanned) else { return }
        folderComparison = comparison
        openTheDifferences(comparison.tree)
        compareSkipped = []
        rebuildSkippedPrefix(comparison)
        rebuildCompareRows()
    }

    /// Drops the previous answer, so a fresh pair does not sit under the old
    /// one while the new comparison is being worked out.
    func clearResult() {
        folderComparison = nil
        compareRefusal = nil
    }

    /// Everything in flight stopped. Whether a sheet or a tab closes is the
    /// shell's business; stopping the work is this object's.
    func close() {
        cancelComparison()
        cancelCompareVerify()
    }
}
