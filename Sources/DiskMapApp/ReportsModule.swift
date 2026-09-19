import Combine
import DiskMapCore
import SwiftUI

/// *What is in here, and what is in here twice* — the whole-subtree reports,
/// separated from the panels that show them.
///
/// Sixth of the seven extractions. It carries the biggest walk in the app: the
/// summary is one pass over the subtree, and copies are a second pass plus a
/// signature over every folder. Both are why this is computed when somebody
/// asks rather than kept up to date.
///
/// What it does *not* take: the tree, the signature cache, and the question of
/// *whether* copies are wanted. The first two belong to the session and are
/// shared with the other modules, so they arrive as arguments. The third is a
/// fact about which tools are open, which is the app's business and not this
/// object's — it is told, not asked.
@MainActor
final class ReportsModule: ObservableObject {
    @Published var summary: SubtreeSummary?
    @Published var largeFiles: [LargeFile] = []
    @Published var duplicates: [DuplicateEntry] = []
    @Published var folderMatches: [FolderEntry] = []
    @Published var summarizing = false

    /// What the walk is doing right now, or nil when nothing is walking.
    ///
    /// Copies take minutes on a large disk and the screen used to say "Working…"
    /// for all of them, which is the same thing a hang says.
    @Published private(set) var progress: MatchProgress?
    @Published var openMatches: Set<Int64> = []

    /// Deep verification, per match: reading every byte to answer "are these
    /// really the same".
    @Published var verifications: [Int64: VerifyStatus] = [:]
    private var verifyTokens: [Int64: CancelToken] = [:]

    /// Every set of things the app called copies of each other, so the planner
    /// can refuse to empty one. Not private so the review-flow tests can seed a
    /// group without running the report.
    var matchGroups: [[Int32]] = []

    /// Called once a report has landed. The tick list belongs to the report it
    /// was made against, and deciding what happens to it is the app's business
    /// rather than this object's.
    var onLoaded: (() -> Void)?

    /// The walk in flight, so a tree that keeps moving cannot leave two of
    /// them running at once. They would both finish, both write, and the one
    /// that happened to be slower would win.
    private var task: Task<Void, Never>?

    /// Walking eleven million nodes takes a moment, so it runs off the main
    /// thread and only when something is actually showing a report.
    func load(tree: LiveTree, root: Int32, physical: Bool,
              includeDuplicates: Bool, cache: SignatureCache) {
        // Verdicts belong to the tree that produced them. Dropping the state
        // without stopping the run would leave gigabytes of reading in flight
        // for an answer nobody can see any more.
        if includeDuplicates { cancelAllVerifications() }
        summarizing = true
        progress = MatchProgress(phase: .measuring, done: 0, total: 0)
        // The tree's own counter, not the view's: retyping a filter must not
        // throw away a hash pass that is still valid.
        let revision = tree.changeCount
        task?.cancel()
        task = Task { [weak self] in
            // The walk runs off the main thread and reports back onto it. The
            // hop is per message, not per node: the passes throttle their own
            // reporting for exactly this reason.
            let report: MatchProgress.Report = { [weak self] step in
                Task { @MainActor in
                    guard self?.summarizing == true else { return }
                    self?.progress = step
                }
            }
            let computed = await Task.detached(priority: .userInitiated) {
                Self.report(tree: tree, root: root, physical: physical,
                            includeDuplicates: includeDuplicates,
                            cache: cache, revision: revision, onProgress: report)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.apply(computed)
        }
    }

    /// Blocking report used by the offscreen renderer, which has no async pass.
    /// Takes over from anything already running: this answer is the newer one.
    func loadSynchronously(tree: LiveTree, root: Int32, physical: Bool,
                           includeDuplicates: Bool, cache: SignatureCache) {
        task?.cancel()
        apply(Self.report(tree: tree, root: root, physical: physical,
                          includeDuplicates: includeDuplicates,
                          cache: cache, revision: tree.changeCount))
    }

    private func apply(_ computed: ReportData) {
        summary = computed.summary
        largeFiles = computed.largest
        duplicates = computed.duplicates
        folderMatches = computed.folders
        matchGroups = computed.folders.map { $0.copies.map(\.id) }
            + computed.duplicates.map { $0.copies.map(\.id) }
        summarizing = false
        progress = nil
        onLoaded?()
    }

    /// Dropped when the tree underneath is replaced.
    ///
    /// Every row here is a set of node ids, and node ids mean nothing across
    /// two scans: the same index is a different file. Leaving the rows standing
    /// left the Copies tab offering, tickable, a list computed from a disk the
    /// app was no longer looking at — and `matchGroups` *was* cleared, so the
    /// "this would remove the last copy" guard no longer recognised the rows it
    /// was guarding.
    func clear() {
        task?.cancel()
        cancelAllVerifications()
        summary = nil
        largeFiles = []
        duplicates = []
        folderMatches = []
        matchGroups = []
        openMatches = []
        summarizing = false
        progress = nil
    }

    // MARK: - Deep verification

    /// Reads every file in the match and compares the contents, which is the
    /// only way to answer "are these really the same". Off by default because
    /// it costs the bytes; the button says how many before you press it.
    func verifyMatch(id: Int64, nodes: [Int32], tree: LiveTree) {
        guard verifications[id]?.running != true else { return }
        let plan = tree.withStore { DeepVerify.plan(store: $0, nodes: nodes) }
        let token = CancelToken()
        verifyTokens[id] = token
        verifications[id] = VerifyStatus(read: 0, total: plan.bytes)

        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) { () -> VerifyOutcome in
                DeepVerify.run(plan, cancel: token) { read in
                    Task { @MainActor [weak self] in
                        guard self?.verifications[id]?.running == true else { return }
                        self?.verifications[id]?.read = read
                    }
                }
            }.value
            guard let self else { return }
            self.verifyTokens[id] = nil
            self.verifications[id]?.read = plan.bytes
            self.verifications[id]?.outcome = outcome
        }
    }

    func cancelVerify(id: Int64) {
        verifyTokens[id]?.cancel()
        verifyTokens[id] = nil
    }

    func cancelAllVerifications() {
        for token in verifyTokens.values { token.cancel() }
        verifyTokens.removeAll()
        verifications.removeAll()
    }

    // MARK: - The walk itself

    /// Duplicate detection is a second walk, so it only runs for the panel that
    /// shows it rather than on every report refresh.
    nonisolated static func report(tree: LiveTree, root: Int32, physical: Bool,
                                   includeDuplicates: Bool,
                                   cache: SignatureCache, revision: Int,
                                   onProgress: MatchProgress.Report? = nil) -> ReportData {
        // One lock acquisition: the store must not escape it.
        tree.withStore { store -> ReportData in
            let summary = Aggregate.summarize(store: store, root: root, usePhysicalSize: physical)
            let files = summary.largestFiles.map { id -> LargeFile in
                let name = store.name(id)
                return LargeFile(
                    id: id, name: name, path: store.path(id),
                    bytes: physical ? store.totalPhysical[Int(id)] : store.totalLogical[Int(id)],
                    category: Categorizer.of(name: name, isDirectory: false),
                    modified: Date(timeIntervalSince1970: TimeInterval(store.mtime[Int(id)])))
            }
            guard includeDuplicates else {
                return ReportData(summary: summary, largest: files, duplicates: [], folders: [])
            }
            let matches = FolderMatches.find(store: store, root: root,
                                             precomputed: cache.signatures(for: store,
                                                                          revision: revision,
                                                                          onProgress: onProgress),
                                             onProgress: onProgress)
            let folders = matches.map { match in
                FolderEntry(id: matchKey(match.nodes), name: store.name(match.nodes[0]),
                            bytes: match.bytes, reclaimable: match.reclaimable,
                            exact: match.exact, sharedItems: match.sharedItems,
                            comparedItems: match.comparedItems,
                            readBytes: match.nodes.reduce(0) { $0 + store.totalPhysical[Int($1)] },
                            copies: match.nodes.map { PathRef(id: $0, path: store.path($0)) })
            }
            let groups = Duplicates.find(store: store, root: root,
                                         insideMatched: matches,
                                         onProgress: onProgress).map { group in
                DuplicateEntry(id: matchKey(group.nodes), name: group.name, bytes: group.bytes,
                               reclaimable: group.reclaimable,
                               readBytes: group.bytes * Int64(group.nodes.count),
                               copies: group.nodes
                                   .map { PathRef(id: $0, path: store.path($0)) }
                                   .sorted { $0.path < $1.path })
            }
            return ReportData(summary: summary, largest: files, duplicates: groups, folders: folders)
        }
    }
}
