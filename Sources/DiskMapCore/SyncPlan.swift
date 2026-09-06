import Foundation

public enum SyncDirection: String, Sendable, CaseIterable, Identifiable {
    /// Make the right folder match the left one exactly: copy what is missing,
    /// replace what differs, and move what the left does not have to the Trash.
    case mirrorLeftToRight
    case mirrorRightToLeft
    /// Copy over what is missing or newer and nothing else. Never removes and
    /// never overwrites something the target changed more recently — the safe
    /// one, and the one most days actually want.
    case updateLeftToRight
    case updateRightToLeft
    /// Give each side everything the other has. Never removes anything.
    case merge
    /// Move to the Trash everything on this side that the other side already
    /// holds, and nothing else. What is unique to it stays exactly where it is.
    case removeLeftDuplicates
    case removeRightDuplicates

    public var id: String { rawValue }

    /// Whether anything ends up in the Trash. Gates the refusal to build a plan
    /// from a comparison that could not read everything.
    public var removesThings: Bool {
        switch self {
        case .mirrorLeftToRight, .mirrorRightToLeft,
             .removeLeftDuplicates, .removeRightDuplicates: true
        case .updateLeftToRight, .updateRightToLeft, .merge: false
        }
    }

    /// Whether this frees space rather than propagating content. Worth its own
    /// question because the screen treats the two differently.
    public var freesSpace: Bool {
        self == .removeLeftDuplicates || self == .removeRightDuplicates
    }

    /// The folder being read from, for anything one-directional. Nil for a
    /// merge, which reads from both.
    public var source: Side? {
        switch self {
        case .mirrorLeftToRight, .updateLeftToRight: .left
        case .mirrorRightToLeft, .updateRightToLeft: .right
        case .removeLeftDuplicates: .right
        case .removeRightDuplicates: .left
        case .merge: nil
        }
    }

    /// The side this writes into, or removes from.
    public var target: Side? {
        switch self {
        case .mirrorLeftToRight, .updateLeftToRight: .right
        case .mirrorRightToLeft, .updateRightToLeft: .left
        case .removeLeftDuplicates: .left
        case .removeRightDuplicates: .right
        case .merge: nil
        }
    }
}

public enum SyncAction: String, Sendable {
    /// Nothing is there yet.
    case copy
    /// Something is there and it is not the same. The old one goes to the
    /// Trash before the new one is written, so it is still recoverable.
    case replace
    /// The source does not have it. Mirrors only.
    case remove
}

public struct SyncStep: Sendable, Identifiable {
    public var id: Int
    public var action: SyncAction
    public var relativePath: String
    /// Absolute. Nil for a removal, which has nothing to read.
    public var source: String?
    public var target: String
    public var isDirectory: Bool
    /// Bytes this writes, or for a removal the bytes it moves to the Trash.
    public var bytes: Int64
    /// The item this replaces, whose bytes go to the Trash first.
    public var replacedBytes: Int64
    /// The target sits inside a folder mirrored to a service, so this does not
    /// stop at this machine.
    public var syncProvider: String?
    /// The source is an iCloud placeholder. Copying it downloads it.
    public var dataless: Bool
    /// What sat at the target when the plan was made: its kind, its length and
    /// its date. Between a plan appearing on screen and the button being
    /// pressed, a sync client or another window can put something else at that
    /// path, and a plan is only a description of the files that were there.
    public var targetIsFolder: Bool
    public var targetBytes: Int64
    public var targetModified: Int32
    /// Removing or copying this takes along names the comparison never looked
    /// at, because the ignore patterns left them out.
    public var coversIgnored: Bool

    public var name: String { (relativePath as NSString).lastPathComponent }

    public init(id: Int, action: SyncAction, relativePath: String, source: String?,
                target: String, isDirectory: Bool, bytes: Int64, replacedBytes: Int64,
                syncProvider: String?, dataless: Bool,
                targetIsFolder: Bool = false, targetBytes: Int64 = -1,
                targetModified: Int32 = 0, coversIgnored: Bool = false) {
        self.id = id; self.action = action; self.relativePath = relativePath
        self.source = source; self.target = target; self.isDirectory = isDirectory
        self.bytes = bytes; self.replacedBytes = replacedBytes
        self.syncProvider = syncProvider; self.dataless = dataless
        self.targetIsFolder = targetIsFolder; self.targetBytes = targetBytes
        self.targetModified = targetModified; self.coversIgnored = coversIgnored
    }
}

public struct SyncPlan: Sendable {
    public var direction: SyncDirection
    public var left: String
    public var right: String
    /// In the order they will be carried out.
    public var steps: [SyncStep]
    public var bytesToWrite: Int64
    public var bytesToTrash: Int64
    /// Differences a two-way merge cannot decide on its own: the two sides
    /// disagree and neither is clearly newer, or one is a folder and the other
    /// a file. They are left exactly as they are.
    public var unresolved: [String]
    /// Free space on the volume each side lives on, at the moment of planning.
    public var freeOnLeftVolume: Int64
    public var freeOnRightVolume: Int64
    /// Which volume each folder was on when the plan was made. Checked again
    /// before anything runs: a disk that has been ejected leaves its mount
    /// point behind as an ordinary empty folder on the boot disk, and a mirror
    /// pointed at one would quietly rebuild the whole tree there.
    public var leftDevice: Int32 = 0
    public var rightDevice: Int32 = 0
    /// Copies that would download a file from iCloud rather than move bytes
    /// that are already here.
    public var datalessCopies: Int
    /// Decisions the user unticked.
    public var skipped: Int = 0
    /// Items that look identical and are not: the deep check read both sides
    /// and found different bytes. Never removed, whatever the direction says.
    public var keptBecauseContentDiffers: [String] = []
    /// Items the deep check did not settle - could not open, or left in iCloud
    /// rather than downloading to compare. Never removed either.
    public var keptBecauseUnreadable: [String] = []
    /// Whether the deep check has run at all. A plan that frees space by
    /// trusting name and length alone has to say that is what it is doing.
    public var contentWasChecked: Bool = false

    /// Things moved to the Trash that hold names the comparison never looked
    /// at, because the ignore patterns left them out. Those names exist on that
    /// side alone: nothing matched them, so nothing is keeping a copy.
    public var removesIgnoredItems: Int {
        steps.filter { $0.action != .copy && $0.coversIgnored }.count
    }

    public var copies: Int { steps.filter { $0.action == .copy }.count }
    public var replacements: Int { steps.filter { $0.action == .replace }.count }
    public var removals: Int { steps.filter { $0.action == .remove }.count }
    public var providers: Set<String> { Set(steps.compactMap(\.syncProvider)) }

    /// Room for what this writes.
    ///
    /// Only the writes count. Moving something to the Trash frees nothing until
    /// the Trash is emptied, so a mirror that removes 400 GB and writes 400 GB
    /// still needs 400 GB free.
    public var fits: Bool {
        var onLeft: Int64 = 0, onRight: Int64 = 0
        for step in steps where step.action != .remove {
            if FolderDiff.isInside(step.target, left) { onLeft += step.bytes } else { onRight += step.bytes }
        }
        return onLeft <= freeOnLeftVolume && onRight <= freeOnRightVolume
    }

    public var isEmpty: Bool { steps.isEmpty }

    public init(direction: SyncDirection, left: String, right: String, steps: [SyncStep],
                bytesToWrite: Int64, bytesToTrash: Int64, unresolved: [String],
                freeOnLeftVolume: Int64, freeOnRightVolume: Int64, datalessCopies: Int,
                leftDevice: Int32 = 0, rightDevice: Int32 = 0,
                skipped: Int = 0, keptBecauseContentDiffers: [String] = [],
                keptBecauseUnreadable: [String] = [],
                contentWasChecked: Bool = false) {
        self.skipped = skipped
        self.keptBecauseContentDiffers = keptBecauseContentDiffers
        self.keptBecauseUnreadable = keptBecauseUnreadable
        self.contentWasChecked = contentWasChecked
        self.direction = direction; self.left = left; self.right = right; self.steps = steps
        self.bytesToWrite = bytesToWrite; self.bytesToTrash = bytesToTrash
        self.unresolved = unresolved
        self.freeOnLeftVolume = freeOnLeftVolume; self.freeOnRightVolume = freeOnRightVolume
        self.leftDevice = leftDevice; self.rightDevice = rightDevice
        self.datalessCopies = datalessCopies
    }
}

/// Turns a comparison plus a chosen direction into an explicit list of what
/// would happen — or a refusal.
///
/// Like `TrashPlanner`, this lives in the core rather than in the interface,
/// because the rules that keep a mirror from destroying the only copy of
/// something belong where a test can prove them.
public enum SyncPlanner {
    /// `skipping` holds the ids of decisions the user has unticked, and
    /// `contentDiffers` the relative paths the deep check found to hold
    /// different bytes behind a matching name and length. The second is the
    /// more important of the two: it is the only thing standing between
    /// "remove what the other side already has" and losing the one copy of
    /// something whose twin was never really its twin.
    public static func plan(_ comparison: FolderComparison, direction: SyncDirection,
                            syncRoots: SyncRoots = SyncRoots(roots: []),
                            excluded: [String] = [],
                            skipping: Set<Int> = [],
                            contentCheck: VerifyDifferences? = nil)
    -> Result<SyncPlan, CompareRefusal> {
        // The whole answer, not a selection from it. Handing the planner one
        // list at a time is how "differs" arrived and "could not be read" did
        // not, twice.
        // Every folder above each one, too. A decision is a folder where the
        // check's answers are files, so a folder removed whole takes files the
        // check disagreed about with it unless the taint climbs.
        let contentDiffers = taint(contentCheck?.differing ?? [])
        let contentUnsettled = taint(contentCheck?.unsettled ?? [])
        let contentCheckWasComplete = contentCheck?.cancelled != true
        let left = comparison.left, right = comparison.right
        // Stopped part-way is not a smaller comparison, it is a partial one:
        // the folders it never reached look empty, and a direction that
        // removes things would act on that.
        if comparison.cancelled, direction.removesThings {
            return .failure(.comparisonIncomplete)
        }
        if let refusal = structuralRefusal(left: left, right: right,
                                           writesTo: writeTargets(direction, left, right),
                                           excluded: excluded) {
            return .failure(refusal)
        }
        // What a mirror did not see, it proposes deleting. A comparison with an
        // unreadable folder in it cannot be the basis of one.
        if direction.removesThings, comparison.unreadable > 0 {
            return .failure(.someFoldersUnreadable(comparison.unreadable))
        }

        var steps: [SyncStep] = []
        var unresolved: [String] = []
        var keptBecauseContentDiffers: [String] = []
        var keptBecauseUnreadable: [String] = []
        var skipped = 0
        var removals: [SyncStep] = [], replacements: [SyncStep] = [], copies: [SyncStep] = []

        for entry in comparison.entries {
            guard !skipping.contains(entry.id) else { skipped += 1; continue }

            // Freeing space is its own shape: only what the other side already
            // holds goes, and only where nothing has said otherwise.
            // A doorway to another disk. It is on the screen so nobody wonders
            // where it went, and it is left exactly as it is, whatever the
            // direction says.
            if entry.notCompared { unresolved.append(entry.relativePath); continue }

            if direction.freesSpace {
                guard entry.kind == .identical, let side = direction.target else { continue }
                guard !contentDiffers.contains(entry.relativePath) else {
                    keptBecauseContentDiffers.append(entry.relativePath); continue
                }
                // Not opened is not the same as opened and found to agree. A
                // file nobody could read is a file nobody can say is held
                // somewhere else.
                guard !contentUnsettled.contains(entry.relativePath) else {
                    keptBecauseUnreadable.append(entry.relativePath); continue
                }
                removals.append(step(.remove, entry, from: side, comparison, syncRoots))
                continue
            }

            switch (direction, entry.kind) {
            case (_, .identical):
                continue

            case (.mirrorLeftToRight, .onlyLeft), (.updateLeftToRight, .onlyLeft),
                 (.merge, .onlyLeft):
                copies.append(step(.copy, entry, from: .left, comparison, syncRoots))
            case (.mirrorRightToLeft, .onlyRight), (.updateRightToLeft, .onlyRight),
                 (.merge, .onlyRight):
                copies.append(step(.copy, entry, from: .right, comparison, syncRoots))

            case (.mirrorLeftToRight, .onlyRight):
                // The item is on the right and that is where it goes from.
                removals.append(step(.remove, entry, from: .right, comparison, syncRoots))
            case (.mirrorRightToLeft, .onlyLeft):
                removals.append(step(.remove, entry, from: .left, comparison, syncRoots))
            case (.mirrorLeftToRight, .differs), (.mirrorLeftToRight, .typeClash):
                replacements.append(step(.replace, entry, from: .left, comparison, syncRoots))
            case (.mirrorRightToLeft, .differs), (.mirrorRightToLeft, .typeClash):
                replacements.append(step(.replace, entry, from: .right, comparison, syncRoots))

            // An update carries the source over only where the source is the
            // newer of the two. Where the target was touched more recently, or
            // where the dates cannot separate them, it stops and says so rather
            // than overwriting work it cannot account for.
            case (.updateLeftToRight, .differs), (.updateRightToLeft, .differs),
                 (.updateLeftToRight, .typeClash), (.updateRightToLeft, .typeClash):
                guard let from = direction.source, entry.newerSide == from else {
                    unresolved.append(entry.relativePath); continue
                }
                replacements.append(step(.replace, entry, from: from, comparison, syncRoots))
            case (.updateLeftToRight, .onlyRight), (.updateRightToLeft, .onlyLeft):
                continue

            case (.merge, .differs):
                // Newest wins, and only when there is a newest. Two files of
                // different lengths stamped with the same second are a question
                // nobody can answer from metadata, so neither is touched.
                guard let newer = entry.newerSide else {
                    unresolved.append(entry.relativePath); continue
                }
                replacements.append(step(.replace, entry, from: newer, comparison, syncRoots))
            case (.merge, .typeClash):
                // A folder on one side and a file on the other is not a
                // conflict a rule should settle.
                unresolved.append(entry.relativePath)

            case (.removeLeftDuplicates, _), (.removeRightDuplicates, _):
                continue  // handled above, before the switch
            }
        }

        // Removals first: on a case-insensitive volume `README` and `readme`
        // are two entries here and one name on disk, so writing before removing
        // would collide. Replacements before plain copies for the same reason.
        steps = removals + replacements + copies
        for index in steps.indices { steps[index].id = index }
        guard !steps.isEmpty else { return .failure(.nothingToDo) }

        let out = SyncPlan(
            direction: direction, left: left, right: right, steps: steps,
            bytesToWrite: steps.filter { $0.action != .remove }.reduce(0) { $0 + $1.bytes },
            bytesToTrash: steps.reduce(0) { $0 + ($1.action == .remove ? $1.bytes : $1.replacedBytes) },
            unresolved: unresolved,
            freeOnLeftVolume: VolumeInfo.forPath(left)?.trueAvailable ?? 0,
            freeOnRightVolume: VolumeInfo.forPath(right)?.trueAvailable ?? 0,
            datalessCopies: steps.filter { $0.dataless && $0.action != .remove }.count,
            leftDevice: deviceOf(left), rightDevice: deviceOf(right),
            skipped: skipped,
            keptBecauseContentDiffers: keptBecauseContentDiffers,
            keptBecauseUnreadable: keptBecauseUnreadable,
            // A check that was stopped part-way read some of the files and
            // none of the rest, which is not the sentence this flag stands
            // for on the screen.
            contentWasChecked: comparison.verifiedAt != nil && contentCheckWasComplete)
        return .success(out)
    }

    /// Trashing one whole copy, once the comparison says the other holds
    /// everything it does.
    ///
    /// The refusal is the point: "delete the redundant one" is only a safe
    /// sentence when nothing on the side being removed is unique to it.
    public static func removeRedundant(_ comparison: FolderComparison, side: Side,
                                       syncRoots: SyncRoots = SyncRoots(roots: []),
                                       excluded: [String] = [],
                                       contentCheck: VerifyDifferences? = nil)
    -> Result<SyncPlan, CompareRefusal> {
        if comparison.cancelled { return .failure(.comparisonIncomplete) }
        let target = side == .left ? comparison.left : comparison.right
        if let refusal = structuralRefusal(left: comparison.left, right: comparison.right,
                                           writesTo: [target], excluded: excluded) {
            return .failure(refusal)
        }
        // A folder that could not be fully read cannot be shown to be redundant.
        if comparison.unreadable > 0 { return .failure(.someFoldersUnreadable(comparison.unreadable)) }
        // Nor can one holding a doorway to another disk: taking this side whole
        // takes that folder too, and nothing under it was ever looked at.
        if let volume = comparison.volumesInside.first {
            return .failure(.volumeMountedInside(volume))
        }
        guard comparison.summary.isCoveredByTheOtherSide(side) else { return .failure(.notRedundant) }
        // "Covered by the other side" is a claim about names and lengths. Once
        // the content check has read the bytes and disagreed about even one of
        // them, this side holds something the other one does not, and taking
        // the whole of it is exactly the mistake the check exists to stop.
        // "Covered by the other side" is a claim about names and lengths. If a
        // check ran, it has to have settled every one of them: bytes that
        // disagreed, a file nobody could open, a placeholder nobody downloaded
        // and a check that was stopped part-way all leave the claim unproven
        // rather than proven.
        if let check = contentCheck, !check.agreed { return .failure(.notRedundant) }

        let bytes = side == .left ? comparison.leftTotal : comparison.rightTotal
        // The folder as it stands right now, so the runner can tell whether
        // anything was put into it between here and the button.
        var info = stat()
        guard lstat(target, &info) == 0 else { return .failure(.notRedundant) }
        let step = SyncStep(id: 0, action: .remove, relativePath: "", source: nil,
                            target: target, isDirectory: true, bytes: bytes,
                            replacedBytes: 0, syncProvider: syncRoots.provider(for: target),
                            dataless: false,
                            targetIsFolder: true, targetBytes: -1,
                            targetModified: Int32(truncatingIfNeeded: info.st_mtimespec.tv_sec),
                            coversIgnored: comparison.tree.coversIgnored(0, on: side))
        return .success(SyncPlan(
            direction: side == .left ? .mirrorRightToLeft : .mirrorLeftToRight,
            left: comparison.left, right: comparison.right, steps: [step],
            bytesToWrite: 0, bytesToTrash: bytes, unresolved: [],
            freeOnLeftVolume: VolumeInfo.forPath(comparison.left)?.trueAvailable ?? 0,
            freeOnRightVolume: VolumeInfo.forPath(comparison.right)?.trueAvailable ?? 0,
            datalessCopies: 0,
            leftDevice: deviceOf(comparison.left), rightDevice: deviceOf(comparison.right),
            contentWasChecked: comparison.verifiedAt != nil && contentCheck?.cancelled != true))
    }

    // MARK: - Refusals

    /// The folders this would write into or remove from — everything the
    /// structural refusals have to be checked against.
    private static func writeTargets(_ direction: SyncDirection,
                                     _ left: String, _ right: String) -> [String] {
        switch direction.target {
        case .left: [left]
        case .right: [right]
        case nil: [left, right]
        }
    }

    private static func structuralRefusal(left: String, right: String,
                                          writesTo: [String],
                                          excluded: [String]) -> CompareRefusal? {
        guard FolderDiff.isDirectory(left) else { return .notAFolder(left) }
        guard FolderDiff.isDirectory(right) else { return .notAFolder(right) }
        if left == right { return .sameFolder(left) }

        // Before the nesting check, because every folder on the machine is
        // inside "/" and "these are nested" is the less useful thing to say
        // about a plan whose target is a whole volume.
        for target in writesTo {
            // Mirroring onto a volume would propose trashing everything the
            // source does not happen to have, which on a startup disk is the
            // operating system.
            if DiskScanner.isVolumeRoot(target) { return .wouldWriteToAVolumeRoot(target) }
            // Resolved, because the never-touch list holds paths the user
            // picked and these are paths the walk produced: /var and
            // /private/var are the same folder, and a guard that misses that
            // is a guard that is silently absent.
            for raw in excluded {
                let path = canonicalPath(raw) ?? raw
                if FolderDiff.isInside(target, path) || FolderDiff.isInside(path, target) {
                    return .onTheNeverTouchList(raw)
                }
            }
        }

        if FolderDiff.isInside(left, right) { return .nested(inner: left, outer: right) }
        if FolderDiff.isInside(right, left) { return .nested(inner: right, outer: left) }
        return nil
    }

    /// `source` names the side the item is read from. A removal has no source
    /// to read: it names the side the item is removed *from*, and that is where
    /// the step points.
    /// Each path, plus every folder above it.
    static func taint(_ paths: [String]) -> Set<String> {
        var out = Set<String>()
        for path in paths {
            out.insert(path)
            var current = Substring(path)
            while let slash = current.lastIndex(of: "/") {
                current = current[current.startIndex..<slash]
                out.insert(String(current))
            }
        }
        return out
    }

    static func deviceOf(_ path: String) -> Int32 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return Int32(truncatingIfNeeded: info.st_dev)
    }

    private static func step(_ action: SyncAction, _ entry: DiffEntry, from source: Side,
                             _ comparison: FolderComparison, _ syncRoots: SyncRoots) -> SyncStep {
        let here = comparison.path(entry.relativePath, on: source)
        let target = action == .remove ? here : comparison.path(entry.relativePath, on: source.other)
        let targetSide = action == .remove ? source : source.other
        return SyncStep(
            id: 0, action: action, relativePath: entry.relativePath,
            source: action == .remove ? nil : here,
            target: target,
            isDirectory: entry.isDirectory,
            // Two different questions. What a removal frees is the space the
            // item occupies, where a second name for one file occupies
            // nothing. What a copy writes is the size of the file, and copying
            // two names for one file makes two files, each the full size.
            bytes: action == .remove ? entry.bytes(on: source) : entry.logical(on: source),
            replacedBytes: action == .replace ? entry.bytes(on: source.other) : 0,
            syncProvider: syncRoots.provider(for: target),
            dataless: entry.dataless,
            targetIsFolder: entry.isFolder(on: targetSide),
            targetBytes: entry.logical(on: targetSide),
            targetModified: entry.modified(on: targetSide),
            coversIgnored: entry.coversIgnored)
    }
}

// MARK: - Carrying it out

public struct SyncFailure: Sendable, Identifiable {
    public var id: Int
    public var relativePath: String
    public var action: SyncAction
    public var message: String
}

public struct SyncProgress: Sendable {
    public var stepsDone: Int
    public var stepsTotal: Int
    public var bytesWritten: Int64
    public var currentPath: String

    public init(stepsDone: Int, stepsTotal: Int, bytesWritten: Int64, currentPath: String) {
        self.stepsDone = stepsDone; self.stepsTotal = stepsTotal
        self.bytesWritten = bytesWritten; self.currentPath = currentPath
    }
}

public struct SyncOutcome: Sendable {
    public var completed = 0
    public var bytesWritten: Int64 = 0
    public var bytesTrashed: Int64 = 0
    public var failures: [SyncFailure] = []
    /// Everything that went to the Trash, so the result screen can point at it.
    public var trashed: [TrashedItem] = []
    public var cancelled = false
    /// Why nothing was attempted at all. Set instead of `failures` when the
    /// run was stopped before its first step.
    public var refused: String?
    public var succeeded: Bool { failures.isEmpty && !cancelled && refused == nil }
}

/// Carries out a plan.
///
/// Two rules hold whatever the plan says. Nothing is ever deleted — every
/// removal, including the old version of a file being replaced, goes to the
/// Trash, where Finder's *Put Back* still works. And no step may touch a path
/// outside the two folders that were compared; a step that would is refused
/// here as well as at planning time, because this is the last place before the
/// filesystem.
public enum SyncRunner {
    public static func run(_ plan: SyncPlan, cancel: CancelToken? = nil,
                           progress: ((SyncProgress) -> Void)? = nil) -> SyncOutcome {
        let span = Telemetry.begin("sync.run")
        var outcome = SyncOutcome()
        let fm = FileManager.default

        if let moved = rootsMoved(plan) {
            outcome.refused = moved
            span.end(["direction": .text(plan.direction.rawValue), "refused": .flag(true)])
            return outcome
        }

        for step in plan.steps {
            if cancel?.isCancelled == true { outcome.cancelled = true; break }
            progress?(SyncProgress(stepsDone: outcome.completed, stepsTotal: plan.steps.count,
                                   bytesWritten: outcome.bytesWritten,
                                   currentPath: step.relativePath))

            guard isWithin(step.target, plan), step.source.map({ isWithin($0, plan) }) ?? true else {
                outcome.failures.append(SyncFailure(id: step.id, relativePath: step.relativePath,
                                                    action: step.action,
                                                    message: "outside the folders being compared"))
                continue
            }

            if step.action != .copy, let changed = drift(step) {
                outcome.failures.append(SyncFailure(id: step.id, relativePath: step.relativePath,
                                                    action: step.action, message: changed))
                continue
            }

            do {
                switch step.action {
                case .remove:
                    guard let item = try trash(step.target, bytes: step.bytes) else { break }
                    outcome.trashed.append(item)
                    outcome.bytesTrashed += step.bytes
                case .replace:
                    if let item = try replace(step, fm: fm) {
                        outcome.trashed.append(item)
                        outcome.bytesTrashed += step.replacedBytes
                    }
                    outcome.bytesWritten += step.bytes
                case .copy:
                    try copy(step.source!, to: step.target, fm: fm)
                    outcome.bytesWritten += step.bytes
                }
                outcome.completed += 1
            } catch {
                outcome.failures.append(SyncFailure(id: step.id, relativePath: step.relativePath,
                                                    action: step.action,
                                                    message: error.localizedDescription))
            }
        }
        progress?(SyncProgress(stepsDone: outcome.completed, stepsTotal: plan.steps.count,
                               bytesWritten: outcome.bytesWritten, currentPath: ""))
        span.end(["direction": .text(plan.direction.rawValue),
                  "steps": .int(Int64(plan.steps.count)),
                  "completed": .int(Int64(outcome.completed)),
                  "written": .int(outcome.bytesWritten),
                  "trashed": .int(outcome.bytesTrashed),
                  "failures": .int(Int64(outcome.failures.count)),
                  "cancelled": .flag(outcome.cancelled)])
        return outcome
    }

    /// Nil when there was nothing there, which is not a failure: a mirror run
    /// twice, or a folder someone tidied in between, both land here.
    /// Why nothing should be attempted, or nil when both folders are where the
    /// plan left them.
    private static func rootsMoved(_ plan: SyncPlan) -> String? {
        for (path, device) in [(plan.left, plan.leftDevice), (plan.right, plan.rightDevice)] {
            var info = stat()
            guard lstat(path, &info) == 0 else { return "\(path) is no longer there" }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { return "\(path) is no longer a folder" }
            // A device of zero means the plan predates this check rather than
            // that the folder was on device zero.
            if device != 0, Int32(truncatingIfNeeded: info.st_dev) != device {
                return "\(path) is on a different disk than when the plan was made"
            }
        }
        return nil
    }

    /// Why this step must not go ahead, or nil when the target is still the
    /// item the plan described.
    ///
    /// A missing target is not drift: nothing is there to lose, and `trash`
    /// treats it as a step with nothing to do.
    private static func drift(_ step: SyncStep) -> String? {
        FileActions.changedSincePlanning(step.target, isFolder: step.targetIsFolder,
                                         bytes: step.targetBytes, modified: step.targetModified)
    }

    private static func trash(_ path: String, bytes: Int64) throws -> TrashedItem? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var resulting: NSURL?
        let url = URL(fileURLWithPath: path)
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return TrashedItem(originalURL: url, trashURL: resulting as URL?,
                           bytesFreed: bytes, node: -1)
    }

    /// Writes the replacement beside the target first, and only then moves the
    /// old one out and puts the new one in its place.
    ///
    /// The obvious order — trash the old, copy the new — leaves the path empty
    /// for as long as the copy takes, and empty for good if the copy fails. A
    /// full disk, a source that has gone away, a permission: any of them and
    /// the file the user was replacing is in the Trash with nothing standing
    /// where it was.
    private static func replace(_ step: SyncStep, fm: FileManager) throws -> TrashedItem? {
        let staging = step.target + ".diskmap-incoming-\(step.id)"
        do {
            try copy(step.source!, to: staging, fm: fm)
        } catch {
            try? discard(staging)
            throw error
        }
        let old: TrashedItem?
        do {
            old = try trash(step.target, bytes: step.replacedBytes)
        } catch {
            try? discard(staging)
            throw error
        }
        // Atomic, and onto a name nothing is holding: the old item has just
        // been moved out, and both paths are in the same folder.
        guard staging.withCString({ from in step.target.withCString { rename(from, $0) } }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey:
                    "the replacement was written next to it but could not take its place"])
        }
        return old
    }

    /// Gets rid of a half-written replacement this run made itself.
    ///
    /// Through the Trash like everything else, because the one thing worse
    /// than a stray file is a delete path that turns out to have been pointed
    /// somewhere else.
    private static func discard(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    private static func copy(_ source: String, to target: String, fm: FileManager) throws {
        let targetURL = URL(fileURLWithPath: target)
        try fm.createDirectory(at: targetURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        // Never over the top of something: if the target reappeared between
        // planning and now, this throws rather than silently taking its place.
        try fm.copyItem(atPath: source, toPath: target)
        // copyItem carries the modification date across, but a mirror whose
        // dates drift shows every file as changed on the next comparison, so
        // the top-level item is set explicitly rather than assumed.
        if let date = (try? fm.attributesOfItem(atPath: source))?[.modificationDate] as? Date {
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: target)
        }
    }

    private static func isWithin(_ path: String, _ plan: SyncPlan) -> Bool {
        FolderDiff.isInside(path, plan.left) || FolderDiff.isInside(path, plan.right)
    }
}
