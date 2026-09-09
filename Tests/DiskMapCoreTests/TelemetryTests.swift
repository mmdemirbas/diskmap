import XCTest
import DiskMapCore
@testable import DiskMapScan

final class TelemetryTests: XCTestCase {
    /// Recording during tests would bury months of real history under
    /// synthetic records from temporary directories.
    func testRecordingIsOffInsideTests() {
        XCTAssertFalse(Telemetry.enabled)
    }

    /// A record is one line. A name containing a quote, a newline or a tab
    /// would otherwise produce a line that no reader can parse — and file names
    /// are exactly where those characters turn up.
    func testAwkwardTextStaysOnOneParsableLine() throws {
        let line = Telemetry.testEncode("odd", ["reason": .text("say \"hi\"\n\tnow\\then")])
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 0)
        let data = try XCTUnwrap(line.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["e"] as? String, "odd")
        XCTAssertEqual(object["reason"] as? String, "say \"hi\"\n\tnow\\then")
    }

    func testEveryValueKindSurvivesTheRoundTrip() throws {
        let line = Telemetry.testEncode("mix", [
            "count": .int(-42), "ratio": .double(0.5), "name": .text("x"), "ok": .flag(true),
        ])
        let data = try XCTUnwrap(line.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["count"] as? Int, -42)
        XCTAssertEqual(object["ratio"] as? Double, 0.5)
        XCTAssertEqual(object["name"] as? String, "x")
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["v"] as? Int, Telemetry.schema)
    }

    /// An infinite duration is a bug in the caller, not a reason to write a
    /// line that stops the whole file from parsing.
    func testNonFiniteNumbersDoNotProduceBrokenJSON() throws {
        let line = Telemetry.testEncode("odd", ["ms": .double(.infinity)])
        let data = try XCTUnwrap(line.data(using: .utf8))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data))
    }

    /// The file is written to by a process that can be killed mid-line.
    func testATornLineIsSkippedRatherThanFatal() {
        XCTAssertNil(Telemetry.testParse("{\"t\":\"x\",\"e\":\"scan\",\"nod"))
        XCTAssertNil(Telemetry.testParse(""))
        XCTAssertNotNil(Telemetry.testParse(Telemetry.testEncode("scan", ["nodes": .int(3)])))
    }

    /// Paths are the one thing this app must not write down about itself.
    func testNoRecordingCallSitePassesAPath() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("Telemetry.record(") || line.contains("span.end(") {
                if line.contains(".path") || line.contains("store.path") || line.contains("store.name") {
                    offenders.append("\(url.lastPathComponent):\(number + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "a path or name reached a metrics record")
    }
}
