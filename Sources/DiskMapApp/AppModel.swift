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

/// Holds the most recent treemap layout outside published state, so the Canvas
/// can read it during a draw without provoking another render pass.
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

    let layoutCache = LayoutCache()
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
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            var options = ScanOptions(roots: targets)
            options.threadCount = min(12, ProcessInfo.processInfo.activeProcessorCount)
            let result = scanner.scan(options) { p in
                let snap = ScanProgressSnapshot(nodes: p.nodes, directories: p.directories,
                                                bytes: p.bytes, path: p.currentPath, fraction: p.fraction)
                Task { @MainActor [weak self] in
                    guard let self, self.isScanning else { return }
                    self.phase = .scanning(snap)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activeScanner = nil
                // A cancelled scan holds a partial tree; showing it as complete
                // would be a lie about what is on disk.
                if result.stats.cancelled { self.phase = .idle } else { self.adopt(LiveTree(result: result)) }
            }
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
                scanRootIsWholeVolume: live.roots.count == 1
                    && (live.rootPath == "/" || live.rootPath == "/System/Volumes/Data"))
        }
        rejectedRoots = live.rejectedRoots
        rootsSpanVolumes = Set(live.roots.compactMap(volumeMountPoint)).count > 1
        live.onChange = { [weak self] in
            Task { @MainActor in self?.treeChanged() }
        }
        live.startWatching()
        liveActive = live.liveUpdatesActive
        hasFullDiskAccess = FileActions.hasFullDiskAccess()
        currentDirectory = 0
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
        currentDirectory = node
        selection = nil
        selectedInfo = nil
        rebuild()
    }

    func goUp() {
        guard let tree, currentDirectory > 0 else { return }
        currentDirectory = tree.withStore { $0.parent[Int(currentDirectory)] }
        selection = nil
        selectedInfo = nil
        rebuild()
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

            let sizes = physical ? store.totalPhysical : store.totalLogical
            let parentTotal = max(sizes[Int(dir)], 1)
            var out: [Row] = []
            for c in store.children(dir) where !store.flagSet(c).contains(.removed) {
                let nm = store.name(c)
                if !filter.isEmpty && !nm.lowercased().contains(filter) { continue }
                let isDir = store.isDirectory(c)
                out.append(Row(id: c, name: abbreviatedName(nm),
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
            // The synthetic root of a multi-folder scan has no path of its own.
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

    // MARK: - Treemap layout

    func layoutKey(size: CGSize) -> String {
        "\(currentDirectory)-\(revision)-\(Int(size.width))x\(Int(size.height))-\(usePhysicalSize)-\(filterText)"
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
                let n = store.name(c.node)
                map[c.node] = CellInfo(
                    name: abbreviatedName(n),
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
                             physical: usePhysicalSize, filter: filterText,
                             key: layoutKey(size: size))
        layoutCache.set(l)
        return l
    }

    func relayout(size: CGSize) async {
        guard let tree, size.width > 8, size.height > 8 else { return }
        let key = layoutKey(size: size)
        if layoutCache.get(key) != nil { return }
        let root = currentDirectory
        let physical = usePhysicalSize
        let filter = filterText
        let l = await Task.detached(priority: .userInitiated) {
            Self.compute(tree: tree, root: root, size: size, physical: physical,
                         filter: filter, key: key)
        }.value
        guard !Task.isCancelled else { return }
        layoutCache.set(l)
        layoutToken &+= 1
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
