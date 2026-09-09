import Foundation
import DiskMapScan

public struct CleanupSuggestion: Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case duplicateFolders, duplicateFiles, buildOutput, appCaches, installers, stale, trash
    }

    /// How much of the user's judgement the suggestion needs. This orders the
    /// list, because "what should I delete first" is answered by what costs
    /// least to be wrong about, not by what is biggest.
    public enum Safety: Int, Sendable, Comparable {
        /// The toolchain or the app rebuilds it. Being wrong costs time.
        case comesBack = 0
        /// Another copy survives the operation.
        case aCopyRemains = 1
        /// Only the user knows whether it is still wanted.
        case yourCall = 2
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String { kind.rawValue }
    public var kind: Kind
    public var safety: Safety
    /// What acting on it would free.
    public var bytes: Int64
    /// What to propose ticking, largest first and capped. Empty means the
    /// suggestion is information only — the Trash is the case, since the app
    /// cannot trash what is already there and emptying it is not something it
    /// should offer.
    public var nodes: [Int32]
    public var itemCount: Int
    /// For copy suggestions, the full groups the proposal came from — so the
    /// review can show which copy is being kept rather than only what goes.
    public var groups: [[Int32]] = []
    /// Left out of the proposal because the list would be too long to read.
    /// A confirmation nobody can check is not a confirmation.
    public var omitted: Int = 0
    public var omittedBytes: Int64 = 0
}

/// Turns a scanned tree into a short list of "here is where the easy space is".
///
/// Ordered by how safe each one is to accept rather than by size, because the
/// first thing anyone should delete is the thing that comes back by itself.
/// Nothing here deletes; every suggestion is a proposal that ends up in the
/// same confirmation list as a hand-made selection, and the same planner rules
/// apply to it.
public enum Cleanup {
    /// Directories a toolchain will rebuild. Deliberately conservative: a name
    /// on this list has to be one that essentially never holds anything the
    /// user typed. `build` and `target` are not here for that reason — they are
    /// ordinary words, and a folder called `build` may be someone's work.
    static let rebuildableDirectories: Set<String> = [
        "DerivedData", "node_modules", "__pycache__", ".pytest_cache",
        ".mypy_cache", ".ruff_cache", ".next", ".turbo", ".parcel-cache",
    ]

    /// Directories that only qualify because of what sits above them.
    ///
    /// `~/.gradle` is 23 GB on this machine and looks like an obvious win, but
    /// it also holds `gradle.properties` — proxy credentials, certificate
    /// paths, local settings a user typed once and will not have written down
    /// anywhere else. Only the parts underneath it that a build regenerates are
    /// ever proposed. The same shape of mistake is waiting in `.m2`, `.npm` and
    /// every other dotfile home, which is why the rule is a pair and not a name.
    static let rebuildableWhenNestedIn: [(child: String, parent: String)] = [
        ("caches", ".gradle"), ("wrapper", ".gradle"), ("daemon", ".gradle"),
        ("repository", ".m2"), ("_cacache", ".npm"),
    ]

    static let installerExtensions: Set<String> = ["dmg", "pkg", "iso"]

    public struct Thresholds: Sendable {
        public var suggestion: Int64 = 200_000_000
        public var installer: Int64 = 100_000_000
        public var staleFile: Int64 = 500_000_000
        public var staleAge: TimeInterval = 2 * 365 * 24 * 3600
        /// Twenty thousand node_modules folders is a real answer and an
        /// unreviewable one. The biggest carry almost all the bytes.
        public var maxItems = 250
        public init() {}
    }

    public static func suggest(store: NodeStore, root: Int32,
                               folderCopies: [[Int32]] = [],
                               fileCopies: [[Int32]] = [],
                               thresholds: Thresholds = Thresholds(),
                               excluding: [String] = [],
                               now: Date = Date()) -> [CleanupSuggestion] {
        let span = Telemetry.begin("cleanup.suggest")
        var out: [CleanupSuggestion] = []

        // Copies first: the app already found them, and keeping one of each is
        // the safest large win available.
        out.append(contentsOf: fromMatches(store, folderCopies,
                                           kind: .duplicateFolders, thresholds: thresholds))
        out.append(contentsOf: fromMatches(store, fileCopies,
                                           kind: .duplicateFiles, thresholds: thresholds))

        let scanned = walk(store: store, root: root, thresholds: thresholds, now: now)
        out.append(contentsOf: scanned)

        // A path the user put on the never-touch list is not a suggestion.
        if !excluding.isEmpty {
            out = out.compactMap { suggestion in
                var kept = suggestion
                kept.nodes = suggestion.nodes.filter { node in
                    !excluding.contains { RootSet.isInside(store.path(node), $0) }
                }
                guard kept.nodes.count != suggestion.nodes.count else { return suggestion }
                guard !kept.nodes.isEmpty || suggestion.nodes.isEmpty else { return nil }
                kept.itemCount = kept.nodes.count
                kept.bytes = kept.nodes.reduce(0) { $0 + store.totalPhysical[Int($1)] }
                return kept.bytes >= thresholds.suggestion || kept.nodes.isEmpty ? kept : nil
            }
        }

        out.sort {
            $0.safety == $1.safety ? $0.bytes > $1.bytes : $0.safety < $1.safety
        }
        span.end(["suggestions": .int(Int64(out.count)),
                  "bytes": .int(out.reduce(0) { $0 + $1.bytes })])
        return out
    }

    /// Every copy but the first of each group. Which copy is kept is not a
    /// decision this makes well, so it keeps the first and leaves the choice
    /// visible in the confirmation list.
    private static func fromMatches(_ store: NodeStore, _ groups: [[Int32]],
                                    kind: CleanupSuggestion.Kind,
                                    thresholds: Thresholds) -> [CleanupSuggestion] {
        var nodes: [Int32] = []
        var bytes: Int64 = 0
        for group in groups where group.count > 1 {
            for node in group.dropFirst() {
                guard node > 0, node < Int32(store.count),
                      !store.flagSet(node).contains(.removed) else { continue }
                nodes.append(node)
                bytes += store.totalPhysical[Int(node)]
            }
        }
        guard bytes >= thresholds.suggestion, !nodes.isEmpty else { return [] }
        var suggestion = capped(kind: kind, safety: .aCopyRemains, nodes: nodes,
                                store: store, limit: thresholds.maxItems)
        // Only the groups the proposal actually reaches after the cap.
        let proposed = Set(suggestion.nodes)
        suggestion.groups = groups.filter { $0.contains(where: proposed.contains) }
        return [suggestion]
    }

    /// Largest first, then cut. What is left out is reported rather than
    /// dropped quietly, so the screen never implies it covered everything.
    private static func capped(kind: CleanupSuggestion.Kind,
                               safety: CleanupSuggestion.Safety,
                               nodes: [Int32], store: NodeStore,
                               limit: Int) -> CleanupSuggestion {
        let sorted = nodes.sorted { store.totalPhysical[Int($0)] > store.totalPhysical[Int($1)] }
        let proposed = Array(sorted.prefix(limit))
        let rest = sorted.dropFirst(proposed.count)
        return CleanupSuggestion(
            kind: kind, safety: safety,
            bytes: proposed.reduce(0) { $0 + store.totalPhysical[Int($1)] },
            nodes: proposed, itemCount: proposed.count,
            omitted: rest.count,
            omittedBytes: rest.reduce(0) { $0 + store.totalPhysical[Int($1)] })
    }

    private static func walk(store: NodeStore, root: Int32,
                             thresholds: Thresholds, now: Date) -> [CleanupSuggestion] {
        var rebuildable: [Int32] = [], rebuildableBytes: Int64 = 0
        var caches: [Int32] = [], cacheBytes: Int64 = 0
        var installers: [Int32] = [], installerBytes: Int64 = 0
        var stale: [Int32] = [], staleBytes: Int64 = 0
        var trashBytes: Int64 = 0, trashItems = 0

        let staleBefore = Int32(truncatingIfNeeded: Int(now.timeIntervalSince1970
                                                        - thresholds.staleAge))
        var stack: [Int32] = [root]

        while let node = stack.popLast() {
            for child in store.children(node) {
                let flags = store.flagSet(child)
                if flags.contains(.removed) || flags.contains(.symlink) { continue }
                let bytes = store.totalPhysical[Int(child)]

                if store.isDirectory(child) {
                    let name = store.name(child)
                    // Matched folders are not descended into: everything below
                    // one goes with it, and proposing the children as well
                    // would count the same bytes twice.
                    if rebuildableDirectories.contains(name)
                        || rebuildableWhenNestedIn.contains(where: {
                            $0.child == name && $0.parent == store.name(node)
                        }) {
                        if bytes > 0 { rebuildable.append(child); rebuildableBytes += bytes }
                        continue
                    }
                    if name == ".Trash", store.name(node) != "" {
                        trashBytes += bytes
                        trashItems += store.children(child).count
                        continue
                    }
                    // One level: the entries directly under Library/Caches, not
                    // Caches itself, so a single huge app can be seen.
                    if name == "Caches", store.name(node) == "Library" {
                        for entry in store.children(child)
                        where !store.flagSet(entry).contains(.removed) {
                            let entryBytes = store.totalPhysical[Int(entry)]
                            if entryBytes > 0 { caches.append(entry); cacheBytes += entryBytes }
                        }
                        continue
                    }
                    stack.append(child)
                    continue
                }

                if flags.contains(.dataless) || flags.contains(.hardlinkDuplicate) { continue }
                if bytes >= thresholds.installer,
                   installerExtensions.contains(extensionOf(store.name(child))) {
                    installers.append(child); installerBytes += bytes
                    continue
                }
                if bytes >= thresholds.staleFile, store.mtime[Int(child)] < staleBefore {
                    stale.append(child); staleBytes += bytes
                }
            }
        }

        var out: [CleanupSuggestion] = []
        func add(_ kind: CleanupSuggestion.Kind, _ safety: CleanupSuggestion.Safety,
                 _ nodes: [Int32], _ bytes: Int64) {
            guard bytes >= thresholds.suggestion, !nodes.isEmpty else { return }
            out.append(capped(kind: kind, safety: safety, nodes: nodes,
                              store: store, limit: thresholds.maxItems))
        }
        add(.buildOutput, .comesBack, rebuildable, rebuildableBytes)
        add(.appCaches, .comesBack, caches, cacheBytes)
        add(.installers, .yourCall, installers, installerBytes)
        add(.stale, .yourCall, stale, staleBytes)

        // Information only. Emptying the Trash is the one deletion that cannot
        // be taken back, so the app reports the size and opens Finder instead.
        if trashBytes >= thresholds.suggestion {
            out.append(CleanupSuggestion(kind: .trash, safety: .yourCall, bytes: trashBytes,
                                         nodes: [], itemCount: trashItems))
        }
        return out
    }

    static func extensionOf(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}
