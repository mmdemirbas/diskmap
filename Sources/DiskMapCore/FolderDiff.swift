import Foundation

public enum Side: String, Sendable, CaseIterable {
    case left, right
    public var other: Side { self == .left ? .right : .left }
}

public enum DiffKind: String, Sendable, CaseIterable {
    /// Same name and same length on both sides. Nothing was read, so this is
    /// "no metadata says they differ", not "these are the same bytes".
    case identical
    /// Present on both sides at different lengths.
    case differs
    case onlyLeft
    case onlyRight
    /// A folder on one side, a file on the other.
    case typeClash
}

/// One name, and what the two folders each have under it.
///
/// A folder present on one side only is a single entry covering its whole
/// subtree; nothing inside it is enumerated, because "copy this folder" is one
/// decision however many files it holds. The same collapse applies to a folder
/// whose contents match all the way down.
public struct DiffEntry: Sendable, Identifiable {
    public var id: Int
    /// Path below the two folders being compared, with no leading separator.
    public var relativePath: String
    public var kind: DiffKind
    /// The left side's kind. For a clash the right side is the other one,
    /// which is the whole of what a clash is — read it through
    /// `isDirectory(on:)` rather than directly.
    public var isDirectory: Bool
    /// On-disk bytes, and for a folder the total below it. Zero on a side
    /// where the item is absent.
    public var leftBytes: Int64
    public var rightBytes: Int64
    /// Unix time, or 0 where the item is absent.
    public var leftModified: Int32
    public var rightModified: Int32
    /// Direct children, for a folder that exists on one side only.
    public var items: Int
    /// Either side is an iCloud placeholder: its bytes are not on this disk,
    /// and copying it would pull them down over the network.
    public var dataless: Bool

    public var name: String { (relativePath as NSString).lastPathComponent }

    /// The side last written to. Nil when the dates agree or one side is
    /// absent — "newer" has no meaning then, and guessing produces the kind of
    /// silent wrong answer this whole screen exists to prevent.
    public var newerSide: Side? {
        guard leftModified > 0, rightModified > 0, leftModified != rightModified else { return nil }
        return leftModified > rightModified ? .left : .right
    }

    public func bytes(on side: Side) -> Int64 { side == .left ? leftBytes : rightBytes }

    public func isDirectory(on side: Side) -> Bool {
        kind == .typeClash && side == .right ? !isDirectory : isDirectory
    }

    public func isPresent(on side: Side) -> Bool {
        switch kind {
        case .onlyLeft: side == .left
        case .onlyRight: side == .right
        default: true
        }
    }

    public init(id: Int, relativePath: String, kind: DiffKind, isDirectory: Bool,
                leftBytes: Int64, rightBytes: Int64, leftModified: Int32, rightModified: Int32,
                items: Int, dataless: Bool) {
        self.id = id; self.relativePath = relativePath; self.kind = kind
        self.isDirectory = isDirectory
        self.leftBytes = leftBytes; self.rightBytes = rightBytes
        self.leftModified = leftModified; self.rightModified = rightModified
        self.items = items; self.dataless = dataless
    }
}

public struct DiffSummary: Sendable, Equatable {
    /// Counted in items, not in rows. A folder whose contents match all the
    /// way down is one row and a thousand matching items, and "1" next to
    /// "2 only on the right" would read as though the two were comparable.
    public var identical = 0
    public var differing = 0
    public var onlyLeft = 0
    public var onlyRight = 0
    public var typeClashes = 0

    public var identicalBytes: Int64 = 0
    /// The larger of the two sides, per item: the bytes the disagreement is about.
    public var differingBytes: Int64 = 0
    public var onlyLeftBytes: Int64 = 0
    public var onlyRightBytes: Int64 = 0

    /// Placeholders on either side. Copying one downloads it.
    public var datalessItems = 0

    public var differences: Int { differing + onlyLeft + onlyRight + typeClashes }
    public var inSync: Bool { differences == 0 }

    /// True when everything on `side` is also on the other side, at the same
    /// length. The other side may hold more.
    public func isCoveredByTheOtherSide(_ side: Side) -> Bool {
        guard differing == 0, typeClashes == 0 else { return false }
        return side == .left ? onlyLeft == 0 : onlyRight == 0
    }

    public init() {}
}

public struct FolderComparison: Sendable {
    public var left: String
    public var right: String
    public var entries: [DiffEntry]
    public var summary: DiffSummary
    public var leftTotal: Int64
    public var rightTotal: Int64
    public var leftItems: Int
    public var rightItems: Int
    /// Folders that could not be opened, on either side. Non-zero means the
    /// comparison did not see everything, so nothing may be mirrored from it.
    public var unreadable: Int
    public var cancelled: Bool
    public var elapsed: Double
    /// Relative paths that the deep check found to differ despite matching
    /// metadata. Empty until `verify` has run.
    public var verifiedAt: Date?

    public func path(_ relative: String, on side: Side) -> String {
        let base = side == .left ? left : right
        return relative.isEmpty ? base : base + "/" + relative
    }

    public func entries(_ kind: DiffKind) -> [DiffEntry] { entries.filter { $0.kind == kind } }

    public init(left: String, right: String, entries: [DiffEntry], summary: DiffSummary,
                leftTotal: Int64, rightTotal: Int64, leftItems: Int, rightItems: Int,
                unreadable: Int, cancelled: Bool, elapsed: Double, verifiedAt: Date? = nil) {
        self.left = left; self.right = right; self.entries = entries; self.summary = summary
        self.leftTotal = leftTotal; self.rightTotal = rightTotal
        self.leftItems = leftItems; self.rightItems = rightItems
        self.unreadable = unreadable; self.cancelled = cancelled; self.elapsed = elapsed
        self.verifiedAt = verifiedAt
    }
}

public enum CompareRefusal: Error, Sendable, Equatable {
    case notAFolder(String)
    case sameFolder(String)
    case nested(inner: String, outer: String)
    /// The target is a whole volume, or the root of one. Mirroring onto it
    /// would propose removing everything the source does not have.
    case wouldWriteToAVolumeRoot(String)
    case onTheNeverTouchList(String)
    case nothingToDo
    /// Asked to remove a copy that holds something the other one does not.
    case notRedundant
    /// A mirror cannot be built from a comparison that could not read
    /// everything: what it did not see, it would propose deleting.
    case someFoldersUnreadable(Int)
}

/// What two folders each hold, and where they disagree.
///
/// Both sides are walked fresh rather than read out of the current scan. A sync
/// acts on the disk as it is now, and a tree from ten minutes ago is a
/// different disk; it also means two folders can be compared whether or not
/// either was ever scanned.
///
/// **Identity is name and length.** The modification date is carried and shown
/// but never decides, so a plain `cp -R` — which shifts every date — does not
/// make two copies look completely different. The cost is that a file edited
/// without changing its length reads as identical here. `verify` is the answer
/// to that, and it reads every byte, so it only runs when asked.
public enum FolderDiff {
    public static func compare(left rawLeft: String, right rawRight: String,
                               cancel: CancelToken? = nil) -> Result<FolderComparison, CompareRefusal> {
        let started = Date()
        let left = canonicalPath(rawLeft) ?? rawLeft
        let right = canonicalPath(rawRight) ?? rawRight

        guard isDirectory(left) else { return .failure(.notAFolder(rawLeft)) }
        guard isDirectory(right) else { return .failure(.notAFolder(rawRight)) }
        if left == right { return .failure(.sameFolder(left)) }
        if isInside(left, right) { return .failure(.nested(inner: left, outer: right)) }
        if isInside(right, left) { return .failure(.nested(inner: right, outer: left)) }

        let span = Telemetry.begin("compare")
        let leftScan = scan(left, cancel: cancel)
        let rightScan = scan(right, cancel: cancel)
        let ls = leftScan.store, rs = rightScan.store

        // Subtree hashes let a folder whose contents match all the way down be
        // reported as one line instead of ten thousand.
        let lsig = FolderMatches.signatures(ls)
        let rsig = FolderMatches.signatures(rs)
        let litems = subtreeItems(ls), ritems = subtreeItems(rs)

        var entries: [DiffEntry] = []
        var summary = DiffSummary()
        ls.withNameBytes { lb in
            rs.withNameBytes { rb in
                var ctx = Context(l: ls, lb: lb, lsig: lsig, litems: litems,
                                  r: rs, rb: rb, rsig: rsig, ritems: ritems,
                                  cancel: cancel)
                walk(&ctx, 0, 0, prefix: "", into: &entries, summary: &summary)
            }
        }
        for index in entries.indices { entries[index].id = index }

        let comparison = FolderComparison(
            left: left, right: right, entries: entries, summary: summary,
            leftTotal: ls.totalPhysical.first ?? 0, rightTotal: rs.totalPhysical.first ?? 0,
            leftItems: leftScan.stats.files + leftScan.stats.directories,
            rightItems: rightScan.stats.files + rightScan.stats.directories,
            unreadable: leftScan.stats.unreadableDirectories + rightScan.stats.unreadableDirectories,
            cancelled: cancel?.isCancelled == true,
            elapsed: Date().timeIntervalSince(started))

        span.end(["entries": .int(Int64(entries.count)),
                  "identical": .int(Int64(summary.identical)),
                  "differing": .int(Int64(summary.differing)),
                  "onlyLeft": .int(Int64(summary.onlyLeft)),
                  "onlyRight": .int(Int64(summary.onlyRight)),
                  "unreadable": .int(Int64(comparison.unreadable)),
                  "cancelled": .flag(comparison.cancelled)])
        return .success(comparison)
    }

    // MARK: - Walking the two trees together

    private struct Context {
        let l: NodeStore
        let lb: UnsafeBufferPointer<UInt8>
        let lsig: [UInt64]
        let litems: [Int32]
        let r: NodeStore
        let rb: UnsafeBufferPointer<UInt8>
        let rsig: [UInt64]
        let ritems: [Int32]
        let cancel: CancelToken?
    }

    /// How many nodes sit at or below each one.
    ///
    /// Both stores here come from a scan that has just finished, where a
    /// child's index is always greater than its parent's, so one reverse pass
    /// visits every child before its parent.
    private static func subtreeItems(_ store: NodeStore) -> [Int32] {
        var out = [Int32](repeating: 1, count: store.count)
        guard store.count > 1 else { return out }
        var i = store.count - 1
        while i > 0 {
            let p = Int(store.parent[i])
            if p >= 0 { out[p] += out[i] }
            i -= 1
        }
        return out
    }

    private static func walk(_ c: inout Context, _ ln: Int32, _ rn: Int32, prefix: String,
                             into out: inout [DiffEntry], summary: inout DiffSummary) {
        if c.cancel?.isCancelled == true { return }
        let lk = sortedChildren(c.l, ln, c.lb)
        let rk = sortedChildren(c.r, rn, c.rb)

        var i = 0, j = 0
        while i < lk.count || j < rk.count {
            if c.cancel?.isCancelled == true { return }
            if j == rk.count {
                emit(one: .left, c.l, lk[i], c.litems, prefix, &out, &summary); i += 1; continue
            }
            if i == lk.count {
                emit(one: .right, c.r, rk[j], c.ritems, prefix, &out, &summary); j += 1; continue
            }
            let order = compareNames(c.lb, c.l.nameSpan(lk[i]), c.rb, c.r.nameSpan(rk[j]))
            if order < 0 {
                emit(one: .left, c.l, lk[i], c.litems, prefix, &out, &summary); i += 1
            } else if order > 0 {
                emit(one: .right, c.r, rk[j], c.ritems, prefix, &out, &summary); j += 1
            } else {
                both(&c, lk[i], rk[j], prefix, &out, &summary)
                i += 1; j += 1
            }
        }
    }

    private static func both(_ c: inout Context, _ ln: Int32, _ rn: Int32, _ prefix: String,
                             _ out: inout [DiffEntry], _ summary: inout DiffSummary) {
        let name = c.l.name(ln)
        let relative = prefix.isEmpty ? name : prefix + "/" + name
        let leftIsDir = c.l.isDirectory(ln), rightIsDir = c.r.isDirectory(rn)

        if leftIsDir != rightIsDir {
            summary.typeClashes += 1
            out.append(entry(relative, .typeClash, c, ln, rn, isDirectory: leftIsDir))
            return
        }
        if leftIsDir {
            // The whole subtree hashes the same, so there is nothing below to
            // report and no reason to walk it.
            if c.lsig[Int(ln)] == c.rsig[Int(rn)] {
                summary.identical += Int(c.litems[Int(ln)])
                summary.identicalBytes += c.l.totalPhysical[Int(ln)]
                out.append(entry(relative, .identical, c, ln, rn, isDirectory: true))
                return
            }
            walk(&c, ln, rn, prefix: relative, into: &out, summary: &summary)
            return
        }
        if c.l.totalLogical[Int(ln)] == c.r.totalLogical[Int(rn)] {
            summary.identical += 1
            summary.identicalBytes += c.l.totalPhysical[Int(ln)]
            out.append(entry(relative, .identical, c, ln, rn, isDirectory: false))
        } else {
            summary.differing += 1
            summary.differingBytes += max(c.l.totalPhysical[Int(ln)], c.r.totalPhysical[Int(rn)])
            out.append(entry(relative, .differs, c, ln, rn, isDirectory: false))
        }
    }

    private static func entry(_ relative: String, _ kind: DiffKind, _ c: Context,
                              _ ln: Int32, _ rn: Int32, isDirectory: Bool) -> DiffEntry {
        let placeholder = c.l.flagSet(ln).contains(.dataless) || c.r.flagSet(rn).contains(.dataless)
        return DiffEntry(id: 0, relativePath: relative, kind: kind, isDirectory: isDirectory,
                         leftBytes: c.l.totalPhysical[Int(ln)],
                         rightBytes: c.r.totalPhysical[Int(rn)],
                         leftModified: c.l.mtime[Int(ln)], rightModified: c.r.mtime[Int(rn)],
                         items: isDirectory ? Int(c.litems[Int(ln)]) - 1 : 0,
                         dataless: placeholder)
    }

    /// A name that only one side has. Its subtree is not enumerated: copying or
    /// removing the folder is one decision, whatever it holds.
    private static func emit(one side: Side, _ store: NodeStore, _ node: Int32,
                             _ subtree: [Int32], _ prefix: String,
                             _ out: inout [DiffEntry], _ summary: inout DiffSummary) {
        let name = store.name(node)
        let relative = prefix.isEmpty ? name : prefix + "/" + name
        let isDir = store.isDirectory(node)
        let bytes = store.totalPhysical[Int(node)]
        let placeholder = store.flagSet(node).contains(.dataless)
        if placeholder { summary.datalessItems += 1 }
        let below = Int(subtree[Int(node)])

        if side == .left {
            summary.onlyLeft += below
            summary.onlyLeftBytes += bytes
            out.append(DiffEntry(id: 0, relativePath: relative, kind: .onlyLeft,
                                 isDirectory: isDir, leftBytes: bytes, rightBytes: 0,
                                 leftModified: store.mtime[Int(node)], rightModified: 0,
                                 items: isDir ? below - 1 : 0, dataless: placeholder))
        } else {
            summary.onlyRight += below
            summary.onlyRightBytes += bytes
            out.append(DiffEntry(id: 0, relativePath: relative, kind: .onlyRight,
                                 isDirectory: isDir, leftBytes: 0, rightBytes: bytes,
                                 leftModified: 0, rightModified: store.mtime[Int(node)],
                                 items: isDir ? below - 1 : 0, dataless: placeholder))
        }
    }

    private static func sortedChildren(_ store: NodeStore, _ node: Int32,
                                       _ bytes: UnsafeBufferPointer<UInt8>) -> [Int32] {
        var kids: [Int32] = []
        for child in store.children(node) where !store.flagSet(child).contains(.removed) {
            kids.append(child)
        }
        kids.sort { compareNames(bytes, store.nameSpan($0), bytes, store.nameSpan($1)) < 0 }
        return kids
    }

    /// Byte order, not collation. Both sides use the same rule, which is all a
    /// merge needs — and it costs no Strings, which at a million names is the
    /// difference between a second and a minute.
    @inline(__always)
    private static func compareNames(_ a: UnsafeBufferPointer<UInt8>, _ sa: (offset: Int, length: Int),
                                     _ b: UnsafeBufferPointer<UInt8>,
                                     _ sb: (offset: Int, length: Int)) -> Int {
        let shared = min(sa.length, sb.length)
        if shared > 0, let pa = a.baseAddress, let pb = b.baseAddress {
            let order = memcmp(pa + sa.offset, pb + sb.offset, shared)
            if order != 0 { return order < 0 ? -1 : 1 }
        }
        if sa.length == sb.length { return 0 }
        return sa.length < sb.length ? -1 : 1
    }

    private static func scan(_ path: String, cancel: CancelToken?) -> ScanResult {
        var options = ScanOptions(rootPath: path)
        // Never inherit the volume-wide inode count: `statfs` answers for the
        // whole disk whatever path it is handed, so a comparison of two small
        // folders would map hundreds of megabytes of arrays twice. Guessing low
        // costs a few array doublings; guessing high costs the mapping.
        options.expectedNodes = 1 << 18
        return DiskScanner(cancel: cancel ?? CancelToken()).scan(options)
    }

    // MARK: - Reading the bytes

    /// Confirms that the items metadata called identical really do hold the
    /// same bytes. Returns the relative paths where they do not.
    ///
    /// This is the check the comparison itself deliberately does not do: it
    /// reads every byte of both sides, which on two photo libraries is hours.
    /// Directories reported as identical are expanded here, since collapsing
    /// them was a metadata decision and this is the pass that doubts it.
    public static func verify(_ comparison: FolderComparison, cancel: CancelToken? = nil,
                              progressStep: Int64 = 64 << 20,
                              progress: ((Int64) -> Void)? = nil) -> VerifyDifferences {
        let span = Telemetry.begin("compare.verify")
        var pairs: [(relative: String, left: String, right: String)] = []
        for entry in comparison.entries where entry.kind == .identical {
            if entry.isDirectory {
                pairs += filePairs(under: entry.relativePath, comparison)
            } else {
                pairs.append((entry.relativePath,
                              comparison.path(entry.relativePath, on: .left),
                              comparison.path(entry.relativePath, on: .right)))
            }
        }

        var read: Int64 = 0
        var reported: Int64 = 0
        var differing: [String] = []
        var unreadable: [String] = []
        for pair in pairs {
            if cancel?.isCancelled == true { break }
            guard let a = DeepVerify.hashFile(pair.left, cancel: cancel, bytesRead: &read),
                  let b = DeepVerify.hashFile(pair.right, cancel: cancel, bytesRead: &read) else {
                unreadable.append(pair.relative)
                continue
            }
            if a != b { differing.append(pair.relative) }
            if read - reported >= progressStep { reported = read; progress?(read) }
        }
        progress?(read)

        let result = VerifyDifferences(pairsChecked: pairs.count, bytesRead: read,
                                       differing: differing, unreadable: unreadable,
                                       cancelled: cancel?.isCancelled == true)
        span.end(["pairs": .int(Int64(pairs.count)), "bytes": .int(read),
                  "differing": .int(Int64(differing.count)),
                  "unreadable": .int(Int64(unreadable.count)),
                  "cancelled": .flag(result.cancelled)])
        return result
    }

    /// Every file below a folder the comparison collapsed as identical.
    private static func filePairs(under relative: String, _ comparison: FolderComparison)
        -> [(relative: String, left: String, right: String)] {
        var out: [(String, String, String)] = []
        let base = comparison.path(relative, on: .left)
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: base),
            includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let suffix = String(url.path.dropFirst(base.count + 1))
            let child = relative.isEmpty ? suffix : relative + "/" + suffix
            out.append((child, url.path, comparison.path(child, on: .right)))
        }
        return out
    }

    // MARK: - Shapes of paths

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Containment on whole components, so `/a/dev` does not contain `/a/development`.
    public static func isInside(_ path: String, _ container: String) -> Bool {
        path == container || path.hasPrefix(container == "/" ? "/" : container + "/")
    }
}

public struct VerifyDifferences: Sendable {
    public var pairsChecked: Int
    public var bytesRead: Int64
    /// Same name, same length, different bytes. The case the metadata
    /// comparison cannot see.
    public var differing: [String]
    /// Could not be opened on one side or the other, so nothing was settled.
    public var unreadable: [String]
    public var cancelled: Bool
    public var agreed: Bool { differing.isEmpty && unreadable.isEmpty && !cancelled }
}
