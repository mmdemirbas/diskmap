import Combine
import DiskMapCore
import SwiftUI

/// *Where the space went* — the map itself, as state rather than as an app.
///
/// Last of the seven extractions, and the one that was always going to be
/// awkward: for most of this app's life the map **was** the app, so the folder
/// being looked at, the rows under it, the selection and three layout caches
/// sat on the same object as the scan, the tools and the Trash.
///
/// It is a view of a scan, so it holds the session rather than being handed a
/// tree per call: navigation is continuous where the other modules are
/// one-shot. Everything it reads about the scan — the tree, the volume, the
/// names the roots are shown under — it reads through that one reference, and
/// nothing else about the app is visible from here.
///
/// What it deliberately does not know: that a report exists. Moving to another
/// folder has to refresh one, and *that* is a fact about which panels are open,
/// which is the app's business. So it announces where it went and lets the app
/// decide what follows.
private let dockStorageKey = "dockLayout"

/// Offscreen rendering drives the app for a screenshot and then exits. It sets
/// which pane is in front, which is a change to the layout — and writing that
/// down would rearrange the window of whoever ran the render.
@MainActor var dockLayoutPersists = true

@MainActor
final class MapModule: ObservableObject {
    private let session: ScanSession
    init(session: ScanSession) { self.session = session }

    private var tree: LiveTree? { session.tree }
    private var volume: VolumeInfo? { session.volume }
    private var rootNames: [String: String] { session.rootNames }
    private func displayName(_ raw: String) -> String { session.displayName(raw) }

    /// Announced after the map moves to another folder. Something else has to
    /// recompute a report against the new one, and deciding that is not this
    /// object's business.
    var onNavigated: (() -> Void)?

    @Published var currentDirectory: Int32 = 0
    /// Folders opened in place in the tree table, without navigating into them.
    @Published var expanded: Set<Int32> = []
    private var backStack: [Int32] = []
    private var forwardStack: [Int32] = []
    /// Rows shown per level. Far beyond what anyone scrolls, but it stops a
    /// folder with a million entries from building a million row structs.
    private let rowsPerLevel = 5000
    @Published var breadcrumb: [(id: Int32, name: String)] = []
    @Published var rows: [Row] = []
    @Published var selection: Int32?
    @Published var selectedInfo: ItemInfo?
    @Published var usePhysicalSize = true
    @Published var filterText = ""

    @Published var colourMode: ColourMode = .type

    /// How the map's area is divided up, and which pane is in front of each
    /// group. This replaced two segmented pickers — one choosing the picture,
    /// one choosing the table — which is what made those seven views
    /// alternatives to each other.
    ///
    /// Written down as it changes: a layout you have to rebuild every morning
    /// is a layout nobody builds.
    @Published var dock = DockLayout.decoded(
        from: UserDefaults.standard.string(forKey: dockStorageKey) ?? "") {
        didSet {
            guard dockLayoutPersists else { return }
            UserDefaults.standard.set(dock.encoded, forKey: dockStorageKey)
        }
    }

    /// What is actually on screen: one pane per group, the one in front.
    ///
    /// The distinction matters for anything expensive. A copy report sitting in
    /// a background tab is not being looked at, and computing one costs a
    /// signature per folder over the whole tree.
    var visiblePanes: [PaneKind] { dock.leaves.map(\.active) }

    /// Puts a pane in front, adding it back to the layout if it had been
    /// closed. The one entry point for "show me this", so a menu item and a
    /// tab click cannot disagree about what showing means.
    func show(_ kind: PaneKind) {
        if dock.contains(kind) { dock.activate(kind) } else { dock.add(kind) }
    }

    let layoutCache = LayoutStore<TreemapLayout>()
    let sunburstCache = LayoutStore<SunburstLayout>()
    let icicleCache = LayoutStore<IcicleLayout>()
    @Published private(set) var layoutToken = 0

    @Published private(set) var revision = 0

    /// The row the list should bring into view. Cleared once it has.
    @Published var scrollTo: Int32?

    // MARK: - Navigation

    func enter(_ node: Int32) {
        guard let tree, tree.withStore({ node < Int32($0.count) && $0.isDirectory(node) }) else { return }
        guard node != currentDirectory else { return }
        backStack.append(currentDirectory)
        forwardStack.removeAll()
        moveTo(node)
    }

    func goUp() {
        guard let tree, currentDirectory > 0 else { return }
        let parent = tree.withStore { $0.parent[Int(currentDirectory)] }
        guard parent >= 0 else { return }
        backStack.append(currentDirectory)
        forwardStack.removeAll()
        moveTo(parent)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentDirectory)
        moveTo(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentDirectory)
        moveTo(next)
    }

    private func moveTo(_ node: Int32) {
        currentDirectory = node
        expanded.removeAll()
        selection = nil
        selectedInfo = nil
        rebuild()
        onNavigated?()
    }

    /// Show a node where it lives: open its folder, put the selection on it and
    /// ask the list to scroll to it. Being handed a path and left to navigate
    /// there by hand is the same work twice.
    func reveal(_ node: Int32) {
        guard let tree else { return }
        let parent = tree.withStore { store -> Int32 in
            guard node > 0, node < Int32(store.count) else { return 0 }
            return store.parent[Int(node)]
        }
        // A filter still in force would hide the very row being focused.
        if !filterText.isEmpty { filterText = "" }
        expanded.removeAll()
        if parent >= 0, parent != currentDirectory {
            backStack.append(currentDirectory)
            forwardStack.removeAll()
            moveTo(parent)
        } else {
            rebuild()
        }
        select(node)
        scrollTo = node
    }

    /// Everything the map was showing, dropped with the tree that produced it.
    /// A node id from one scan means a different file in the next.
    func clear() {
        rows = []
        breadcrumb = []
        currentDirectory = 0
        expanded = []
        selection = nil
        selectedInfo = nil
        scrollTo = nil
        backStack = []
        forwardStack = []
        filterText = ""
        layoutCache.clear(); sunburstCache.clear(); icicleCache.clear()
    }

    /// Where a freshly adopted tree opens.
    ///
    /// A startup-disk scan has two roots and effectively everything lives on
    /// the Data volume. Opening on the synthetic parent shows one enormous
    /// rectangle and nothing useful, so start where the bytes are. The
    /// breadcrumb still goes up to the system volume.
    func openAtTheRoot(of live: LiveTree) {
        currentDirectory = 0
        if RootSet.coversWholeVolume(live.roots), live.roots.count > 1,
           let dataNode = live.withStore({ $0.find(path: RootSet.startupDataVolume) }) {
            currentDirectory = dataNode
        }
        selection = nil
        selectedInfo = nil
    }

    /// Opens or closes a folder inside the table, leaving the view where it is.
    func toggleExpanded(_ node: Int32) {
        if expanded.contains(node) {
            // Close descendants too, so reopening does not restore a deep tree.
            expanded = expanded.filter { !isDescendant($0, of: node) && $0 != node }
        } else {
            expanded.insert(node)
        }
        rebuild()
    }

    private func isDescendant(_ node: Int32, of ancestor: Int32) -> Bool {
        guard let tree else { return false }
        return tree.withStore { store in
            var cur = node
            while cur > 0 {
                cur = store.parent[Int(cur)]
                if cur == ancestor { return true }
            }
            return false
        }
    }

    func select(_ node: Int32?) {
        selection = node
        selectedInfo = node.flatMap(info(for:))
    }

    private func info(for node: Int32) -> ItemInfo? {
        guard let tree, let volume else { return nil }
        return tree.withStore { store -> ItemInfo? in
            guard node >= 0, node < Int32(store.count),
                  !store.flagSet(node).contains(.removed) else { return nil }
            let rawName = store.name(node)
            let name = displayName(rawName)
            let isDir = store.isDirectory(node)
            let path = store.path(node)
            return ItemInfo(
                node: node, name: name, path: path,
                physical: store.totalPhysical[Int(node)],
                logical: store.totalLogical[Int(node)],
                isDirectory: isDir,
                category: Categorizer.of(name: rawName, isDirectory: isDir, path: path),
                flags: store.flagSet(node),
                modified: Date(timeIntervalSince1970: TimeInterval(store.mtime[Int(node)])),
                fractionOfVolume: volume.used > 0
                    ? Double(store.totalPhysical[Int(node)]) / Double(volume.used) : 0,
                childCount: store.children(node).count)
        }
    }

    func rebuild() {
        guard let tree else { rows = []; breadcrumb = []; return }
        let physical = usePhysicalSize
        let filter = filterText.lowercased()

        let (dir, newRows, crumbs) = tree.withStore { store -> (Int32, [Row], [(Int32, String)]) in
            // If the folder we were looking at has been deleted, climb to the
            // nearest ancestor that still exists rather than showing a blank.
            var dir = currentDirectory
            if dir < 0 || dir >= Int32(store.count) { dir = 0 }
            while dir > 0 && store.flagSet(dir).contains(.removed) { dir = store.parent[Int(dir)] }

            var out: [Row] = []
            appendRows(store, parent: dir, depth: 0, physical: physical,
                       filter: filter, into: &out)

            var chain: [(Int32, String)] = []
            var cur = dir
            while cur > 0 { chain.append((cur, displayName(store.name(cur)))); cur = store.parent[Int(cur)] }
            chain.append((0, store.isMultiRoot ? "" : store.name(0)))
            return (dir, out, chain.reversed())
        }
        if dir != currentDirectory { currentDirectory = dir }
        rows = newRows
        breadcrumb = crumbs.map { (id: $0.0, name: $0.1) }
        selectedInfo = selection.flatMap(info(for:))
        if selectedInfo == nil { selection = nil }
        revision &+= 1
    }

    /// Flattens the visible part of the tree: every child of `parent`, and the
    /// children of any folder the user has opened, in one array the list can
    /// render without knowing anything about the tree.
    private func appendRows(_ store: NodeStore, parent: Int32, depth: Int,
                            physical: Bool, filter: String, into out: inout [Row]) {
        let sizes = physical ? store.totalPhysical : store.totalLogical
        let parentTotal = max(sizes[Int(parent)], 1)

        var kids: [Int32] = []
        for c in store.children(parent) where !store.flagSet(c).contains(.removed) {
            // The filter applies to the level being browsed; once a folder is
            // opened, everything inside it is shown.
            if depth == 0, !filter.isEmpty, !store.name(c).lowercased().contains(filter) { continue }
            kids.append(c)
        }
        kids.sort { sizes[Int($0)] > sizes[Int($1)] }

        let shown = kids.prefix(rowsPerLevel)
        for c in shown {
            let name = displayName(store.name(c))
            let isDir = store.isDirectory(c)
            let childCount = store.children(c).count
            let isOpen = expanded.contains(c)
            out.append(Row(id: c, name: name,
                           physical: store.totalPhysical[Int(c)],
                           logical: store.totalLogical[Int(c)],
                           isDirectory: isDir,
                           category: Categorizer.of(name: name, isDirectory: isDir),
                           fractionOfParent: Double(sizes[Int(c)]) / Double(parentTotal),
                           flags: store.flagSet(c),
                           modified: Date(timeIntervalSince1970: TimeInterval(store.mtime[Int(c)])),
                           depth: depth,
                           hasChildren: isDir && childCount > 0,
                           isExpanded: isOpen,
                           hiddenSiblings: 0))
            if isOpen && childCount > 0 {
                appendRows(store, parent: c, depth: depth + 1, physical: physical,
                           filter: "", into: &out)
            }
        }
        if kids.count > shown.count {
            let rest = kids.dropFirst(shown.count)
            let bytes = rest.reduce(Int64(0)) { $0 + sizes[Int($1)] }
            out.append(Row(id: -(parent + 2), name: "", physical: bytes, logical: bytes,
                           isDirectory: false, category: .other,
                           fractionOfParent: Double(bytes) / Double(parentTotal),
                           flags: [], modified: Date(timeIntervalSince1970: 0),
                           depth: depth, hasChildren: false, isExpanded: false,
                           hiddenSiblings: rest.count))
        }
    }

    // MARK: - Treemap layout

    /// Which picture, at which size, of what.
    ///
    /// The kind is a parameter rather than `self.visualization`, and that is
    /// the whole difference between three views that take turns and three
    /// views that can be on screen at once. While it was read from the model,
    /// asking for a sunburst layout while the treemap was the chosen one
    /// computed a treemap and filed it under the sunburst's name.
    func layoutKey(_ kind: Visualization, size: CGSize) -> String {
        "\(kind.rawValue)-\(currentDirectory)-\(revision)-\(Int(size.width))x\(Int(size.height))-\(usePhysicalSize)-\(filterText)"
    }

    func cachedLayout(for size: CGSize) -> TreemapLayout? {
        layoutCache.get(layoutKey(.treemap, size: size))
    }

    nonisolated static func compute(tree: LiveTree, root: Int32, size: CGSize,
                                    physical: Bool, filter: String, key: String,
                                    rootNames names: [String: String] = [:]) -> TreemapLayout {
        let span = Telemetry.begin("layout")
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let needle = filter.lowercased()
        return tree.withStore { store in
            let laid = Treemap.layout(
                store: store, root: root, in: rect, usePhysicalSize: physical,
                includeAtRoot: needle.isEmpty ? nil : { store.name($0).lowercased().contains(needle) })
            var map: [Int32: CellInfo] = [:]
            map.reserveCapacity(laid.count)
            for c in laid where c.node >= 0 {
                map[c.node] = cellInfo(store, c.node, physical: physical, rootNames: names)
            }
            span.end(["cells": .int(Int64(laid.count)),
                      "w": .int(Int64(size.width)), "h": .int(Int64(size.height)),
                      "view": .text("treemap")], minMilliseconds: 40)
            return TreemapLayout(key: key, cells: laid, info: map)
        }
    }

    nonisolated static func cellInfo(_ store: NodeStore, _ node: Int32, physical: Bool,
                                    rootNames: [String: String] = [:]) -> CellInfo {
        let name = store.name(node)
        let isDir = store.isDirectory(node)
        let age = AgeBucket.of(secondsAgo: Date().timeIntervalSince1970
                               - Double(store.mtime[Int(node)]))
        return CellInfo(name: rootNames[name] ?? abbreviatedName(name),
                        category: Categorizer.of(name: name, isDirectory: isDir),
                        bytes: physical ? store.totalPhysical[Int(node)] : store.totalLogical[Int(node)],
                        isDirectory: isDir,
                        flags: store.flagSet(node),
                        age: age)
    }

    nonisolated static func computeSunburst(tree: LiveTree, root: Int32, size: CGSize,
                                            physical: Bool, filter: String, key: String,
                                            rootNames names: [String: String] = [:]) -> SunburstLayout {
        let span = Telemetry.begin("layout")
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
        let needle = filter.lowercased()
        return tree.withStore { store in
            let segments = Sunburst.layout(
                store: store, root: root, in: rect, usePhysicalSize: physical,
                includeAtRoot: needle.isEmpty ? nil : { store.name($0).lowercased().contains(needle) })
            var map: [Int32: CellInfo] = [:]
            map.reserveCapacity(segments.count)
            for segment in segments where segment.node >= 0 {
                map[segment.node] = cellInfo(store, segment.node, physical: physical, rootNames: names)
            }
            span.end(["cells": .int(Int64(segments.count)),
                      "w": .int(Int64(size.width)), "h": .int(Int64(size.height)),
                      "view": .text("sunburst")], minMilliseconds: 40)
            return SunburstLayout(key: key, segments: segments, info: map)
        }
    }

    nonisolated static func computeIcicle(tree: LiveTree, root: Int32, size: CGSize,
                                          physical: Bool, filter: String, key: String,
                                          rootNames names: [String: String] = [:]) -> IcicleLayout {
        let span = Telemetry.begin("layout")
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        let needle = filter.lowercased()
        return tree.withStore { store in
            let cells = Icicle.layout(
                store: store, root: root, in: rect, usePhysicalSize: physical,
                includeAtRoot: needle.isEmpty ? nil : { store.name($0).lowercased().contains(needle) })
            var map: [Int32: CellInfo] = [:]
            map.reserveCapacity(cells.count)
            for cell in cells where cell.node >= 0 {
                map[cell.node] = cellInfo(store, cell.node, physical: physical, rootNames: names)
            }
            span.end(["cells": .int(Int64(cells.count)),
                      "w": .int(Int64(size.width)), "h": .int(Int64(size.height)),
                      "view": .text("icicle")], minMilliseconds: 40)
            return IcicleLayout(key: key, cells: cells, info: map)
        }
    }

    func cachedIcicle(for size: CGSize) -> IcicleLayout? {
        icicleCache.get(layoutKey(.icicle, size: size))
    }

    @discardableResult
    func computeIcicleSync(size: CGSize) -> IcicleLayout? {
        guard let tree, size.width > 16, size.height > 16 else { return nil }
        let layout = Self.computeIcicle(tree: tree, root: currentDirectory, size: size,
                                        physical: usePhysicalSize, filter: filterText,
                                        key: layoutKey(.icicle, size: size), rootNames: rootNames)
        icicleCache.set(layout)
        return layout
    }

    func cachedSunburst(for size: CGSize) -> SunburstLayout? {
        sunburstCache.get(layoutKey(.sunburst, size: size))
    }

    @discardableResult
    func computeSunburstSync(size: CGSize) -> SunburstLayout? {
        guard let tree, size.width > 16, size.height > 16 else { return nil }
        let layout = Self.computeSunburst(tree: tree, root: currentDirectory, size: size,
                                          physical: usePhysicalSize, filter: filterText,
                                          key: layoutKey(.sunburst, size: size), rootNames: rootNames)
        sunburstCache.set(layout)
        return layout
    }

    @discardableResult
    func computeLayoutSync(size: CGSize) -> TreemapLayout? {
        guard let tree, size.width > 8, size.height > 8 else { return nil }
        let l = Self.compute(tree: tree, root: currentDirectory, size: size,
                             physical: usePhysicalSize, filter: filterText,
                             key: layoutKey(.treemap, size: size), rootNames: rootNames)
        layoutCache.set(l)
        return l
    }

    /// Lays out one picture, which is the one asked for rather than the one
    /// the model happens to consider current.
    func relayout(_ kind: Visualization, size: CGSize) async {
        guard let tree, size.width > 8, size.height > 8 else { return }
        let key = layoutKey(kind, size: size)
        let root = currentDirectory
        let physical = usePhysicalSize
        let filter = filterText
        let names = rootNames
        switch kind {
        case .treemap:
            if layoutCache.get(key) != nil { return }
            let layout = await Task.detached(priority: .userInitiated) {
                Self.compute(tree: tree, root: root, size: size, physical: physical,
                             filter: filter, key: key, rootNames: names)
            }.value
            guard !Task.isCancelled else { return }
            layoutCache.set(layout)
        case .sunburst:
            if sunburstCache.get(key) != nil { return }
            let layout = await Task.detached(priority: .userInitiated) {
                Self.computeSunburst(tree: tree, root: root, size: size, physical: physical,
                                     filter: filter, key: key, rootNames: names)
            }.value
            guard !Task.isCancelled else { return }
            sunburstCache.set(layout)
        case .icicle:
            if icicleCache.get(key) != nil { return }
            let layout = await Task.detached(priority: .userInitiated) {
                Self.computeIcicle(tree: tree, root: root, size: size, physical: physical,
                                   filter: filter, key: key, rootNames: names)
            }.value
            guard !Task.isCancelled else { return }
            icicleCache.set(layout)
        }
        layoutToken &+= 1
    }
}
