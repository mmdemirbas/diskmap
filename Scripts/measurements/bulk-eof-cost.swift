import Darwin
import Foundation

// How much of the enumeration cost is the extra call that only says "no more".
// One directory of N entries takes two getattrlistbulk calls: one that returns
// the entries, one that returns 0. This times the pair against the first alone.
let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("eofbench-\(UUID().uuidString)").path
mkdir(base, 0o755)
let dirCount = 2000, entriesEach = 8
var dirs: [String] = []
for d in 0..<dirCount {
    let p = base + "/d\(d)"
    mkdir(p, 0o755)
    for e in 0..<entriesEach { close(open(p + "/f\(e)", O_CREAT | O_WRONLY, 0o644)) }
    dirs.append(p)
}

let bufSize = 512 * 1024
let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
var attrs = attrlist()
attrs.bitmapcount = 5
attrs.commonattr = 0x8000_0000 | 0x2000_0000 | 0x0000_0001 | 0x0000_0008
                 | 0x0000_0400 | 0x0004_0000 | 0x0200_0000
attrs.fileattr = 0x0000_0001 | 0x0000_0002 | 0x0000_0004

func run(_ label: String, stopAfterFirst: Bool) {
    let t = Date()
    var calls = 0, entries = 0
    for p in dirs {
        let fd = open(p, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { continue }
        while true {
            let n = withUnsafeMutablePointer(to: &attrs) {
                getattrlistbulk(fd, $0, buffer, bufSize, 0)
            }
            calls += 1
            if n <= 0 { break }
            entries += Int(n)
            if stopAfterFirst { break }
        }
        close(fd)
    }
    let ms = Date().timeIntervalSince(t) * 1000
    print(String(format: "  %-22s %7.2f ms   %d calls, %d entries",
                 (label as NSString).utf8String!, ms, calls, entries))
}

for _ in 0..<3 {
    run("with the EOF call", stopAfterFirst: false)
    run("first call only", stopAfterFirst: true)
}
buffer.deallocate()
try? FileManager.default.removeItem(atPath: base)
