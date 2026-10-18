import XCTest
@testable import ScreenCore

final class ScreenFadeTests: XCTestCase {
    func testHalfSecondFadeAndVisibleClosedEyes() {
        var fade = ScreenFade()
        fade.target(true)
        fade.advance(seconds: 0.4)
        XCTAssertEqual(fade.eyeClosure, 1)
        XCTAssertLessThan(fade.dimming, 0.7)
        XCTAssertTrue(fade.isRunning)
        fade.advance(seconds: 0.1)
        XCTAssertEqual(fade.dimming, 1)
        XCTAssertFalse(fade.isRunning)
    }

    func testReversalPreservesCurrentLevelAndRepeatedToggles() {
        var fade = ScreenFade()
        fade.target(true)
        fade.advance(seconds: 0.25)
        let level = fade.dimming
        fade.target(false)
        XCTAssertEqual(fade.dimming, level)
        fade.advance(seconds: 0.1)
        XCTAssertLessThan(fade.dimming, level)
        fade.target(true)
        fade.advance(seconds: 0.1)
        XCTAssertEqual(fade.dimming, level, accuracy: 0.000001)
        fade.target(false)
        fade.advance(seconds: 1)
        XCTAssertEqual(fade.progress, 0)
        XCTAssertFalse(fade.isRunning)
    }

    func testInvalidElapsedTimeAndImmediateReset() {
        var fade = ScreenFade()
        fade.target(true)
        for invalid in [Double.nan, .infinity, -1] { fade.advance(seconds: invalid) }
        XCTAssertEqual(fade.progress, 0)
        fade.reset(isBlack: true)
        XCTAssertEqual(fade.progress, 1)
        XCTAssertFalse(fade.isRunning)
        fade.reset(isBlack: false)
        XCTAssertEqual(fade.dimming, 0)
    }
}
