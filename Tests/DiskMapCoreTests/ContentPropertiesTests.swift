import XCTest
import DiskMapCore
@testable import DiskMapScan

/// Asking the index instead of opening the file, and remembering the answer
/// only for as long as it is still the answer.
///
/// What the index itself says is a property of the machine — a volume with
/// indexing switched off answers for nothing — so nothing here asserts that
/// Spotlight knows anything. What is tested is the part that is ours: the key
/// the answers are cached under, which is where a wrong answer would come from
/// and would be believed.
final class ContentCacheTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dmcontent-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? fm.removeItem(at: root) } }

    /// A fetcher that counts, and answers with something recognisable.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [String] = []
        func fetch(_ path: String) -> ContentProperties {
            lock.lock(); calls.append(path); let n = calls.count; lock.unlock()
            var out = ContentProperties()
            out.indexed = true
            out.pixelWidth = n
            return out
        }
    }

    private func write(_ name: String, _ bytes: Int) throws -> String {
        let url = root.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url.path
    }

    func testTheSameFileIsOnlyAskedAboutOnce() throws {
        let counter = Counter()
        let cache = ContentCache(fetch: { counter.fetch($0) })
        let path = try write("a.bin", 10)

        XCTAssertEqual(cache.properties(ofFile: path)?.pixelWidth, 1)
        XCTAssertEqual(cache.properties(ofFile: path)?.pixelWidth, 1)
        XCTAssertEqual(counter.calls.count, 1)
    }

    /// The answer describes the bytes, so it stops being the answer when the
    /// bytes change. A cache that could not see that would keep showing the
    /// dimensions of a picture that has been replaced.
    func testChangingTheFileMakesTheAnswerStale() throws {
        let counter = Counter()
        let cache = ContentCache(fetch: { counter.fetch($0) })
        let path = try write("a.bin", 10)
        _ = cache.properties(ofFile: path)

        // Same path, different content and a different length.
        try Data(count: 5_000).write(to: URL(fileURLWithPath: path))

        XCTAssertEqual(cache.properties(ofFile: path)?.pixelWidth, 2,
                       "the cache answered for bytes that are no longer there")
        XCTAssertEqual(counter.calls.count, 2)
    }

    /// A path is not an identity: one can be renamed onto another file. The key
    /// is what the filesystem calls the file, not what it is called today.
    func testTwoDifferentFilesDoNotShareAnAnswer() throws {
        let counter = Counter()
        let cache = ContentCache(fetch: { counter.fetch($0) })
        let a = try write("a.bin", 10)
        let b = try write("b.bin", 20)

        XCTAssertEqual(cache.properties(ofFile: a)?.pixelWidth, 1)
        XCTAssertEqual(cache.properties(ofFile: b)?.pixelWidth, 2)
        XCTAssertEqual(cache.count, 2)
    }

    /// Nothing there at all is a different answer from nothing to say, and the
    /// caller has to be able to tell them apart.
    func testAMissingFileIsNotAnEmptyAnswer() {
        let counter = Counter()
        let cache = ContentCache(fetch: { counter.fetch($0) })
        XCTAssertNil(cache.properties(ofFile: root.appendingPathComponent("nope").path))
        XCTAssertTrue(counter.calls.isEmpty, "the index was asked about a file that is not there")
    }

    func testTheCacheStopsGrowing() throws {
        let counter = Counter()
        let cache = ContentCache(limit: 3, fetch: { counter.fetch($0) })
        for i in 0..<10 { _ = cache.properties(ofFile: try write("f\(i).bin", i + 1)) }
        XCTAssertEqual(cache.count, 3)
    }

    // MARK: - What an answer means

    /// An unindexed volume answers for nothing, and that must not look like a
    /// file with no properties.
    func testNotIndexedIsNotTheSameAsNothingToSay() {
        var nothingKnown = ContentProperties()
        XCTAssertFalse(nothingKnown.indexed)
        XCTAssertTrue(nothingKnown.isEmpty)

        var knownButPlain = ContentProperties()
        knownButPlain.contentType = "public.plain-text"
        knownButPlain.indexed = true
        XCTAssertTrue(knownButPlain.isEmpty, "a text file has none of these properties")
        XCTAssertTrue(knownButPlain.indexed, "but the index does know it")

        nothingKnown.pixelWidth = 4
        XCTAssertFalse(nothingKnown.isEmpty)
        knownButPlain.durationSeconds = 12
        XCTAssertFalse(knownButPlain.isEmpty)
    }

    /// A query with nowhere to look would ask about the whole machine — every
    /// volume, every home folder — and answer about files nobody scanned.
    func testAQueryWithNoScopeAsksNothing() {
        XCTAssertTrue(SpotlightQuery.paths(matching: "kMDItemPixelWidth > 0", under: []).isEmpty)
    }

    /// The probe that tells "nothing matched" from "nothing to match against"
    /// is a query of its own, and a query with a predicate the index rejects
    /// would answer "not indexed" for every folder on the machine — turning a
    /// true empty answer into a false explanation.
    func testTheIndexProbeAgreesWithTheIndex() throws {
        let known = "/System/Library/CoreServices/Finder.app"
        guard Spotlight.properties(ofFile: known).indexed else {
            throw XCTSkip("this volume is not indexed, so there is nothing to agree with")
        }
        XCTAssertTrue(SpotlightQuery.isIndexed("/System/Library/CoreServices"),
                      "the probe says an indexed folder is not indexed")
    }

    /// The real index, on whatever machine this runs on. Not an assertion about
    /// what it knows — that is the machine's business — only that asking it
    /// costs what the design assumed. Skipped rather than failed where the
    /// volume is not indexed, because that is a true answer too.
    func testAskingTheRealIndexIsFastEnoughToDoWhileSomebodyWatches() throws {
        let path = "/System/Library/CoreServices/Finder.app"
        guard Spotlight.properties(ofFile: path).indexed else {
            throw XCTSkip("this volume is not indexed, so there is nothing to time")
        }
        let began = DispatchTime.now()
        for _ in 0..<20 { _ = Spotlight.properties(ofFile: path) }
        let each = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds)
            / 20 / 1_000_000
        XCTAssertLessThan(each, 50, "asking the index took \(each)ms per file")
    }
}
