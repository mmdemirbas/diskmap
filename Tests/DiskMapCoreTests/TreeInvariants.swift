import XCTest
@testable import DiskMapScan

/// What a store promises every reader, checked the way a reader would find
/// out: by walking it.
extension XCTestCase {
    /// Every live node sits inside its parent's child run, and every run holds
    /// only nodes that name it as their parent. This is what `children(_:)`
    /// means, and every view and every walk reads the tree through it.
    func assertWellFormed(_ store: NodeStore, file: StaticString = #filePath, line: UInt = #line) {
        // A removed folder's descendants are not marked one by one; they are
        // unreachable through it, which is what removed means for them.
        func underSomethingRemoved(_ id: Int32) -> Bool {
            var n = id
            while n >= 0 {
                if store.flagSet(n).contains(.removed) { return true }
                n = store.parent[Int(n)]
            }
            return false
        }
        for i in 1..<Int32(store.count) where !underSomethingRemoved(i) {
            let p = store.parent[Int(i)]
            XCTAssertTrue(store.children(p).contains(i),
                          "\(store.path(i)) [\(i)] is not in its parent's child run \(store.children(p)) [parent \(p)\(store.flagSet(p).contains(.removed) ? " removed" : "")\(store.isDirectory(p) ? " dir" : " file")]",
                          file: file, line: line)
        }
        // A superseded node keeps its old run; its children now name the
        // node that took over, and nothing reads the old one again.
        for i in 0..<Int32(store.count) where !store.flagSet(i).contains(.removed) {
            for c in store.children(i) where store.parent[Int(c)] != i {
                XCTFail("\(store.path(c)) is listed under \(store.path(i)) but belongs to \(store.path(store.parent[Int(c)]))",
                        file: file, line: line)
            }
        }
    }

    /// The tree as a reader sees it: every node reachable from the root
    /// through child runs, skipping what is marked removed, with what it
    /// is and what it holds. Two stores that agree here show the same map.
    func reachable(_ store: NodeStore) -> [String: TreeEntry] {
        var out: [String: TreeEntry] = [:]
        var queue: [Int32] = [0]
        while let n = queue.popLast() {
            let flags = store.flagSet(n)
            if flags.contains(.removed) { continue }
            out[store.path(n)] = TreeEntry(
                logical: store.totalLogical[Int(n)], physical: store.totalPhysical[Int(n)],
                isDirectory: flags.contains(.directory), isSymlink: flags.contains(.symlink),
                children: store.children(n).filter { !store.flagSet($0).contains(.removed) }.count)
            queue.append(contentsOf: store.children(n))
        }
        return out
    }

    /// Where two trees disagree, as lines a failure can print.
    func differences(_ a: [String: TreeEntry], _ b: [String: TreeEntry],
                     labels: (String, String) = ("live", "scan")) -> [String] {
        var lines: [String] = []
        for k in Set(a.keys).union(b.keys).sorted() {
            switch (a[k], b[k]) {
            case let (x?, y?) where x != y: lines.append("\(k): \(labels.0) \(x)  \(labels.1) \(y)")
            case (nil, let y?): lines.append("\(k): only in \(labels.1) \(y)")
            case (let x?, nil): lines.append("\(k): only in \(labels.0) \(x)")
            default: break
            }
        }
        return lines
    }
}

struct TreeEntry: Equatable, CustomStringConvertible {
    var logical: Int64
    var physical: Int64
    var isDirectory: Bool
    var isSymlink: Bool
    var children: Int
    var description: String {
        "\(isDirectory ? "dir" : isSymlink ? "link" : "file") \(logical)/\(physical)b \(children)c"
    }
}
