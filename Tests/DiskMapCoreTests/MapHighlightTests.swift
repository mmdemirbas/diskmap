import DiskMapCore
import SwiftUI
import XCTest
@testable import DiskMapApp

/// A swatch picked from the legend points at part of the map and changes
/// nothing else: which cells are greyed, and when the pick lets go.
@MainActor
final class MapHighlightTests: XCTestCase {
    private func cell(_ category: FileCategory, _ age: AgeBucket) -> CellInfo {
        CellInfo(name: "x", category: category, bytes: 1, isDirectory: false, flags: [], age: age)
    }

    func testOnlyWhatThePickNamesKeepsItsColour() {
        let map = AppModel().map
        let video = cell(.video, .week), image = cell(.image, .older)
        XCTAssertFalse(map.isDimmed(video) || map.isDimmed(image), "greyed with nothing picked")

        map.highlight = .category(.video)
        XCTAssertFalse(map.isDimmed(video))
        XCTAssertTrue(map.isDimmed(image))
        XCTAssertEqual(map.fill(video, .light), FileCategory.video.color(.light))

        map.colourMode = .age
        XCTAssertNil(map.highlight, "a kind stayed picked under the age legend")
        map.highlight = .age(.older)
        XCTAssertTrue(map.isDimmed(video))
        XCTAssertFalse(map.isDimmed(image))
    }
}
