import Combine
import DiskMapCore
import SwiftUI

/// *What changed since last time* — this scan against a stored one.
///
/// Owns the digests and nothing else. Reading a stored digest can fail, and it
/// says so by throwing rather than by reaching for the toast: whose job it is
/// to tell the user is a question for the shell, and a module that writes to
/// the chrome directly is a module that cannot be opened twice.
@MainActor
final class ChangesModule: ObservableObject {
    /// The digest of the scan currently loaded. Written when a scan finishes.
    var current: DiskDigest?
    @Published private(set) var history: [SnapshotStore.Entry] = []
    @Published private(set) var comparison: DigestDiff?
    @Published private(set) var comparingTo: String?

    private let snapshots: SnapshotStore

    init(snapshots: SnapshotStore) {
        self.snapshots = snapshots
    }

    /// A few megabytes per scan, so a month of them is affordable. Walking the
    /// tree and writing the file both stay off the main thread.
    func record(_ live: LiveTree) {
        let store = snapshots
        Task { [weak self] in
            let digest = await Task.detached(priority: .utility) {
                live.withStore { DiskDigest.of(store: $0, stats: live.stats) }
            }.value
            self?.current = digest
            await Task.detached(priority: .utility) {
                do {
                    try store.write(digest)
                } catch {
                    Telemetry.problem("snapshot", error.localizedDescription)
                }
            }.value
            Telemetry.record("snapshot.write", ["folders": .int(Int64(digest.folders.count))])
        }
    }

    /// Lists what there is to compare against, and picks the most recent.
    /// Throws only from the comparison it starts; listing cannot fail.
    func loadHistory(tree: LiveTree?) throws {
        // Everything except this scan's own entry, which would compare the
        // tree against itself.
        let mine = current?.takenAt.timeIntervalSince1970
        history = snapshots.list()
            .filter { abs($0.takenAt.timeIntervalSince1970 - (mine ?? -1)) > 1 }
            .reversed()
        if comparison == nil, let latest = history.first {
            try compare(with: latest, tree: tree)
        }
    }

    func compare(with entry: SnapshotStore.Entry, tree: LiveTree?) throws {
        guard let current else { return }
        let old = try snapshots.read(entry.url)
        let raw = DiskDigest.diff(from: old, to: current)
        // Only the live tree can tell a deleted folder from one that merely
        // shrank below what a digest records.
        comparison = tree.map { live in
            live.withStore { store in raw.resolvingVanished { store.find(path: $0) != nil } }
        } ?? raw
        comparingTo = entry.id
        Telemetry.record("snapshot.compare",
                         ["changes": .int(Int64(comparison?.changes.count ?? 0)),
                          "delta": .int(comparison?.totalDelta ?? 0)])
    }

    /// Dropped when the tree underneath is replaced: a comparison is against a
    /// scan that no longer exists.
    func clear() {
        current = nil
        comparison = nil
        comparingTo = nil
        history = []
    }
}
