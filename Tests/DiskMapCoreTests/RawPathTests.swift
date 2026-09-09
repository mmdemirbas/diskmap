import XCTest
import DiskMapCore
@testable import DiskMapScan

/// Paths as bytes, because that is what a filename is.
///
/// The failure being prevented: a name the volume allowed and Unicode does not
/// becomes U+FFFD when it passes through a `String`, and a path rebuilt from
/// that names nothing. The folder does not open, so it and everything beneath
/// it is counted as unreadable — a whole subtree missing from a total, with a
/// permissions warning as the only clue.
///
/// The name cannot be created here: APFS refuses it at creation with EILSEQ,
/// which `testThisVolumeRefusesSuchANameAtAll` records. So the bytes are put
/// into the store directly, which is what a Samba or NFS share from a Linux box
/// would have handed the walk.
final class RawPathTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    /// 0xFF and 0xFE never appear anywhere in valid UTF-8.
    private let awkward: [UInt8] = [0x62, 0xFF, 0xFE, 0x64]

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: fm.temporaryDirectory.path)
            .appendingPathComponent("dmraw-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // The scan stores resolved paths — the temporary directory is reached
        // through /var, which is a link to /private/var — so the expectations
        // have to be built from the same form the tree holds.
        root = URL(fileURLWithPath: canonicalPath(root.path) ?? root.path)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    // MARK: - The type

    func testJoiningKeepsEveryByte() {
        let path = RawPath("/tmp/x").appending(awkward)
        XCTAssertEqual(path.bytes, Array("/tmp/x/".utf8) + awkward)
    }

    /// "/" already ends in a separator. "//usr" is a path the standard lets an
    /// implementation treat as something of its own.
    func testJoiningOntoTheRootDoesNotDoubleTheSeparator() {
        XCTAssertEqual(RawPath("/").appending(Array("usr".utf8)).display, "/usr")
        XCTAssertEqual(RawPath("/usr").appending(Array("bin".utf8)).display, "/usr/bin")
    }

    func testComponentsSkipTheEmptyOnes() {
        XCTAssertEqual(RawPath("/a//b/").components.map { Array($0) },
                       [Array("a".utf8), Array("b".utf8)])
        XCTAssertTrue(RawPath("/").components.isEmpty)
    }

    /// The display form is allowed to be lossy — it is a label, never a path —
    /// but it must not be mistaken for one.
    func testDisplayIsLossyAndTheBytesAreNot() {
        let path = RawPath("/tmp").appending(awkward)
        XCTAssertTrue(path.display.contains("\u{FFFD}"), "the test is not testing")
        XCTAssertNotEqual(Array(path.display.utf8), path.bytes,
                          "the display form happened to survive; pick worse bytes")
        XCTAssertEqual(path.bytes.suffix(4), awkward)
    }

    /// The round trip that matters: bytes to URL and back, unchanged. It is how
    /// every action on a file leaves the app.
    func testAURLKeepsTheBytes() {
        let path = RawPath("/tmp").appending(awkward)
        let url = path.url(isDirectory: false)
        let back = url.withUnsafeFileSystemRepresentation { rep -> [UInt8] in
            guard let rep else { return [] }
            return Array(UnsafeBufferPointer(
                start: UnsafeRawPointer(rep).assumingMemoryBound(to: UInt8.self),
                count: strlen(rep)))
        }
        XCTAssertEqual(back, path.bytes)
    }

    func testACStringIsTerminatedAndUnchanged() {
        let path = RawPath("/tmp").appending(awkward)
        let length = path.withCString { strlen($0) }
        XCTAssertEqual(Int(length), path.bytes.count)
    }

    // MARK: - Through the store

    /// A store carrying a name that cannot be written down still names it.
    func testAPathRebuiltFromTheStoreKeepsTheBytes() throws {
        try Data(count: 100).write(to: root.appendingPathComponent("ordinary.bin"))
        let store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        let parent = try XCTUnwrap(store.find(path: root.path))

        // What a share serving raw bytes would have handed the walk.
        let node = awkward.withUnsafeBufferPointer {
            store.append(name: UnsafeRawPointer($0.baseAddress!), nameLength: awkward.count,
                         parent: parent, logical: 10, physical: 10, mtime: 0, flags: [])
        }

        XCTAssertEqual(store.pathBytes(node).bytes, RawPath(root.path).appending(awkward).bytes)
        XCTAssertTrue(store.path(node).contains("\u{FFFD}"), "the display form should be honest")
        XCTAssertEqual(store.url(node).withUnsafeFileSystemRepresentation { rep -> [UInt8] in
            guard let rep else { return [] }
            return Array(UnsafeBufferPointer(
                start: UnsafeRawPointer(rep).assumingMemoryBound(to: UInt8.self),
                count: strlen(rep)))
        }, store.pathBytes(node).bytes, "the URL to act on lost the name")
    }

    /// Ordinary names must come out exactly as before.
    func testOrdinaryPathsAreUnchanged() throws {
        try fm.createDirectory(at: root.appendingPathComponent("inner/deeper"),
                               withIntermediateDirectories: true)
        try Data(count: 10).write(to: root.appendingPathComponent("inner/deeper/f.bin"))
        let store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        let node = try XCTUnwrap(store.find(path: root.appendingPathComponent("inner/deeper/f.bin").path))

        XCTAssertEqual(store.path(node), root.appendingPathComponent("inner/deeper/f.bin").path)
        XCTAssertEqual(store.pathBytes(node).display, store.path(node))
    }

    /// Non-ASCII names that *are* valid UTF-8 are the ordinary case on a Turkish
    /// or emoji-using disk, and go through the same byte path.
    func testNamesOutsideASCIISurviveTheWalk() throws {
        let name = "ölçüm–2026 🎞.bin"
        try Data(count: 20).write(to: root.appendingPathComponent(name))
        let store = DiskScanner().scan(ScanOptions(rootPath: root.path)).store
        let node = try XCTUnwrap(store.find(path: root.appendingPathComponent(name).path))
        XCTAssertEqual(store.pathBytes(node).bytes,
                       Array(root.appendingPathComponent(name).path.utf8))
    }

    /// Opening by bytes reaches the same directory opening by text did.
    func testOpeningADirectoryByItsBytes() throws {
        try fm.createDirectory(at: root.appendingPathComponent("üst/alt"),
                               withIntermediateDirectories: true)
        let fd = DiskScanner.openDirectory(RawPath(root.appendingPathComponent("üst/alt").path))
        XCTAssertGreaterThanOrEqual(fd, 0)
        if fd >= 0 { close(fd) }
        XCTAssertLessThan(DiskScanner.openDirectory(RawPath(root.path + "/nope")), 0)
    }

    /// Why the awkward name has to be injected rather than created. If this
    /// ever starts failing, the case above became reachable locally and there
    /// should be an end-to-end test beside it.
    func testThisVolumeRefusesSuchANameAtAll() {
        var name = Array(RawPath(root.path).appending(awkward).bytes)
        name.append(0)
        let made = name.withUnsafeBufferPointer { raw in
            raw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: raw.count) {
                mkdir($0, 0o755)
            }
        }
        if made == 0 {
            _ = name.withUnsafeBufferPointer { raw in
                raw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: raw.count) { rmdir($0) }
            }
            XCTFail("this volume now accepts the name; add the end-to-end test")
        } else {
            XCTAssertEqual(errno, EILSEQ, "refused, but for a reason worth knowing about")
        }
    }
}
