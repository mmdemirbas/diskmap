import Combine
import DiskMapCore
import SwiftUI

/// *Where the easy space is* — the module, separated from the screen it is
/// shown on.
///
/// Second of the extractions the redesign plan lists, and the first of a
/// module rather than of the scan. It is deliberately the one behind the
/// loudest complaint: this is today a sheet sized by its presenter, and it
/// becomes a tab. Nothing about finding the space cares which of those it is,
/// so that knowledge moves out first and the presentation question is left
/// alone until there is somewhere for a tab to go.
///
/// What it does *not* take: the tree, the signature cache and the never-touch
/// list. All three are shared with the other modules and belong to the session
/// rather than to this, so they arrive as arguments until the session is ready
/// to hold them. Passing them keeps this object honest about what it owns.
@MainActor
final class SpaceModule: ObservableObject {
    @Published private(set) var suggestions: [CleanupSuggestion] = []
    @Published private(set) var loading = false

    /// Which of the three passes is running. Same reason as on the copies
    /// screen: this is the slowest thing in the app and a spinner alone does
    /// not distinguish work from a hang.
    @Published private(set) var progress: MatchProgress?
    /// Not published: read when a search starts, never while one is on screen.
    var thresholds = Cleanup.Thresholds()

    /// The pass in flight. This one is the most expensive in the app — a
    /// signature per folder, then the duplicate pass, then the rules — and a
    /// tree that keeps moving must not start a second before the first is done.
    private var task: Task<Void, Never>?

    /// Computed when asked for rather than kept up to date: it needs the match
    /// passes, and nobody wants to pay for those while browsing.
    func load(tree: LiveTree, root: Int32, cache: SignatureCache, excluding: [String]) {
        loading = true
        progress = MatchProgress(phase: .signing, done: 0, total: 0)
        let revision = tree.changeCount
        let thresholds = self.thresholds
        task?.cancel()
        task = Task { [weak self] in
            let report: MatchProgress.Report = { [weak self] step in
                Task { @MainActor in
                    guard self?.loading == true else { return }
                    self?.progress = step
                }
            }
            let found = await Task.detached(priority: .userInitiated) {
                Self.compute(tree: tree, root: root, cache: cache, revision: revision,
                             thresholds: thresholds, excluding: excluding,
                             onProgress: report)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.suggestions = found
            self.loading = false
            self.progress = nil
        }
    }

    /// The offscreen renderer has no async phase, so it fills the module in one
    /// call rather than starting a task and drawing an empty screen. Same
    /// reason `refreshSummarySync` exists.
    func loadSynchronously(tree: LiveTree, root: Int32,
                           cache: SignatureCache, excluding: [String] = []) {
        suggestions = Self.compute(tree: tree, root: root, cache: cache,
                                   revision: tree.changeCount, thresholds: thresholds,
                                   excluding: excluding)
        loading = false
    }

    /// Dropped when the tree underneath them is replaced: a suggestion names
    /// nodes, and nodes from a previous scan mean nothing to this one.
    func clear() {
        task?.cancel()
        suggestions = []
        loading = false
        progress = nil
    }

    nonisolated static func compute(tree: LiveTree, root: Int32,
                                    cache: SignatureCache, revision: Int,
                                    thresholds: Cleanup.Thresholds,
                                    excluding: [String] = [],
                                    onProgress: MatchProgress.Report? = nil) -> [CleanupSuggestion] {
        tree.withStore { store in
            let folders = FolderMatches.find(store: store, root: root,
                                             precomputed: cache.signatures(for: store,
                                                                           revision: revision,
                                                                           onProgress: onProgress),
                                             onProgress: onProgress)
            let files = Duplicates.find(store: store, root: root, insideMatched: folders,
                                        onProgress: onProgress)
            return Cleanup.suggest(store: store, root: root,
                                   folderCopies: folders.map(\.nodes),
                                   fileCopies: files.map(\.nodes),
                                   thresholds: thresholds, excluding: excluding)
        }
    }
}
