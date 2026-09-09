import Foundation

public enum AgeBucket: Int, CaseIterable, Sendable {
    case week, month, halfYear, year, twoYears, older

    /// Upper bound in days; `older` has none.
    public var days: Double? {
        switch self {
        case .week: 7;      case .month: 30
        case .halfYear: 182; case .year: 365
        case .twoYears: 730; case .older: nil
        }
    }

    public static func of(secondsAgo: Double) -> AgeBucket {
        let days = secondsAgo / 86_400
        for bucket in AgeBucket.allCases {
            if let limit = bucket.days, days < limit { return bucket }
        }
        return .older
    }
}

public struct CategoryUsage: Sendable {
    public var category: FileCategory
    public var bytes: Int64
    public var files: Int
}

public struct AgeUsage: Sendable {
    public var bucket: AgeBucket
    public var bytes: Int64
    public var files: Int
}

/// The few figures the capacity screen reconciles against a volume, for one
/// subtree rather than for the whole scan.
///
/// Scanning two disks at once used to compare the *combined* scanned bytes
/// against each disk's own used figure, which is two unrelated quantities in
/// one sentence. Every number here comes from one root, so a volume's screen
/// only ever holds that volume's data.
public struct SubtreeTotals: Sendable {
    public var physical: Int64 = 0
    public var datalessLogical: Int64 = 0
    public var datalessCount = 0
    public var hardlinkDuplicateLogical: Int64 = 0
    public var hardlinkDuplicateCount = 0
    public var unreadableDirectories = 0

    public init() {}

    public static func + (a: SubtreeTotals, b: SubtreeTotals) -> SubtreeTotals {
        var out = SubtreeTotals()
        out.physical = a.physical + b.physical
        out.datalessLogical = a.datalessLogical + b.datalessLogical
        out.datalessCount = a.datalessCount + b.datalessCount
        out.hardlinkDuplicateLogical = a.hardlinkDuplicateLogical + b.hardlinkDuplicateLogical
        out.hardlinkDuplicateCount = a.hardlinkDuplicateCount + b.hardlinkDuplicateCount
        out.unreadableDirectories = a.unreadableDirectories + b.unreadableDirectories
        return out
    }
}

public struct SubtreeSummary: Sendable {
    /// Node ids, biggest first. Files only, from anywhere in the subtree.
    public var largestFiles: [Int32] = []
    public var byCategory: [CategoryUsage] = []
    public var byAge: [AgeUsage] = []
    public var files = 0
    public var directories = 0
    public var totalPhysical: Int64 = 0
}

/// Whole-subtree reports.
///
/// The tree table answers "what is in this folder". These answer "where did the
/// space actually go", which is the question someone opens a disk analyser
/// with: the biggest files anywhere below here, what kinds of file they are,
/// and how much of it has not been touched in years.
public enum Aggregate {
    /// What one root holds, for reconciling against the volume it sits on.
    ///
    /// The physical total is already aggregated on the node; the rest are
    /// properties of individual files and need the walk. One pass, and only
    /// when a breakdown is actually asked for.
    public static func totals(store: NodeStore, root: Int32) -> SubtreeTotals {
        var out = SubtreeTotals()
        guard root >= 0, root < Int32(store.count) else { return out }
        out.physical = store.totalPhysical[Int(root)]

        var stack: [Int32] = [root]
        while let node = stack.popLast() {
            for child in store.children(node) {
                let index = Int(child)
                let flags = store.flagSet(child)
                if flags.contains(.removed) { continue }
                if flags.contains(.dataless) {
                    out.datalessLogical += store.totalLogical[index]
                    out.datalessCount += 1
                }
                if flags.contains(.hardlinkDuplicate) {
                    out.hardlinkDuplicateLogical += store.totalLogical[index]
                    out.hardlinkDuplicateCount += 1
                }
                if store.isDirectory(child) {
                    if flags.contains(.unreadable) { out.unreadableDirectories += 1 }
                    stack.append(child)
                }
            }
        }
        return out
    }

    public static func summarize(store: NodeStore, root: Int32,
                                 usePhysicalSize: Bool = true,
                                 largestCount: Int = 300,
                                 now: Date = Date()) -> SubtreeSummary {
        let span = Telemetry.begin("report.summary")
        defer { span.end(["nodes": .int(Int64(store.count))]) }
        var summary = SubtreeSummary()
        guard root >= 0, root < Int32(store.count) else { return summary }

        let sizes = usePhysicalSize ? store.totalPhysical : store.totalLogical
        var categoryBytes = [Int64](repeating: 0, count: FileCategory.allCases.count)
        var categoryFiles = [Int](repeating: 0, count: FileCategory.allCases.count)
        var ageBytes = [Int64](repeating: 0, count: AgeBucket.allCases.count)
        var ageFiles = [Int](repeating: 0, count: AgeBucket.allCases.count)

        // Top-N by insertion into a short sorted array. After the first few
        // hundred entries almost everything fails the threshold test outright.
        var largest: [(id: Int32, size: Int64)] = []
        largest.reserveCapacity(largestCount + 1)
        var threshold: Int64 = 0

        let nowSeconds = now.timeIntervalSince1970
        var stack: [Int32] = [root]

        store.nameBytes.withUnsafeBufferPointer { nameBuffer in
            guard let names = nameBuffer.baseAddress else { return }
            while let node = stack.popLast() {
                for child in store.children(node) {
                    let index = Int(child)
                    let flags = store.flagSet(child)
                    if flags.contains(.removed) { continue }

                    if store.isDirectory(child) {
                        summary.directories += 1
                        stack.append(child)
                        continue
                    }
                    summary.files += 1
                    let size = sizes[index]
                    summary.totalPhysical += store.totalPhysical[index]

                    let category = Categorizer.category(
                        bytes: names + Int(store.nameOffset[index]),
                        length: Int(store.nameLen[index]),
                        isDirectory: false)
                    categoryBytes[category.rawValue] += size
                    categoryFiles[category.rawValue] += 1

                    let bucket = AgeBucket.of(secondsAgo: nowSeconds - Double(store.mtime[index]))
                    ageBytes[bucket.rawValue] += size
                    ageFiles[bucket.rawValue] += 1

                    if size > threshold || largest.count < largestCount {
                        let position = largest.firstIndex { $0.size < size } ?? largest.count
                        largest.insert((child, size), at: position)
                        if largest.count > largestCount { largest.removeLast() }
                        threshold = largest.count >= largestCount ? largest[largest.count - 1].size : 0
                    }
                }
            }
        }

        summary.largestFiles = largest.map(\.id)
        summary.byCategory = FileCategory.allCases
            .map { CategoryUsage(category: $0, bytes: categoryBytes[$0.rawValue],
                                 files: categoryFiles[$0.rawValue]) }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
        summary.byAge = AgeBucket.allCases
            .map { AgeUsage(bucket: $0, bytes: ageBytes[$0.rawValue], files: ageFiles[$0.rawValue]) }
        return summary
    }
}
