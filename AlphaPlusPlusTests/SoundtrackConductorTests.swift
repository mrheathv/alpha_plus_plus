import XCTest
@testable import AlphaPlusPlus

/// The music's settings row: four levels over one stored volume.
final class SoundtrackConductorTests: XCTestCase {

    func testEveryStoredVolumeShowsAsOneOfTheFourLevels() {
        XCTAssertEqual(MusicLevel.nearest(to: 0), .off)
        XCTAssertEqual(MusicLevel.nearest(to: SoundtrackConductor.defaultVolume), .medium)
        XCTAssertEqual(MusicLevel.nearest(to: 0.9), .high)
        XCTAssertEqual(MusicLevel.nearest(to: 0.2), .low)
        for level in MusicLevel.allCases { XCTAssertEqual(MusicLevel.nearest(to: level.rawValue), level) }
    }

    /// "Off" has to mean silence: the conductor mutes at a volume of zero
    /// rather than trusting a zero gain to be inaudible.
    func testOffIsZero() {
        XCTAssertEqual(MusicLevel.off.rawValue, 0)
    }
}
