import Foundation
import DiskMapScan

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
    /// Left out because the user put them on the never-touch list.
    public var excluded: Int = 0
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

public struct ReviewMember: Sendable, Identifiable {
    public var id: Int32 { node }
    public let node: Int32
    public let path: String
    public let name: String
    public let bytes: Int64
    public let isDirectory: Bool
    public let itemCount: Int
    public let syncProvider: String?
}

/// One decision the user is being asked to make.
///
/// For copies that is the whole group — every copy, kept and removed alike —
/// because "delete this one" is not a judgement anybody can make without seeing
/// which one survives. For everything else it is a single item standing alone.
public struct ReviewGroup: Sendable, Identifiable {
    public let id: Int64
    public let name: String
    public let members: [ReviewMember]
    /// True when at least one member has to survive.
    public let isCopyGroup: Bool
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
                            syncRoots: SyncRoots = SyncRoots(roots: []),
                            excluded: [String] = []) -> Result<TrashPlan, TrashRefusal> {
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

        // A relist rebuilds a folder's children under new ids. A tick made
        // before one refers to the old id, and "already gone" is the wrong
        // thing to say about a file that is still there.
        let selected = Set(selected.map(store.current))
        let groups = groups.map { $0.map(store.current) }

        for node in selected.sorted() {
            guard node != 0 else { return .failure(.includesAScanRoot(store.path(0))) }
            guard node > 0, node < Int32(store.count) else { plan.alreadyGone += 1; continue }
            guard !store.flagSet(node).contains(.removed) else { plan.alreadyGone += 1; continue }
            let path = store.path(node)
            if rootForms.contains(path) { return .failure(.includesAScanRoot(path)) }
            // A path on the never-touch list is dropped rather than refused:
            // the rest of a selection is still perfectly actionable.
            if excluded.contains(where: { RootSet.isInside(path, $0) }) { plan.excluded += 1; continue }
            guard path.hasPrefix("/"), !path.contains("/../"),
                  rootForms.contains(where: { RootSet.isInside(path, $0) }) else {
                return .failure(.outsideTheScannedTree(path))
            }
            resolved.append((node, path))
        }
        guard !resolved.isEmpty else { return .success(plan) }

        // Shortest path first, so a folder is seen before anything inside it.
        resolved.sort { $0.path.count == $1.path.count ? $0.path < $1.path : $0.path.count < $1.path.count }
        var keep: [(node: Int32, path: String)] = []
        for item in resolved {
            if keep.contains(where: { RootSet.isInside(item.path, $0.path) && item.path != $0.path }) {
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
                return !keep.contains { RootSet.isInside(memberPath, $0.path) }
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

    /// Everything the selection touches, arranged as decisions rather than as
    /// a list of victims. A group appears in full as soon as one of its members
    /// is selected, so what stays is on screen next to what goes.
    public static func review(store: NodeStore, selected: Set<Int32>,
                              groups: [[Int32]] = [],
                              syncRoots: SyncRoots = SyncRoots(roots: []),
                              excluded: [String] = []) -> [ReviewGroup] {
        var out: [ReviewGroup] = []
        var accounted = Set<Int32>()

        for group in groups where group.count > 1 && group.contains(where: selected.contains) {
            let members = group.compactMap { member(store, $0, syncRoots) }
            guard members.count > 1 else { continue }
            for m in members { accounted.insert(m.node) }
            out.append(ReviewGroup(id: key(members.map(\.node)),
                                   name: members[0].name, members: members,
                                   isCopyGroup: true))
        }

        for node in selected.sorted() where !accounted.contains(node) {
            guard let only = member(store, node, syncRoots),
                  !excluded.contains(where: { RootSet.isInside(only.path, $0) }) else { continue }
            out.append(ReviewGroup(id: key([node]), name: only.name,
                                   members: [only], isCopyGroup: false))
        }

        // Biggest decision first, measured by what removing the extras frees.
        out.sort { weight($0, selected) > weight($1, selected) }
        return out
    }

    private static func weight(_ group: ReviewGroup, _ selected: Set<Int32>) -> Int64 {
        group.members.filter { selected.contains($0.node) }.reduce(0) { $0 + $1.bytes }
    }

    private static func member(_ store: NodeStore, _ node: Int32,
                               _ syncRoots: SyncRoots) -> ReviewMember? {
        guard node > 0, node < Int32(store.count),
              !store.flagSet(node).contains(.removed) else { return nil }
        let path = store.path(node)
        let isDir = store.isDirectory(node)
        return ReviewMember(node: node, path: path, name: store.name(node),
                            bytes: store.totalPhysical[Int(node)], isDirectory: isDir,
                            itemCount: isDir ? store.children(node).count : 0,
                            syncProvider: syncRoots.provider(for: path))
    }

    /// A group is identified by the set it holds, not by any one member: the
    /// same folder can appear in more than one group.
    public static func key(_ nodes: [Int32]) -> Int64 {
        nodes.sorted().reduce(Int64(bitPattern: 0xcbf2_9ce4_8422_2325)) {
            ($0 ^ Int64($1)) &* 0x100_0000_01b3
        }
    }

}
