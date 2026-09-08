// Measures what asking Spotlight for content-derived metadata actually costs,
// in process, against a real directory tree.
//
// The point of the measurement: DiskMap's scan never opens a file, and that is
// why it walks eleven million nodes in under two minutes. Content properties —
// pixel dimensions, capture date, media duration — normally mean opening the
// file. On an indexed volume Spotlight has already done that, so the question
// is whether reading its answers is cheap enough to do in bulk, or only on
// demand for what is on screen.
//
//   swift Scripts/probe-spotlight.swift <directory> [limit]
//
// Reports: files probed, how many Spotlight had an answer for, and the median
// and mean microseconds per file.

import CoreServices
import Foundation

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write(Data("usage: probe-spotlight.swift <dir> [limit]\n".utf8))
    exit(2)
}
let root = args[1]
let limit = args.count > 2 ? Int(args[2]) ?? 2000 : 2000

var paths: [String] = []
if let e = FileManager.default.enumerator(atPath: root) {
    for case let p as String in e {
        let full = root + "/" + p
        var st = stat()
        guard lstat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
        paths.append(full)
        if paths.count >= limit { break }
    }
}
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("no regular files under \(root)\n".utf8))
    exit(1)
}

// The attributes a size-analyser would actually want: what kind of thing this
// is, when the content was made (not when the file was copied), and the shape
// of an image or the length of a media file.
let wanted = [kMDItemContentType, kMDItemContentCreationDate,
              kMDItemPixelWidth, kMDItemPixelHeight, kMDItemDurationSeconds] as [CFString]

var timings: [Double] = []
var answered = 0
timings.reserveCapacity(paths.count)

for path in paths {
    let began = DispatchTime.now()
    var got = false
    if let item = MDItemCreate(nil, path as CFString) {
        for attribute in wanted where MDItemCopyAttribute(item, attribute) != nil {
            got = true
        }
    }
    let ended = DispatchTime.now()
    timings.append(Double(ended.uptimeNanoseconds - began.uptimeNanoseconds) / 1000)
    if got { answered += 1 }
}

timings.sort()
let median = timings[timings.count / 2]
let mean = timings.reduce(0, +) / Double(timings.count)
let p99 = timings[min(timings.count - 1, Int(Double(timings.count) * 0.99))]
let total = timings.reduce(0, +) / 1_000_000

print("""
    files probed      \(paths.count)
    Spotlight knew    \(answered)  (\(answered * 100 / paths.count)%)
    median            \(String(format: "%.1f", median)) us
    mean              \(String(format: "%.1f", mean)) us
    p99               \(String(format: "%.1f", p99)) us
    total             \(String(format: "%.3f", total)) s
    projected 1M      \(String(format: "%.1f", mean * 1_000_000 / 1_000_000)) s
    """)
