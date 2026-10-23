import XCTest
@testable import ScreenCore

final class KeepAwakeTests: XCTestCase {
    func testOpenLidKeepsOneAssertionAcrossRepeatedRefreshes() throws {
        var acquired = 0, released: [UInt32] = []
        let awake = KeepAwake(acquire: { acquired += 1; return 0 }, release: { released.append($0) })
        try awake.start(lidClosed: false)
        for _ in 0..<60 { try awake.refresh() }
        XCTAssertTrue(awake.isActive) // Zero is a valid assertion ID, not an inactive sentinel.
        XCTAssertEqual(acquired, 1)
        awake.stop(); awake.stop()
        XCTAssertEqual(released, [0])
    }

    func testClosingLidReleasesWithoutWaitingForSystemSleep() throws {
        var acquired = 0, released: [UInt32] = []
        let awake = KeepAwake(acquire: { acquired += 1; return UInt32(acquired) }, release: { released.append($0) })
        try awake.start(lidClosed: false)
        try awake.lidChanged(closed: true)
        try awake.lidChanged(closed: true)
        try awake.refresh() // A closed external-display session may still be running.
        XCTAssertFalse(awake.isActive)
        XCTAssertEqual(released, [1])
        XCTAssertEqual(acquired, 1)
        try awake.lidChanged(closed: false)
        XCTAssertTrue(awake.isActive)
        XCTAssertEqual(acquired, 2)
    }

    func testLaunchClosedDoesNotAcquireUntilOpened() throws {
        var acquired = 0
        let awake = KeepAwake(acquire: { acquired += 1; return 1 }, release: { _ in })
        try awake.start(lidClosed: true)
        XCTAssertEqual(acquired, 0)
        try awake.lidChanged(closed: false)
        XCTAssertEqual(acquired, 1)
    }

    func testOpenEventDuringSleepDoesNotReacquireUntilWake() throws {
        var acquired = 0, released = 0
        let awake = KeepAwake(acquire: { acquired += 1; return UInt32(acquired) }, release: { _ in released += 1 })
        try awake.start(lidClosed: false)
        awake.willSleep(); awake.willSleep()
        try awake.lidChanged(closed: false)
        try awake.refresh()
        XCTAssertFalse(awake.isActive)
        XCTAssertEqual(acquired, 1)
        XCTAssertEqual(released, 1)
        try awake.didWake(lidClosed: false)
        try awake.didWake(lidClosed: false)
        XCTAssertTrue(awake.isActive)
        XCTAssertEqual(acquired, 2)
    }

    func testDarkWakeWithClosedLidDoesNotHoldDisplayAwake() throws {
        var acquired = 0
        let awake = KeepAwake(acquire: { acquired += 1; return 1 }, release: { _ in })
        try awake.start(lidClosed: false)
        awake.willSleep()
        try awake.didWake(lidClosed: true)
        XCTAssertFalse(awake.isActive)
        XCTAssertEqual(acquired, 1)
    }

    func testLateEventsAfterStopDoNotAcquire() throws {
        var acquired = 0, released = 0
        let awake = KeepAwake(acquire: { acquired += 1; return 1 }, release: { _ in released += 1 })
        try awake.start(lidClosed: false)
        awake.stop()
        try awake.didWake(lidClosed: false)
        try awake.lidChanged(closed: false)
        try awake.refresh()
        XCTAssertFalse(awake.isActive)
        XCTAssertEqual(acquired, 1)
        XCTAssertEqual(released, 1)
    }

    func testFailedAcquireCanRetryWithoutReleasingAnInvalidID() throws {
        var fail = true, acquired = 0, released = 0
        let awake = KeepAwake(acquire: {
            acquired += 1
            if fail { throw ScreenError("power assertion failed") }
            return 7
        }, release: { _ in released += 1 })
        XCTAssertThrowsError(try awake.start(lidClosed: false))
        XCTAssertFalse(awake.isActive)
        XCTAssertEqual(released, 0)
        fail = false
        try awake.refresh()
        XCTAssertTrue(awake.isActive)
        XCTAssertEqual(acquired, 2)
        awake.stop()
        XCTAssertEqual(released, 1)
    }

    func testDeinitReleasesOwnedAssertion() throws {
        var released: [UInt32] = []
        var awake: KeepAwake? = KeepAwake(acquire: { 9 }, release: { released.append($0) })
        try awake?.start(lidClosed: false)
        awake = nil
        XCTAssertEqual(released, [9])
    }
}
