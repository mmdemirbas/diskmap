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

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "volume" {
case "volume": cmdVolume()
case "validate": cmdValidate(args.count > 2 ? args[2] : FileManager.default.homeDirectoryForCurrentUser.path)
case "scan": cmdScan(args.count > 2 ? Array(args.dropFirst(2)) : [FileManager.default.homeDirectoryForCurrentUser.path])
default: print("usage: dmbench [volume | validate <path> | scan <path> [path...]]")
}
