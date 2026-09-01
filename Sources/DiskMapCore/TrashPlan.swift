import Foundation

public struct TrashCandidate: Sendable, Identifiable {
    public var id: Int32 { node }
    public let node: Int32
    public let path: String
    public let name: String
    public let bytes: Int64
    public let isDirectory: Bool
    public let itemCount: Int
    /// Set when the deletion will propagate to a sync service, not just here.
    public let syncProvider: String?
}

public struct TrashPlan: Sendable {
    public var items: [TrashCandidate] = []
    /// Left out because a folder above them is already in the plan; trashing
    /// the folder takes them anyway.
    public var coveredByAnAncestor: Int = 0
    /// Left out because the tree says they are already gone.
    public var alreadyGone: Int = 0
    public var bytes: Int64 = 0
    public var synced: [TrashCandidate] { items.filter { $0.syncProvider != nil } }
    public var isEmpty: Bool { items.isEmpty }
}

/// Reasons the planner will not produce a plan. Every one of them is a case
/// where carrying on could destroy something the user cannot get back.
public enum TrashRefusal: Error, Sendable, Equatable {
    case nothingSelected
    /// The app called these copies of each other. Removing all of them leaves
    /// nothing, which is never what "delete the duplicates" meant.
    case wouldRemoveEveryCopy(String)
    /// A folder the whole scan is rooted at.
    case includesAScanRoot(String)
    /// Should be impossible from the UI, and is checked anyway: the planner
    /// will not hand back a path it cannot show is inside what was scanned.
    case outsideTheScannedTree(String)
}

/// Turns a set of selected nodes into an explicit list of what would be
/// trashed — or a refusal.
///
/// This lives in the core, away from the interface, because it is where the
/// rules that protect the user's data belong. A checkbox that is hard to tick
/// by accident is worth having; a rule that a test can prove is worth more.
public enum TrashPlanner {
    public static func plan(store: NodeStore,
                            selected: Set<Int32>,
                            groups: [[Int32]] = [],
                            syncRoots: SyncRoots = SyncRoots(roots: [])) -> Result<TrashPlan, TrashRefusal> {
        guard !selected.isEmpty else { return .failure(.nothingSelected) }

        // A firmlinked tree stores one form of a path and shows another, so
        // containment is checked against both spellings of every root.
        var rootForms = Set<String>()
        for root in store.roots {
            rootForms.insert(root)
            rootForms.insert(Firmlinks.displayPath(root))
        }

        var plan = TrashPlan()
        var resolved: [(node: Int32, path: String)] = []

        for node in selected.sorted() {
            guard node != 0 else { return .failure(.includesAScanRoot(store.path(0))) }
            guard node > 0, node < Int32(store.count) else { plan.alreadyGone += 1; continue }
            guard !store.flagSet(node).contains(.removed) else { plan.alreadyGone += 1; continue }
            let path = store.path(node)
            if rootForms.contains(path) { return .failure(.includesAScanRoot(path)) }
            guard path.hasPrefix("/"), !path.contains("/../"),
                  rootForms.contains(where: { isInside(path, $0) }) else {
                return .failure(.outsideTheScannedTree(path))
            }
            resolved.append((node, path))
        }
        guard !resolved.isEmpty else { return .success(plan) }

        // Shortest path first, so a folder is seen before anything inside it.
        resolved.sort { $0.path.count == $1.path.count ? $0.path < $1.path : $0.path.count < $1.path.count }
        var keep: [(node: Int32, path: String)] = []
        for item in resolved {
            if keep.contains(where: { isInside(item.path, $0.path) && item.path != $0.path }) {
                plan.coveredByAnAncestor += 1
                continue
            }
            keep.append(item)
        }

        // The invariant that matters most: whatever else happens, something the
        // app called a copy must still exist afterwards. A member counts as
        // surviving only if it is neither selected nor sitting inside a folder
        // that is — selecting one copy and the other copy's parent folder would
        // otherwise wipe out both.
        for group in groups where group.count > 1 {
            let survivors = group.filter { member in
                guard member > 0, member < Int32(store.count),
                      !store.flagSet(member).contains(.removed) else { return false }
                let memberPath = store.path(member)
                return !keep.contains { isInside(memberPath, $0.path) }
            }
            if survivors.isEmpty {
                let name = group.first.map { store.name($0) } ?? ""
                return .failure(.wouldRemoveEveryCopy(name))
            }
        }

        for item in keep {
            let isDir = store.isDirectory(item.node)
            let bytes = store.totalPhysical[Int(item.node)]
            plan.items.append(TrashCandidate(
                node: item.node, path: item.path, name: store.name(item.node),
                bytes: bytes, isDirectory: isDir,
                itemCount: isDir ? store.children(item.node).count : 0,
                syncProvider: syncRoots.provider(for: item.path)))
            plan.bytes += bytes
        }
        plan.items.sort { $0.bytes > $1.bytes }
        return .success(plan)
    }

    /// Containment, on whole path components. Without the trailing separator
    /// `/Users/md/dev` would appear to contain `/Users/md/development`.
    static func isInside(_ path: String, _ container: String) -> Bool {
        path == container || path.hasPrefix(container == "/" ? "/" : container + "/")
    }
}
