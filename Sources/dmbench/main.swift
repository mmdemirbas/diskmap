import DiskMapCore
import Darwin
import Foundation

func fmt(_ v: Int64) -> String { formatBytes(v) }

func cmdVolume() {
    for v in VolumeInfo.mountedVolumes() {
        print("\(v.name)  (\(v.path))")
        print("  capacity                 \(fmt(v.total))")
        print("  used                     \(fmt(v.used))   \(String(format: "%.1f%%", v.usedFraction * 100))")
        print("  free (real)              \(fmt(v.trueAvailable))")
        print("  free (what Finder says)  \(fmt(v.finderAvailable))")
        print("  purgeable  -> Finder overstates free space by \(fmt(v.purgeable))")
        let snaps = Snapshots.list(volume: v.path)
        if !snaps.isEmpty { print("  local snapshots          \(snaps.count)") }
        print("")
    }
}

/// Correctness gate: getattrlistbulk parsing is order-sensitive, so every field
/// is cross-checked against lstat for the same directory.
func cmdValidate(_ path: String) {
    guard let dir = opendir(path) else { print("cannot open \(path)"); exit(1) }
    var byName: [String: (UInt64, Int64, Int64, Bool)] = [:]
    while let ent = readdir(dir) {
        var nameBuf = ent.pointee.d_name
        let name = withUnsafeBytes(of: &nameBuf) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        if name == "." || name == ".." { continue }
        var st = stat()
        if lstat(path + "/" + name, &st) != 0 { continue }
        byName[name] = (UInt64(st.st_ino), st.st_size, Int64(st.st_blocks) * 512,
                        (st.st_mode & S_IFMT) == S_IFDIR)
    }
    closedir(dir)

    let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { print("cannot open \(path)"); exit(1) }
    var checked = 0, mismatches = 0, missing = 0
    var samples: [String] = []
    _ = BulkReader().enumerate(dirFD: fd) { e in
        let name = String(decoding: UnsafeRawBufferPointer(start: e.name, count: e.nameLen), as: UTF8.self)
        guard let ref = byName[name] else { missing += 1; return }
        checked += 1
        var bad: [String] = []
        if e.fileID != ref.0 { bad.append("inode \(e.fileID) != \(ref.0)") }
        if e.isDir != ref.3 { bad.append("type") }
        if !e.isDir && !e.isDataless {
            if e.logicalSize != ref.1 { bad.append("logical \(e.logicalSize) != \(ref.1)") }
            if e.physicalSize != ref.2 { bad.append("physical \(e.physicalSize) != \(ref.2)") }
        }
        if !bad.isEmpty {
            mismatches += 1
            if samples.count < 8 { samples.append("  \(name): \(bad.joined(separator: ", "))") }
        }
    }
    close(fd)
    print("validate \(path)")
    print("  entries cross-checked against lstat: \(checked)")
    print("  not seen by lstat:                   \(missing)")
    print("  mismatches:                          \(mismatches)")
    samples.forEach { print($0) }
    print(mismatches == 0 ? "  OK" : "  FAIL")
}

func cmdScan(_ paths: [String]) {
    let path = paths[0]
    var opts = ScanOptions(roots: paths)
    opts.threadCount = ProcessInfo.processInfo.environment["DM_THREADS"].flatMap(Int.init)
        ?? min(12, ProcessInfo.processInfo.activeProcessorCount)
    print("scanning \(paths.joined(separator: ", ")) with \(opts.threadCount) threads ...")

    let r = DiskScanner().scan(opts) { p in
        FileHandle.standardError.write("\r  \(p.nodes) nodes, \(p.directories) dirs, \(formatBytes(p.bytes))    ".data(using: .utf8)!)
    }
    FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!)

    for rejected in r.rejectedRoots {
        print("  skipped \(rejected.path): \(rejected.reason.explanation)")
    }
    let s = r.stats
    print("""
    elapsed            \(String(format: "%.2f s", s.elapsed))
    nodes              \(r.store.count)   (\(s.directories) dirs, \(s.files) files, \(s.symlinks) symlinks)
    rate               \(String(format: "%.0f", Double(r.store.count) / max(s.elapsed, 0.001))) entries/s
    physical (on disk) \(fmt(s.totalPhysical))
    logical (apparent) \(fmt(s.totalLogical))
    iCloud placeholder \(s.datalessCount) files, \(fmt(s.datalessLogical)) apparent but 0 on disk
    hardlink dupes     \(s.hardlinkDuplicates) extra links, \(fmt(s.hardlinkDuplicateLogical)) not double-counted
    compressed         \(s.compressedCount)
    unreadable dirs    \(s.unreadableDirectories)
    skipped mounts     \(s.skippedMountPoints)
    """)
    if !s.unreadableSamples.isEmpty {
        print("  e.g. " + s.unreadableSamples.prefix(4).joined(separator: "\n       "))
    }

    if let v = VolumeInfo.forPath(path) {
        let rec = Reconciliation(volumeUsed: v.used, scannedPhysical: s.totalPhysical,
                                 datalessLogical: s.datalessLogical,
                                 hardlinkDuplicateLogical: s.hardlinkDuplicateLogical,
                                 unreadableDirectories: s.unreadableDirectories,
                                 snapshotCount: Snapshots.list(volume: "/").count,
                                 scanRootIsWholeVolume: path == "/" || path == "/System/Volumes/Data")
        print("")
        print("reconciliation")
        if rec.comparesToVolume {
            print("  volume reports used   \(fmt(rec.volumeUsed))")
            print("  scan attributed       \(fmt(rec.scannedPhysical))")
            print("  unaccounted           \(fmt(rec.unaccounted))  (\(String(format: "%.1f%%", rec.unaccountedFraction * 100)))")
        } else {
            print("  scan attributed       \(fmt(rec.scannedPhysical))")
        }
        rec.explanations.forEach { print("  - \($0)") }
    }

    print("\nmemory")
    r.store.memoryReport().lines.forEach { print("  \($0)") }

    // Top 15 by bytes actually on disk.
    let st = r.store
    var idx = Array(0..<Int32(st.count))
    idx.sort { st.totalPhysical[Int($0)] > st.totalPhysical[Int($1)] }
    print("\nlargest directories")
    var shown = 0
    for i in idx where st.isDirectory(i) && shown < 12 {
        print("  \(fmt(st.totalPhysical[Int(i)]).padding(toLength: 11, withPad: " ", startingAt: 0))  \(st.path(i))")
        shown += 1
    }
    print("\nlargest files")
    shown = 0
    for i in idx where !st.isDirectory(i) && shown < 12 {
        print("  \(fmt(st.totalPhysical[Int(i)]).padding(toLength: 11, withPad: " ", startingAt: 0))  \(st.path(i))")
        shown += 1
    }
}

/// Times the duplicate pass on a real tree. It is a second walk over the
/// scanned nodes, so its cost is worth knowing separately from the scan.
func cmdDupes(_ paths: [String]) {
    let result = DiskScanner().scan(ScanOptions(roots: paths))
    let store = result.store
    let start = DispatchTime.now().uptimeNanoseconds
    let groups = Duplicates.find(store: store, root: 0, limit: 10_000)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

    let reclaimable = groups.reduce(Int64(0)) { $0 + $1.reclaimable }
    print("duplicate candidates in \(paths.joined(separator: ", "))")
    print("  nodes scanned      \(result.stats.files + result.stats.directories)")
    print("  groups             \(groups.count)")
    print("  reclaimable        \(fmt(reclaimable))")
    print("  pass took          \(String(format: "%.2fs", elapsed))")
    print("\ntop groups")
    for group in groups.prefix(8) {
        print("  \(fmt(group.reclaimable).padding(toLength: 11, withPad: " ", startingAt: 0))"
              + "  \(group.nodes.count) x \(fmt(group.bytes))  \(group.name)")
    }

    let folderStart = DispatchTime.now().uptimeNanoseconds
    let folders = FolderMatches.find(store: store, root: 0, limit: 10_000)
    let folderElapsed = Double(DispatchTime.now().uptimeNanoseconds - folderStart) / 1e9
    print("\nfolder matches")
    print("  exact              \(folders.filter(\.exact).count)")
    print("  partial            \(folders.filter { !$0.exact }.count)")
    print("  reclaimable        \(fmt(folders.reduce(Int64(0)) { $0 + $1.reclaimable }))")
    print("  pass took          \(String(format: "%.2fs", folderElapsed))")
    for match in folders.prefix(10) {
        let shape = match.exact ? "identical"
            : "\(match.sharedItems)/\(match.comparedItems) shared"
        print("  \(fmt(match.reclaimable).padding(toLength: 11, withPad: " ", startingAt: 0))"
              + "  \(match.nodes.count) x \(fmt(match.bytes))  \(shape)")
        for node in match.nodes.prefix(3) { print("      \(store.path(node))") }
    }
}

/// End-to-end check of the deep path: plan two or more real folders, read every
/// byte, and say whether they are the same.
func cmdVerify(_ paths: [String]) {
    guard paths.count > 1 else { print("usage: dmbench verify <path> <path> [path...]"); exit(1) }
    let parent = (paths[0] as NSString).deletingLastPathComponent
    let store = DiskScanner().scan(ScanOptions(roots: paths)).store
    let nodes = paths.compactMap { store.find(path: $0) }
    guard nodes.count == paths.count else { print("could not locate all paths under \(parent)"); exit(1) }

    let plan = DeepVerify.plan(store: store, nodes: nodes)
    print("verify \(paths.count) paths")
    print("  files              \(plan.files)")
    print("  to read            \(fmt(plan.bytes))")
    print("  skipped (iCloud)   \(plan.skipped)")

    let start = DispatchTime.now().uptimeNanoseconds
    let outcome = DeepVerify.run(plan)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    print("  read in            \(String(format: "%.1fs", elapsed))"
          + "  (\(fmt(Int64(Double(plan.bytes) / max(elapsed, 0.001))))/s)")
    print("  distinct contents  \(outcome.distinct)")
    print("  identical          \(outcome.identical)")
    for result in outcome.results {
        print("    \(result.digest.prefix(16))  \(store.path(result.node))")
    }
}

/// Finds folder matches under a path and verifies the largest one that fits a
/// read budget, which is the whole pipeline end to end on real data.
func cmdVerifyTop(_ path: String, budget: Int64) {
    let store = DiskScanner().scan(ScanOptions(rootPath: path)).store
    let matches = FolderMatches.find(store: store, root: 0, limit: 10_000)
    let plans = matches.map { ($0, $0.nodes.reduce(Int64(0)) { $0 + store.totalPhysical[Int($1)] }) }
    guard let (match, cost) = plans.filter({ $0.1 <= budget }).max(by: { $0.0.reclaimable < $1.0.reclaimable })
    else { print("no match under \(fmt(budget))"); exit(1) }

    print("verifying \(match.exact ? "an identical" : "a partial") match, \(fmt(cost)) to read")
    for node in match.nodes { print("  \(store.path(node))") }
    let plan = DeepVerify.plan(store: store, nodes: match.nodes)
    print("  files \(plan.files), skipped (iCloud) \(plan.skipped)")

    let start = DispatchTime.now().uptimeNanoseconds
    let outcome = DeepVerify.run(plan)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    print("  read \(fmt(plan.bytes)) in \(String(format: "%.1fs", elapsed))"
          + "  (\(fmt(Int64(Double(plan.bytes) / max(elapsed, 0.001))))/s)")
    print("  distinct contents \(outcome.distinct), identical \(outcome.identical),"
          + " unread \(outcome.unread)")
}

/// What the app has recorded about itself, across every run.
///
/// The point of accumulating is comparison over time: a scan that used to take
/// 66 s and now takes 90 s is a finding, and it is only visible if the old
/// number was written down when it happened.
func cmdMetrics(_ limit: Int) {
    let history = Telemetry.history()
    guard !history.isEmpty else {
        print("no records yet at \(Telemetry.logURL.path)")
        print("(set DISKMAP_METRICS=0 to turn recording off)")
        exit(0)
    }
    let sessions = Set(history.compactMap { $0.fields["s"] }).count
    print("\(history.count) records from \(sessions) runs")
    print("  \(history.first?.time ?? "") .. \(history.last?.time ?? "")")
    print("  \(Telemetry.logURL.path)")

    var byEvent: [String: [Double]] = [:]
    var counts: [String: Int] = [:]
    for record in history {
        counts[record.event, default: 0] += 1
        if let ms = record.ms { byEvent[record.event, default: []].append(ms) }
    }

    print("\nstage                    count      p50       p95       max")
    for event in counts.keys.sorted() {
        let name = event.rightPadded(22)
        guard var times = byEvent[event], !times.isEmpty else {
            print("  \(name) \(String(counts[event]!).leftPadded(7))        -         -         -")
            continue
        }
        times.sort()
        // Lower median, so two samples do not both report as the slower one.
        let p50 = times[(times.count - 1) / 2]
        let p95 = times[min(times.count - 1, Int(Double(times.count) * 0.95))]
        print("  \(name) \(String(counts[event]!).leftPadded(7))"
              + "\(ms(p50).leftPadded(9))\(ms(p95).leftPadded(10))\(ms(times.last!).leftPadded(10))")
    }

    // A relist that finds new folders scans each of them, so most "scan"
    // records are a handful of nodes. Those are noise in a list meant to show
    // how full scans behave over time.
    let scans = history.filter {
        $0.event == "scan" && (Int64($0.fields["nodes"] ?? "0") ?? 0) >= 1_000
    }
    if !scans.isEmpty {
        print("\nrecent full scans (\(counts["scan"]! - scans.count) smaller ones not shown)")
        for record in scans.suffix(limit) {
            let nodes = Int64(record.fields["nodes"] ?? "0") ?? 0
            let physical = Int64(record.fields["physical"] ?? "0") ?? 0
            let footprint = Int64(record.fields["footprint"] ?? "0") ?? 0
            let seconds = (record.ms ?? 0) / 1000
            let rate = seconds > 0 ? Double(nodes) / seconds : 0
            print("  \(record.time.prefix(19))  \(String(nodes).leftPadded(10)) nodes"
                  + "  \(fmt(physical).leftPadded(10))  \(String(format: "%.1fs", seconds).leftPadded(8))"
                  + "  \(String(format: "%.0f", rate).leftPadded(9))/s"
                  + "  rss \(fmt(footprint))")
        }
    }

    let problems = history.filter { $0.event.hasPrefix("problem.") }
    if !problems.isEmpty {
        print("\nproblems")
        var byKind: [String: Int] = [:]
        for p in problems { byKind[p.event, default: 0] += 1 }
        for (kind, count) in byKind.sorted(by: { $0.value > $1.value }) {
            print("  \(String(count).leftPadded(5)) x \(kind)")
        }
    }
}

private func ms(_ value: Double) -> String { String(format: "%.1f", value) }

extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
    /// Pads, never truncates: a clipped event name is a different event.
    func rightPadded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

/// What the app would propose, printed and nothing more. Deletes nothing,
/// selects nothing, and exists so the suggestions can be sanity-checked
/// against a real disk before anyone is asked to act on them.
func cmdCleanup(_ path: String) {
    let store = DiskScanner().scan(ScanOptions(rootPath: path)).store
    let folders = FolderMatches.find(store: store, root: 0, limit: 10_000)
    let files = Duplicates.find(store: store, root: 0, limit: 10_000, insideMatched: folders)

    let start = DispatchTime.now().uptimeNanoseconds
    let found = Cleanup.suggest(store: store, root: 0,
                                folderCopies: folders.map(\.nodes),
                                fileCopies: files.map(\.nodes))
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9

    let actionable = found.filter { !$0.nodes.isEmpty }
    print("cleanup suggestions for \(path)")
    print("  pass took          \(String(format: "%.2fs", elapsed))")
    print("  could be freed     \(fmt(actionable.reduce(Int64(0)) { $0 + $1.bytes }))")
    print("")
    for suggestion in found {
        let safety = ["comes back", "a copy stays", "your call"][suggestion.safety.rawValue]
        print("  \(fmt(suggestion.bytes).leftPadded(10))  \(suggestion.kind.rawValue.rightPadded(18))"
              + "\(String(suggestion.itemCount).leftPadded(6)) items  [\(safety)]")
        // A few examples, so the proposal can be judged rather than trusted.
        for node in suggestion.nodes.sorted(by: { store.totalPhysical[Int($0)] > store.totalPhysical[Int($1)] }).prefix(3) {
            print("      \(fmt(store.totalPhysical[Int(node)]).leftPadded(9))  \(store.path(node))")
        }
    }
}

/// Records what a tree looks like now, so a later run has something to compare
/// against. Writes one small file and touches nothing else.
func cmdSnapshot(_ path: String, _ historyDir: String?) {
    let result = DiskScanner().scan(ScanOptions(rootPath: path))
    let store = historyDir.map { SnapshotStore(directory: URL(fileURLWithPath: $0)) }
        ?? SnapshotStore()
    let digest = DiskDigest.of(store: result.store, stats: result.stats)
    do {
        let url = try store.write(digest)
        let size = (try? Data(contentsOf: url).count) ?? 0
        print("wrote \(digest.folders.count) folders, \(fmt(Int64(size))) -> \(url.path)")
        print("kept snapshots: \(store.list().count)")
    } catch {
        print("could not write: \(error.localizedDescription)")
        exit(1)
    }
}

/// Compares the newest recorded snapshot against the tree as it is now.
func cmdChanges(_ path: String, _ historyDir: String?) {
    let store = historyDir.map { SnapshotStore(directory: URL(fileURLWithPath: $0)) }
        ?? SnapshotStore()
    guard let previous = store.list().last else {
        print("no earlier snapshot; run `dmbench snapshot \(path)` first")
        exit(1)
    }
    let result = DiskScanner().scan(ScanOptions(rootPath: path))
    let now = DiskDigest.of(store: result.store, stats: result.stats)
    guard let old = try? store.read(previous.url) else { print("unreadable snapshot"); exit(1) }

    let diff = DiskDigest.diff(from: old, to: now)
    print("changes since \(old.takenAt)")
    print("  whole tree         \(diff.totalDelta >= 0 ? "+" : "-")\(fmt(abs(diff.totalDelta)))")
    print("  folders moved      \(diff.changes.count)")
    for change in diff.changes.prefix(20) {
        let sign = change.ownDelta >= 0 ? "+" : "-"
        print("  \("\(sign)\(fmt(abs(change.ownDelta)))".leftPadded(11))"
              + "  \(change.kind.rawValue.rightPadded(9))  \(change.path)")
    }
}


final class Peak: @unchecked Sendable {
    private let baseline: Int64
    private var running = false
    private(set) var highWater: Int64 = 0
    init(baseline: Int64) { self.baseline = baseline }
    func start() {
        running = true
        Thread.detachNewThread { [self] in
            while running {
                highWater = max(highWater, Telemetry.footprintBytes() - baseline)
                usleep(300)
            }
        }
    }
    func stop() { running = false; usleep(2000) }
}

/// What one live update costs.
///
/// A relist scans every directory that has just appeared. The overwhelming
/// majority of those hold nothing yet, so the whole cost is setup: sizing the
/// arrays and starting the threads. `statfs` reports the volume's inode count
/// for any path on it, so sizing from that reserved room for the entire disk to
/// measure an empty folder — which is what this command exists to keep honest.
func cmdRelistCost(_ entries: Int, _ runs: Int) {
    let fm = FileManager.default
    let base = fm.currentDirectoryPath + "/tmp/relistcost"
    try? fm.removeItem(atPath: base)
    try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: base) }
    for i in 0..<entries {
        fm.createFile(atPath: base + "/f\(i)", contents: Data(count: 64))
    }

    var fs = statfs()
    _ = statfs(base, &fs)
    let inodes = max(0, Int(fs.f_files) - Int(fs.f_ffree))
    print("directory with \(entries) entries, volume using \(inodes.formatted()) inodes")

    func measure(_ label: String, _ make: () -> ScanOptions) {
        _ = DiskScanner().scan(make())
        let before = Telemetry.footprintBytes()
        // The allocation is transient: it is mapped and thrown away inside one
        // scan, so a reading taken afterwards shows nothing. Sampling from
        // another thread is the only way to see what the process actually held.
        let peak = Peak(baseline: before)
        peak.start()
        let t0 = DispatchTime.now()
        var nodes = 0
        for _ in 0..<runs { nodes = DiskScanner().scan(make()).store.count }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        peak.stop()
        print(String(format: "  %-24@  %8.3f ms   %d nodes   peak footprint +%@",
                     label as NSString, ms / Double(runs), nodes,
                     fmt(peak.highWater) as NSString))
    }
    measure("sized from the volume") { ScanOptions(rootPath: base) }
    measure("sized by the caller") {
        var o = ScanOptions(rootPath: base)
        o.expectedNodes = 4096
        o.threadCount = 2
        return o
    }
}



/// Which directories the filesystem is actually changing, and how big they are.
///
/// A live update costs what the churning directories cost, and a directory with
/// a hundred thousand entries costs a hundred thousand times what an empty one
/// does. Watches without maintaining a tree, so the measurement does not pay
/// the cost it is measuring.
func cmdChurn(_ path: String, _ seconds: Int) {
    print("scanning \(path) for entry counts ...")
    let store = DiskScanner().scan(ScanOptions(rootPath: path)).store

    let tally = Tally()
    let watcher = FileSystemWatcher(paths: [path]) { paths in
        for p in paths {
            var isDir: ObjCBool = false
            let dir = FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
                ? p : (p as NSString).deletingLastPathComponent
            tally.bump(dir)
        }
    }
    print("  watching for \(seconds)s\n")
    watcher.start()
    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
    watcher.stop()

    let counts = tally.snapshot()
    let total = counts.values.reduce(0, +)
    print("  \(total) events across \(counts.count) directories\n")
    print("  events   entries  directory")
    var chargedEntries = 0
    for (dir, n) in counts.sorted(by: { $0.value > $1.value }) {
        let entries = store.find(path: dir).map { store.children($0).count } ?? -1
        if entries > 0 { chargedEntries += n * entries }
        guard n > 2 else { continue }
        let shown = dir.hasPrefix(path) ? "~" + dir.dropFirst(path.count) : dir
        print(String(format: "  %6d  %8@  %@", n,
                     (entries < 0 ? "?" : entries.formatted()) as NSString,
                     String(shown.prefix(88)) as NSString))
    }
    print("\n  rows a relist would append if every event were applied "
          + "separately: \(chargedEntries.formatted())")
}


/// What a search costs while somebody is typing.
func cmdFind(_ path: String, _ needle: String) {
    let store = DiskScanner().scan(ScanOptions(rootPath: path)).store
    print("\(store.count.formatted()) nodes")
    for probe in [needle, needle.lowercased(), "/" + needle] {
        let t0 = DispatchTime.now()
        let found = Find.search(store: store, needle: probe, limit: 300)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        print(String(format: "  %-28@ %7.1f ms  %d shown of %d", probe as NSString, ms,
                     found.items.count, found.total))
    }
    for item in Find.search(store: store, needle: needle, limit: 5).items {
        print("    \(fmt(item.physical))  \(item.kind)  \(item.path)")
    }
}

/// One line per sort key, every field starting at the same column.
private func report(_ label: String, _ ms: Double, _ page: FileTablePage) {
    let name = label.padding(toLength: 11, withPad: " ", startingAt: 0)
    let rows = "\(page.rows.count) of \(page.total.formatted())"
    print(String(format: "  %@%7.1f ms   %@", name, ms,
                 rows.padding(toLength: 20, withPad: " ", startingAt: 0) + fmt(page.totalPhysical)))
}

/// What the flat table costs, per sort key.
///
/// The claim the screen rests on is that re-ordering ten million files does
/// not mean sorting ten million files: the walk keeps only the page it is
/// about to show. This is where that claim is checked against a real tree
/// rather than a fixture.
func cmdTable(_ path: String, _ limit: Int) {
    let store = DiskScanner().scan(ScanOptions(rootPath: path)).store
    print("\(store.count.formatted()) nodes, page of \(limit)")
    // The table's own total, summed file by file, against what the scan
    // aggregated bottom-up. They are two routes to the same number, and a
    // footer that disagrees with the map is worse than no footer.
    print("  tree total \(fmt(store.totalPhysical[0]))")
    for sort in FileSort.allCases {
        var best = Double.infinity
        var page = FileTablePage()
        for _ in 0..<3 {
            let t0 = DispatchTime.now()
            page = FileTable.page(store: store, sort: sort, ascending: false, limit: limit)
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
        }
        report(sort.rawValue, best, page)
    }
    // A filtered pass costs the same walk plus the test, and it is the shape
    // most likely to be run repeatedly while somebody narrows an answer.
    var filter = FileFilter()
    filter.categories = [.video]
    filter.minBytes = 100 << 20
    let t0 = DispatchTime.now()
    let filtered = FileTable.page(store: store, filter: filter, sort: .size, limit: limit)
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
    report("video>100M", ms, filtered)
    for row in filtered.rows.prefix(5) { print("    \(fmt(row.physical))  \(row.path)") }
}

final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func bump(_ key: String) { lock.lock(); counts[key, default: 0] += 1; lock.unlock() }
    func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// What the live tree costs while it is just sitting there.
///
/// The question a battery complaint actually asks is what share of wall clock
/// the app spends working when nobody has touched it. Scans the tree, watches
/// it for a while, and reports the duty cycle and how far the store drifted.
func cmdLive(_ path: String, _ seconds: Int) {
    print("scanning \(path) ...")
    let result = DiskScanner().scan(ScanOptions(rootPath: path))
    let tree = LiveTree(result: result)
    let startNodes = result.store.count
    print("  \(startNodes.formatted()) nodes; watching for \(seconds)s\n")

    let ticks = Counter()
    tree.onChange = { ticks.bump() }
    tree.startWatching()

    var cpuBefore = rusage()
    getrusage(RUSAGE_SELF, &cpuBefore)
    let t0 = Date()
    let deadline = t0.addingTimeInterval(TimeInterval(seconds))
    while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
    var cpuAfter = rusage()
    getrusage(RUSAGE_SELF, &cpuAfter)
    tree.stopWatching()

    func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    let cpu = (secs(cpuAfter.ru_utime) - secs(cpuBefore.ru_utime))
            + (secs(cpuAfter.ru_stime) - secs(cpuBefore.ru_stime))
    let wall = Date().timeIntervalSince(t0)
    let endNodes = tree.withStore { $0.count }
    print(String(format: "  CPU %.1fs over %.0fs wall = %.1f%% of one core",
                 cpu, wall, cpu / wall * 100))
    print("  \(tree.changeCount) tree changes, \(ticks.value) UI notifications")
    print("  store \(startNodes.formatted()) -> \(endNodes.formatted()) nodes "
          + "(+\(fmt(Int64(endNodes - startNodes) * 39)) of rows)")
    print(String(format: "  next debounce would be %.2fs", tree.flushDelay))
}

/// Times a folder comparison, and separates the two halves of the cost:
/// walking both sides, and everything the comparison itself does on top.
///
/// The second half is the one that moves when the merge changes. It opens every
/// folder to collect the decisions, so a change to how names are paired shows
/// up here and nowhere else.
func cmdCompare(_ left: String, _ right: String, verify: Bool = false) {
    let t0 = DispatchTime.now().uptimeNanoseconds
    let scanned = DiskScanner().scan(ScanOptions(rootPath: left))
    let scanOnly = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9

    let t1 = DispatchTime.now().uptimeNanoseconds
    guard case .success(let c) = FolderDiff.compare(left: left, right: right) else {
        print("refused"); return
    }
    let whole = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e9

    print("compare \(left) against \(right)")
    print("  items              \(c.leftItems) / \(c.rightItems)")
    print("  decisions          \(c.entries.count)")
    print("  identical          \(c.summary.identical)")
    print("  differs            \(c.summary.differing)")
    print("  only one side      \(c.summary.onlyLeft) / \(c.summary.onlyRight)")
    print("  ignored names      \(c.summary.ignored)")
    print("  unreadable         \(c.unreadable)")
    print("  one side scanned   \(String(format: "%.2fs", scanOnly))"
          + "  (\(scanned.stats.files + scanned.stats.directories) nodes)")
    print("  whole comparison   \(String(format: "%.2fs", whole))")
    print("  over two scans     \(String(format: "%.2fs", max(0, whole - scanOnly * 2)))")

    let t2 = DispatchTime.now().uptimeNanoseconds
    var rows = 0
    var stack: [Int32] = [0]
    while let id = stack.popLast() {
        for child in c.tree.children(of: id) {
            rows += 1
            if c.tree.isOpen(child) || c.tree.kind(child) == .differs { stack.append(child) }
        }
    }
    print("  walking every row  \(String(format: "%.2fs", Double(DispatchTime.now().uptimeNanoseconds - t2) / 1e9))"
          + "  (\(rows) rows)")

    guard verify else { return }
    // The claim the space-freeing directions stand on, against real bytes.
    let t3 = DispatchTime.now().uptimeNanoseconds
    var lastReport: Int64 = 0
    let check = FolderDiff.verify(c, progressStep: 1 << 30) { read in
        if read - lastReport >= 1 << 30 { lastReport = read; print("    read \(fmt(read)) ...") }
    }
    let took = Double(DispatchTime.now().uptimeNanoseconds - t3) / 1e9
    print("\ncontent check")
    print("  pairs read         \(check.pairsChecked)")
    print("  bytes read         \(fmt(check.bytesRead))")
    print("  differing          \(check.differing.count)")
    print("  unreadable         \(check.unreadable.count)")
    print("  left in iCloud     \(check.notDownloaded.count)")
    print("  agreed             \(check.agreed)")
    print("  took               \(String(format: "%.1fs", took))"
          + (took > 0 ? "  (\(fmt(Int64(Double(check.bytesRead) / took)))/s)" : ""))
    for path in check.differing.prefix(5) { print("    differs: \(path)") }
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "volume" {
case "volume": cmdVolume()
case "validate": cmdValidate(args.count > 2 ? args[2] : FileManager.default.homeDirectoryForCurrentUser.path)
case "scan": cmdScan(args.count > 2 ? Array(args.dropFirst(2)) : [FileManager.default.homeDirectoryForCurrentUser.path])
case "dupes": cmdDupes(args.count > 2 ? Array(args.dropFirst(2)) : [FileManager.default.homeDirectoryForCurrentUser.path])
case "snapshot": cmdSnapshot(args.count > 2 ? args[2] : FileManager.default.homeDirectoryForCurrentUser.path,
                             args.count > 3 ? args[3] : nil)
case "changes": cmdChanges(args.count > 2 ? args[2] : FileManager.default.homeDirectoryForCurrentUser.path,
                           args.count > 3 ? args[3] : nil)
case "cleanup": cmdCleanup(args.count > 2 ? args[2] : FileManager.default.homeDirectoryForCurrentUser.path)
case "table": cmdTable(args.count > 2 ? args[2] : FileManager.default.homeDirectoryForCurrentUser.path,
                       args.count > 3 ? (Int(args[3]) ?? 1000) : 1000)
case "find": cmdFind(args.count > 2 ? args[2] : FileManager.default.homeDirectoryForCurrentUser.path,
                     args.count > 3 ? args[3] : "node_modules")
case "churn": cmdChurn(args.count > 2 ? args[2] : FileManager.default.homeDirectoryForCurrentUser.path,
                       args.count > 3 ? (Int(args[3]) ?? 120) : 120)
case "live": cmdLive(args.count > 2 ? args[2] : FileManager.default.homeDirectoryForCurrentUser.path,
                     args.count > 3 ? (Int(args[3]) ?? 120) : 120)
case "relistcost": cmdRelistCost(args.count > 2 ? (Int(args[2]) ?? 8) : 8,
                                 args.count > 3 ? (Int(args[3]) ?? 40) : 40)
case "metrics": cmdMetrics(args.count > 2 ? (Int(args[2]) ?? 10) : 10)
case "compare": cmdCompare(args.count > 3 ? args[2] : ".", args.count > 3 ? args[3] : ".",
                           verify: args.contains("--verify"))
case "verify": cmdVerify(Array(args.dropFirst(2)))
case "verifytop": cmdVerifyTop(args.count > 2 ? args[2] : FileManager.default.homeDirectoryForCurrentUser.path,
                               budget: args.count > 3 ? (Int64(args[3]) ?? 0) << 30 : 12 << 30)
default: print("usage: dmbench [volume | validate <path> | scan <path> [path...]"
               + " | dupes <path> | compare <left> <right> [--verify]"
               + " | verify <path> <path> | verifytop <path> [GB]"
               + " | cleanup <path> | snapshot <path> [dir] | changes <path> [dir]"
               + " | table <path> [rows] | find <path> <needle> | churn <path> [seconds] | live <path> [seconds] | relistcost [entries] [runs] | metrics [n]]")
}
