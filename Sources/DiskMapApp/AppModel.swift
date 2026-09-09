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

    /// Where the space went: the folder being looked at, the rows under it,
    /// the selection and the three layout caches. Re-emitted like the rest, so
    /// every view that reads `model.rows` did not have to be re-pointed for the
    /// move; a pane that only draws the map can observe this object directly.
    lazy var map = MapModule(session: session)
    private var mapRelay: AnyCancellable?

    var currentDirectory: Int32 {
        get { map.currentDirectory } set { map.currentDirectory = newValue }
    }
    var expanded: Set<Int32> {
        get { map.expanded } set { map.expanded = newValue }
    }
    var breadcrumb: [(id: Int32, name: String)] { map.breadcrumb }
    var rows: [Row] { map.rows }
    var selection: Int32? {
        get { map.selection } set { map.selection = newValue }
    }
    var selectedInfo: ItemInfo? {
        get { map.selectedInfo } set { map.selectedInfo = newValue }
    }
    var usePhysicalSize: Bool {
        get { map.usePhysicalSize } set { map.usePhysicalSize = newValue }
    }
    var filterText: String {
        get { map.filterText } set { map.filterText = newValue }
    }
    /// Which picture is in front, and which table.
    ///
    /// Both were stored choices and are now questions about the layout: there
    /// is no single current picture when three of them can be on screen at
    /// once. Kept in the old vocabulary because "show me the ring chart" is
    /// still a thing to say — from a menu, from the offscreen renderer, from a
    /// test — and it still means put that one in front.
    var visualization: Visualization {
        get { map.visiblePanes.compactMap(\.visualization).first ?? .treemap }
        set { showPane(PaneKind(newValue)) }
    }
    var colourMode: ColourMode {
        get { map.colourMode } set { map.colourMode = newValue }
    }
    var panel: PanelMode {
        get { map.visiblePanes.compactMap(\.panel).first ?? .contents }
        set { showPane(PaneKind(newValue)) }
    }

    // MARK: - Arranging the panes

    /// Every change to the layout goes through one of these, so a click on a
    /// tab and a choice in a menu cannot disagree, and so the one thing the
    /// layout does not know about — that a report has to be recomputed when a
    /// different pane comes forward — is decided in one place.
    func showPane(_ kind: PaneKind) {
        map.show(kind)
        refreshSummary()
    }

    func addPane(_ kind: PaneKind, to leaf: UUID) {
        map.dock.insert(kind, into: leaf, edge: nil)
        refreshSummary()
    }

    func closePane(_ kind: PaneKind) {
        map.dock.remove(kind)
    }

    func movePane(_ kind: PaneKind, to leaf: UUID, edge: DockEdge?) {
        map.dock.move(kind, to: leaf, edge: edge)
        refreshSummary()
    }

    func setDockRatio(_ split: UUID, _ ratio: Double) {
        map.dock.setRatio(split, ratio)
    }
    /// The row the list should bring into view. Cleared once it has.
    var scrollTo: Int32? {
        get { map.scrollTo } set { map.scrollTo = newValue }
    }
    var revision: Int { map.revision }
    var layoutToken: Int { map.layoutToken }
    var layoutCache: LayoutStore<TreemapLayout> { map.layoutCache }
    var sunburstCache: LayoutStore<SunburstLayout> { map.sunburstCache }
    var icicleCache: LayoutStore<IcicleLayout> { map.icicleCache }

    func enter(_ node: Int32) { map.enter(node) }
    func goUp() { map.goUp() }
    func goBack() { map.goBack() }
    func goForward() { map.goForward() }
    var canGoBack: Bool { map.canGoBack }
    var canGoForward: Bool { map.canGoForward }
    func toggleExpanded(_ node: Int32) { map.toggleExpanded(node) }
    func select(_ node: Int32?) { map.select(node) }
    func rebuild() { map.rebuild() }
    func layoutKey(_ kind: Visualization, size: CGSize) -> String {
        map.layoutKey(kind, size: size)
    }
    func cachedLayout(for size: CGSize) -> TreemapLayout? { map.cachedLayout(for: size) }
    func cachedSunburst(for size: CGSize) -> SunburstLayout? { map.cachedSunburst(for: size) }
    func cachedIcicle(for size: CGSize) -> IcicleLayout? { map.cachedIcicle(for: size) }
    @discardableResult
    func computeLayoutSync(size: CGSize) -> TreemapLayout? { map.computeLayoutSync(size: size) }
    @discardableResult
    func computeSunburstSync(size: CGSize) -> SunburstLayout? { map.computeSunburstSync(size: size) }
    @discardableResult
    func computeIcicleSync(size: CGSize) -> IcicleLayout? { map.computeIcicleSync(size: size) }
    func relayout(_ kind: Visualization, size: CGSize) async {
        await map.relayout(kind, size: size)
    }

    /// The name to show for a node, which for a root is its disk.
    func displayName(_ raw: String) -> String { session.displayName(raw) }
    var rootLabel: String { session.rootLabel }

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
    var suggestions: [CleanupSuggestion] { space.suggestions }
    // MARK: - Which tools are open

    /// Open tools, left to right. The map is always the first and cannot be
    /// closed: it is the scan itself rather than a tool over it.
    @Published private(set) var openTabs: [ModuleTab] = [.map]
    @Published var activeTab: ModuleTab = .map

    /// Opens a tool, or brings it forward if it is already open. Opening one no
    /// longer closes another, which is the entire reason these stopped being
    /// sheets.
    func open(_ tab: ModuleTab) {
        let wasClosed = !openTabs.contains(tab)
        if !openTabs.contains(tab) {
            openTabs.append(tab)
            openTabs.sort { ModuleTab.allCases.firstIndex(of: $0)! < ModuleTab.allCases.firstIndex(of: $1)! }
        }
        activeTab = tab
        // The copy report is a second walk and only runs for whoever wants it,
        // so opening the tool is what asks for it.
        if wasClosed, tab == .duplicates { refreshSummary() }
    }

    func close(_ tab: ModuleTab) {
        guard tab.isClosable else { return }
        // Whatever the tool had running stops with it, rather than carrying on
        // against a screen nobody can see.
        switch tab {
        case .compare: compare.close()
        case .search: search.clear()
        case .files: files.clear()
        default: break
        }
        openTabs.removeAll { $0 == tab }
        if activeTab == tab { activeTab = openTabs.last ?? .map }
    }

    @Published var showCompareIgnore = false

    /// Comparing two folders. The only module that needs no scan, which is why
    /// it should open from a cold launch once there is somewhere to open it.
    lazy var compare = CompareModule(settings: compareSettings)
    private var compareRelay: AnyCancellable?

    typealias ComparePage = CompareModule.ComparePage
    typealias RowInclusion = CompareModule.RowInclusion

    var compareLeft: String {
        get { compare.compareLeft } set { compare.compareLeft = newValue }
    }
    var compareRight: String {
        get { compare.compareRight } set { compare.compareRight = newValue }
    }
    var folderComparison: FolderComparison? { compare.folderComparison }
    var comparing: Bool { compare.comparing }
    var compareRefusal: CompareRefusal? { compare.compareRefusal }
    var comparePage: ComparePage {
        get { compare.comparePage } set { compare.comparePage = newValue }
    }
    var compareFilter: CompareFilter {
        get { compare.compareFilter } set { compare.compareFilter = newValue }
    }
    var dateFilter: DateFilter {
        get { compare.dateFilter } set { compare.dateFilter = newValue }
    }
    var syncDirection: SyncDirection {
        get { compare.syncDirection } set { compare.syncDirection = newValue }
    }
    var syncPlan: SyncPlan? { compare.syncPlan }
    var syncOutcome: SyncOutcome? { compare.syncOutcome }
    var syncRunning: Bool { compare.syncRunning }
    var syncProgress: SyncProgress? { compare.syncProgress }
    var compareVerification: VerifyDifferences? { compare.compareVerification }
    var compareVerifying: Bool { compare.compareVerifying }
    var compareVerifyBytes: Int64 { compare.compareVerifyBytes }
    var compareRows: [Int32] { compare.compareRows }
    var compareRowsOmitted: Int { compare.compareRowsOmitted }
    var compareExpanded: Set<Int32> { compare.compareExpanded }
    var compareSkipped: Set<Int> { compare.compareSkipped }

    /// Persisted across launches, and shared by every comparison rather than
    /// owned by one of them.
    let compareSettings = CompareSettings()
    private var compareSettingsRelay: AnyCancellable?

    var compareDateTolerance: Int {
        get { compareSettings.dateTolerance } set { compareSettings.dateTolerance = newValue }
    }
    var compareIgnore: [String] { compareSettings.ignore }
    var compareOptions: CompareOptions { compareSettings.options }
    var comparePairs: [(left: String, right: String)] { compareSettings.pairs }

    /// Adding or dropping a pattern changes what the answer on screen is, so
    /// the answer is worked out again rather than left standing as something
    /// the current settings would not produce. The settings object reports
    /// whether anything actually changed; deciding what to do about it is this
    /// object's business, not its.
    func addIgnorePattern(_ pattern: String) {
        if compareSettings.add(pattern), folderComparison != nil { compare.runComparison() }
    }

    func removeIgnorePattern(_ pattern: String) {
        if compareSettings.remove(pattern), folderComparison != nil { compare.runComparison() }
    }

    func resetIgnorePatterns() {
        compareSettings.reset()
        if folderComparison != nil { compare.runComparison() }
    }

    private func rememberPair(_ left: String, _ right: String) {
        compareSettings.remember(left, right)
    }
    private var compareCancel: CancelToken?
    private var compareGeneration = 0

    /// Finding one thing, and telling this scan apart from a stored one. Both
    /// re-emitted like the session, so their views did not have to be
    /// re-pointed for the move.
    let search = SearchModule()
    private var searchRelay: AnyCancellable?

    /// Every file at once, as a flat table. Re-emitted like the rest, so a view
    /// observing this object sees the table change without knowing there is a
    /// second object underneath.
    let files = FilesModule()
    private var filesRelay: AnyCancellable?
    var findText: String {
        get { search.text } set { search.text = newValue }
    }
    var findResults: [FoundItem] { search.results }
    var findTotal: Int { search.total }
    var findSearching: Bool { search.searching }

    // MARK: - The flat table

    /// Forwarded the way the comparison's settings are: a view binds to this
    /// object, and `$model.filesText` reaches the module without every screen
    /// having to know there is one.
    var filesText: String {
        get { files.text } set { files.text = newValue }
    }
    var filesKinds: Set<FileCategory> {
        get { files.categories } set { files.categories = newValue }
    }
    var filesSize: FilesModule.SizeBand {
        get { files.sizeBand } set { files.sizeBand = newValue }
    }
    var filesTime: FilesModule.TimeBand {
        get { files.timeBand } set { files.timeBand = newValue }
    }
    var filesShowFolders: Bool {
        get { files.includeFolders } set { files.includeFolders = newValue }
    }

    func reloadFiles() { files.reload(in: tree) }
    func resetFiles() { files.reset(in: tree) }
    func sortFiles(by key: FileSort) { files.sortBy(key, in: tree) }
    func showMoreFiles() { files.showMore(in: tree) }

    func clearFileFilters() {
        files.text = ""
        files.categories = []
        files.sizeBand = .any
        files.timeBand = .any
        files.includeFolders = false
        files.reset(in: tree)
    }

    var suggestionsLoading: Bool { space.loading }
    /// Sizes below which a suggestion is not worth making. A field rather than
    /// a constant so a fixture can exercise the screen without a gigabyte of
    /// files, and so it can become a preference later.
    /// Where the easy space is. Re-emitted like the session, so the sheet that
    /// reads `model.suggestions` did not have to be re-pointed for the move.
    let space = SpaceModule()
    private var spaceRelay: AnyCancellable?
    var cleanupThresholds: Cleanup.Thresholds {
        get { space.thresholds } set { space.thresholds = newValue }
    }
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
    lazy var changes = ChangesModule(snapshots: snapshots)
    private var changesRelay: AnyCancellable?
    /// What this scan looked like, kept so a comparison has a right-hand side
    /// without re-walking the tree.
    var currentDigest: DiskDigest? {
        get { changes.current } set { changes.current = newValue }
    }
    var history: [SnapshotStore.Entry] { changes.history }
    var comparison: DigestDiff? { changes.comparison }
    var comparingTo: String? { changes.comparingTo }
    /// The groups the open review is judged against — the panel's matches, or
    /// the ones a suggestion came from.
    private var reviewGroups: [[Int32]] = []
    /// Not a constant so the offscreen renderer can point it at a fixture; a
    /// warning nobody can render is a warning nobody has checked.
    var syncRoots = SyncRoots.detected()
    @Published var pendingTrash: PendingTrash?
    /// Asked before throwing a scan away. Measuring a whole disk is minutes of
    /// walking, every open tool goes with it, and so does the undo stack — the
    /// part nobody expects, because the items are still in the Trash and this
    /// was the only thing that knew where they came from.
    @Published var pendingNewScan = false
    @Published var hasFullDiskAccess = FileActions.hasFullDiskAccess()

    @AppStorage("appearance") var appearance: Appearance = .system {
        willSet { objectWillChange.send() }
    }


    /// What is in here, and what is in here twice. Re-emitted like the rest, so
    /// the panels that read `model.duplicates` did not have to be re-pointed
    /// for the move.
    let reports = ReportsModule()
    private var reportsRelay: AnyCancellable?

    /// Shared with the space module rather than owned by either: it caches a
    /// hash per folder against the tree's own revision, and two modules asking
    /// the same question of the same tree should not pay for it twice.
    private let signatureCache = SignatureCache()

    var summary: SubtreeSummary? {
        get { reports.summary } set { reports.summary = newValue }
    }
    var duplicates: [DuplicateEntry] {
        get { reports.duplicates } set { reports.duplicates = newValue }
    }
    var folderMatches: [FolderEntry] {
        get { reports.folderMatches } set { reports.folderMatches = newValue }
    }
    var largeFiles: [LargeFile] {
        get { reports.largeFiles } set { reports.largeFiles = newValue }
    }
    var summarizing: Bool {
        get { reports.summarizing } set { reports.summarizing = newValue }
    }
    var verifications: [Int64: VerifyStatus] {
        get { reports.verifications } set { reports.verifications = newValue }
    }
    var openMatches: Set<Int64> {
        get { reports.openMatches } set { reports.openMatches = newValue }
    }
    var matchGroups: [[Int32]] {
        get { reports.matchGroups } set { reports.matchGroups = newValue }
    }

    /// Offscreen rendering has no async phase, so layout must run inline.
    var renderMode = false

    var tree: LiveTree? { session.tree }

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
        spaceRelay = space.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        searchRelay = search.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        filesRelay = files.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        reportsRelay = reports.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        mapRelay = map.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        // Moving to another folder makes every open report stale. The map does
        // not know a report exists; this is where that is decided.
        map.onNavigated = { [weak self] in self?.refreshSummary() }
        // A tick refers to a node in the report that produced it — unless a
        // review is open, in which case it refers to a decision being made.
        reports.onLoaded = { [weak self] in
            guard let self, self.reviewing == nil else { return }
            self.checked = []
        }
        changesRelay = changes.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        compareSettingsRelay = compareSettings.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        compareRelay = compare.objectWillChange.sink { [weak self] in
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

    // MARK: - Scan targets

    /// Folders the user has added, ticked or not.
    ///
    /// A disk stays in the list whether or not it is ticked, because the list
    /// of disks is what is mounted. A folder had no such list: `scanTargets`
    /// was both the folders and the choice, so leaving one out of a scan meant
    /// deleting it and typing it in again next time. Now the two are separate
    /// for folders as well, and the × means forget it rather than skip it.
    @Published private(set) var addedFolders: [String] = []

    func addTargets(_ urls: [URL]) {
        for path in urls.map(\.path) where !addedFolders.contains(path) {
            addedFolders.append(path)
        }
        let candidates = scanTargets + urls.map(\.path)
        let normalized = RootSet.normalize(candidates)
        scanTargets = normalized.roots
        rejectedRoots = normalized.rejected
        refreshVolume()
    }

    /// True when this folder will be measured: ticked, or already inside
    /// something else that is.
    func isTargeted(folder path: String) -> Bool {
        scanTargets.contains(path) || coveringTarget(path) != nil
    }

    /// The ticked root that already contains this folder, if any. Adding a
    /// folder inside a ticked disk is absorbed by normalisation, so the row has
    /// to say it is covered rather than appear unticked while being measured.
    func coveringTarget(_ path: String) -> String? {
        scanTargets.first { $0 != path && TrashPlanner.isInside(path, $0) }
    }

    func toggle(folder path: String) {
        // Nothing to toggle while a ticked disk contains it: unticking here
        // would not leave it out, and pretending otherwise is worse than
        // saying so.
        guard coveringTarget(path) == nil else { return }
        if scanTargets.contains(path) {
            removeTarget(path)
        } else {
            addTargets([URL(fileURLWithPath: path)])
        }
    }

    /// Drops it from the list entirely, which is what the × has always meant.
    func forgetFolder(_ path: String) {
        addedFolders.removeAll { $0 == path }
        removeTarget(path)
    }

    func removeTarget(_ path: String) {
        scanTargets.removeAll { $0 == path }
        rejectedRoots = []
        refreshVolume()
    }

    func clearTargets() {
        scanTargets = []
        addedFolders = []
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
    /// Nothing to lose before a scan exists, so nothing to ask about.
    func requestNewScan() {
        if tree == nil { newScan() } else { pendingNewScan = true }
    }

    func newScan() {
        cancelScan()
        tree?.stopWatching()
        session.adopt(nil)
        liveActive = false
        stats = nil
        reconciliation = nil
        rejectedRoots = []
        rootsSpanVolumes = false
        map.clear()
        checked = []
        reviewing = nil
        space.clear()
        files.clear()
        reports.clear()
        reviewGroups = []
        // Was `currentDigest = nil`, which left the comparison, the entry it
        // was against and the history list standing. `openChanges` only
        // auto-compares when there is no comparison yet, so after a rescan the
        // screen kept showing a diff computed from the digest of a scan that no
        // longer existed — and kept skipping the one it should have made.
        changes.clear()
        // Trashed items are still in the Trash and still recoverable from
        // Finder; the app just can no longer be the one to put them back,
        // because "back" was a place in a tree that no longer exists.
        undoStack = []
        liveRefreshTask?.cancel()
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
        session.buildRootNames(live.roots)
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
        map.openAtTheRoot(of: live)
        phase = .ready
        rebuild()
        // The layout is restored from the last run, so a report pane can be in
        // front before anything has been clicked. Without this the app opens on
        // an empty "Largest" or "Types" and only fills it once the user touches
        // something — which reads as the scan having found nothing.
        refreshSummary()
    }

    private func treeChanged() {
        // Rebuilding rows and re-laying out a treemap nobody can see is pure
        // battery. The work is not skipped, it is deferred to the moment the
        // window is on screen again.
        guard windowIsVisible else { rebuildWhenVisible = true; return }
        refreshVolumeIfStale()
        rebuild()
        scheduleLiveRefresh()
    }

    private var liveRefreshTask: Task<Void, Never>?

    /// The tools that read the tree, brought up to date after it moved.
    ///
    /// The map rebuilds on every flush because that is cheap and it is what the
    /// user is looking at. These are whole-tree walks — the copy pass is a
    /// signature per folder — so they wait for the tree to stop moving first.
    /// FSEvents arrives in bursts, and a build running in a watched folder
    /// would otherwise start a walk, throw it away, and start another.
    private func scheduleLiveRefresh() {
        liveRefreshTask?.cancel()
        liveRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshLiveViews()
        }
    }

    /// Everything open that reads the tree. Each part decides for itself
    /// whether it is wanted: nothing here recomputes for a screen nobody has
    /// opened.
    func refreshLiveViews() {
        guard let tree else { return }
        refreshSummary()
        if openTabs.contains(.files) { files.reload(in: tree) }
        if openTabs.contains(.space) { reloadCleanup() }
    }

    /// Whole-subtree reports. The walk lives in the reports module; what stays
    /// here is the question only the app can answer — whether anything is
    /// showing one, and whether copies are part of it.
    func refreshSummary() {
        guard let tree, wantsAReport else { return }
        reports.load(tree: tree, root: currentDirectory, physical: usePhysicalSize,
                     includeDuplicates: wantsDuplicateReport, cache: signatureCache)
    }

    /// Who is asking for a report, and whether copies are part of it.
    ///
    /// This used to read the map's side panel and nothing else, which was true
    /// while the copy report only existed as one of that panel's four views.
    /// It is a tool of its own now, so the panel is one of two things that can
    /// want the answer.
    /// A pane in a background tab is not being looked at, so it does not get a
    /// walk of the whole subtree computed for it. `visiblePanes` is one per
    /// group — the one in front — which is exactly what the two segmented
    /// pickers used to mean.
    private var wantsAReport: Bool {
        map.visiblePanes.contains { $0 != .contents && $0.panel != nil }
            || openTabs.contains(.duplicates)
    }

    private var wantsDuplicateReport: Bool {
        map.visiblePanes.contains(.copies) || openTabs.contains(.duplicates)
    }

    /// Blocking report used by the offscreen renderer, which has no async pass.
    func refreshSummarySync() {
        guard let tree else { return }
        reports.loadSynchronously(tree: tree, root: currentDirectory,
                                  physical: usePhysicalSize,
                                  includeDuplicates: wantsDuplicateReport,
                                  cache: signatureCache)
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

    private func recordDigest(of live: LiveTree) {
        changes.record(live)
    }

    func openChanges() {
        open(.changes)
        report { try changes.loadHistory(tree: tree) }
    }

    func compare(with entry: SnapshotStore.Entry) {
        report { try changes.compare(with: entry, tree: tree) }
    }

    /// A module says a stored digest is unreadable by throwing; saying so on
    /// screen is this object's job, because the toast is shared and a module
    /// that writes to it directly is a module that cannot be opened twice.
    private func report(_ work: () throws -> Void) {
        do {
            try work()
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
        activeTab = .map
        enter(node)
    }

    // MARK: - Where the easy space is

    func openCleanup() {
        open(.space)
        reloadCleanup()
    }

    func reloadCleanup() {
        guard let tree else { return }
        space.load(tree: tree, root: currentDirectory,
                   cache: signatureCache, excluding: excludedPaths)
    }

    /// A suggestion never deletes. It fills the selection and hands over to the
    /// same confirmation list a hand-made selection ends up in.
    func review(_ suggestion: CleanupSuggestion) {
        guard !suggestion.nodes.isEmpty else { return }
        activeTab = .map
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
        open(.search)
        if !findText.isEmpty { runFind() }
    }

    func runFind() {
        guard let tree else { return }
        search.run(in: tree)
    }

    /// Show a found item where it lives: open its folder, put the selection on
    /// it, and leave the sheet. Finding something and being told only its path
    /// would make the user do the navigating twice.
    func focus(_ item: FoundItem) { focus(node: item.node) }

    func focus(node: Int32) {
        activeTab = .map
        map.reveal(node)
    }


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
            // The review can come back empty for more than one reason, and
            // cancelling drops the refusal that says which — so every one of
            // them used to report the never-touch list. Ticking a scan root
            // was answered with "everything picked is on the never-touch
            // list", which is not what happened and not what to do about it.
            let why = reviewRefusalText
            cancelBulkTrash()
            toast = why ?? L10n.shared[.allExcluded]
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

    func verifyMatch(id: Int64, nodes: [Int32]) {
        guard let tree else { return }
        reports.verifyMatch(id: id, nodes: nodes, tree: tree)
    }

    func cancelVerify(id: Int64) { reports.cancelVerify(id: id) }
    func cancelAllVerifications() { reports.cancelAllVerifications() }

    /// Blocking scan used by the offscreen renderer.
    func scanSynchronously() {
        var options = ScanOptions(roots: scanTargets)
        options.threadCount = min(12, ProcessInfo.processInfo.activeProcessorCount)
        adopt(LiveTree(result: DiskScanner().scan(options)))
    }

    // MARK: - Comparing two folders

    func openCompare(left: String? = nil, right: String? = nil) {
        open(.compare)
        compare.openCompare(left: left, right: right)
    }

    /// Opens the sheet with one side already filled in, from a folder in the
    /// tree or from one of the copies the app found.
    ///
    /// The one thing the comparison cannot do for itself: it reads two folders
    /// and holds no tree, so starting from a node in the scanned one is this
    /// object's job.
    func compareWith(_ node: Int32) {
        guard let tree, let path = tree.withStore({ store -> String? in
            guard node >= 0, node < Int32(store.count) else { return nil }
            return store.path(node)
        }) else { return }
        compareLeft = path
        compareRight = ""
        compare.clearResult()
        comparePage = .diff
        open(.compare)
        compare.chooseCompareSide(.right)
    }

    // Straight pass-throughs. The screens still observe this object, so they
    // keep calling it; re-pointing them at the module is a separate step and
    // deliberately not bundled with the move.
    var canCompare: Bool { compare.canCompare }
    var compareIncludedCount: Int { compare.compareIncludedCount }
    func runComparison() { compare.runComparison() }
    func cancelComparison() { compare.cancelComparison() }
    func chooseCompareSide(_ side: Side) { compare.chooseCompareSide(side) }

    /// Sets one side from a path that is already known — a drop, or a folder
    /// picked somewhere else in the app.
    ///
    /// A file resolves to the folder holding it. Dropping a file on a folder
    /// comparison is a near miss rather than a mistake, and refusing it teaches
    /// nothing.
    func setCompareSide(_ side: Side, _ url: URL) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path,
                                                    isDirectory: &isDirectory)
        guard exists else { return }
        let path = isDirectory.boolValue ? url.path : url.deletingLastPathComponent().path
        if side == .left { compareLeft = path } else { compareRight = path }
        compare.clearResult()
        if canCompare { runComparison() }
    }
    func swapCompareSides() { compare.swapCompareSides() }
    func rebuildCompareRows() { compare.rebuildCompareRows() }
    func openTheDifferences(_ tree: DiffTree) { compare.openTheDifferences(tree) }
    func compareCount(_ filter: CompareFilter) -> Int? { compare.compareCount(filter) }
    func compareInclusion(_ tree: DiffTree, _ id: Int32) -> RowInclusion {
        compare.compareInclusion(tree, id)
    }
    func toggleCompareInclusion(_ tree: DiffTree, _ id: Int32) {
        compare.toggleCompareInclusion(tree, id)
    }
    func includeEveryDecision() { compare.includeEveryDecision() }
    func includeNoDecision() { compare.includeNoDecision() }
    func toggleCompareExpanded(_ id: Int32) { compare.toggleCompareExpanded(id) }
    func isCompareExpanded(_ id: Int32) -> Bool { compare.isCompareExpanded(id) }
    func isRedundant(_ side: Side) -> Bool { compare.isRedundant(side) }
    func verifyComparison() { compare.verifyComparison() }
    func cancelCompareVerify() { compare.cancelCompareVerify() }
    func backToComparison() { compare.backToComparison() }
    func runSync() { compare.runSync() }
    func cancelSync() { compare.cancelSync() }
    func revealTrashedBySync() { compare.revealTrashedBySync() }

    func closeCompare() {
        close(.compare)
    }

    /// Both planners need the sync roots and the never-touch list, which are
    /// shared with everything else that removes files, so they are handed over
    /// rather than read from inside the comparison.
    func previewSync() {
        compare.previewSync(syncRoots: syncRoots, excluded: excludedPaths)
    }

    func previewRemoveRedundant(_ side: Side) {
        compare.previewRemoveRedundant(side, syncRoots: syncRoots, excluded: excludedPaths)
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
        // Everything is confirmed, whatever its size or kind. This used to send
        // a file under five gigabytes straight to the Trash on one click of a
        // context menu — the only route in the app that acted without saying
        // what it was about to do, and the one that is easiest to hit by
        // accident, since the item under the pointer when the menu opened is
        // not always the item the eye was on.
        pendingTrash = PendingTrash(node: candidate.node, name: candidate.name,
                                    bytes: candidate.bytes,
                                    itemCount: candidate.itemCount,
                                    isDirectory: candidate.isDirectory)
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
            // Was `if panel != .contents`, which is a narrower question than
            // the one that matters: the copy report is a tab of its own now, so
            // trashing something while it was open and the side panel happened
            // to be showing contents left the trashed row sitting in it,
            // tickable. `refreshLiveViews` asks each tool whether it is open.
            refreshLiveViews()
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
        refreshLiveViews()
    }

}
