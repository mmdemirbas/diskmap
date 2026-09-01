import CryptoKit
import Darwin
import Foundation

public struct VerifyFile: Sendable {
    public var path: String
    /// Position inside the folder being verified, so the same tree under two
    /// different names compares equal.
    public var relative: String
    public var bytes: Int64
}

public struct VerifyItem: Sendable {
    public var node: Int32
    public var files: [VerifyFile]
    /// Placeholders that live only in iCloud. Reading one would download it, so
    /// they are left alone and counted instead.
    public var skipped: Int
}

public struct VerifyPlan: Sendable {
    public var items: [VerifyItem]
    public var files: Int
    public var bytes: Int64
    public var skipped: Int
}

public struct VerifyResult: Sendable {
    public var node: Int32
    public var digest: String
    public var unread: Int
    public var skipped: Int
}

public struct VerifyOutcome: Sendable {
    public var results: [VerifyResult]
    public var cancelled: Bool
    /// True when every folder produced the same digest and nothing was left out.
    public var identical: Bool {
        !cancelled && results.count > 1
            && Set(results.map(\.digest)).count == 1
            && results.allSatisfy { $0.unread == 0 && $0.skipped == 0 }
    }
    /// Distinct contents among the folders compared.
    public var distinct: Int { Set(results.map(\.digest)).count }
    public var unread: Int { results.reduce(0) { $0 + $1.unread } }
    public var skipped: Int { results.reduce(0) { $0 + $1.skipped } }
}

/// Answers the question the metadata match cannot: are these actually the same
/// bytes? It reads every file, so it only ever runs when asked for.
///
/// Split in two on purpose. `plan` touches the tree and must be called while
/// the store is locked; `run` touches only the filesystem and can take minutes,
/// so it must not hold that lock.
public enum DeepVerify {
    public static func plan(store: NodeStore, nodes: [Int32]) -> VerifyPlan {
        var items: [VerifyItem] = []
        var totalFiles = 0
        var totalBytes: Int64 = 0
        var totalSkipped = 0

        for node in nodes {
            var files: [VerifyFile] = []
            var skipped = 0
            let base = store.path(node)
            let prefix = base.hasSuffix("/") ? base.count : base.count + 1

            var stack: [Int32] = [node]
            if !store.isDirectory(node) {
                files.append(VerifyFile(path: base, relative: store.name(node),
                                        bytes: store.totalLogical[Int(node)]))
                stack = []
                if store.flagSet(node).contains(.dataless) { files.removeAll(); skipped += 1 }
            }
            while let current = stack.popLast() {
                for child in store.children(current) {
                    let flags = store.flagSet(child)
                    if flags.contains(.removed) { continue }
                    if store.isDirectory(child) { stack.append(child); continue }
                    if flags.contains(.symlink) { continue }
                    if flags.contains(.dataless) { skipped += 1; continue }
                    let path = store.path(child)
                    files.append(VerifyFile(path: path, relative: String(path.dropFirst(prefix)),
                                            bytes: store.totalLogical[Int(child)]))
                }
            }
            files.sort { $0.relative < $1.relative }
            totalFiles += files.count
            totalBytes += files.reduce(0) { $0 + $1.bytes }
            totalSkipped += skipped
            items.append(VerifyItem(node: node, files: files, skipped: skipped))
        }
        return VerifyPlan(items: items, files: totalFiles, bytes: totalBytes, skipped: totalSkipped)
    }

    /// `progress` receives the running total of bytes read, serialised and no
    /// more often than every `progressStep` bytes — a 50 GB folder would
    /// otherwise report fifty thousand times.
    public static func run(_ plan: VerifyPlan, cancel: CancelToken? = nil,
                           progressStep: Int64 = 64 << 20,
                           progress: ((Int64) -> Void)? = nil) -> VerifyOutcome {
        guard !plan.items.isEmpty else { return VerifyOutcome(results: [], cancelled: false) }
        let span = Telemetry.begin("verify")
        let tally = Tally(step: progressStep, report: progress)
        var results = [VerifyResult?](repeating: nil, count: plan.items.count)

        results.withUnsafeMutableBufferPointer { out in
            let sink = UncheckedSendable(out.baseAddress!)
            // Folders are hashed in parallel; there are usually two of them and
            // the drive is happier with more than one request in flight.
            DispatchQueue.concurrentPerform(iterations: plan.items.count) { index in
                let item = plan.items[index]
                var folder = SHA256()
                var unread = 0
                for file in item.files {
                    if cancel?.isCancelled == true { break }
                    guard let digest = hash(file.path, cancel: cancel, tally: tally) else {
                        unread += 1
                        continue
                    }
                    folder.update(data: Data(file.relative.utf8))
                    folder.update(data: Data([0]))
                    folder.update(data: Data(digest))
                }
                sink.value[index] = VerifyResult(node: item.node,
                                                 digest: hex(folder.finalize()),
                                                 unread: unread, skipped: item.skipped)
            }
        }
        tally.flush()
        let outcome = VerifyOutcome(results: results.compactMap { $0 },
                                    cancelled: cancel?.isCancelled == true)
        span.end(["folders": .int(Int64(plan.items.count)), "files": .int(Int64(plan.files)),
                  "bytes": .int(plan.bytes), "distinct": .int(Int64(outcome.distinct)),
                  "identical": .flag(outcome.identical), "cancelled": .flag(outcome.cancelled),
                  "unread": .int(Int64(outcome.unread)), "skipped": .int(Int64(outcome.skipped))])
        return outcome
    }

    private static func hash(_ path: String, cancel: CancelToken?, tally: Tally) -> [UInt8]? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // Verifying can read hundreds of gigabytes. Keeping it out of the page
        // cache leaves the rest of the machine's working set alone.
        _ = fcntl(fd, F_NOCACHE, 1)
        _ = fcntl(fd, F_RDAHEAD, 1)

        var hasher = SHA256()
        let size = 1 << 20
        var buffer = [UInt8](repeating: 0, count: size)
        while true {
            if cancel?.isCancelled == true { return nil }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, size) }
            if n < 0 { return nil }
            if n == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            tally.add(Int64(n))
        }
        return Array(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var total: Int64 = 0
        private var reported: Int64 = 0
        private let step: Int64
        private let report: ((Int64) -> Void)?
        init(step: Int64, report: ((Int64) -> Void)?) { self.step = step; self.report = report }
        func add(_ n: Int64) {
            lock.lock()
            total += n
            let due = total - reported >= step
            if due { reported = total }
            let now = total
            lock.unlock()
            if due { report?(now) }
        }
        /// The last reading, so a caller always ends on the true total.
        func flush() {
            lock.lock(); let now = total; reported = total; lock.unlock()
            report?(now)
        }
    }

    private struct UncheckedSendable<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}
