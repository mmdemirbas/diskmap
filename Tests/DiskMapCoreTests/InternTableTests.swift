import XCTest
@testable import DiskMapScan

/// The name table is sized once, from a guess. What happens when the guess
/// is short is the difference between a slower scan and one that never ends.
final class InternTableTests: XCTestCase {
    /// More distinct names than the table has slots. Open addressing with no
    /// growth and no fallback probes for an empty slot that does not exist,
    /// forever — and the caller is the live update, holding a folder that
    /// just appeared with more names in it than the hint allowed for.
    func testMoreNamesThanTheHintDoesNotHang() {
        let store = NodeStore()
        store.reserve(16)
        store.beginInterning(expectedNodes: 16)
        let n = 20_000
        var ids: [Int32] = []
        for i in 0..<n {
            let name = Array("name-\(i)".utf8)
            ids.append(name.withUnsafeBufferPointer {
                store.append(name: UnsafeRawPointer($0.baseAddress!), nameLength: name.count,
                             parent: 0, logical: 1, physical: 1, mtime: 0, flags: [])
            })
        }
        store.endInterning()
        XCTAssertEqual(store.count, n)
        XCTAssertEqual(store.nameBytes(of: ids[n - 1]), Array("name-\(n - 1)".utf8))
        XCTAssertEqual(store.nameBytes(of: ids[4097]), Array("name-4097".utf8))
    }
}
