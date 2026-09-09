import Darwin
import Foundation

// Times two ways of opening the same directories: by absolute path, and by
// name from an already-open parent fd. The parent fds and the name strings are
// prepared outside the timed region, so what is measured is the syscall alone.
let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("openbench-\(UUID().uuidString)").path
let depth = 10
var leaves: [(path: String, parent: String, name: String)] = []

func build(_ path: String, _ level: Int) {
    mkdir(path, 0o755)
    guard level < depth else { return }
    let fanout = level == depth - 1 ? 3 : 2
    for i in 0..<fanout {
        let child = path + "/d\(i)"
        if level == depth - 1 { leaves.append((child, path, "d\(i)")) }
        build(child, level + 1)
    }
}
build(base, 0)

var parentFDs: [String: Int32] = [:]
for leaf in leaves where parentFDs[leaf.parent] == nil {
    parentFDs[leaf.parent] = open(leaf.parent, O_RDONLY | O_DIRECTORY)
}
let work: [(Int32, String, String)] = leaves.map { (parentFDs[$0.parent]!, $0.name, $0.path) }
print("leaves: \(leaves.count), parents: \(parentFDs.count), depth \(depth)")

func time(_ label: String, _ body: () -> Int) {
    let t = Date()
    let n = body()
    let ms = Date().timeIntervalSince(t) * 1000
    print(String(format: "  %-24s %7.2f ms  %6.2f us/open", (label as NSString).utf8String!,
                 ms, ms * 1000 / Double(max(n, 1))))
}

for p in leaves { let fd = open(p.path, O_RDONLY | O_DIRECTORY); if fd >= 0 { close(fd) } }

for _ in 0..<3 {
    time("open(absolute)") {
        var n = 0
        for w in work { let fd = open(w.2, O_RDONLY | O_DIRECTORY); if fd >= 0 { n += 1; close(fd) } }
        return n
    }
    time("openat(parent, name)") {
        var n = 0
        for w in work { let fd = openat(w.0, w.1, O_RDONLY | O_DIRECTORY); if fd >= 0 { n += 1; close(fd) } }
        return n
    }
}
for fd in parentFDs.values where fd >= 0 { close(fd) }
try? FileManager.default.removeItem(atPath: base)
