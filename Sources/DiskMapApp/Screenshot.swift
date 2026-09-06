import AppKit
import DiskMapCore
import SwiftUI

/// Renders the real UI to a PNG without a window server or Screen Recording
/// permission, so the interface can be checked in CI or over SSH.
///
///   DISKMAP_RENDER="<paths>|<w>|<h>|<out.png>[|<subdir>[|light|dark[|en|tr]]]"
///
/// `paths` may be several folders separated by commas, which renders a
/// multi-folder scan. Prefix it with `start:` to render the start screen with
/// those folders queued instead of scanning them.
@MainActor
enum OffscreenRenderer {
    static func runIfRequested() -> Bool {
        guard let spec = ProcessInfo.processInfo.environment["DISKMAP_RENDER"] else { return false }
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4,
              let width = Double(parts[1]), let height = Double(parts[2]) else {
            FileHandle.standardError.write(Data("DISKMAP_RENDER needs path|w|h|out.png\n".utf8))
            return true
        }

        let model = AppModel()
        model.renderMode = true
        if parts.count >= 6, let mode = Appearance(rawValue: parts[5]) { model.appearance = mode }
        if parts.count >= 7, let lang = L10n.Language(rawValue: parts[6]) {
            L10n.shared.preference = lang
        }

        let startOnly = parts[0].hasPrefix("start:")
        let targetSpec = startOnly ? String(parts[0].dropFirst("start:".count)) : parts[0]
        let paths = targetSpec.split(separator: ",").map(String.init)

        model.clearTargets()
        model.addTargets(paths.map { URL(fileURLWithPath: $0) })
        if let first = paths.first { model.selectedVolumePath = first }
        model.refreshVolume()
        if !startOnly { model.scanSynchronously() }

        if parts.count >= 5, !parts[4].isEmpty, let tree = model.tree {
            // Accept either a path relative to the first root or an absolute one.
            let target = parts[4].hasPrefix("/")
                ? parts[4]
                : (parts[0] == "/" ? "" : parts[0]) + "/" + parts[4]
            if let node = tree.withStore({ $0.find(path: target) }) {
                model.enter(node)
            }
        }
        let env = ProcessInfo.processInfo.environment
        if let v = env["DISKMAP_VIEW"], let mode = Visualization(rawValue: v) { model.visualization = mode }
        if let c = env["DISKMAP_COLOUR"], let mode = ColourMode(rawValue: c) { model.colourMode = mode }
        if let p = env["DISKMAP_PANEL"], let mode = PanelMode(rawValue: p) {
            model.panel = mode
            model.refreshSummarySync()
        }
        // After the report, or there is nothing to open yet.
        if env["DISKMAP_EXPAND"] != nil, let first = model.folderMatches.first {
            model.openMatches.insert(first.id)
        }

        // Open the two largest folders so the render shows the tree nesting.
        for _ in 0..<2 {
            if let folder = model.rows.first(where: { $0.hasChildren && !$0.isExpanded }) {
                model.toggleExpanded(folder.id)
            }
        }
        if let biggest = model.rows.first { model.select(biggest.id) }

        let scheme: ColorScheme = model.appearance == .dark ? .dark : .light

        // A sheet cannot be captured through the window it sits over, and the
        // trash confirmation is the one screen that must be checked rather than
        // assumed. Rendering it directly is the only way to see it here.
        let view: AnyView
        if let home = env["DISKMAP_SYNC_HOME"] { model.syncRoots = SyncRoots.detected(home: home) }
        if let floor = env["DISKMAP_CLEANUP_MIN"].flatMap(Int64.init) {
            var t = Cleanup.Thresholds()
            t.suggestion = floor; t.installer = floor; t.staleFile = floor
            model.cleanupThresholds = t
        }
        if let history = env["DISKMAP_HISTORY_DIR"] {
            model.snapshots = SnapshotStore(directory: URL(fileURLWithPath: history))
        }
        if env["DISKMAP_SHEET"] == "reconciliation", let v = model.volume {
            // The one screen whose whole job is to be understood at a glance,
            // and the one that cannot be seen through the window it sits over.
            view = AnyView(ReconciliationSheet(volume: v, reconciliation: model.reconciliation,
                                               stats: model.stats, renderMode: true)
                .environment(\.colorScheme, scheme))
        } else if env["DISKMAP_SHEET"] == "exclusions" {
            model.excludedPaths = (env["DISKMAP_EXCLUDED"] ?? "").split(separator: ":").map(String.init)
            view = AnyView(ExclusionsView(model: model).environment(\.colorScheme, scheme))
        } else if env["DISKMAP_SHEET"] == "changes", let tree = model.tree {
            model.currentDigest = tree.withStore { DiskDigest.of(store: $0, stats: tree.stats) }
            model.openChanges()
            view = AnyView(ChangesView(model: model).environment(\.colorScheme, scheme))
        } else if env["DISKMAP_SHEET"] == "cleanup" {
            model.suggestions = MainActor.assumeIsolated {
                AppModel.computeSuggestions(tree: model.tree!, root: model.currentDirectory,
                                            cache: SignatureCache(), revision: 0,
                                            thresholds: model.cleanupThresholds)
            }
            model.suggestionsLoading = false
            view = AnyView(CleanupView(model: model).environment(\.colorScheme, scheme))
        } else if env["DISKMAP_SHEET"] == "compare" {
            // Two folders on disk, walked for real. There is no fixture form of
            // this screen: what it shows is what the comparison found.
            model.compareLeft = env["DISKMAP_COMPARE_LEFT"] ?? ""
            model.compareRight = env["DISKMAP_COMPARE_RIGHT"] ?? ""
            if let d = env["DISKMAP_COMPARE_DIR"], let direction = SyncDirection(rawValue: d) {
                model.syncDirection = direction
            }
            if let f = env["DISKMAP_COMPARE_FILTER"], let filter = CompareFilter(rawValue: f) {
                model.compareFilter = filter
            }
            if let d = env["DISKMAP_COMPARE_DATE"], let filter = DateFilter(rawValue: d) {
                model.dateFilter = filter
            }
            if case .success(let comparison) = FolderDiff.compare(left: model.compareLeft,
                                                                  right: model.compareRight) {
                model.folderComparison = comparison
                model.openTheDifferences(comparison.tree)
                model.rebuildCompareRows()
            }
            switch env["DISKMAP_COMPARE_PAGE"] {
            case "plan": model.previewSync()
            case "redundant": model.previewRemoveRedundant(.right)
            default: break
            }
            if env["DISKMAP_COMPARE_PAGE"] == "ignore" {
                view = AnyView(CompareIgnoreView(model: model).environment(\.colorScheme, scheme))
            } else {
                // Sized here as well as inside, so a resizable sheet can be
                // checked at more than the one width it opens at.
                view = AnyView(CompareView(model: model).environment(\.colorScheme, scheme)
                    .frame(width: width, height: height))
            }
        } else if env["DISKMAP_SHEET"] == "trash" {
            // The report is what finds the copies, and nothing had run it - so
            // this branch fell through to the main window and the most
            // destructive screen in the app had no render at all.
            model.panel = .duplicates
            // Same knob the exclusions sheet reads, so the never-touch line on
            // this screen can be rendered at all rather than only reasoned about.
            model.excludedPaths = (env["DISKMAP_EXCLUDED"] ?? "").split(separator: ":").map(String.init)
            model.refreshSummarySync()
            guard let match = model.folderMatches.first else {
                FileHandle.standardError.write(Data("no folder matches under that root\n".utf8))
                exit(1)
            }
            model.checkExtras(match.copies)
            model.requestBulkTrash()
            if let groups = model.reviewing {
                view = AnyView(TrashConfirmView(model: model, groups: groups)
                    .environment(\.colorScheme, scheme)
                    .frame(width: width, height: height))
            } else {
                view = AnyView(Text(model.toast ?? "no plan").padding()
                    .frame(width: width, height: height))
            }
        } else {
            view = AnyView(ContentView(model: model)
                .environment(\.colorScheme, scheme)
                .frame(width: width, height: height))
        }

        // System colours resolve through NSAppearance, not the SwiftUI
        // environment, so both have to be set for an offscreen render.
        let nsAppearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        var image: CGImage?
        nsAppearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            image = renderer.cgImage
        }
        guard let cg = image else {
            FileHandle.standardError.write(Data("render produced no image\n".utf8))
            return true
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return true }
        try? png.write(to: URL(fileURLWithPath: parts[3]))
        FileHandle.standardError.write(Data("wrote \(parts[3]) (\(cg.width)x\(cg.height))\n".utf8))
        return true
    }
}
