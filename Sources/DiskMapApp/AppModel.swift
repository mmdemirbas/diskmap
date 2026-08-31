import AppKit
import Combine
import DiskMapCore
import SwiftUI

struct Row: Identifiable, Equatable {
    let id: Int32
    let name: String
    let physical: Int64
    let logical: Int64
    let isDirectory: Bool
    let category: FileCategory
    let fractionOfParent: Double
    let flags: NodeFlags
    let modified: Date
    /// Nesting level below the folder on screen. 0 is a direct child.
    let depth: Int
    let hasChildren: Bool
    let isExpanded: Bool
    /// Set on the synthetic trailing row standing in for a truncated level.
    let hiddenSiblings: Int
}

struct CellInfo: Sendable {
    var name: String
    var category: FileCategory
    var bytes: Int64
    var isDirectory: Bool
    var flags: NodeFlags
    var age: AgeBucket
}

enum Visualization: String, CaseIterable, Identifiable {
    case treemap, sunburst, icicle
    var id: String { rawValue }
    var key: L10n.K {
        switch self {
        case .treemap: .treemapView
        case .sunburst: .sunburstView
        case .icicle: .icicleView
        }
    }
    var symbol: String {
        switch self {
        case .treemap: "square.grid.2x2.fill"
        case .sunburst: "circle.circle"
        case .icicle: "chart.bar.doc.horizontal"
        }
    }
}

/// What the colours mean. Type answers "what kind of thing is this"; age
/// answers "how much of this have I not touched in years", which is usually
/// the more useful question when you are trying to free space.
enum ColourMode: String, CaseIterable, Identifiable {
    case type, age
    var id: String { rawValue }
    var key: L10n.K { self == .type ? .colourByType : .colourByAge }
}

enum PanelMode: String, CaseIterable, Identifiable {
    case contents, largest, types, duplicates
    var id: String { rawValue }
    var key: L10n.K {
        switch self {
        case .contents: .panelContents
        case .largest: .panelLargest
        case .types: .panelTypes
        case .duplicates: .panelDuplicates
        }
    }
}

protocol KeyedLayout: Sendable { var key: String { get } }

struct SunburstLayout: KeyedLayout {
    var key: String
    var segments: [SunburstSegment]
    var info: [Int32: CellInfo]
}

struct IcicleLayout: KeyedLayout {
    var key: String
    var cells: [IcicleCell]
    var info: [Int32: CellInfo]
}

/// One entry of the largest-files report.
struct LargeFile: Identifiable {
    let id: Int32
    let name: String
    let path: String
    let bytes: Int64
    let category: FileCategory
    let modified: Date
}

struct TreemapLayout: KeyedLayout {
    var key: String
    var cells: [TreemapCell]
    var info: [Int32: CellInfo]
}

/// Holds the most recent layout outside published state, so the Canvas can read
/// it during a draw without provoking another render pass.
final class LayoutStore<L: KeyedLayout>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: L?
    func get(_ key: String) -> L? {
        lock.lock(); defer { lock.unlock() }
        return current?.key == key ? current : nil
    }
    func any() -> L? { lock.lock(); defer { lock.unlock() }; return current }
    func set(_ layout: L) { lock.lock(); current = layout; lock.unlock() }
}

/// One group of files that share a name and a byte length. See `Duplicates`
/// for why that is a candidate rather than a proven copy.
struct DuplicateEntry: Identifiable {
    struct Copy: Identifiable { let id: Int32; let path: String }
    let id: Int32
    let name: String
    let bytes: Int64
    let reclaimable: Int64
    let copies: [Copy]
}

struct ItemInfo: Equatable {
    var node: Int32
    var name: String
    var path: String
    var physical: Int64
    var logical: Int64
    var isDirectory: Bool
    var category: FileCategory
    var flags: NodeFlags
    var modified: Date
    var fractionOfVolume: Double
    var childCount: Int
}

/// A destructive action waiting for confirmation.
struct PendingTrash: Identifiable, Equatable {
    let id = UUID()
    var node: Int32
    var name: String
    var bytes: Int64
    var itemCount: Int
    var isDirectory: Bool
}

enum Phase: Equatable {
    case idle
    case scanning(ScanProgressSnapshot)
    case ready
    case failed(String)
}

struct ScanProgressSnapshot: Equatable {
    var nodes: Int
    var directories: Int
    var bytes: Int64
    var path: String
    var fraction: Double?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var volumes: [VolumeInfo] = []
    @Published var selectedVolumePath: String = "/System/Volumes/Data"
    /// Folders chosen explicitly. Empty means "measure the selected volume".
    @Published var scanTargets: [String] = []
    @Published var rejectedRoots: [RejectedRoot] = []
    @Published var rootsSpanVolumes = false
    @Published var volume: VolumeInfo?
    @Published var reconciliation: Reconciliation?
    @Published var stats: ScanStats?

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

    @Published var liveActive = false
    @Published var toast: String?
    @Published var undoStack: [TrashedItem] = []
    @Published var pendingTrash: PendingTrash?
    @Published var hasFullDiskAccess = FileActions.hasFullDiskAccess()

    @AppStorage("appearance") var appearance: Appearance = .system {
        willSet { objectWillChange.send() }
    }

    @Published var visualization: Visualization = .treemap
    @Published var colourMode: ColourMode = .type
    @Published var panel: PanelMode = .contents
    @Published var summary: SubtreeSummary?
    @Published var duplicates: [DuplicateEntry] = []
    @Published var largeFiles: [LargeFile] = []
    @Published var summarizing = false

    let layoutCache = LayoutStore<TreemapLayout>()
    let sunburstCache = LayoutStore<SunburstLayout>()
    let icicleCache = LayoutStore<IcicleLayout>()
    @Published private(set) var layoutToken = 0
    /// Offscreen rendering has no async phase, so layout must run inline.
    var renderMode = false

    private(set) var tree: LiveTree?
    @Published private(set) var revision = 0

    private var activeScanner: DiskScanner?
    private var scanTask: Task<Void, Never>?

    init() {
        volumes = VolumeInfo.mountedVolumes()
        if volumes.first(where: { $0.path == selectedVolumePath }) == nil {
            selectedVolumePath = volumes.first?.path ?? "/"
        }
        refreshVolume()
    }

    /// The capacity bar describes the volume the scan actually lives on, which
    /// for a folder scan is the volume containing it, not the one last picked.
    func refreshVolume() {
        volume = VolumeInfo.forPath(tree?.roots.first ?? scanTargets.first ?? selectedVolumePath)
    }

    var isMultiRoot: Bool { (tree?.roots.count ?? 0) > 1 }

    /// Total of the folder currently on screen, for the sunburst hub.
    var currentDirectoryBytes: Int64 {
        guard let tree else { return 0 }
        let node = currentDirectory
        return tree.withStore { store in
            guard node >= 0, node < Int32(store.count) else { return 0 }
            return usePhysicalSize ? store.totalPhysical[Int(node)] : store.totalLogical[Int(node)]
        }
    }

    /// The startup disk arrives as two volumes. Showing "2 locations" for what
    /// the user asked to scan as one disk would be needless jargon.
    var rootLabel: String {
        guard let roots = tree?.roots, !roots.isEmpty else { return "/" }
        if RootSet.coversWholeVolume(roots) { return volume?.name ?? "/" }
        return L10n.shared.locationCount(roots.count)
    }

    // MARK: - Scan targets

    func addTargets(_ urls: [URL]) {
        let candidates = scanTargets + urls.map(\.path)
        let normalized = RootSet.normalize(candidates)
        scanTargets = normalized.roots
        rejectedRoots = normalized.rejected
        refreshVolume()
    }

    func removeTarget(_ path: String) {
        scanTargets.removeAll { $0 == path }
        rejectedRoots = []
        refreshVolume()
    }

    func clearTargets() {
        scanTargets = []
        rejectedRoots = []
        refreshVolume()
    }

    /// Opens the standard folder chooser. Multiple selection is allowed because
    /// measuring several folders as one total is the point.
    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.shared[.chooseFolders]
        panel.message = L10n.shared[.choosePanelMessage]
        if panel.runModal() == .OK { addTargets(panel.urls) }
    }

    var isScanning: Bool { if case .scanning = phase { return true }; return false }

    // MARK: - Scanning

    func scan() {
        cancelScan()
        let targets = scanTargets.isEmpty ? [selectedVolumePath] : scanTargets
        let path = targets[0]
        tree?.stopWatching()
        tree = nil
        liveActive = false
        layoutCache.set(TreemapLayout(key: "", cells: [], info: [:]))
        phase = .scanning(ScanProgressSnapshot(nodes: 0, directories: 0, bytes: 0, path: path, fraction: 0))

        let scanner = DiskScanner()
        activeScanner = scanner

        // Both callbacks are built here, on the main actor, so the detached
        // task captures two immutable closures rather than a mutable `self`.
        let report: @Sendable (ScanProgressSnapshot) -> Void = { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.isScanning else { return }
                self.phase = .scanning(snapshot)
            }
        }
        let finish: @Sendable (ScanResult) -> Void = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.activeScanner = nil
                // A cancelled scan holds a partial tree; presenting it as
                // complete would misstate what is on disk.
                if result.stats.cancelled {
                    self.phase = .idle
                } else {
                    self.adopt(LiveTree(result: result))
                }
            }
        }

        scanTask = Task.detached(priority: .userInitiated) {
            var options = ScanOptions(roots: targets)
            options.threadCount = min(12, ProcessInfo.processInfo.activeProcessorCount)
            let result = scanner.scan(options) { p in
                report(ScanProgressSnapshot(nodes: p.nodes, directories: p.directories,
                                            bytes: p.bytes, path: p.currentPath, fraction: p.fraction))
            }
            finish(result)
        }
    }

    func cancelScan() {
        activeScanner?.cancelToken.cancel()
        scanTask?.cancel()
        activeScanner = nil
        scanTask = nil
    }

    func adopt(_ live: LiveTree) {
        tree = live
        stats = live.stats
        refreshVolume()
        if let v = volume {
            reconciliation = Reconciliation(
                volumeUsed: v.used,
                scannedPhysical: live.stats.totalPhysical,
                datalessLogical: live.stats.datalessLogical,
                hardlinkDuplicateLogical: live.stats.hardlinkDuplicateLogical,
                unreadableDirectories: live.stats.unreadableDirectories,
                snapshotCount: Snapshots.list(volume: "/").count,
                scanRootIsWholeVolume: RootSet.coversWholeVolume(live.roots))
        }
        rejectedRoots = live.rejectedRoots
        // The startup disk is two volumes but one physical disk, so the
        // "more than one disk" note would be noise there.
        rootsSpanVolumes = !RootSet.coversWholeVolume(live.roots)
            && Set(live.roots.compactMap(volumeMountPoint)).count > 1
        live.onChange = { [weak self] in
            Task { @MainActor in self?.treeChanged() }
        }
        live.startWatching()
        liveActive = live.liveUpdatesActive
        hasFullDiskAccess = FileActions.hasFullDiskAccess()
        currentDirectory = 0
        // A startup-disk scan has two roots and effectively everything lives on
        // the Data volume. Opening on the synthetic parent shows one enormous
        // rectangle and nothing useful, so start where the bytes are. The
        // breadcrumb still goes up to the system volume.
        if RootSet.coversWholeVolume(live.roots), live.roots.count > 1,
           let dataNode = live.withStore({ $0.find(path: RootSet.startupDataVolume) }) {
            currentDirectory = dataNode
        }
        selection = nil
        selectedInfo = nil
        phase = .ready
        rebuild()
    }

    private func treeChanged() {
        refreshVolume()
        rebuild()
    }

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
        refreshSummary()
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
            let name = abbreviatedName(rawName)
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
            while cur > 0 { chain.append((cur, store.name(cur))); cur = store.parent[Int(cur)] }
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
            let name = abbreviatedName(store.name(c))
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

    func layoutKey(size: CGSize) -> String {
        "\(visualization.rawValue)-\(currentDirectory)-\(revision)-\(Int(size.width))x\(Int(size.height))-\(usePhysicalSize)-\(filterText)"
    }

    func cachedLayout(for size: CGSize) -> TreemapLayout? { layoutCache.get(layoutKey(size: size)) }

    nonisolated static func compute(tree: LiveTree, root: Int32, size: CGSize,
                                    physical: Bool, filter: String, key: String) -> TreemapLayout {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let needle = filter.lowercased()
        return tree.withStore { store in
            let laid = Treemap.layout(
                store: store, root: root, in: rect, usePhysicalSize: physical,
                includeAtRoot: needle.isEmpty ? nil : { store.name($0).lowercased().contains(needle) })
            var map: [Int32: CellInfo] = [:]
            map.reserveCapacity(laid.count)
            for c in laid where c.node >= 0 {
                map[c.node] = cellInfo(store, c.node, physical: physical)
            }
            return TreemapLayout(key: key, cells: laid, info: map)
        }
    }

    nonisolated static func cellInfo(_ store: NodeStore, _ node: Int32, physical: Bool) -> CellInfo {
        let name = store.name(node)
        let isDir = store.isDirectory(node)
        let age = AgeBucket.of(secondsAgo: Date().timeIntervalSince1970
                               - Double(store.mtime[Int(node)]))
        return CellInfo(name: abbreviatedName(name),
                        category: Categorizer.of(name: name, isDirectory: isDir),
                        bytes: physical ? store.totalPhysical[Int(node)] : store.totalLogical[Int(node)],
                        isDirectory: isDir,
                        flags: store.flagSet(node),
                        age: age)
    }

    nonisolated static func computeSunburst(tree: LiveTree, root: Int32, size: CGSize,
                                            physical: Bool, filter: String,
                                            key: String) -> SunburstLayout {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
        let needle = filter.lowercased()
        return tree.withStore { store in
            let segments = Sunburst.layout(
                store: store, root: root, in: rect, usePhysicalSize: physical,
                includeAtRoot: needle.isEmpty ? nil : { store.name($0).lowercased().contains(needle) })
            var map: [Int32: CellInfo] = [:]
            map.reserveCapacity(segments.count)
            for segment in segments where segment.node >= 0 {
                map[segment.node] = cellInfo(store, segment.node, physical: physical)
            }
            return SunburstLayout(key: key, segments: segments, info: map)
        }
    }

    nonisolated static func computeIcicle(tree: LiveTree, root: Int32, size: CGSize,
                                          physical: Bool, filter: String,
                                          key: String) -> IcicleLayout {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        let needle = filter.lowercased()
        return tree.withStore { store in
            let cells = Icicle.layout(
                store: store, root: root, in: rect, usePhysicalSize: physical,
                includeAtRoot: needle.isEmpty ? nil : { store.name($0).lowercased().contains(needle) })
            var map: [Int32: CellInfo] = [:]
            map.reserveCapacity(cells.count)
            for cell in cells where cell.node >= 0 {
                map[cell.node] = cellInfo(store, cell.node, physical: physical)
            }
            return IcicleLayout(key: key, cells: cells, info: map)
        }
    }

    func cachedIcicle(for size: CGSize) -> IcicleLayout? { icicleCache.get(layoutKey(size: size)) }

    @discardableResult
    func computeIcicleSync(size: CGSize) -> IcicleLayout? {
        guard let tree, size.width > 16, size.height > 16 else { return nil }
        let layout = Self.computeIcicle(tree: tree, root: currentDirectory, size: size,
                                        physical: usePhysicalSize, filter: filterText,
                                        key: layoutKey(size: size))
        icicleCache.set(layout)
        return layout
    }

    func cachedSunburst(for size: CGSize) -> SunburstLayout? { sunburstCache.get(layoutKey(size: size)) }

    @discardableResult
    func computeSunburstSync(size: CGSize) -> SunburstLayout? {
        guard let tree, size.width > 16, size.height > 16 else { return nil }
        let layout = Self.computeSunburst(tree: tree, root: currentDirectory, size: size,
                                          physical: usePhysicalSize, filter: filterText,
                                          key: layoutKey(size: size))
        sunburstCache.set(layout)
        return layout
    }

    @discardableResult
    func computeLayoutSync(size: CGSize) -> TreemapLayout? {
        guard let tree, size.width > 8, size.height > 8 else { return nil }
        let l = Self.compute(tree: tree, root: currentDirectory, size: size,
                             physical: usePhysicalSize, filter: filterText,
                             key: layoutKey(size: size))
        layoutCache.set(l)
        return l
    }

    func relayout(size: CGSize) async {
        guard let tree, size.width > 8, size.height > 8 else { return }
        let key = layoutKey(size: size)
        let root = currentDirectory
        let physical = usePhysicalSize
        let filter = filterText
        switch visualization {
        case .treemap:
            if layoutCache.get(key) != nil { return }
            let layout = await Task.detached(priority: .userInitiated) {
                Self.compute(tree: tree, root: root, size: size, physical: physical,
                             filter: filter, key: key)
            }.value
            guard !Task.isCancelled else { return }
            layoutCache.set(layout)
        case .sunburst:
            if sunburstCache.get(key) != nil { return }
            let layout = await Task.detached(priority: .userInitiated) {
                Self.computeSunburst(tree: tree, root: root, size: size, physical: physical,
                                     filter: filter, key: key)
            }.value
            guard !Task.isCancelled else { return }
            sunburstCache.set(layout)
        case .icicle:
            if icicleCache.get(key) != nil { return }
            let layout = await Task.detached(priority: .userInitiated) {
                Self.computeIcicle(tree: tree, root: root, size: size, physical: physical,
                                   filter: filter, key: key)
            }.value
            guard !Task.isCancelled else { return }
            icicleCache.set(layout)
        }
        layoutToken &+= 1
    }

    /// Whole-subtree reports. Walking 11M nodes takes a moment, so it runs off
    /// the main thread and only when a report panel is actually showing.
    func refreshSummary() {
        guard let tree, panel != .contents else { return }
        let root = currentDirectory
        let physical = usePhysicalSize
        let wantsDuplicates = panel == .duplicates
        summarizing = true
        Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) {
                Self.report(tree: tree, root: root, physical: physical,
                            includeDuplicates: wantsDuplicates)
            }.value
            guard let self else { return }
            self.apply(computed)
        }
    }

    /// Blocking report used by the offscreen renderer, which has no async pass.
    func refreshSummarySync() {
        guard let tree else { return }
        apply(Self.report(tree: tree, root: currentDirectory, physical: usePhysicalSize,
                          includeDuplicates: panel == .duplicates))
    }

    private func apply(_ computed: (SubtreeSummary, [LargeFile], [DuplicateEntry])) {
        summary = computed.0
        largeFiles = computed.1
        duplicates = computed.2
        summarizing = false
    }

    /// Duplicate detection is a second walk, so it only runs for the panel that
    /// shows it rather than on every report refresh.
    nonisolated static func report(tree: LiveTree, root: Int32, physical: Bool,
                                   includeDuplicates: Bool)
    -> (SubtreeSummary, [LargeFile], [DuplicateEntry]) {
        // One lock acquisition: the store must not escape it.
        tree.withStore { store -> (SubtreeSummary, [LargeFile], [DuplicateEntry]) in
            let summary = Aggregate.summarize(store: store, root: root, usePhysicalSize: physical)
            let files = summary.largestFiles.map { id -> LargeFile in
                let name = store.name(id)
                return LargeFile(
                    id: id, name: name, path: store.path(id),
                    bytes: physical ? store.totalPhysical[Int(id)] : store.totalLogical[Int(id)],
                    category: Categorizer.of(name: name, isDirectory: false),
                    modified: Date(timeIntervalSince1970: TimeInterval(store.mtime[Int(id)])))
            }
            guard includeDuplicates else { return (summary, files, []) }
            let groups = Duplicates.find(store: store, root: root).map { group in
                DuplicateEntry(id: group.nodes[0], name: group.name, bytes: group.bytes,
                               reclaimable: group.reclaimable,
                               copies: group.nodes
                                   .map { DuplicateEntry.Copy(id: $0, path: store.path($0)) }
                                   .sorted { $0.path < $1.path })
            }
            return (summary, files, groups)
        }
    }

    /// Blocking scan used by the offscreen renderer.
    func scanSynchronously() {
        var options = ScanOptions(roots: scanTargets.isEmpty ? [selectedVolumePath] : scanTargets)
        options.threadCount = min(12, ProcessInfo.processInfo.activeProcessorCount)
        adopt(LiveTree(result: DiskScanner().scan(options)))
    }

    // MARK: - Actions

    func reveal(_ node: Int32) {
        guard let tree else { return }
        let path = tree.withStore { $0.path(node) }
        FileActions.revealInFinder([URL(fileURLWithPath: path)])
    }

    func copyPath(_ node: Int32) {
        guard let tree else { return }
        FileActions.copyToPasteboard(tree.withStore { $0.path(node) })
        toast = L10n.shared[.pathCopied]
    }

    /// Folders and large files ask first. Everything smaller goes straight to
    /// the Trash, which is recoverable and undoable anyway.
    func requestTrash(_ node: Int32) {
        guard let tree else { return }
        let info = tree.withStore { store -> (String, Int64, Int, Bool)? in
            guard node > 0, node < Int32(store.count),
                  !store.flagSet(node).contains(.removed) else { return nil }
            return (store.name(node), store.totalPhysical[Int(node)],
                    store.children(node).count, store.isDirectory(node))
        }
        guard let (name, bytes, children, isDir) = info else { return }
        if isDir || bytes >= 5_000_000_000 {
            pendingTrash = PendingTrash(node: node, name: name, bytes: bytes,
                                        itemCount: children, isDirectory: isDir)
        } else {
            performTrash(node)
        }
    }

    func confirmPendingTrash() {
        guard let p = pendingTrash else { return }
        pendingTrash = nil
        performTrash(p.node)
    }

    private func performTrash(_ node: Int32) {
        guard let tree else { return }
        let (path, bytes) = tree.withStore {
            ($0.path(node), $0.totalPhysical[Int(node)])
        }
        do {
            let (trashed, failures) = try FileActions.moveToTrash(
                [(url: URL(fileURLWithPath: path), node: node, bytes: bytes)])
            if let first = failures.first { toast = first.errorDescription; return }
            // Reflect it now; the FSEvents relist that follows is a no-op.
            tree.markRemoved(node)
            undoStack.append(contentsOf: trashed)
            if selection == node { select(nil) }
            toast = L10n.shared.freedBytes(shortBytes(bytes))
            refreshVolume()
            rebuild()
        } catch {
            toast = error.localizedDescription
        }
    }

    func undoLastTrash() {
        guard let item = undoStack.popLast() else { return }
        do {
            try FileActions.restore(item)
            toast = L10n.shared.restored(item.originalURL.lastPathComponent)
            tree?.refresh(directory: item.originalURL.deletingLastPathComponent().path)
            refreshVolume()
            rebuild()
        } catch {
            toast = L10n.shared.couldNotRestore(error.localizedDescription)
        }
    }
}
