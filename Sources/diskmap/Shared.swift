import DiskMapReports
import DiskMapScan
import Foundation

/// Progress goes to stderr, the answer goes to stdout. That split is what lets
/// `diskmap files / --tsv | sort` work while a person still sees what it is
/// doing.
var quiet = false

func note(_ text: String) {
    guard !quiet else { return }
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data(("diskmap: " + message + "\n").utf8))
    exit(code)
}

/// `500MB`, `2GB`, or a plain number of bytes.
func bytes(_ text: String) -> Int64? {
    let upper = text.uppercased()
    let units: [(String, Int64)] = [("TB", 1 << 40), ("GB", 1 << 30),
                                    ("MB", 1 << 20), ("KB", 1 << 10)]
    for (suffix, scale) in units where upper.hasSuffix(suffix) {
        guard let n = Double(upper.dropLast(suffix.count)) else { return nil }
        return Int64(n * Double(scale))
    }
    return Int64(upper)
}

/// Reads the next argument as the value of `name`, or stops with a usage error.
struct Arguments {
    var rest: [String]

    mutating func next() -> String? {
        guard !rest.isEmpty else { return nil }
        return rest.removeFirst()
    }

    mutating func value(_ name: String) -> String {
        guard let v = next() else { fail("\(name) needs a value", 1) }
        return v
    }

    mutating func size(_ name: String) -> Int64 {
        guard let n = bytes(value(name)) else { fail("\(name) needs a size", 1) }
        return n
    }

    mutating func number(_ name: String) -> Int {
        let raw = value(name)
        // A negative used to be clamped to zero, and zero means "every row" —
        // so a mistyped `--limit -5` quietly asked for three million lines.
        guard let n = Int(raw), n >= 0 else {
            fail("\(name) needs a number that is not negative, got \(raw)", 1)
        }
        return n
    }

    mutating func days(_ name: String) -> Double {
        guard let n = Double(value(name)), n >= 0 else {
            fail("\(name) needs a number of days", 1)
        }
        return n
    }
}

/// Scans the paths, or stops with the same exit codes the scan command uses.
/// Shared because every query command has to have an index before it can
/// answer anything, and there is no form of the export that carries a whole
/// tree for it to read instead.
func scanned(_ paths: [String]) -> ScanResult {
    guard !paths.isEmpty else { fail("no paths given", 1) }
    let normalized = RootSet.normalize(paths)
    for rejected in normalized.rejected {
        note("skipped \(rejected.path): \(rejected.reason.explanation)")
    }
    guard !normalized.isEmpty else { fail("nothing to measure", 2) }
    note("measuring \(normalized.roots.joined(separator: ", ")) ...")
    let result = DiskScanner().scan(ScanOptions(roots: normalized.roots))
    guard result.store.count > 1 else { fail("nothing could be read", 2) }
    return result
}

/// Writes the answer where it was asked for, and says so on stderr when that
/// is a file — silence and a written file are hard to tell apart.
func deliver(_ data: Data, to out: String?) {
    guard let out else {
        FileHandle.standardOutput.write(data)
        if data.last != UInt8(ascii: "\n") {
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        return
    }
    do {
        try data.write(to: URL(fileURLWithPath: out), options: .atomic)
        note("wrote \(out) (\(formatBytes(Int64(data.count))))")
    } catch {
        fail("could not write \(out): \(error.localizedDescription)", 3)
    }
}

func encoded<T: Encodable>(_ doc: T, prettyPrinted: Bool) -> Data {
    do { return try Export.encode(doc, prettyPrinted: prettyPrinted) }
    catch { fail("could not encode the result: \(error)", 3) }
}

/// The document formatter lives beside the other machine-readable shapes, so
/// the escaping it has to do is testable. This is only the local name for it.
func tsv(_ header: [String], _ rows: [[String]]) -> Data {
    Export.tsv(header, rows)
}

let isoDate: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
