import Darwin
import Foundation
import os

/// A value that can appear in a metrics record.
public enum MetricValue: Sendable {
    case int(Int64)
    case double(Double)
    case text(String)
    case flag(Bool)
}

extension MetricValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                       ExpressibleByStringLiteral, ExpressibleByBooleanLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .text(value) }
    public init(booleanLiteral value: Bool) { self = .flag(value) }
}

/// Durable, local-only measurement of what the app actually does.
///
/// Two outputs from one call site. **Signposts** go to the system tracing
/// machinery, which is what Instruments reads: free when nobody is recording,
/// and the only way to see a stage in context with the kernel time around it.
/// **A JSONL file** accumulates across runs, so a slow scan three weeks ago is
/// still answerable rather than a memory.
///
/// What is recorded is counts, sizes and durations. No file or folder paths and
/// no file names: this is a disk analyzer, so its own logs would otherwise be a
/// listing of everything the user owns. Roots are recorded as a count. The file
/// never leaves the machine and nothing here opens a network connection.
public enum Telemetry {
    public static let subsystem = "com.mmdemirbas.diskmap"
    /// Bumped when the shape of a record changes, so old lines stay readable.
    public static let schema = 1

    private static let signposter = OSSignposter(subsystem: subsystem, category: "stages")
    private static let logger = Logger(subsystem: subsystem, category: "diskmap")
    private static let queue = DispatchQueue(label: "diskmap.telemetry", qos: .utility)
    private static let state = Writer()

    /// Groups every record from one process run.
    public static let sessionID: String = {
        let bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        return bytes.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    }()

    /// Off inside tests, and switchable from the environment for a clean run.
    ///
    /// The environment variable alone was not enough: a `swift test` run sets a
    /// different one depending on the runner, and a hundred tests scanning
    /// temporary directories otherwise buried the real history under synthetic
    /// records. Asking whether XCTest is loaded answers it directly.
    public static let enabled: Bool = {
        if NSClassFromString("XCTestCase") != nil { return false }
        let env = ProcessInfo.processInfo.environment
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
        where env[key] != nil { return false }
        if let flag = env["DISKMAP_METRICS"] { return flag != "0" && flag.lowercased() != "off" }
        return true
    }()

    /// Drops every "only if it was slow" threshold. For working on the app
    /// itself: without it a stage that is never slow leaves no evidence that
    /// its instrumentation works at all.
    public static let recordEverything: Bool =
        ProcessInfo.processInfo.environment["DISKMAP_METRICS_ALL"] == "1"

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DiskMap", isDirectory: true)
    }

    public static var logURL: URL { directory.appendingPathComponent("metrics.jsonl") }
    public static var previousLogURL: URL { directory.appendingPathComponent("metrics-1.jsonl") }

    // MARK: - Recording

    public static func record(_ event: String, _ fields: [String: MetricValue] = [:]) {
        guard enabled else { return }
        let line = encode(event: event, fields: fields)
        queue.async { state.append(line) }
    }

    /// A stage with a duration. `end` carries the fields only known afterwards,
    /// which is usually the interesting half — how many results, how many bytes.
    public struct Span {
        let event: String
        let started: UInt64
        let signpost: OSSignpostID
        let signpostState: OSSignpostIntervalState?

        /// `minMilliseconds` keeps high-frequency stages out of the file
        /// unless they were actually slow. A treemap relaid on every resize
        /// frame would otherwise bury a day of real events in noise; the
        /// signpost is still emitted every time, so a live Instruments trace
        /// sees them all.
        public func end(_ fields: [String: MetricValue] = [:], minMilliseconds: Double = 0) {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            if let signpostState {
                signposter.endInterval("stage", signpostState)
            }
            guard ms >= minMilliseconds || Telemetry.recordEverything else { return }
            var all = fields
            all["ms"] = .double((ms * 1000).rounded() / 1000)
            Telemetry.record(event, all)
        }
    }

    public static func begin(_ event: String) -> Span {
        guard enabled else {
            return Span(event: event, started: DispatchTime.now().uptimeNanoseconds,
                        signpost: .invalid, signpostState: nil)
        }
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval("stage", id: id, "\(event)")
        return Span(event: event, started: DispatchTime.now().uptimeNanoseconds,
                    signpost: id, signpostState: state)
    }

    @discardableResult
    public static func measure<T>(_ event: String, _ fields: [String: MetricValue] = [:],
                                  body: () throws -> T) rethrows -> T {
        let span = begin(event)
        defer { span.end(fields) }
        return try body()
    }

    /// Something went wrong and the user may or may not have seen it. Errors go
    /// to the unified log as well, so they show up in Console.app live.
    public static func problem(_ event: String, _ reason: String,
                               _ fields: [String: MetricValue] = [:]) {
        logger.error("\(event, privacy: .public): \(reason, privacy: .public)")
        var all = fields
        all["reason"] = .text(reason)
        record("problem." + event, all)
    }

    // MARK: - Process facts worth stamping on a record

    /// Memory the process is actually charged for, which is the number that
    /// matters on a machine under pressure — not resident size.
    public static func footprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    // MARK: - Reading back

    public struct Record: Sendable {
        public var time: String
        public var event: String
        public var fields: [String: String]
        public var ms: Double? { fields["ms"].flatMap(Double.init) }
    }

    /// Reads the accumulated records, oldest first, across both files.
    public static func history() -> [Record] {
        var out: [Record] = []
        for url in [previousLogURL, logURL] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let record = parse(String(line)) { out.append(record) }
            }
        }
        return out
    }

    // MARK: - Encoding
    //
    // Hand-rolled rather than JSONEncoder: the record shape is flat, the key
    // order should be stable so a diff of two runs is readable, and this runs
    // on paths that are themselves being measured.

    private static func encode(event: String, fields: [String: MetricValue]) -> String {
        var out = "{\"t\":\"\(timestamp())\",\"v\":\(schema),\"s\":\"\(sessionID)\",\"e\":\(quote(event))"
        for key in fields.keys.sorted() {
            out += ",\(quote(key)):\(literal(fields[key]!))"
        }
        return out + "}"
    }

    private static func literal(_ value: MetricValue) -> String {
        switch value {
        case .int(let v): return String(v)
        case .double(let v): return v.isFinite ? String(v) : "null"
        case .text(let v): return quote(v)
        case .flag(let v): return v ? "true" : "false"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func timestamp() -> String { formatter.string(from: Date()) }

    /// Deliberately forgiving: a record from an older schema, or a line torn by
    /// a crash mid-write, should not stop the rest from being read.
    private static func parse(_ line: String) -> Record? {
        guard line.hasPrefix("{"), line.hasSuffix("}"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["e"] as? String else { return nil }
        var fields: [String: String] = [:]
        for (key, value) in object where key != "e" && key != "t" {
            fields[key] = String(describing: value)
        }
        return Record(time: object["t"] as? String ?? "", event: event, fields: fields)
    }

    // Encoding is the part that has to be right whatever a file is called, so
    // it is reachable from tests without going near the file.
    static func testEncode(_ event: String, _ fields: [String: MetricValue]) -> String {
        encode(event: event, fields: fields)
    }
    static func testParse(_ line: String) -> Record? { parse(line) }

    /// Owns the file handle. Only ever touched from `queue`.
    private final class Writer: @unchecked Sendable {
        private var handle: FileHandle?
        private var written = 0
        /// Two files of this size is the whole footprint on disk.
        private let rotateAt = 8 << 20

        func append(_ line: String) {
            guard let handle = open() else { return }
            guard let data = (line + "\n").data(using: .utf8) else { return }
            try? handle.write(contentsOf: data)
            written += data.count
            if written >= rotateAt { rotate() }
        }

        private func open() -> FileHandle? {
            if let handle { return handle }
            let fm = FileManager.default
            let dir = Telemetry.directory
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = Telemetry.logURL
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return nil }
            written = (try? h.seekToEnd()).map(Int.init) ?? 0
            handle = h
            return h
        }

        private func rotate() {
            try? handle?.close()
            handle = nil
            written = 0
            let fm = FileManager.default
            try? fm.removeItem(at: Telemetry.previousLogURL)
            try? fm.moveItem(at: Telemetry.logURL, to: Telemetry.previousLogURL)
        }
    }
}
