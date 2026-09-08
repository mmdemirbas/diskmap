import Combine
import DiskMapCore
import SwiftUI

/// One scan, and everything that describes it.
///
/// Split out of `AppModel` because a scan is not the property of any one
/// screen. Several modules open at once read the same scan, and a module that
/// needs no scan at all — comparing two folders walks them directly — should be
/// able to exist without one. Neither is expressible while the tree, the phase
/// and the targets are fields on the object that also owns the treemap's
/// scroll position.
///
/// Every property here was a `@Published` on `AppModel` a moment ago, and is
/// still observed through it: `AppModel` re-emits this object's changes as its
/// own, so the move re-pointed no views. Views that care only about the scan
/// can observe this object directly instead, one at a time, rather than in one
/// landing.
@MainActor
final class ScanSession: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var volumes: [VolumeInfo] = []
    /// Kept only as the volume the capacity bar falls back to before anything
    /// has been scanned. It is not a scan target; there is only one of those.
    @Published var selectedVolumePath: String = "/System/Volumes/Data"
    /// Everything to measure, as one total. A whole disk and a folder are the
    /// same kind of thing here — a path to walk — so both live in this list and
    /// any number of either can be chosen at once.
    @Published var scanTargets: [String] = []
    @Published var rejectedRoots: [RejectedRoot] = []
    @Published var rootsSpanVolumes = false
    @Published var volume: VolumeInfo?
    @Published var reconciliation: Reconciliation?
    @Published var stats: ScanStats?
    @Published var liveActive = false

    /// The tree every module reads.
    ///
    /// Not settable from outside: a tree arrives from the scan lifecycle and
    /// from nowhere else, and that was true when this was a `private(set)` on
    /// `AppModel`. The lifecycle has not moved here yet, so it asks.
    private(set) var tree: LiveTree?

    /// Takes on a freshly scanned tree, or drops the current one.
    func adopt(_ tree: LiveTree?) {
        self.tree = tree
    }
}
