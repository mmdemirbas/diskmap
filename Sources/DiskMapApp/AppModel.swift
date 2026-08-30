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
}

struct CellInfo: Sendable {
    var name: String
    var category: FileCategory
    var bytes: Int64
    var isDirectory: Bool
    var flags: NodeFlags
}

struct TreemapLayout: Sendable {
    var key: String
    var cells: [TreemapCell]
    var info: [Int32: CellInfo]
}

/// Holds the most recent treemap layout outside the published state, so the
/// Canvas can read it during a draw without triggering another render pass.
final class LayoutCache: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TreemapLayout?
    func get(_ key: String) -> TreemapLayout? {
        lock.lock(); defer { lock.unlock() }
        return current?.key == key ? current : nil
    }
    func any() -> TreemapLayout? { lock.lock(); defer { lock.unlock() }; return current }
    func set(_ l: TreemapLayout) { lock.lock(); current = l; lock.unlock() }
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
    @Published var volume: VolumeInfo?
    @Published var reconciliation: Reconciliation?
    @Published var stats: ScanStats?

    @Published var currentDirectory: Int32 = 0
    @Published var breadcrumb: [(id: Int32, name: String)] = []
    @Published var rows: [Row] = []
    @Published var selection: Int32?
    @Published var selectedInfo: ItemInfo?
    @Published var usePhysicalSize = true
    @Published var filterText = ""

    @Published var liveActive = false
    @Published var lastChange: Date?
    @Published var toast: String?
    @Published var undoStack: [TrashedItem] = []
    @Published var hasFullDiskAccess = FileActions.hasFullDiskAccess()

    let layoutCache = LayoutCache()
    /// Bumped after an async layout lands, to make the Canvas redraw.
    @Published private(set) var layoutToken = 0
    /// Offscreen rendering has no async phase, so layout must run inline.
    var renderMode = false

    private(set) var tree: LiveTree?
    /// Bumped whenever the tree changes so views recompute their layout.
    @Published private(set) var revision = 0

    init() {
        volumes = VolumeInfo.mountedVolumes()
        if volumes.first(where: { $0.path == selectedVolumePath }) == nil {
            selectedVolumePath = volumes.first?.path ?? "/"
        }
        refreshVolume()
    }

    func refreshVolume() {
        volume = VolumeInfo.forPath(selectedVolumePath)
    }

    // MARK: - Scanning

    func scan() {
        let path = selectedVolumePath
        tree?.stopWatching()
        tree = nil
        phase = .scanning(ScanProgressSnapshot(nodes: 0, directories: 0, bytes: 0, path: path, fraction: 0))

        Task.detached(priority: .userInitiated) { [weak self] in
            var options = ScanOptions(rootPath: path)
            options.threadCount = min(12, ProcessInfo.processInfo.activeProcessorCount)
            let result = DiskScanner().scan(options) { p in
                let snap = ScanProgressSnapshot(nodes: p.nodes, directories: p.directories,
                                                bytes: p.bytes, path: p.currentPath, fraction: p.fraction)
                Task { @MainActor in
                    guard let self, case .scanning = self.phase else { return }
                    self.phase = .scanning(snap)
                }
            }
            let live = LiveTree(result: result)
            await MainActor.run { self?.adopt(live) }
        }
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
                scanRootIsWholeVolume: live.rootPath == "/" || live.rootPath == "/System/Volumes/Data")
        }
        live.onChange = { [weak self] in
            Task { @MainActor in self?.treeChanged() }
        }
        live.startWatching()
        liveActive = live.liveUpdatesActive
        hasFullDiskAccess = FileActions.hasFullDiskAccess()
        currentDirectory = 0
        selection = nil
        phase = .ready
        rebuild()
    }

    private func treeChanged() {
        lastChange = tree?.lastChangeAt
        refreshVolume()
        rebuild()
    }

    // MARK: - Navigation

    func enter(_ node: Int32) {
        guard let tree, tree.withStore({ $0.isDirectory(node) }) else { return }
        currentDirectory = node
        selection = nil
        rebuild()
    }

    func goUp() {
        guard let tree, currentDirectory > 0 else { return }
        currentDirectory = tree.withStore { $0.parent[Int(currentDirectory)] }
        rebuild()
    }

    func select(_ node: Int32?) {
        selection = node
        selectedInfo = node.flatMap(info(for:))
    }

    private func info(for node: Int32) -> ItemInfo? {
        guard let tree, let volume else { return nil }
        return tree.withStore { store -> ItemInfo? in
            guard node >= 0, node < Int32(store.count) else { return nil }
            let name = node == 0 ? store.name(0) : store.name(node)
            let isDir = store.isDirectory(node)
            let path = store.path(node, rootPath: tree.rootPath)
            return ItemInfo(
                node: node, name: name, path: path,
                physical: store.totalPhysical[Int(node)],
                logical: store.totalLogical[Int(node)],
                isDirectory: isDir,
                category: Categorizer.of(name: name, isDirectory: isDir, path: path),
                flags: store.flagSet(node),
                modified: Date(timeIntervalSince1970: TimeInterval(store.mtime[Int(node)])),
                fractionOfVolume: volume.used > 0
                    ? Double(store.totalPhysical[Int(node)]) / Double(volume.used) : 0,
                childCount: store.children(node).count)
        }
    }

    func rebuild() {
        guard let tree else { rows = []; breadcrumb = []; return }
        let dir = currentDirectory
        let physical = usePhysicalSize
        let filter = filterText.lowercased()

        let (newRows, crumbs) = tree.withStore { store -> ([Row], [(Int32, String)]) in
            let sizes = physical ? store.totalPhysical : store.totalLogical
            let parentTotal = max(sizes[Int(dir)], 1)
            var out: [Row] = []
            for c in store.children(dir) where !store.flagSet(c).contains(.removed) {
                let nm = store.name(c)
                if !filter.isEmpty && !nm.lowercased().contains(filter) { continue }
                let isDir = store.isDirectory(c)
                out.append(Row(id: c, name: nm,
                               physical: store.totalPhysical[Int(c)],
                               logical: store.totalLogical[Int(c)],
                               isDirectory: isDir,
                               category: Categorizer.of(name: nm, isDirectory: isDir),
                               fractionOfParent: Double(sizes[Int(c)]) / Double(parentTotal),
                               flags: store.flagSet(c),
                               modified: Date(timeIntervalSince1970: TimeInterval(store.mtime[Int(c)]))))
            }
            out.sort { (physical ? $0.physical : $0.logical) > (physical ? $1.physical : $1.logical) }

            var chain: [(Int32, String)] = []
            var cur = dir
            while cur > 0 { chain.append((cur, store.name(cur))); cur = store.parent[Int(cur)] }
            chain.append((0, store.name(0)))
            return (out, chain.reversed())
        }
        rows = newRows
        breadcrumb = crumbs.map { (id: $0.0, name: $0.1) }
        if let s = selection { selectedInfo = info(for: s) }
        revision &+= 1
    }

    // MARK: - Treemap layout

    func layoutKey(size: CGSize) -> String {
        "\(currentDirectory)-\(revision)-\(Int(size.width))x\(Int(size.height))-\(usePhysicalSize)"
    }

    func cachedLayout(for size: CGSize) -> TreemapLayout? {
        layoutCache.get(layoutKey(size: size))
    }

    /// Pure function of the tree; safe to call from any thread.
    nonisolated static func compute(tree: LiveTree, root: Int32, size: CGSize,
                                    physical: Bool, key: String) -> TreemapLayout {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        return tree.withStore { store in
            let laid = Treemap.layout(store: store, root: root, in: rect, usePhysicalSize: physical)
            var map: [Int32: CellInfo] = [:]
            map.reserveCapacity(laid.count)
            for c in laid where c.node >= 0 {
                let n = store.name(c.node)
                map[c.node] = CellInfo(
                    name: n,
                    category: Categorizer.of(name: n, isDirectory: c.isDirectory),
                    bytes: physical ? store.totalPhysical[Int(c.node)] : store.totalLogical[Int(c.node)],
                    isDirectory: c.isDirectory,
                    flags: store.flagSet(c.node))
            }
            return TreemapLayout(key: key, cells: laid, info: map)
        }
    }

    @discardableResult
    func computeLayoutSync(size: CGSize) -> TreemapLayout? {
        guard let tree, size.width > 8, size.height > 8 else { return nil }
        let l = Self.compute(tree: tree, root: currentDirectory, size: size,
                             physical: usePhysicalSize, key: layoutKey(size: size))
        layoutCache.set(l)
        return l
    }

    func relayout(size: CGSize) async {
        guard let tree, size.width > 8, size.height > 8 else { return }
        let key = layoutKey(size: size)
        if layoutCache.get(key) != nil { return }
        let root = currentDirectory
        let physical = usePhysicalSize
        let l = await Task.detached(priority: .userInitiated) {
            Self.compute(tree: tree, root: root, size: size, physical: physical, key: key)
        }.value
        layoutCache.set(l)
        layoutToken &+= 1
    }

    /// Blocking scan used by the offscreen renderer.
    func scanSynchronously() {
        var options = ScanOptions(rootPath: selectedVolumePath)
        options.threadCount = min(12, ProcessInfo.processInfo.activeProcessorCount)
        adopt(LiveTree(result: DiskScanner().scan(options)))
    }

    // MARK: - Actions

    func reveal(_ node: Int32) {
        guard let tree else { return }
        let path = tree.withStore { $0.path(node, rootPath: tree.rootPath) }
        FileActions.revealInFinder([URL(fileURLWithPath: path)])
    }

    func copyPath(_ node: Int32) {
        guard let tree else { return }
        FileActions.copyToPasteboard(tree.withStore { $0.path(node, rootPath: tree.rootPath) })
        toast = "Path copied"
    }

    func moveToTrash(_ node: Int32) {
        guard let tree else { return }
        let (path, bytes) = tree.withStore {
            ($0.path(node, rootPath: tree.rootPath), $0.totalPhysical[Int(node)])
        }
        do {
            let (trashed, failures) = try FileActions.moveToTrash(
                [(url: URL(fileURLWithPath: path), node: node, bytes: bytes)])
            if let first = failures.first { toast = first.errorDescription; return }
            // Reflect it now; the FSEvents relist that follows is a no-op.
            tree.markRemoved(node)
            undoStack.append(contentsOf: trashed)
            if selection == node { select(nil) }
            toast = "Moved to Trash · freed \(shortBytes(bytes))"
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
            toast = "Restored \(item.originalURL.lastPathComponent)"
            if let tree {
                tree.refresh(directory: item.originalURL.deletingLastPathComponent().path)
            }
            refreshVolume()
            rebuild()
        } catch {
            toast = "Could not restore: \(error.localizedDescription)"
        }
    }
}
