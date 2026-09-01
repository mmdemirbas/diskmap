import Foundation

public enum SyncDirection: String, Sendable, CaseIterable, Identifiable {
    /// Make the right folder match the left one: copy what is missing, replace
    /// what differs, and move what the left does not have to the Trash.
    case mirrorLeftToRight
    case mirrorRightToLeft
    /// Give each side everything the other has. Never removes anything.
    case merge

    public var id: String { rawValue }
    public var removesThings: Bool { self != .merge }
    /// The folder being read from, for a mirror. Nil for a merge, which reads
    /// from both.
    public var source: Side? {
        switch self {
        case .mirrorLeftToRight: .left
        case .mirrorRightToLeft: .right
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

    public var name: String { (relativePath as NSString).lastPathComponent }

    public init(id: Int, action: SyncAction, relativePath: String, source: String?,
                target: String, isDirectory: Bool, bytes: Int64, replacedBytes: Int64,
                syncProvider: String?, dataless: Bool) {
        self.id = id; self.action = action; self.relativePath = relativePath
        self.source = source; self.target = target; self.isDirectory = isDirectory
        self.bytes = bytes; self.replacedBytes = replacedBytes
        self.syncProvider = syncProvider; self.dataless = dataless
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
    /// Copies that would download a file from iCloud rather than move bytes
    /// that are already here.
    public var datalessCopies: Int

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
                freeOnLeftVolume: Int64, freeOnRightVolume: Int64, datalessCopies: Int) {
        self.direction = direction; self.left = left; self.right = right; self.steps = steps
        self.bytesToWrite = bytesToWrite; self.bytesToTrash = bytesToTrash
        self.unresolved = unresolved
        self.freeOnLeftVolume = freeOnLeftVolume; self.freeOnRightVolume = freeOnRightVolume
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
    public static func plan(_ comparison: FolderComparison, direction: SyncDirection,
                            syncRoots: SyncRoots = SyncRoots(roots: []),
                            excluded: [String] = []) -> Result<SyncPlan, CompareRefusal> {
        let left = comparison.left, right = comparison.right
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
        var removals: [SyncStep] = [], replacements: [SyncStep] = [], copies: [SyncStep] = []

        for entry in comparison.entries {
            switch (direction, entry.kind) {
            case (_, .identical):
                continue

            case (.mirrorLeftToRight, .onlyLeft), (.merge, .onlyLeft):
                copies.append(step(.copy, entry, from: .left, comparison, syncRoots))
            case (.mirrorRightToLeft, .onlyRight), (.merge, .onlyRight):
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
            datalessCopies: steps.filter { $0.dataless && $0.action != .remove }.count)
        return .success(out)
    }

    /// Trashing one whole copy, once the comparison says the other holds
    /// everything it does.
    ///
    /// The refusal is the point: "delete the redundant one" is only a safe
    /// sentence when nothing on the side being removed is unique to it.
    public static func removeRedundant(_ comparison: FolderComparison, side: Side,
                                       syncRoots: SyncRoots = SyncRoots(roots: []),
                                       excluded: [String] = []) -> Result<SyncPlan, CompareRefusal> {
        let target = side == .left ? comparison.left : comparison.right
        if let refusal = structuralRefusal(left: comparison.left, right: comparison.right,
                                           writesTo: [target], excluded: excluded) {
            return .failure(refusal)
        }
        // A folder that could not be fully read cannot be shown to be redundant.
        if comparison.unreadable > 0 { return .failure(.someFoldersUnreadable(comparison.unreadable)) }
        guard comparison.summary.isCoveredByTheOtherSide(side) else { return .failure(.notRedundant) }

        let bytes = side == .left ? comparison.leftTotal : comparison.rightTotal
        let step = SyncStep(id: 0, action: .remove, relativePath: "", source: nil,
                            target: target, isDirectory: true, bytes: bytes,
                            replacedBytes: 0, syncProvider: syncRoots.provider(for: target),
                            dataless: false)
        return .success(SyncPlan(
            direction: side == .left ? .mirrorRightToLeft : .mirrorLeftToRight,
            left: comparison.left, right: comparison.right, steps: [step],
            bytesToWrite: 0, bytesToTrash: bytes, unresolved: [],
            freeOnLeftVolume: VolumeInfo.forPath(comparison.left)?.trueAvailable ?? 0,
            freeOnRightVolume: VolumeInfo.forPath(comparison.right)?.trueAvailable ?? 0,
            datalessCopies: 0))
    }

    // MARK: - Refusals

    private static func writeTargets(_ direction: SyncDirection,
                                     _ left: String, _ right: String) -> [String] {
        switch direction {
        case .mirrorLeftToRight: [right]
        case .mirrorRightToLeft: [left]
        case .merge: [left, right]
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
    private static func step(_ action: SyncAction, _ entry: DiffEntry, from source: Side,
                             _ comparison: FolderComparison, _ syncRoots: SyncRoots) -> SyncStep {
        let here = comparison.path(entry.relativePath, on: source)
        let target = action == .remove ? here : comparison.path(entry.relativePath, on: source.other)
        return SyncStep(
            id: 0, action: action, relativePath: entry.relativePath,
            source: action == .remove ? nil : here,
            target: target,
            isDirectory: entry.isDirectory,
            bytes: entry.bytes(on: source),
            replacedBytes: action == .replace ? entry.bytes(on: source.other) : 0,
            syncProvider: syncRoots.provider(for: target),
            dataless: entry.dataless)
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
    public var succeeded: Bool { failures.isEmpty && !cancelled }
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

            do {
                switch step.action {
                case .remove:
                    guard let item = try trash(step.target, bytes: step.bytes) else { break }
                    outcome.trashed.append(item)
                    outcome.bytesTrashed += step.bytes
                case .replace:
                    if let item = try trash(step.target, bytes: step.replacedBytes) {
                        outcome.trashed.append(item)
                        outcome.bytesTrashed += step.replacedBytes
                    }
                    try copy(step.source!, to: step.target, fm: fm)
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
    private static func trash(_ path: String, bytes: Int64) throws -> TrashedItem? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var resulting: NSURL?
        let url = URL(fileURLWithPath: path)
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return TrashedItem(originalURL: url, trashURL: resulting as URL?,
                           bytesFreed: bytes, node: -1)
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
