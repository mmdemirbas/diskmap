import XCTest
@testable import DiskMapApp

@MainActor
final class LocalizationTests: XCTestCase {
    /// A missing entry falls back to the raw key, which ships as visible
    /// gibberish. Assert every key is translated in both languages.
    func testEveryKeyHasBothLanguages() {
        let loc = L10n.shared
        let original = loc.preference
        defer { loc.preference = original }

        let missing = L10n.K.allCases.filter { L10n.table[$0] == nil }
        XCTAssertEqual(missing, [], "keys with no table entry")

        for key in L10n.K.allCases {
            loc.preference = .en
            XCTAssertFalse(loc[key].isEmpty, "empty English for \(key)")
            loc.preference = .tr
            XCTAssertFalse(loc[key].isEmpty, "empty Turkish for \(key)")
        }
    }

    /// Byte sizes must follow the chosen language, not the system one.
    func testByteFormattingFollowsSelectedLanguage() {
        let loc = L10n.shared
        let original = loc.preference
        defer { loc.preference = original }

        loc.preference = .en
        let en = shortBytes(1_500_000_000)
        loc.preference = .tr
        let tr = shortBytes(1_500_000_000)

        XCTAssertTrue(en.contains("."), "English should use a decimal point: \(en)")
        XCTAssertTrue(tr.contains(","), "Turkish should use a decimal comma: \(tr)")
        XCTAssertTrue(en.hasSuffix("GB") && tr.hasSuffix("GB"))
    }

    func testTurkishDiffersFromEnglishForTranslatedTerms() {
        let loc = L10n.shared
        let original = loc.preference
        defer { loc.preference = original }
        for key in [L10n.K.free, .purgeable, .inUse, .moveToTrash, .rescan, .emptyFolder] {
            loc.preference = .en
            let en = loc[key]
            loc.preference = .tr
            XCTAssertNotEqual(loc[key], en, "\(key) is not translated")
        }
    }
}
