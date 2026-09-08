import AppKit
import Combine
import DiskMapCore
import SwiftUI
import UniformTypeIdentifiers

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
    /// Beside the other toolbar pickers there is no room for a sentence,
    /// and the label above them already says what is being chosen.
    var shortKey: L10n.K { self == .type ? .colourTypeShort : .colourAgeShort }
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

/// Which rows of a folder comparison are on screen.
///
/// Two axes rather than one, because they are genuinely independent: a file can
/// hold the same bytes on both sides and still have been written more recently
/// on one of them. Folding them into a single list of states would make
/// "everything the left touched last" unaskable.
enum CompareFilter: String, CaseIterable, Identifiable {
    /// Everything except what matched. The default, because it is the question.
    case differences
    case all
    case identical, differs, onlyLeft, onlyRight, typeClash

    var id: String { rawValue }

    /// The kind this chip stands for, or nil for the two that span kinds.
    var kind: DiffKind? {
        switch self {
        case .differences, .all: nil
        case .identical: .identical
        case .differs: .differs
        case .onlyLeft: .onlyLeft
        case .onlyRight: .onlyRight
        case .typeClash: .typeClash
        }
    }

    var key: L10n.K {
        switch self {
        case .differences: .filterDifferences
        case .all: .filterAll
        case .identical: .diffIdentical
        case .differs: .diffDiffers
        case .onlyLeft: .diffOnlyLeft
        case .onlyRight: .diffOnlyRight
        case .typeClash: .diffClash
        }
    }

    /// Which kinds this chip wants. Matched against what a node's subtree
    /// holds rather than against the node's own kind, so a closed folder that
    /// could contain a match is never hidden — hiding it would make everything
    /// inside unreachable.
    var mask: DiffKindMask {
        switch self {
        case .all: .everything
        case .differences: DiffKindMask.everything.subtracting(.identical)
        case .identical: .identical
        case .differs: .differs
        case .onlyLeft: .onlyLeft
        case .onlyRight: .onlyRight
        case .typeClash: .typeClash
        }
    }
}

/// The other axis: which side was written last.
enum DateFilter: String, CaseIterable, Identifiable {
    case any, leftNewer, rightNewer, sameDate
    var id: String { rawValue }

    var key: L10n.K {
        switch self {
        case .any: .dateAny
        case .leftNewer: .dateLeftNewer
        case .rightNewer: .dateRightNewer
        case .sameDate: .dateSame
        }
    }

    /// An item present on one side only has no second date to be newer than,
    /// so every filter but `any` excludes it. That is the honest answer rather
    /// than an accident: "what did I touch more recently over there" is not a
    /// question about a file that only exists here.
    func accepts(_ tree: DiffTree, _ id: Int32) -> Bool {
        switch self {
        case .any: return true
        case .leftNewer: return tree.newerSide(id) == .left
        case .rightNewer: return tree.newerSide(id) == .right
        case .sameDate:
            let left = tree.modified(id, on: .left)
            return left > 0 && left == tree.modified(id, on: .right)
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
    func clear() { lock.lock(); current = nil; lock.unlock() }
}

struct PathRef: Identifiable { let id: Int32; let path: String }

/// A match is identified by the set of things it matches, not by any one of
/// them: the same folder can appear in several matches.
func matchKey(_ nodes: [Int32]) -> Int64 {
    nodes.reduce(Int64(bitPattern: 0xcbf2_9ce4_8422_2325)) {
        ($0 ^ Int64($1)) &* 0x100_0000_01b3
    }
}

/// One group of files that share a name and a byte length. See `Duplicates`
/// for why that is a candidate rather than a proven copy.
struct DuplicateEntry: Identifiable {
    let id: Int64
    let name: String
    let bytes: Int64
    let reclaimable: Int64
    /// What verifying this match would read, so the button can say the price
    /// without the view searching for it on every row it draws.
    let readBytes: Int64
    let copies: [PathRef]
}

/// One set of folders holding the same thing. See `FolderMatches`.
struct FolderEntry: Identifiable {
    let id: Int64
    let name: String
    let bytes: Int64
    let reclaimable: Int64
    let exact: Bool
    let sharedItems: Int
    let comparedItems: Int
    /// What verifying this match would read, so the button can say the price.
    let readBytes: Int64
    let copies: [PathRef]
}

/// Progress and verdict of a content check, keyed by the match it belongs to.
struct VerifyStatus {
    var read: Int64 = 0
    var total: Int64 = 0
    var outcome: VerifyOutcome?
    var running: Bool { outcome == nil }
}

/// The folder hashes cover the whole tree and only change when the tree does,
/// so browsing with the panel open should not pay for them again each time.
///
/// The key is the tree's revision, and a hash is not purely a function of the
/// tree: a symlink contributes where it points, which is read from disk. That
/// holds together only because the revision moves whenever a relist writes
/// anything — including a date with no size behind it, which is all a
/// re-pointed link leaves in the store. The cache is exactly as fresh as the
/// tree, never fresher.
final class SignatureCache: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = -1
    private var values: [UInt64] = []

    func signatures(for store: NodeStore, revision: Int) -> [UInt64] {
        lock.lock(); defer { lock.unlock() }
        if self.revision == revision, values.count == store.count { return values }
        values = FolderMatches.signatures(store)
        self.revision = revision
        return values
    }
}

/// Everything the report panels show, produced by one walk of the subtree.
struct ReportData {
    var summary: SubtreeSummary
    var largest: [LargeFile]
    var duplicates: [DuplicateEntry]
    var folders: [FolderEntry]
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
/// One trash operation, undone as a unit. Trashing forty copies and then
/// pressing undo forty times is not an undo.
struct TrashBatch: Identifiable {
    let id = UUID()
    let items: [TrashedItem]
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytesFreed } }
}

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
    /// The scan every module reads from, and the first piece of this object to
    /// stop being this object's private business. Its changes are re-emitted
    /// below as this object's own, so everything that reads `model.phase` and
    /// the rest through the forwarding properties keeps working unchanged.
    let session = ScanSession()
    private var sessionRelay: AnyCancellable?

    var phase: Phase {
        get { session.phase } set { session.phase = newValue }
    }
    var volumes: [VolumeInfo] {
        get { session.volumes } set { session.volumes = newValue }
    }
    var selectedVolumePath: String {
        get { session.selectedVolumePath } set { session.selectedVolumePath = newValue }
    }
    var scanTargets: [String] {
        get { session.scanTargets } set { session.scanTargets = newValue }
    }
    var rejectedRoots: [RejectedRoot] {
        get { session.rejectedRoots } set { session.rejectedRoots = newValue }
    }
    var rootsSpanVolumes: Bool {
        get { session.rootsSpanVolumes } set { session.rootsSpanVolumes = newValue }
    }
    var volume: VolumeInfo? {
        get { session.volume } set { session.volume = newValue }
    }
    var reconciliation: Reconciliation? {
        get { session.reconciliation } set { session.reconciliation = newValue }
    }
    var stats: ScanStats? {
        get { session.stats } set { session.stats = newValue }
    }

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

    var liveActive: Bool {
        get { session.liveActive } set { session.liveActive = newValue }
    }
    @Published var toast: String?
    @Published var undoStack: [TrashBatch] = []
    /// Explicitly ticked for a bulk action. Kept apart from `selection`, which
    /// is only what the eye is on — a highlight must never become a delete.
    @Published var checked: Set<Int32> = []
    /// The decisions on screen while the confirmation is open. Nil when it is
    /// closed; the sheet is driven by this rather than by a frozen plan, so
    /// what is about to happen can be changed while looking at it.
    @Published var reviewing: [ReviewGroup]?
    @Published private(set) var reviewPlan: TrashPlan?
    @Published private(set) var reviewRefusal: TrashRefusal?
    @Published var suggestions: [CleanupSuggestion] = []
    @Published var showCompare = false
    @Published var showCompareIgnore = false
    @Published var compareLeft = ""
    @Published var compareRight = ""
    @Published var folderComparison: FolderComparison?
    @Published private(set) var comparing = false
    @Published private(set) var compareRefusal: CompareRefusal?
    @Published var comparePage: ComparePage = .diff
    @Published var compareFilter: CompareFilter = .differences
    @Published var dateFilter: DateFilter = .any
    @Published var syncDirection: SyncDirection = .mirrorLeftToRight
    @Published private(set) var syncPlan: SyncPlan?
    @Published private(set) var syncOutcome: SyncOutcome?
    @Published private(set) var syncRunning = false
    @Published private(set) var syncProgress: SyncProgress?
    @Published private(set) var compareVerification: VerifyDifferences?
    @Published private(set) var compareVerifying = false
    @Published private(set) var compareVerifyBytes: Int64 = 0
    /// The rows on screen, as tree nodes. Held rather than derived: walking the
    /// tree inside `body` would do it again on every redraw.
    @Published private(set) var compareRows: [Int32] = []
    @Published private(set) var compareRowsOmitted = 0
    @Published private(set) var compareExpanded: Set<Int32> = []
    /// Decisions the user has unticked. Empty means everything is in, which is
    /// what a comparison starts as — narrowing is the deliberate act, not
    /// widening.
    @Published private(set) var compareSkipped: Set<Int> = []
    /// Running count of unticked decisions, so a row can say whether its own
    /// run of them is all in, all out or mixed without counting a set every
    /// time it draws.
    private var skippedPrefix: [Int] = []

    /// Persisted across launches: these are settings, not session state.
    @AppStorage("compareIgnore") private var storedIgnore = CompareOptions.noise.joined(separator: "\n")
    @AppStorage("compareDateTolerance") var compareDateTolerance = 0
    @AppStorage("comparePairs") private var storedPairs = ""

    var compareIgnore: [String] {
        get { storedIgnore.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
        set { objectWillChange.send(); storedIgnore = newValue.joined(separator: "\n") }
    }

    /// Adding or dropping a pattern changes what the answer on screen is, so
    /// the answer is worked out again rather than left standing as something
    /// the current settings would not produce.
    func addIgnorePattern(_ pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !compareIgnore.contains(trimmed) else { return }
        compareIgnore = compareIgnore + [trimmed]
        if folderComparison != nil { runComparison() }
    }

    func removeIgnorePattern(_ pattern: String) {
        compareIgnore = compareIgnore.filter { $0 != pattern }
        if folderComparison != nil { runComparison() }
    }

    func resetIgnorePatterns() {
        compareIgnore = CompareOptions.noise
        if folderComparison != nil { runComparison() }
    }

    var compareOptions: CompareOptions {
        CompareOptions(ignore: compareIgnore, dateTolerance: Int32(compareDateTolerance))
    }

    /// Folder pairs compared before, newest first. A sync is a thing you do
    /// again next week, and retyping both sides is the part nobody does.
    var comparePairs: [(left: String, right: String)] {
        storedPairs.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    private func rememberPair(_ left: String, _ right: String) {
        var kept = comparePairs.filter { !($0.left == left && $0.right == right) }
        kept.insert((left, right), at: 0)
        storedPairs = kept.prefix(8).map { "\($0.left)\t\($0.right)" }.joined(separator: "\n")
    }
    private var compareCancel: CancelToken?
    private var compareGeneration = 0

    @Published var showFind = false
    @Published var findText = ""
    @Published private(set) var findResults: [FoundItem] = []
    /// How many matched altogether. The list is capped, and a reader must not
    /// take the rows they can see for the whole answer.
    @Published private(set) var findTotal = 0
    @Published private(set) var findSearching = false
    private var findTask: Task<Void, Never>?
    @Published var suggestionsLoading = false
    @Published var showCleanup = false
    /// Sizes below which a suggestion is not worth making. A field rather than
    /// a constant so a fixture can exercise the screen without a gigabyte of
    /// files, and so it can become a preference later.
    var cleanupThresholds = Cleanup.Thresholds()
    /// Folders the app must never propose removing. Kept across launches,
    /// because "stop suggesting my Drive" is not a thing anyone wants to say
    /// twice. Deliberately not applied to the scan: excluding a folder from
    /// measurement would quietly make every total on screen wrong.
    @Published var excludedPaths: [String] = AppModel.loadExclusions() {
        didSet {
            UserDefaults.standard.set(excludedPaths, forKey: AppModel.exclusionsKey)
            if reviewing != nil { refreshReviewPlan() }
        }
    }
    @Published var showExclusions = false
    static let exclusionsKey = "excludedPaths"
    static func loadExclusions() -> [String] {
        UserDefaults.standard.stringArray(forKey: exclusionsKey) ?? []
    }

    func exclude(_ path: String) {
        guard !excludedPaths.contains(path) else { return }
        excludedPaths.append(path)
        excludedPaths.sort()
        // Anything already ticked under it stops being a target.
        if let tree {
            let inside = tree.withStore { store in
                checked.filter { TrashPlanner.isInside(store.path($0), path) }
            }
            checked.subtract(inside)
        }
        Telemetry.record("exclusion.add", ["total": .int(Int64(excludedPaths.count))])
        if reviewing != nil { rebuildReview() }
    }

    func unexclude(_ path: String) {
        excludedPaths.removeAll { $0 == path }
    }

    func chooseExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.shared[.neverSuggest]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { exclude(url.path) }
    }
    /// Both settable so the offscreen renderer can point them at a fixture: a
    /// comparison screen that cannot be rendered is a screen nobody has checked.
    var snapshots = SnapshotStore()
    /// What this scan looked like, kept so a comparison has a right-hand side
    /// without re-walking the tree.
    var currentDigest: DiskDigest?
    @Published var showChanges = false
    @Published var history: [SnapshotStore.Entry] = []
    @Published var comparison: DigestDiff?
    @Published var comparingTo: String?
    /// Every set of things the app called copies of each other, so the planner
    /// can refuse to empty one.
    private var matchGroups: [[Int32]] = []
    /// The groups the open review is judged against — the panel's matches, or
    /// the ones a suggestion came from.
    private var reviewGroups: [[Int32]] = []
    /// Not a constant so the offscreen renderer can point it at a fixture; a
    /// warning nobody can render is a warning nobody has checked.
    var syncRoots = SyncRoots.detected()
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
    @Published var folderMatches: [FolderEntry] = []
    @Published var verifications: [Int64: VerifyStatus] = [:]
    @Published var openMatches: Set<Int64> = []
    private var verifyTokens: [Int64: CancelToken] = [:]
    private let signatureCache = SignatureCache()
    @Published var largeFiles: [LargeFile] = []
    @Published var summarizing = false

    let layoutCache = LayoutStore<TreemapLayout>()
    let sunburstCache = LayoutStore<SunburstLayout>()
    let icicleCache = LayoutStore<IcicleLayout>()
    @Published private(set) var layoutToken = 0
    /// Offscreen rendering has no async phase, so layout must run inline.
    var renderMode = false

    var tree: LiveTree? { session.tree }
    @Published private(set) var revision = 0

    private var activeScanner: DiskScanner?
    private var scanTask: Task<Void, Never>?
    /// Which scan the app is currently listening to.
    ///
    /// Cancelling a scan does not stop it instantly: the token is cooperative,
    /// so the detached task keeps going until the walk notices, then delivers a
    /// partial result and calls back. Without a stamp to check, that callback
    /// belonged to nobody in particular — it cleared the scanner handle of the
    /// scan that had replaced it and pushed the UI back to the start screen
    /// while the new scan was still running, which then finished and dropped a
    /// result onto a screen that had moved on.
    private(set) var scanGeneration = 0

    init() {
        // The session is a separate object, so its changes are separate events.
        // Re-emitting them keeps every existing view — all of which observe
        // this object — seeing the scan exactly as before.
        sessionRelay = session.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        volumes = VolumeInfo.mountedVolumes()
        if volumes.first(where: { $0.path == selectedVolumePath }) == nil {
            selectedVolumePath = volumes.first?.path ?? "/"
        }
        // Something sensible to scan on opening, in the same list the user
        // edits, rather than a separate default hidden behind a picker.
        // "/" and not the Data volume: the disk list names the startup disk by
        // its mount point, so seeding the other one would leave the default
        // target unticked in that list and showing up as a stray folder. The
        // scan expands "/" to both volumes on its own.
        scanTargets = RootSet.normalize(["/"]).roots
        refreshVolume()
        observeVisibility()
    }

    /// A disk that was plugged in after launch is still a disk.
    func refreshVolumes() {
        volumes = VolumeInfo.mountedVolumes()
    }

    /// True when this volume is one of the things about to be measured.
    func isTargeted(_ volume: VolumeInfo) -> Bool {
        scanTargets.contains(volume.path)
    }

    func toggle(_ volume: VolumeInfo) {
        if scanTargets.contains(volume.path) {
            removeTarget(volume.path)
        } else {
            addTargets([URL(fileURLWithPath: volume.path)])
        }
    }

    /// The volumes the chosen targets actually live on, in the order the
    /// targets were given. One capacity bar per disk being measured: showing a
    /// single disk's bar while measuring two is a screen that misstates itself.
    var targetedVolumes: [VolumeInfo] {
        let paths = tree?.roots ?? scanTargets
        var seen = Set<String>()
        var out: [VolumeInfo] = []
        for path in paths {
            guard let mount = volumeMountPoint(path) else { continue }
            // The startup disk mounts twice and is one disk. Without folding
            // them, ticking it produced two identical bars for "Macintosh HD".
            let disk = RootSet.physicalDisk(mount)
            guard seen.insert(disk).inserted, let info = VolumeInfo.forPath(disk) else { continue }
            out.append(info)
        }
        return out.isEmpty ? [volume].compactMap { $0 } : out
    }

    // MARK: - Doing nothing while nobody is looking

    /// Assumed true until told otherwise: an offscreen render has no window at
    /// all, and starting out "invisible" would defer work that has no later
    /// moment to happen in.
    private var windowIsVisible = true
    private var rebuildWhenVisible = false
    private var lastVolumeRefresh = Date.distantPast
    private var visibilityObserver: NSObjectProtocol?

    /// Occlusion, not activation. A window can be entirely covered by another
    /// app while this one is still frontmost by some measures, and it can be
    /// perfectly readable beside the editor the user is actually typing in.
    /// What decides whether laying out a treemap is worth doing is whether any
    /// pixel of it is on screen, which is the one thing occlusion state means.
    private func observeVisibility() {
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.visibilityChanged() }
        }
    }

    private func visibilityChanged() {
        let visible = NSApp.occlusionState.contains(.visible)
        guard visible != windowIsVisible else { return }
        windowIsVisible = visible
        // The tree keeps following the filesystem either way; only the rate
        // changes. Coming back to a stale window is the failure this app is
        // meant not to have.
        tree?.setSuspended(!visible)
        guard visible, rebuildWhenVisible else { return }
        rebuildWhenVisible = false
        refreshVolume()
        rebuild()
    }

    /// Free space moves in gigabytes over minutes, not between two filesystem
    /// events a few milliseconds apart, and asking for it means asking the
    /// volume about purgeable space. Every few seconds is as often as anyone
    /// can read it.
    private func refreshVolumeIfStale(after seconds: TimeInterval = 5) {
        guard Date().timeIntervalSince(lastVolumeRefresh) >= seconds else { return }
        lastVolumeRefresh = Date()
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

    // MARK: - Naming a root

    /// A root node's name is its absolute path, so a scan of two disks lists
    /// "/", "/System/Volumes/Data" and "/Volumes/MD8TB" — three mount points
    /// where the user chose two disks, one of which is silently split in half.
    /// Roots are named the way the disk chooser names them instead, so there is
    /// one vocabulary across the app.
    private var rootNames: [String: String] = [:]

    private func buildRootNames(_ roots: [String]) {
        var names: [String: String] = [:]
        for root in roots where volumeMountPoint(root) == root {
            guard let info = VolumeInfo.forPath(root) else { continue }
            // Both halves of the startup disk report the same volume name, and
            // two rows called "Macintosh HD" is the confusion this replaces.
            // The read-only half is the one that needs saying.
            names[root] = root == "/" && roots.contains(RootSet.startupDataVolume)
                ? L10n.shared.systemVolume(info.name)
                : info.name
        }
        rootNames = names
    }

    /// The name to show for a node, which for a root is its disk.
    func displayName(_ raw: String) -> String {
        rootNames[raw] ?? abbreviatedName(raw)
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

    var canScan: Bool { !scanTargets.isEmpty }

    func scan() {
        guard canScan else { return }
        cancelScan()                       // bumps the generation
        let generation = scanGeneration
        let targets = scanTargets
        let path = targets[0]
        tree?.stopWatching()
        session.adopt(nil)
        liveActive = false
        layoutCache.set(TreemapLayout(key: "", cells: [], info: [:]))
        phase = .scanning(ScanProgressSnapshot(nodes: 0, directories: 0, bytes: 0, path: path, fraction: 0))

        let scanner = DiskScanner()
        activeScanner = scanner

        // Both callbacks are built here, on the main actor, so the detached
        // task captures two immutable closures rather than a mutable `self`.
        let report: @Sendable (ScanProgressSnapshot) -> Void = { [weak self] snapshot in
            Task { @MainActor in self?.applyProgress(snapshot, from: generation) }
        }
        let finish: @Sendable (ScanResult) -> Void = { [weak self] result in
            Task { @MainActor in self?.applyResult(result, from: generation) }
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

    /// Progress from a scan that may no longer be the one on screen.
    func applyProgress(_ snapshot: ScanProgressSnapshot, from generation: Int) {
        guard scanGeneration == generation, isScanning else { return }
        phase = .scanning(snapshot)
    }

    /// The end of a scan, which may have been superseded while it wound down.
    func applyResult(_ result: ScanResult, from generation: Int) {
        guard scanGeneration == generation else { return }
        activeScanner = nil
        // A cancelled scan holds a partial tree; presenting it as complete
        // would misstate what is on disk.
        if result.stats.cancelled {
            phase = .idle
        } else {
            adopt(LiveTree(result: result))
        }
    }

    func cancelScan() {
        activeScanner?.cancelToken.cancel()
        scanTask?.cancel()
        activeScanner = nil
        scanTask = nil
        // Anything still in flight now speaks for a scan nobody is listening to.
        scanGeneration &+= 1
    }

    /// Stop the running scan and go back to the chooser.
    func stopScanning() {
        cancelScan()
        phase = .idle
    }

    /// Measure something else, without relaunching the app.
    ///
    /// Everything derived from the old tree goes with it. Node indices mean
    /// nothing across two scans, so a selection, a tick list or a set of
    /// findings carried over would point at whatever now happens to sit at
    /// that index — and the tick list is the one that feeds the Trash.
    func newScan() {
        cancelScan()
        tree?.stopWatching()
        session.adopt(nil)
        liveActive = false
        stats = nil
        reconciliation = nil
        rejectedRoots = []
        rootsSpanVolumes = false
        rows = []
        breadcrumb = []
        currentDirectory = 0
        expanded = []
        selection = nil
        selectedInfo = nil
        checked = []
        reviewing = nil
        suggestions = []
        summary = nil
        largeFiles = []
        matchGroups = []
        reviewGroups = []
        currentDigest = nil
        // Trashed items are still in the Trash and still recoverable from
        // Finder; the app just can no longer be the one to put them back,
        // because "back" was a place in a tree that no longer exists.
        undoStack = []
        backStack = []
        forwardStack = []
        filterText = ""
        layoutCache.clear(); sunburstCache.clear(); icicleCache.clear()
        phase = .idle
        refreshVolume()
    }

    func adopt(_ live: LiveTree) {
        session.adopt(live)
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
        buildRootNames(live.roots)
        rejectedRoots = live.rejectedRoots
        // The startup disk is two volumes but one physical disk, so the
        // "more than one disk" note would be noise there.
        rootsSpanVolumes = !RootSet.coversWholeVolume(live.roots)
            && Set(live.roots.compactMap(volumeMountPoint)).count > 1
        live.onChange = { [weak self] in
            Task { @MainActor in self?.treeChanged() }
        }
        recordDigest(of: live)
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
        // Rebuilding rows and re-laying out a treemap nobody can see is pure
        // battery. The work is not skipped, it is deferred to the moment the
        // window is on screen again.
        guard windowIsVisible else { rebuildWhenVisible = true; return }
        refreshVolumeIfStale()
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

    func layoutKey(size: CGSize) -> String {
        "\(visualization.rawValue)-\(currentDirectory)-\(revision)-\(Int(size.width))x\(Int(size.height))-\(usePhysicalSize)-\(filterText)"
    }

    func cachedLayout(for size: CGSize) -> TreemapLayout? { layoutCache.get(layoutKey(size: size)) }

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

    func cachedIcicle(for size: CGSize) -> IcicleLayout? { icicleCache.get(layoutKey(size: size)) }

    @discardableResult
    func computeIcicleSync(size: CGSize) -> IcicleLayout? {
        guard let tree, size.width > 16, size.height > 16 else { return nil }
        let layout = Self.computeIcicle(tree: tree, root: currentDirectory, size: size,
                                        physical: usePhysicalSize, filter: filterText,
                                        key: layoutKey(size: size), rootNames: rootNames)
        icicleCache.set(layout)
        return layout
    }

    func cachedSunburst(for size: CGSize) -> SunburstLayout? { sunburstCache.get(layoutKey(size: size)) }

    @discardableResult
    func computeSunburstSync(size: CGSize) -> SunburstLayout? {
        guard let tree, size.width > 16, size.height > 16 else { return nil }
        let layout = Self.computeSunburst(tree: tree, root: currentDirectory, size: size,
                                          physical: usePhysicalSize, filter: filterText,
                                          key: layoutKey(size: size), rootNames: rootNames)
        sunburstCache.set(layout)
        return layout
    }

    @discardableResult
    func computeLayoutSync(size: CGSize) -> TreemapLayout? {
        guard let tree, size.width > 8, size.height > 8 else { return nil }
        let l = Self.compute(tree: tree, root: currentDirectory, size: size,
                             physical: usePhysicalSize, filter: filterText,
                             key: layoutKey(size: size), rootNames: rootNames)
        layoutCache.set(l)
        return l
    }

    func relayout(size: CGSize) async {
        guard let tree, size.width > 8, size.height > 8 else { return }
        let key = layoutKey(size: size)
        let root = currentDirectory
        let physical = usePhysicalSize
        let filter = filterText
        let names = rootNames
        switch visualization {
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

    /// Whole-subtree reports. Walking 11M nodes takes a moment, so it runs off
    /// the main thread and only when a report panel is actually showing.
    func refreshSummary() {
        guard let tree, panel != .contents else { return }
        let root = currentDirectory
        let physical = usePhysicalSize
        let wantsDuplicates = panel == .duplicates
        // Verdicts belong to the tree that produced them. Dropping the state
        // without stopping the run would leave gigabytes of reading in flight
        // for an answer nobody can see any more.
        if wantsDuplicates { cancelAllVerifications() }
        summarizing = true
        let cache = signatureCache
        // The tree's own counter, not the view's: retyping a filter must not
        // throw away a hash pass that is still valid.
        let revision = tree.changeCount
        Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) {
                Self.report(tree: tree, root: root, physical: physical,
                            includeDuplicates: wantsDuplicates,
                            cache: cache, revision: revision)
            }.value
            guard let self else { return }
            self.apply(computed)
        }
    }

    /// Blocking report used by the offscreen renderer, which has no async pass.
    func refreshSummarySync() {
        guard let tree else { return }
        apply(Self.report(tree: tree, root: currentDirectory, physical: usePhysicalSize,
                          includeDuplicates: panel == .duplicates,
                          cache: signatureCache, revision: tree.changeCount))
    }

    private func apply(_ computed: ReportData) {
        summary = computed.summary
        largeFiles = computed.largest
        duplicates = computed.duplicates
        folderMatches = computed.folders
        matchGroups = computed.folders.map { $0.copies.map(\.id) }
            + computed.duplicates.map { $0.copies.map(\.id) }
        // A tick refers to a node in the report that produced it — unless a
        // review is open, in which case it refers to a decision being made.
        if reviewing == nil { checked = [] }
        summarizing = false
    }

    /// Duplicate detection is a second walk, so it only runs for the panel that
    /// shows it rather than on every report refresh.
    nonisolated static func report(tree: LiveTree, root: Int32, physical: Bool,
                                   includeDuplicates: Bool,
                                   cache: SignatureCache, revision: Int) -> ReportData {
        // One lock acquisition: the store must not escape it.
        tree.withStore { store -> ReportData in
            let summary = Aggregate.summarize(store: store, root: root, usePhysicalSize: physical)
            let files = summary.largestFiles.map { id -> LargeFile in
                let name = store.name(id)
                return LargeFile(
                    id: id, name: name, path: store.path(id),
                    bytes: physical ? store.totalPhysical[Int(id)] : store.totalLogical[Int(id)],
                    category: Categorizer.of(name: name, isDirectory: false),
                    modified: Date(timeIntervalSince1970: TimeInterval(store.mtime[Int(id)])))
            }
            guard includeDuplicates else {
                return ReportData(summary: summary, largest: files, duplicates: [], folders: [])
            }
            let matches = FolderMatches.find(store: store, root: root,
                                             precomputed: cache.signatures(for: store,
                                                                          revision: revision))
            let folders = matches.map { match in
                FolderEntry(id: matchKey(match.nodes), name: store.name(match.nodes[0]),
                            bytes: match.bytes, reclaimable: match.reclaimable,
                            exact: match.exact, sharedItems: match.sharedItems,
                            comparedItems: match.comparedItems,
                            readBytes: match.nodes.reduce(0) { $0 + store.totalPhysical[Int($1)] },
                            copies: match.nodes.map { PathRef(id: $0, path: store.path($0)) })
            }
            let groups = Duplicates.find(store: store, root: root,
                                         insideMatched: matches).map { group in
                DuplicateEntry(id: matchKey(group.nodes), name: group.name, bytes: group.bytes,
                               reclaimable: group.reclaimable,
                               readBytes: group.bytes * Int64(group.nodes.count),
                               copies: group.nodes
                                   .map { PathRef(id: $0, path: store.path($0)) }
                                   .sorted { $0.path < $1.path })
            }
            return ReportData(summary: summary, largest: files, duplicates: groups, folders: folders)
        }
    }

    // MARK: - Choosing things to remove

    func toggleChecked(_ node: Int32) {
        if checked.contains(node) { checked.remove(node) }
        else if !wouldBeTheLastCopy(node), !isNeverTouch(node) { checked.insert(node) }
        if reviewing != nil { refreshReviewPlan() }
    }

    /// True when the never-touch list covers this node.
    ///
    /// Adding a path to the list already unticks what is under it, but the list
    /// outlives the session: the copy report does not filter by it, so *Select
    /// extras* would tick a folder excluded months ago. The card then said
    /// "Trash" beside it while the planner dropped it — two screens describing
    /// the same item differently, on the screen that decides what is deleted.
    func isNeverTouch(_ node: Int32) -> Bool {
        guard let tree, !excludedPaths.isEmpty else { return false }
        let path = tree.withStore { $0.path(node) }
        return excludedPaths.contains { TrashPlanner.isInside(path, $0) }
    }

    /// Keeps exactly this copy and removes the others in its group. One click
    /// for the decision the screen is actually asking about.
    func keepOnly(_ node: Int32, in group: ReviewGroup) {
        for member in group.members {
            if member.node == node || isNeverTouch(member.node) { checked.remove(member.node) }
            else { checked.insert(member.node) }
        }
        if reviewing != nil { refreshReviewPlan() }
    }

    /// True when ticking this would leave a group with nothing in it. The
    /// planner refuses that too; stopping the tick is better, because it says
    /// so before the user has built a selection they cannot use.
    func wouldBeTheLastCopy(_ node: Int32) -> Bool {
        for group in matchGroups where group.contains(node) {
            let survivors = group.filter { $0 != node && !checked.contains($0) }
            if survivors.isEmpty { return true }
        }
        return false
    }

    /// Ticks every copy but the first. The first is a choice the user can undo
    /// by hand — nothing here decides which copy is the real one.
    func checkExtras(_ copies: [PathRef]) {
        for copy in copies.dropFirst()
        where !wouldBeTheLastCopy(copy.id) && !isNeverTouch(copy.id) {
            checked.insert(copy.id)
        }
    }

    func clearChecked() { checked = [] }

    var checkedBytes: Int64 {
        guard let tree else { return 0 }
        return tree.withStore { store in
            checked.reduce(0) { total, node in
                guard node > 0, node < Int32(store.count) else { return total }
                return total + store.totalPhysical[Int(node)]
            }
        }
    }

    // MARK: - What changed since last time

    /// A few megabytes per scan, so a month of them is affordable. Written off
    /// the main thread: it walks the tree.
    private func recordDigest(of live: LiveTree) {
        let store = snapshots
        Task { [weak self] in
            let digest = await Task.detached(priority: .utility) {
                live.withStore { DiskDigest.of(store: $0, stats: live.stats) }
            }.value
            self?.currentDigest = digest
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

    func openChanges() {
        showChanges = true
        // Everything except this scan's own entry, which would compare the
        // tree against itself.
        let mine = currentDigest?.takenAt.timeIntervalSince1970
        history = snapshots.list()
            .filter { abs($0.takenAt.timeIntervalSince1970 - (mine ?? -1)) > 1 }
            .reversed()
        if comparison == nil, let latest = history.first { compare(with: latest) }
    }

    func compare(with entry: SnapshotStore.Entry) {
        guard let current = currentDigest else { return }
        do {
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
        } catch {
            Telemetry.problem("snapshot.read", error.localizedDescription)
            toast = L10n.shared[.snapshotUnreadable]
        }
    }

    /// Opens the folder a change points at, which is the only useful next step
    /// from a list of things that grew.
    func revealChange(_ change: FolderChange) {
        guard let node = tree?.withStore({ $0.find(path: change.path) }) else {
            FileActions.revealInFinder([URL(fileURLWithPath: change.path)])
            return
        }
        showChanges = false
        enter(node)
    }

    // MARK: - Where the easy space is

    /// Computed when asked for rather than kept up to date: it needs the match
    /// passes, and nobody wants to pay for those while browsing.
    func openCleanup() {
        guard let tree else { return }
        showCleanup = true
        suggestionsLoading = true
        let root = currentDirectory
        let cache = signatureCache
        let revision = tree.changeCount
        let thresholds = cleanupThresholds
        let excluded = excludedPaths
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                Self.computeSuggestions(tree: tree, root: root, cache: cache,
                                        revision: revision, thresholds: thresholds,
                                        excluding: excluded)
            }.value
            guard let self else { return }
            self.suggestions = found
            self.suggestionsLoading = false
        }
    }

    nonisolated static func computeSuggestions(tree: LiveTree, root: Int32,
                                               cache: SignatureCache, revision: Int,
                                               thresholds: Cleanup.Thresholds,
                                               excluding: [String] = []) -> [CleanupSuggestion] {
        tree.withStore { store in
            let folders = FolderMatches.find(store: store, root: root,
                                             precomputed: cache.signatures(for: store,
                                                                           revision: revision))
            let files = Duplicates.find(store: store, root: root, insideMatched: folders)
            return Cleanup.suggest(store: store, root: root,
                                   folderCopies: folders.map(\.nodes),
                                   fileCopies: files.map(\.nodes),
                                   thresholds: thresholds, excluding: excluding)
        }
    }

    /// A suggestion never deletes. It fills the selection and hands over to the
    /// same confirmation list a hand-made selection ends up in.
    func review(_ suggestion: CleanupSuggestion) {
        guard !suggestion.nodes.isEmpty else { return }
        showCleanup = false
        checked = Set(suggestion.nodes)
        Telemetry.record("cleanup.review", ["kind": .text(suggestion.kind.rawValue),
                                            "items": .int(Int64(suggestion.itemCount)),
                                            "bytes": .int(suggestion.bytes)])
        // A copy suggestion is judged against the groups it came from, so the
        // review can show which copy it proposes keeping.
        requestBulkTrash(groups: suggestion.groups)
    }

    // MARK: - Finding one thing

    /// The filter box narrows the folder being browsed, which answers "what is
    /// in here". This answers "where is that", over the whole tree.
    func openFind() {
        showFind = true
        if !findText.isEmpty { runFind() }
    }

    func runFind() {
        guard let tree else { return }
        let needle = findText
        guard needle.trimmingCharacters(in: .whitespaces).count >= 2 else {
            findResults = []; findTotal = 0; findSearching = false
            return
        }
        findSearching = true
        let limit = 300
        findTask?.cancel()
        findTask = Task { [weak self] in
            // A search over nine million names costs about two tenths of a
            // second, which is fine once and wasteful on every keystroke.
            // Waiting for the typing to settle is cheaper than cancelling
            // work that has already started.
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let (found, total) = await Task.detached(priority: .userInitiated) {
                tree.withStore { store in
                    let all = Find.search(store: store, needle: needle, limit: .max)
                    return (Array(all.prefix(limit)), all.count)
                }
            }.value
            guard !Task.isCancelled, let self, self.findText == needle else { return }
            self.findResults = found
            self.findTotal = total
            self.findSearching = false
        }
    }

    /// Show a found item where it lives: open its folder, put the selection on
    /// it, and leave the sheet. Finding something and being told only its path
    /// would make the user do the navigating twice.
    func focus(_ item: FoundItem) {
        guard let tree else { return }
        let parent = tree.withStore { store -> Int32 in
            guard item.node > 0, item.node < Int32(store.count) else { return 0 }
            return store.parent[Int(item.node)]
        }
        showFind = false
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
        select(item.node)
        scrollTo = item.node
    }

    /// The row the list should bring into view. Cleared once it has.
    @Published var scrollTo: Int32?

    // MARK: - Handing the result to another program

    /// Writes the scan as JSON another program can read.
    ///
    /// The same document the `diskmap` command prints, so a script and a person
    /// get the same shape. Cleanup suggestions ride along when they have
    /// already been worked out; copies do not, because finding them is a second
    /// pass and a save dialog is the wrong place to spend a minute. The command
    /// line takes --duplicates for that.
    func exportResults() {
        guard let tree, let stats else {
            toast = L10n.shared[.nothingToExport]
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultExportName()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let volumes = targetedVolumes
        let suggestions = self.suggestions
        let document = tree.withStore { store -> Data? in
            var doc = Export.document(store: store, stats: stats, volumes: volumes)
            if !suggestions.isEmpty {
                Export.addSuggestions(to: &doc, store: store, suggestions: suggestions)
            }
            return try? Export.encode(doc)
        }
        guard let document else {
            toast = L10n.shared[.exportFailed]
            return
        }
        do {
            try document.write(to: url, options: .atomic)
            toast = L10n.shared.exportedTo(url.lastPathComponent, shortBytes(Int64(document.count)))
        } catch {
            toast = L10n.shared[.exportFailed]
        }
    }

    private func defaultExportName() -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let label = rootLabel.replacingOccurrences(of: "/", with: "-")
        return "diskmap-\(label)-\(stamp.string(from: Date())).json"
    }

    func showTrashInFinder() {
        FileActions.revealInFinder([URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")])
    }

    // MARK: - Bulk trash

    func requestBulkTrash(groups: [[Int32]]? = nil) {
        guard tree != nil, !checked.isEmpty else {
            toast = L10n.shared[.nothingToRemove]
            return
        }
        reviewGroups = groups ?? matchGroups
        rebuildReview()
        if reviewing?.isEmpty == true {
            cancelBulkTrash()
            toast = L10n.shared[.allExcluded]
        }
    }

    private func rebuildReview() {
        guard let tree else { return }
        reviewing = tree.withStore {
            TrashPlanner.review(store: $0, selected: checked, groups: reviewGroups,
                                syncRoots: syncRoots, excluded: excludedPaths)
        }
        refreshReviewPlan()
    }

    /// Recomputed on every tick, so the total at the bottom is always the total
    /// of what is ticked right now.
    func refreshReviewPlan() {
        guard let tree else { return }
        switch tree.withStore({
            TrashPlanner.plan(store: $0, selected: checked, groups: reviewGroups,
                              syncRoots: syncRoots, excluded: excludedPaths)
        }) {
        case .success(let plan): reviewPlan = plan; reviewRefusal = nil
        case .failure(let refusal): reviewPlan = nil; reviewRefusal = refusal
        }
    }

    func cancelBulkTrash() {
        reviewing = nil
        reviewPlan = nil
        reviewRefusal = nil
    }

    var reviewRefusalText: String? { reviewRefusal.map(localizedRefusal) }

    /// Re-plans from the tree as it is now and acts only if that matches what
    /// was on screen. Between showing the list and pressing the button the disk
    /// can move, and a stale plan is a plan to delete the wrong thing.
    func confirmBulkTrash() {
        guard let tree, let approved = reviewPlan else { return }

        let fresh = tree.withStore {
            TrashPlanner.plan(store: $0, selected: checked, groups: reviewGroups,
                              syncRoots: syncRoots, excluded: excludedPaths)
        }
        guard case .success(let plan) = fresh else {
            if case .failure(let refusal) = fresh { toast = localizedRefusal(refusal) }
            return
        }
        guard Set(plan.items.map(\.node)) == Set(approved.items.map(\.node)) else {
            Telemetry.problem("bulk.stale", "the tree changed between preview and confirmation")
            toast = L10n.shared[.selectionChanged]
            reviewing = tree.withStore {
                TrashPlanner.review(store: $0, selected: checked, groups: reviewGroups,
                                    syncRoots: syncRoots, excluded: excludedPaths)
            }
            reviewPlan = plan
            return
        }
        cancelBulkTrash()
        performTrash(plan.items.map { (URL(fileURLWithPath: $0.path), $0.node, $0.bytes) },
                     label: L10n.shared.freedBytes(shortBytes(plan.bytes)))
    }

    private func localizedRefusal(_ refusal: TrashRefusal) -> String {
        switch refusal {
        case .nothingSelected: L10n.shared[.nothingToRemove]
        case .wouldRemoveEveryCopy(let name): L10n.shared.wouldRemoveEveryCopy(name)
        case .includesAScanRoot: L10n.shared[.cannotRemoveScanRoot]
        case .outsideTheScannedTree: L10n.shared[.cannotRemoveOutside]
        }
    }

    // MARK: - Deep verification

    /// Reads every file in the match and compares the contents, which is the
    /// only way to answer "are these really the same". Off by default because
    /// it costs the bytes; the button says how many before you press it.
    func verifyMatch(id: Int64, nodes: [Int32]) {
        guard let tree, verifications[id]?.running != true else { return }
        let plan = tree.withStore { DeepVerify.plan(store: $0, nodes: nodes) }
        let token = CancelToken()
        verifyTokens[id] = token
        verifications[id] = VerifyStatus(read: 0, total: plan.bytes)

        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) { () -> VerifyOutcome in
                DeepVerify.run(plan, cancel: token) { read in
                    Task { @MainActor [weak self] in
                        guard self?.verifications[id]?.running == true else { return }
                        self?.verifications[id]?.read = read
                    }
                }
            }.value
            guard let self else { return }
            self.verifyTokens[id] = nil
            self.verifications[id]?.read = plan.bytes
            self.verifications[id]?.outcome = outcome
        }
    }

    func cancelVerify(id: Int64) {
        verifyTokens[id]?.cancel()
        verifyTokens[id] = nil
    }

    func cancelAllVerifications() {
        for token in verifyTokens.values { token.cancel() }
        verifyTokens.removeAll()
        verifications.removeAll()
    }

    /// Blocking scan used by the offscreen renderer.
    func scanSynchronously() {
        var options = ScanOptions(roots: scanTargets)
        options.threadCount = min(12, ProcessInfo.processInfo.activeProcessorCount)
        adopt(LiveTree(result: DiskScanner().scan(options)))
    }

    // MARK: - Comparing two folders

    /// Which of the three screens the comparison sheet is showing.
    ///
    /// Pages rather than nested sheets: all three are the same size, so moving
    /// between them moves nothing on screen.
    enum ComparePage { case diff, plan, result }

    func openCompare(left: String? = nil, right: String? = nil) {
        if let left { compareLeft = left }
        if let right { compareRight = right }
        comparePage = .diff
        showCompare = true
        if !compareLeft.isEmpty, !compareRight.isEmpty { runComparison() }
    }

    /// Opens the sheet with one side already filled in, from a folder in the
    /// tree or from one of the copies the app found.
    func compareWith(_ node: Int32) {
        guard let tree, let path = tree.withStore({ store -> String? in
            guard node >= 0, node < Int32(store.count) else { return nil }
            return store.path(node)
        }) else { return }
        compareLeft = path
        compareRight = ""
        folderComparison = nil
        compareRefusal = nil
        comparePage = .diff
        showCompare = true
        chooseCompareSide(.right)
    }

    func chooseCompareSide(_ side: Side) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.shared[.compareChoose]
        panel.message = L10n.shared[.compareChooseMessage]
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        if side == .left { compareLeft = url.path } else { compareRight = url.path }
        if !compareLeft.isEmpty, !compareRight.isEmpty { runComparison() }
    }

    func swapCompareSides() {
        let held = compareLeft
        compareLeft = compareRight
        compareRight = held
        if !compareLeft.isEmpty, !compareRight.isEmpty { runComparison() }
    }

    var canCompare: Bool { !compareLeft.isEmpty && !compareRight.isEmpty && !comparing }

    func runComparison() {
        guard !compareLeft.isEmpty, !compareRight.isEmpty else { return }
        cancelComparison()
        compareGeneration += 1
        let generation = compareGeneration
        let left = compareLeft, right = compareRight
        let token = CancelToken()
        compareCancel = token

        folderComparison = nil
        compareRefusal = nil
        compareVerification = nil
        syncPlan = nil
        syncOutcome = nil
        comparing = true
        comparePage = .diff

        let options = compareOptions
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                FolderDiff.compare(left: left, right: right, options: options, cancel: token)
            }.value
            guard let self, self.compareGeneration == generation else { return }
            self.comparing = false
            self.compareCancel = nil
            switch outcome {
            case .success(let comparison):
                self.folderComparison = comparison
                self.compareLeft = comparison.left
                self.compareRight = comparison.right
                self.openTheDifferences(comparison.tree)
                self.compareSkipped = []
                self.rebuildSkippedPrefix(comparison)
                self.rebuildCompareRows()
                self.rememberPair(comparison.left, comparison.right)
            case .failure(let refusal):
                self.compareRefusal = refusal
            }
        }
    }

    /// At most this many rows reach the screen. A folder pair can disagree
    /// about a million names and no one reads a million rows, but the count of
    /// what is not shown has to be on screen or the list reads as the whole
    /// answer. The plan is always built from every entry, never from these.
    static let compareRowLimit = 2000

    func rebuildCompareRows() {
        guard let tree = folderComparison?.tree else {
            compareRows = []; compareRowsOmitted = 0; return
        }
        var rows: [Int32] = []
        appendCompareRows(tree, 0, into: &rows)
        compareRowsOmitted = max(0, rows.count - Self.compareRowLimit)
        compareRows = Array(rows.prefix(Self.compareRowLimit))
    }

    /// The visible frontier: the children of the root, and of everything open
    /// below it, in the order the tree holds them — biggest first within each
    /// folder.
    private func appendCompareRows(_ tree: DiffTree, _ id: Int32, into rows: inout [Int32]) {
        for child in tree.children(of: id) {
            guard compareExpanded.contains(child), tree.isExpandable(child) else {
                if showsCompareRow(tree, child) { rows.append(child) }
                continue
            }
            // An open folder is judged on what is under it: if the filter
            // emptied it and the folder is not itself a match, it goes too,
            // rather than sitting there as a row that leads nowhere.
            let start = rows.count
            rows.append(child)
            appendCompareRows(tree, child, into: &rows)
            if rows.count == start + 1, !showsCompareRow(tree, child) { rows.removeLast() }
        }
    }

    /// A closed folder is judged on itself; the kind filter keeps it when its
    /// subtree could hold a match, so the way in is never hidden. The date
    /// filter has no such escape — what is under a closed folder was never
    /// paired up, so there are no two dates to compare — and judging it on its
    /// own pair of dates is the honest reading of the row on screen.
    private func showsCompareRow(_ tree: DiffTree, _ id: Int32) -> Bool {
        guard !compareFilter.mask.isDisjoint(with: tree.contains(id)) else { return false }
        return dateFilter.accepts(tree, id)
    }

    // MARK: - Which decisions are in

    private func rebuildSkippedPrefix(_ comparison: FolderComparison) {
        skippedPrefix = [Int](repeating: 0, count: comparison.entries.count + 1)
        for index in comparison.entries.indices {
            skippedPrefix[index + 1] = skippedPrefix[index] + (compareSkipped.contains(index) ? 1 : 0)
        }
    }

    /// Whether a row is all in, all out, or somewhere between.
    ///
    /// Counted from a prefix sum rather than by walking the run, because a
    /// folder can stand for a hundred thousand decisions and this is asked once
    /// per visible row on every redraw.
    enum RowInclusion { case all, none, some }

    func compareInclusion(_ tree: DiffTree, _ id: Int32) -> RowInclusion {
        let range = tree.decisions(id)
        guard !range.isEmpty, range.upperBound < skippedPrefix.count else { return .all }
        let out = skippedPrefix[range.upperBound] - skippedPrefix[range.lowerBound]
        if out == 0 { return .all }
        return out == range.count ? .none : .some
    }

    /// Ticking a folder takes everything it stands for with it, which is the
    /// only reading that makes sense: the row is the decision.
    func toggleCompareInclusion(_ tree: DiffTree, _ id: Int32) {
        guard let comparison = folderComparison else { return }
        let range = tree.decisions(id)
        guard !range.isEmpty else { return }
        let putBackIn = compareInclusion(tree, id) != .all
        for decision in range {
            if putBackIn { compareSkipped.remove(decision) } else { compareSkipped.insert(decision) }
        }
        rebuildSkippedPrefix(comparison)
    }

    func includeEveryDecision() {
        guard let comparison = folderComparison else { return }
        compareSkipped = []
        rebuildSkippedPrefix(comparison)
    }

    func includeNoDecision() {
        guard let comparison = folderComparison else { return }
        compareSkipped = Set(comparison.entries.indices)
        rebuildSkippedPrefix(comparison)
    }

    var compareIncludedCount: Int {
        (folderComparison?.entries.count ?? 0) - compareSkipped.count
    }

    func toggleCompareExpanded(_ id: Int32) {
        if compareExpanded.contains(id) { compareExpanded.remove(id) }
        else { compareExpanded.insert(id) }
        rebuildCompareRows()
    }

    func isCompareExpanded(_ id: Int32) -> Bool { compareExpanded.contains(id) }

    /// Opens the folders the comparison itself had to walk into — the ones that
    /// differ — so the screen starts on the differences instead of on a closed
    /// root. Everything it stopped at stays shut, which is the point of having
    /// stopped.
    func openTheDifferences(_ tree: DiffTree) {
        var open = Set<Int32>()
        for id in 0..<Int32(tree.count) where tree.isOpen(id) && tree.isExpandable(id) {
            open.insert(id)
        }
        compareExpanded = open
    }

    /// What each chip would show, in items rather than rows — the same measure
    /// the key has always used.
    func compareCount(_ filter: CompareFilter) -> Int? {
        guard let s = folderComparison?.summary else { return nil }
        switch filter {
        case .differences: return s.differences
        case .all: return s.differences + s.identical
        case .identical: return s.identical
        case .differs: return s.differing
        case .onlyLeft: return s.onlyLeft
        case .onlyRight: return s.onlyRight
        case .typeClash: return s.typeClashes
        }
    }

    /// True when one side holds nothing the other does not, which is the only
    /// state in which "delete the redundant copy" is a safe sentence.
    func isRedundant(_ side: Side) -> Bool {
        guard let comparison = folderComparison else { return false }
        return comparison.summary.isCoveredByTheOtherSide(side)
    }

    func cancelComparison() {
        compareCancel?.cancel()
        compareCancel = nil
        comparing = false
    }

    /// The check the comparison itself will not do: reads both sides of
    /// everything it called identical, because the same length is not the same
    /// bytes.
    func verifyComparison() {
        guard let comparison = folderComparison, !compareVerifying else { return }
        let token = CancelToken()
        compareCancel = token
        compareVerifying = true
        compareVerifyBytes = 0
        compareVerification = nil

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                FolderDiff.verify(comparison, cancel: token) { read in
                    Task { @MainActor [weak self] in self?.compareVerifyBytes = read }
                }
            }.value
            guard let self else { return }
            self.compareVerifying = false
            self.compareCancel = nil
            self.compareVerification = result
            self.folderComparison?.verifiedAt = Date()
        }
    }

    func cancelCompareVerify() {
        compareCancel?.cancel()
        compareCancel = nil
        compareVerifying = false
    }

    /// Builds the plan and shows it. Nothing is written until it is read.
    func previewSync() {
        guard let comparison = folderComparison else { return }
        apply(SyncPlanner.plan(comparison, direction: syncDirection,
                               syncRoots: syncRoots, excluded: excludedPaths,
                               skipping: compareSkipped,
                               contentCheck: compareVerification))
    }

    /// The whole of one side to the Trash, once the other holds everything it
    /// does. The planner refuses when that is not true.
    func previewRemoveRedundant(_ side: Side) {
        guard let comparison = folderComparison else { return }
        apply(SyncPlanner.removeRedundant(
            comparison, side: side, syncRoots: syncRoots, excluded: excludedPaths,
            contentCheck: compareVerification))
    }

    private func apply(_ result: Result<SyncPlan, CompareRefusal>) {
        switch result {
        case .success(let plan):
            syncPlan = plan
            compareRefusal = nil
            comparePage = .plan
        case .failure(let refusal):
            syncPlan = nil
            compareRefusal = refusal
        }
    }

    func backToComparison() {
        comparePage = .diff
        syncPlan = nil
        syncOutcome = nil
    }

    func runSync() {
        guard let plan = syncPlan, !syncRunning else { return }
        let token = CancelToken()
        compareCancel = token
        syncRunning = true
        syncOutcome = nil
        syncProgress = SyncProgress(stepsDone: 0, stepsTotal: plan.steps.count,
                                    bytesWritten: 0, currentPath: "")
        comparePage = .result

        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                SyncRunner.run(plan, cancel: token) { progress in
                    Task { @MainActor [weak self] in self?.syncProgress = progress }
                }
            }.value
            guard let self else { return }
            self.syncRunning = false
            self.compareCancel = nil
            self.syncOutcome = outcome
            // The folders are as they are now, so anything on screen about how
            // they used to differ is stale. Measure again rather than let the
            // old figures stand.
            self.folderComparison = nil
            self.compareVerification = nil
        }
    }

    func cancelSync() {
        compareCancel?.cancel()
        compareCancel = nil
    }

    func revealTrashedBySync() {
        guard let outcome = syncOutcome else { return }
        FileActions.revealInFinder(outcome.trashed.compactMap(\.trashURL))
    }

    func closeCompare() {
        cancelComparison()
        cancelCompareVerify()
        showCompare = false
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
        // Asked before the sheet, not after: being told a folder is a scan root
        // is only useful while it is still a question. The plan is made again
        // at the moment of the click, because the sheet can sit open for a
        // while and the disk does not wait.
        guard let candidate = planOne(node) else { return }
        if candidate.isDirectory || candidate.bytes >= 5_000_000_000 {
            pendingTrash = PendingTrash(node: candidate.node, name: candidate.name,
                                        bytes: candidate.bytes,
                                        itemCount: candidate.itemCount,
                                        isDirectory: candidate.isDirectory)
        } else {
            performTrash(node)
        }
    }

    /// One node through the same planner every other route to the Trash uses,
    /// or nil with the reason on screen.
    ///
    /// This path used to check only that the id was in range and not marked
    /// removed, and go. A scan root is node zero *only in a single-root scan* —
    /// scan several folders and each root is a node above zero, so one
    /// right-click would have taken a whole scanned folder. The never-touch
    /// list was not consulted here at all.
    ///
    /// No groups: the never-empty-a-group rule protects a bulk selection from
    /// wiping a set of copies, and somebody pointing at one file is not making
    /// that mistake.
    private func planOne(_ node: Int32) -> TrashCandidate? {
        guard let tree else { return nil }
        let outcome = tree.withStore {
            TrashPlanner.plan(store: $0, selected: [node],
                              syncRoots: syncRoots, excluded: excludedPaths)
        }
        switch outcome {
        case .failure(let refusal):
            toast = localizedRefusal(refusal)
            return nil
        case .success(let plan):
            if let item = plan.items.first { return item }
            // Dropped rather than refused. The planner tells the two apart, and
            // silence here would look exactly like a Trash that worked.
            if plan.excluded > 0 {
                toast = L10n.shared[.refuseExcluded]
            } else {
                // Gone between the menu opening and the click, so its path may
                // belong to something else entirely by now.
                Telemetry.problem("trash", "target no longer exists")
                toast = L10n.shared[.itemGone]
                rebuild()
            }
            return nil
        }
    }

    func confirmPendingTrash() {
        guard let p = pendingTrash else { return }
        pendingTrash = nil
        performTrash(p.node)
    }

    private func performTrash(_ node: Int32) {
        guard let item = planOne(node) else { return }
        performTrash([(url: URL(fileURLWithPath: item.path), node: item.node, bytes: item.bytes)],
                     label: L10n.shared.freedBytes(shortBytes(item.bytes)))
    }

    /// The one place anything is moved to the Trash. Everything above it
    /// decides *what*; this decides nothing.
    private func performTrash(_ targets: [(url: URL, node: Int32, bytes: Int64)], label: String) {
        guard let tree, !targets.isEmpty else { return }
        // Each target carries what the tree last saw of it, so the one place
        // anything is moved to the Trash can check that it is still that thing.
        let described: [FileActions.Target] = tree.withStore { store in
            // A node the tree does not have is a node nothing can vouch for,
            // so it is dropped rather than trashed on no description at all.
            targets.compactMap { t -> FileActions.Target? in
                guard t.node > 0, t.node < Int32(store.count) else { return nil }
                let folder = store.isDirectory(t.node)
                return FileActions.Target(
                    url: t.url, node: t.node, bytes: t.bytes, isFolder: folder,
                    length: folder ? -1 : store.totalLogical[Int(t.node)],
                    modified: store.mtime[Int(t.node)])
            }
        }
        do {
            let (trashed, failures) = try FileActions.moveToTrash(described)
            for item in trashed {
                // Reflect it now; the FSEvents relist that follows is a no-op.
                tree.markRemoved(item.node)
                checked.remove(item.node)
                if selection == item.node { select(nil) }
            }
            if !trashed.isEmpty {
                undoStack.append(TrashBatch(items: trashed))
                Telemetry.record("action.trash", [
                    "items": .int(Int64(trashed.count)),
                    "physical": .int(trashed.reduce(0) { $0 + $1.bytesFreed }),
                ])
            }
            if let first = failures.first {
                Telemetry.problem("trash", first.errorDescription ?? "unknown",
                                  ["failed": .int(Int64(failures.count))])
                toast = failures.count == 1
                    ? (first.errorDescription ?? "")
                    : L10n.shared.someCouldNotBeTrashed(failures.count, trashed.count)
            } else {
                toast = label
            }
            refreshVolume()
            rebuild()
            if panel != .contents { refreshSummary() }
        } catch {
            Telemetry.problem("trash", error.localizedDescription)
            toast = error.localizedDescription
        }
    }

    /// Undoes the whole batch, because that is what was done.
    func undoLastTrash() {
        guard let batch = undoStack.popLast() else { return }
        var restored = 0
        var lastFailure: String?
        var stillInTheTrash: [TrashedItem] = []
        for item in batch.items {
            do { try FileActions.restore(item); restored += 1 }
            catch {
                lastFailure = error.localizedDescription
                stillInTheTrash.append(item)
            }
        }
        // Whatever did not come back is still in the Trash and still belongs
        // somewhere, and this app was the only thing that knew where. Dropping
        // the batch on a failure spent the undo without doing it — put the
        // remainder back so a second press can try again once whatever was in
        // the way is out of it.
        if !stillInTheTrash.isEmpty { undoStack.append(TrashBatch(items: stillInTheTrash)) }

        // Only the folders that actually got something back need re-reading.
        var parents = Set<String>()
        for item in batch.items { parents.insert(item.originalURL.deletingLastPathComponent().path) }
        for parent in parents { tree?.refresh(directory: parent) }

        if let lastFailure, restored < batch.items.count {
            Telemetry.problem("undo", lastFailure,
                              ["restored": .int(Int64(restored)),
                               "of": .int(Int64(batch.items.count))])
            toast = restored == 0
                ? L10n.shared.couldNotRestore(lastFailure)
                : L10n.shared.restoredSome(restored, batch.items.count)
        } else {
            Telemetry.record("action.undo", ["items": .int(Int64(restored))])
            toast = batch.items.count == 1
                ? L10n.shared.restored(batch.items[0].originalURL.lastPathComponent)
                : L10n.shared.restoredCount(restored)
        }
        refreshVolume()
        rebuild()
        if panel != .contents { refreshSummary() }
    }

}
