import Foundation

public enum Side: String, Sendable, CaseIterable {
    case left, right
    public var other: Side { self == .left ? .right : .left }
}

/// What to leave out, and how exact to be about dates.
///
/// Both are here because a comparison of two real folders is unusable without
/// them: `.DS_Store` differs in every directory macOS has ever opened, and a
/// copy that went through exFAT or a network share comes back with every
/// timestamp a second or two off.
public struct CompareOptions: Sendable, Equatable {
    /// Names never compared, matched as shell globs against the name alone —
    /// `*.tmp`, `node_modules`, `.git`. Case is ignored, because the volumes
    /// this runs on mostly ignore it too.
    public var ignore: [String]
    /// Two dates this far apart or closer are the same moment. Zero is exact;
    /// 2 is what FAT and exFAT round to; 3600 absorbs a daylight-saving shift.
    public var dateTolerance: Int32

    public init(ignore: [String] = CompareOptions.noise, dateTolerance: Int32 = 0) {
        self.ignore = ignore
        self.dateTolerance = dateTolerance
    }

    /// Files the system writes and nobody compares. On by default, and the
    /// screen says how many were skipped so it is never a silent decision.
    public static let noise = [".DS_Store", ".Spotlight-V100", ".fseventsd",
                               ".TemporaryItems", ".Trashes", ".localized",
                               "Thumbs.db", "desktop.ini", ".apDisk"]
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

    /// The side last written to. Nil when one side is absent, or when the two
    /// dates are within the tolerance the comparison was given — "newer" has no
    /// meaning then, and guessing produces the kind of silent wrong answer this
    /// whole screen exists to prevent.
    ///
    /// Stored rather than worked out on demand, so the tolerance is applied in
    /// one place and every reader gets the same answer.
    public var newerSide: Side?

    /// What each side is, as the comparison saw it. The runner checks the
    /// target against this before it moves anything to the Trash, so that a
    /// plan reviewed on screen cannot act on a file that has since changed.
    public var leftLogical: Int64 = 0
    public var rightLogical: Int64 = 0
    public var leftIsFolder = false
    public var rightIsFolder = false
    /// The ignore patterns kept something out of this item's subtree, so
    /// copying or removing it whole takes along a name nothing compared.
    public var coversIgnored = false

    public func bytes(on side: Side) -> Int64 { side == .left ? leftBytes : rightBytes }
    public func logical(on side: Side) -> Int64 { side == .left ? leftLogical : rightLogical }
    public func modified(on side: Side) -> Int32 { side == .left ? leftModified : rightModified }
    public func isFolder(on side: Side) -> Bool { side == .left ? leftIsFolder : rightIsFolder }

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
                items: Int, dataless: Bool, newerSide: Side? = nil,
                leftLogical: Int64 = 0, rightLogical: Int64 = 0,
                leftIsFolder: Bool = false, rightIsFolder: Bool = false,
                coversIgnored: Bool = false) {
        self.leftLogical = leftLogical; self.rightLogical = rightLogical
        self.leftIsFolder = leftIsFolder; self.rightIsFolder = rightIsFolder
        self.coversIgnored = coversIgnored
        self.id = id; self.relativePath = relativePath; self.kind = kind
        self.isDirectory = isDirectory
        self.leftBytes = leftBytes; self.rightBytes = rightBytes
        self.leftModified = leftModified; self.rightModified = rightModified
        self.items = items; self.dataless = dataless; self.newerSide = newerSide
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
    /// Names left out by the ignore patterns while the comparison ran. Reported
    /// because a filter nobody can see is a filter that lies.
    public var ignored = 0

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
    /// The two folders as one tree of pairs, for a screen that lets you open
    /// them. Separate from `entries`, which is the flat list of decisions a
    /// plan is built from — the same walk, asked two different questions.
    public var tree: DiffTree
    /// What the comparison was told to leave out, and how exact to be about
    /// dates. Kept so the screen can say so and a rerun can repeat it.
    public var options: CompareOptions
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

    public init(left: String, right: String, tree: DiffTree,
                options: CompareOptions = CompareOptions(),
                entries: [DiffEntry], summary: DiffSummary,
                leftTotal: Int64, rightTotal: Int64, leftItems: Int, rightItems: Int,
                unreadable: Int, cancelled: Bool, elapsed: Double, verifiedAt: Date? = nil) {
        self.left = left; self.right = right; self.tree = tree; self.options = options
        self.entries = entries; self.summary = summary
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
    /// The comparison was stopped part-way, so it describes part of two
    /// folders. Same reasoning: what it never reached, it would read as absent
    /// from that side.
    case comparisonIncomplete
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
                               options: CompareOptions = CompareOptions(),
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
        // reported as one line instead of ten thousand, and let it stay one
        // line until somebody opens it.
        let leftSignatures = DiffTree.signatures(ls, ignore: options.ignore)
        let rightSignatures = DiffTree.signatures(rs, ignore: options.ignore)
        let tree = DiffTree(left: ls, right: rs,
                            leftSig: leftSignatures.values, rightSig: rightSignatures.values,
                            leftHasIgnored: leftSignatures.hasIgnored,
                            rightHasIgnored: rightSignatures.hasIgnored,
                            leftItems: subtreeItems(ls), rightItems: subtreeItems(rs),
                            options: options)

        var entries: [DiffEntry] = []
        var summary = DiffSummary()
        collect(tree, 0, prefix: "", into: &entries, summary: &summary, cancel: cancel)
        for index in entries.indices { entries[index].id = index }
        summary.ignored = tree.ignored

        let comparison = FolderComparison(
            left: left, right: right, tree: tree, options: options,
            entries: entries, summary: summary,
            leftTotal: ls.totalPhysical.first ?? 0, rightTotal: rs.totalPhysical.first ?? 0,
            leftItems: leftScan.stats.files + leftScan.stats.directories,
            rightItems: rightScan.stats.files + rightScan.stats.directories,
            unreadable: leftScan.stats.unreadableDirectories + rightScan.stats.unreadableDirectories,
            cancelled: cancel?.isCancelled == true,
            elapsed: Date().timeIntervalSince(started))

        span.end(["entries": .int(Int64(entries.count)),
                  "treeNodes": .int(Int64(tree.count)),
                  "identical": .int(Int64(summary.identical)),
                  "differing": .int(Int64(summary.differing)),
                  "onlyLeft": .int(Int64(summary.onlyLeft)),
                  "onlyRight": .int(Int64(summary.onlyRight)),
                  "unreadable": .int(Int64(comparison.unreadable)),
                  "cancelled": .flag(comparison.cancelled)])
        return .success(comparison)
    }

    // MARK: - Walking the two folders together

    /// How many nodes sit at or below each one.
    ///
    /// Both stores here come from a scan that has just finished, where a
    /// child's index is always greater than its parent's, so one reverse pass
    /// visits every child before its parent.
    static func subtreeItems(_ store: NodeStore) -> [Int32] {
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

    /// Turns the tree into the list of decisions, opening the folders that
    /// differ on the way through.
    ///
    /// Where it stops is the whole design. A folder the other side does not
    /// have is one decision however many files it holds, and so is a folder
    /// whose contents match all the way down; neither is walked into, so
    /// neither costs anything until somebody opens it on screen. A folder that
    /// differs is walked into, because the differences are why we are here.
    private static func collect(_ tree: DiffTree, _ id: Int32, prefix: String,
                                into out: inout [DiffEntry], summary: inout DiffSummary,
                                cancel: CancelToken?) {
        if cancel?.isCancelled == true { return }
        // Decisions come out in tree order, so everything below a node is one
        // contiguous run of them. Recording where it starts is what lets a row
        // on screen say "these are mine" without a search.
        tree.beginDecisions(id, at: out.count)
        defer { tree.endDecisions(id, at: out.count) }
        for child in tree.children(of: id) {
            if cancel?.isCancelled == true { return }
            let kind = tree.kind(child)
            let name = tree.name(child)
            let relative = prefix.isEmpty ? name : prefix + "/" + name

            if kind == .differs,
               tree.isDirectory(child, on: .left), tree.isDirectory(child, on: .right) {
                collect(tree, child, prefix: relative, into: &out, summary: &summary,
                        cancel: cancel)
                tree.absorb(child, into: id)
                continue
            }

            let side: Side = tree.isPresent(child, on: .left) ? .left : .right
            let isDirectory = tree.isDirectory(child, on: side)
            let below = tree.items(child, on: side)

            switch kind {
            case .identical:
                summary.identical += isDirectory ? below + 1 : 1
                summary.identicalBytes += tree.bytes(child, on: .left)
            case .differs:
                summary.differing += 1
                summary.differingBytes += max(tree.bytes(child, on: .left),
                                              tree.bytes(child, on: .right))
            case .onlyLeft:
                summary.onlyLeft += isDirectory ? below + 1 : 1
                summary.onlyLeftBytes += tree.bytes(child, on: .left)
            case .onlyRight:
                summary.onlyRight += isDirectory ? below + 1 : 1
                summary.onlyRightBytes += tree.bytes(child, on: .right)
            case .typeClash:
                summary.typeClashes += 1
            }
            if tree.dataless(child) { summary.datalessItems += 1 }

            tree.beginDecisions(child, at: out.count)
            out.append(DiffEntry(
                id: 0, relativePath: relative, kind: kind, isDirectory: isDirectory,
                leftBytes: tree.bytes(child, on: .left),
                rightBytes: tree.bytes(child, on: .right),
                leftModified: tree.modified(child, on: .left),
                rightModified: tree.modified(child, on: .right),
                items: isDirectory ? below : 0,
                dataless: tree.dataless(child),
                newerSide: tree.newerSide(child),
                leftLogical: tree.logicalBytes(child, on: .left),
                rightLogical: tree.logicalBytes(child, on: .right),
                leftIsFolder: tree.isDirectory(child, on: .left),
                rightIsFolder: tree.isDirectory(child, on: .right),
                coversIgnored: tree.coversIgnored(child, on: .left)
                    || tree.coversIgnored(child, on: .right)))
            tree.endDecisions(child, at: out.count)
            tree.absorb(child, into: id)
        }
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
        var notDownloaded: [String] = []
        for entry in comparison.entries where entry.kind == .identical {
            if entry.isDirectory {
                let below = filePairs(under: entry.relativePath, comparison)
                pairs += below.settled
                notDownloaded += below.dataless
            } else if entry.dataless {
                // Reading a placeholder is what fetches it. A check that
                // silently pulled somebody's whole iCloud library down to
                // answer a question about duplicates would be a worse surprise
                // than the question.
                notDownloaded.append(entry.relativePath)
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
                                       notDownloaded: notDownloaded,
                                       cancelled: cancel?.isCancelled == true)
        span.end(["pairs": .int(Int64(pairs.count)), "bytes": .int(read),
                  "differing": .int(Int64(differing.count)),
                  "unreadable": .int(Int64(unreadable.count)),
                  "notDownloaded": .int(Int64(notDownloaded.count)),
                  "cancelled": .flag(result.cancelled)])
        return result
    }

    /// Every file below a folder the comparison collapsed as identical.
    private static func filePairs(under relative: String, _ comparison: FolderComparison)
        -> (settled: [(relative: String, left: String, right: String)], dataless: [String]) {
        var out: [(String, String, String)] = []
        var dataless: [String] = []
        let base = comparison.path(relative, on: .left)
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: base),
            includingPropertiesForKeys: [.isRegularFileKey]) else { return (out, dataless) }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let suffix = String(url.path.dropFirst(base.count + 1))
            let child = relative.isEmpty ? suffix : relative + "/" + suffix
            // The scan flagged placeholders on the way past, but a folder that
            // collapsed as identical was never walked into, so the flag for
            // what is inside it was never carried out here. One `lstat` per
            // file is cheaper than the download opening one would start.
            if isDataless(url.path) { dataless.append(child); continue }
            out.append((child, url.path, comparison.path(child, on: .right)))
        }
        return (out, dataless)
    }

    static func isDataless(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_flags & SF_DATALESS_FLAG != 0
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
    /// Placeholders. Their bytes are in iCloud, and reading one is what brings
    /// it down, so they are left alone and counted rather than checked.
    public var notDownloaded: [String] = []
    public var cancelled: Bool

    public init(pairsChecked: Int, bytesRead: Int64, differing: [String],
                unreadable: [String], notDownloaded: [String] = [], cancelled: Bool) {
        self.pairsChecked = pairsChecked; self.bytesRead = bytesRead
        self.differing = differing; self.unreadable = unreadable
        self.notDownloaded = notDownloaded; self.cancelled = cancelled
    }

    /// Everything this could not settle, whatever the reason. A plan that
    /// removes things has to keep all of it, so it is one list.
    public var unsettled: [String] { unreadable + notDownloaded }
    public var agreed: Bool {
        differing.isEmpty && unreadable.isEmpty && notDownloaded.isEmpty && !cancelled
    }
}
