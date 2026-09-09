import DiskMapScan
import Foundation

/// Answering a comparison from a scan that already happened.
///
/// Comparing two folders walks both of them. When the app has already measured
/// them — the ordinary case, since the folders being compared are usually on
/// the disk being looked at — that walk asks the filesystem for something it
/// has already been told, and pays for it in syscalls at the rate the whole
/// subtree costs.
///
/// The saving is only worth having if the answer cannot change, so this refuses
/// far more often than it has to. The rule is: hand over a copy only when the
/// scan holds *everything* a fresh walk would have found. Anything the scan
/// deliberately did not descend into — an excluded path, a mount point it did
/// not cross, a directory it could not open — would come back as a folder full
/// of missing files, and a comparison that invents differences is worse than a
/// slow one.
public enum ScanReuse {
    /// Why a folder could not be answered from the scan. Reported rather than
    /// swallowed, because "it walked the disk again" is otherwise invisible.
    public enum Refusal: String, Sendable, Error {
        /// The tree is not being watched, so how old it is cannot be known.
        case notWatching
        /// Not in the scan at all, or below something that was not walked.
        case notScanned
        /// A file, or a symlink. A comparison is between two folders.
        case notAFolder
        /// The scan stopped somewhere inside it on purpose, so the copy would
        /// be missing files that are really there.
        case incomplete
        /// It holds an extra link to an inode the scan first saw somewhere
        /// else, so the copy's byte totals are not the ones a walk of this
        /// folder alone would produce.
        case sharedInodes
    }

    /// The subtree as a scan of its own, or the reason it is not offered.
    ///
    /// Call it inside the tree's own lock — `LiveTree.withStore` — so the tree
    /// cannot move between the check and the copy.
    public static func offer(_ store: NodeStore, folder: String,
                             watching: Bool) -> Result<ScanResult, Refusal> {
        guard watching else { return .failure(.notWatching) }
        guard let node = store.find(path: folder) else { return .failure(.notScanned) }
        guard store.isDirectory(node) else { return .failure(.notAFolder) }
        guard isWhole(store, node) else {
            return .failure(hasSharedInode(store, node) ? .sharedInodes : .incomplete)
        }

        let copy = store.subtree(root: node)
        guard copy.count > 0 else { return .failure(.notScanned) }
        return .success(ScanResult(store: copy, stats: describe(copy),
                                   roots: copy.roots, rejectedRoots: []))
    }

    /// Whether the scan walked all the way down this subtree, and whether what
    /// it recorded there means the same thing on its own.
    ///
    /// A whole-subtree check rather than a check of the folder itself: the
    /// missing part can be ten levels down, and a comparison that reports a
    /// hundred files as "only on the left" because the right side's scan
    /// stopped at an unreadable directory is exactly the failure this exists to
    /// prevent.
    ///
    /// Hard links are the subtler half. A scan counts an inode's bytes once, at
    /// the first link it meets, and zeroes every later one — which is right for
    /// the disk being measured and wrong for a folder lifted out of it. If the
    /// first link was in some other folder, this one's copy carries a zero
    /// where a walk of it alone would carry the file's real size, and the two
    /// sides of a comparison would disagree by exactly those bytes. Nothing in
    /// the flags says where the first link was, so any extra link is refused.
    private static func isWhole(_ store: NodeStore, _ root: Int32) -> Bool {
        let blocking: NodeFlags = [.excluded, .mountPoint, .unreadable, .hardlinkDuplicate]
        var stack: [Int32] = [root]
        while let node = stack.popLast() {
            let flags = store.flagSet(node)
            if flags.contains(.removed) { continue }
            if !flags.intersection(blocking).isEmpty { return false }
            for child in store.children(node) { stack.append(child) }
        }
        return true
    }

    /// Which of the two reasons `isWhole` refused for. Split out only so the
    /// refusal can say something true; the decision is the same either way.
    private static func hasSharedInode(_ store: NodeStore, _ root: Int32) -> Bool {
        var stack: [Int32] = [root]
        while let node = stack.popLast() {
            let flags = store.flagSet(node)
            if flags.contains(.removed) { continue }
            if flags.contains(.hardlinkDuplicate) { return true }
            for child in store.children(node) { stack.append(child) }
        }
        return false
    }

    /// The counts a walk would have reported, from the copy rather than from
    /// the disk. Only the fields a comparison reads are filled: a copy has no
    /// unreadable directories and skipped no mount points, or it would not have
    /// been offered.
    private static func describe(_ store: NodeStore) -> ScanStats {
        var stats = ScanStats()
        for id in 0..<store.count {
            let flags = store.flagSet(Int32(id))
            if flags.contains(.removed) { continue }
            if flags.contains(.directory) {
                stats.directories += 1
            } else if flags.contains(.symlink) {
                stats.symlinks += 1
            } else {
                stats.files += 1
            }
        }
        // The root is the folder being compared, not an entry inside it.
        stats.directories = max(0, stats.directories - 1)
        stats.totalLogical = store.totalLogical.first ?? 0
        stats.totalPhysical = store.totalPhysical.first ?? 0
        return stats
    }
}
