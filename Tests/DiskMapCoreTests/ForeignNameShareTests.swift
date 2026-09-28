import XCTest
import DiskMapCore
@testable import DiskMapScan

/// Names that are not UTF-8, on a share whose server allows them.
///
/// APFS refuses such a name, so no test can make one on this Mac, and the
/// macOS NFS client will not create one either — it will only list what the
/// server already holds. Every other test of awkward names therefore stops
/// at the byte path. This one points the scanner at a real folder that has
/// them, and holds the scan and a relist of every folder to an independent
/// reading of the same folder: `readdir` and `lstat` on bytes.
///
/// Opt-in, because it needs a folder a Linux machine wrote. With OrbStack:
///
///     docker volume create dm-names
///     docker run --rm -v dm-names:/v --entrypoint sh <any linux image> -c \
///       'cd /v; mkdir "$(printf "dir-\377")"; head -c 5000 /dev/zero > "$(printf "dir-\377/b\377\376d")";
///        head -c 12345 /dev/zero > "$(printf "caf\351")"; ln "$(printf "caf\351")" "$(printf "link-\351")";
///        ln -s "$(printf "caf\351")" "$(printf "sym-\351")"'
///     DISKMAP_FOREIGN_SHARE=~/OrbStack/docker/volumes/dm-names swift test --filter ForeignNameShareTests
///
/// Only reads. Nothing on the share is changed.
final class ForeignNameShareTests: XCTestCase {
    private struct Listed { let isDirectory: Bool; let logical: Int64; let physical: Int64; let inode: UInt64 }

    func testAShareWithNamesThatAreNotUTF8ScansAndRelistsWhole() throws {
        guard let given = ProcessInfo.processInfo.environment["DISKMAP_FOREIGN_SHARE"] else {
            throw XCTSkip("set DISKMAP_FOREIGN_SHARE to a folder on a share holding names that are not UTF-8")
        }
        let root = RawPath(canonicalPath(given) ?? given)
        let listed = list(root)
        let foreign = listed.keys.filter { String(validatingUTF8: $0.map { CChar(bitPattern: $0) } + [0]) == nil }
        XCTAssertFalse(foreign.isEmpty, "nothing under \(root.display) has a name that is not UTF-8; see the comment above for how to make one")

        // The folder itself is chosen as text, as it is in the app; the names
        // below it are what is under test.
        let tree = LiveTree(result: DiskScanner().scan(ScanOptions(rootPath: root.display)))
        tree.withStore { check($0, root: root, against: listed, "after the scan") }

        // Every folder relisted, as a burst of events would: the live path
        // reads the same names through `open` and `getattrlistbulk` again,
        // and writes them back into a store that already holds them.
        let folders = listed.filter(\.value.isDirectory).keys.map { RawPath(bytes: root.bytes + [0x2F] + $0) }
        tree.flushNow(events: [root] + folders)
        tree.withStore { check($0, root: root, against: listed, "after every folder was relisted") }
    }

    /// Every entry under `root`, keyed by its path below the root, as bytes.
    private func list(_ root: RawPath) -> [[UInt8]: Listed] {
        var out: [[UInt8]: Listed] = [:]
        var queue: [[UInt8]] = [[]]
        while let rel = queue.popLast() {
            let dir = rel.isEmpty ? root : RawPath(bytes: root.bytes + [0x2F] + rel)
            guard let d = dir.withCString({ opendir($0) }) else {
                XCTFail("could not open \(dir.display)"); continue
            }
            defer { closedir(d) }
            while let e = readdir(d) {
                let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
                    Array(raw.prefix(Int(e.pointee.d_namlen)))
                }
                if name == [0x2E] || name == [0x2E, 0x2E] { continue }
                let relChild = rel.isEmpty ? name : rel + [0x2F] + name
                var info = stat()
                let full = RawPath(bytes: root.bytes + [0x2F] + relChild)
                guard full.withCString({ lstat($0, &info) }) == 0 else {
                    XCTFail("lstat failed on \(String(decoding: relChild, as: UTF8.self)): \(String(cString: strerror(errno)))"); continue
                }
                let isDir = info.st_mode & S_IFMT == S_IFDIR
                out[relChild] = Listed(isDirectory: isDir, logical: Int64(info.st_size),
                                       physical: Int64(info.st_blocks) * 512, inode: UInt64(info.st_ino))
                if isDir { queue.append(relChild) }
            }
        }
        return out
    }

    private func check(_ store: NodeStore, root: RawPath, against listed: [[UInt8]: Listed], _ when: String) {
        assertWellFormed(store)
        guard let top = store.lookup(root) else { return XCTFail("\(when): the root is not in the store") }

        // Walk the store the way the views do, collecting paths as bytes.
        var seen: [[UInt8]: Int32] = [:]
        var queue: [(Int32, [UInt8])] = [(top, [])]
        while let (node, rel) = queue.popLast() {
            for c in store.children(node) where !store.flagSet(c).contains(.removed) {
                let name = store.nameBytes(of: c)
                let relChild = rel.isEmpty ? name : rel + [0x2F] + name
                seen[relChild] = c
                if store.isDirectory(c) { queue.append((c, relChild)) }
            }
        }
        func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
        for k in Set(listed.keys).subtracting(seen.keys) { XCTFail("\(when): \(text(k)) is on the share and not in the tree") }
        for k in Set(seen.keys).subtracting(listed.keys) { XCTFail("\(when): \(text(k)) is in the tree and not on the share") }

        var keepers: [UInt64: Int] = [:]
        for (rel, node) in seen {
            guard let entry = listed[rel] else { continue }
            let full = RawPath(bytes: root.bytes + [0x2F] + rel)
            // The path the tree hands out, and the URL every action is given,
            // name this entry byte for byte.
            XCTAssertEqual(store.pathBytes(node), full, "\(when): path of \(text(rel))")
            XCTAssertEqual(RawPath(url: store.url(node)), full, "\(when): URL of \(text(rel))")
            XCTAssertEqual(store.lookup(full), node, "\(when): lookup by bytes of \(text(rel))")
            XCTAssertFalse(store.name(node).isEmpty, "\(when): a name to show for \(text(rel))")
            guard !entry.isDirectory else { continue }
            XCTAssertEqual(store.totalLogical[Int(node)], entry.logical, "\(when): size of \(text(rel))")
            if store.flagSet(node).contains(.hardlinkDuplicate) {
                XCTAssertEqual(store.totalPhysical[Int(node)], 0, "\(when): a later link of \(text(rel)) holds no bytes")
            } else {
                XCTAssertEqual(store.totalPhysical[Int(node)], entry.physical, "\(when): bytes on disk of \(text(rel))")
                keepers[entry.inode, default: 0] += 1
            }
        }
        // Every file's bytes counted exactly once, whatever it is called.
        let inodes = Set(listed.values.filter { !$0.isDirectory }.map(\.inode))
        for i in inodes { XCTAssertEqual(keepers[i], 1, "\(when): inode \(i) keeps its bytes on exactly one name") }
    }
}
