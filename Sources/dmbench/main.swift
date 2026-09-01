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

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "volume" {
case "volume": cmdVolume()
case "validate": cmdValidate(args.count > 2 ? args[2] : FileManager.default.homeDirectoryForCurrentUser.path)
case "scan": cmdScan(args.count > 2 ? Array(args.dropFirst(2)) : [FileManager.default.homeDirectoryForCurrentUser.path])
case "dupes": cmdDupes(args.count > 2 ? Array(args.dropFirst(2)) : [FileManager.default.homeDirectoryForCurrentUser.path])
case "metrics": cmdMetrics(args.count > 2 ? (Int(args[2]) ?? 10) : 10)
case "verify": cmdVerify(Array(args.dropFirst(2)))
case "verifytop": cmdVerifyTop(args.count > 2 ? args[2] : FileManager.default.homeDirectoryForCurrentUser.path,
                               budget: args.count > 3 ? (Int64(args[3]) ?? 0) << 30 : 12 << 30)
default: print("usage: dmbench [volume | validate <path> | scan <path> [path...]"
               + " | dupes <path> | verify <path> <path> | verifytop <path> [GB] | metrics [n]]")
}
