import Foundation
import XCTest
@testable import ScreenCore

final class ScheduleTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    func date(_ text: String, calendar: Calendar? = nil) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar ?? self.calendar
        formatter.timeZone = (calendar ?? self.calendar).timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }
    var enabled: BlackoutSchedule {
        var value = BlackoutSchedule(); value.enabled = true
        return value
    }

    func testDisabledValidationAndPersistence() throws {
        XCTAssertNil(BlackoutSchedule().interval(at: date("2026-10-16 12:30"), calendar: calendar))
        let defaults = UserDefaults(suiteName: "Wink.ScheduleTests.\(UUID())")!
        defer { defaults.removeObject(forKey: BlackoutSchedule.preferenceKey) }
        var value = enabled
        value.weekdays = [1, 3, 6]
        try value.save(to: defaults)
        XCTAssertEqual(BlackoutSchedule.load(from: defaults), value)
        value.weekdays = []
        XCTAssertThrowsError(try value.save(to: defaults))
        value.weekdays = [8]
        XCTAssertNotNil(value.validationError)
        value.weekdays = [1]; value.endMinute = value.startMinute
        XCTAssertNotNil(value.validationError)
        value.endMinute = 1440
        XCTAssertNotNil(value.validationError)
        defaults.set(Data("broken".utf8), forKey: BlackoutSchedule.preferenceKey)
        XCTAssertEqual(BlackoutSchedule.load(from: defaults), BlackoutSchedule())
    }

    func testBoundariesAndSelectedDays() {
        var value = enabled; value.weekdays = [6] // Friday
        XCTAssertNil(value.interval(at: date("2026-10-16 11:59"), calendar: calendar))
        XCTAssertNotNil(value.interval(at: date("2026-10-16 12:00"), calendar: calendar))
        XCTAssertNotNil(value.interval(at: date("2026-10-16 13:29"), calendar: calendar))
        XCTAssertNil(value.interval(at: date("2026-10-16 13:30"), calendar: calendar))
        XCTAssertNil(value.interval(at: date("2026-10-17 12:30"), calendar: calendar))
    }

    func testOvernightBelongsToStartDayIncludingWeekBoundary() {
        var value = enabled
        value.weekdays = [7]; value.startMinute = 23 * 60; value.endMinute = 90
        let interval = value.interval(at: date("2026-10-18 01:00"), calendar: calendar)
        XCTAssertEqual(interval?.start, date("2026-10-17 23:00"))
        XCTAssertEqual(interval?.end, date("2026-10-18 01:30"))
        XCTAssertNil(value.interval(at: date("2026-10-18 23:30"), calendar: calendar))
    }

    func testAutomaticStartAndEnd() {
        var runner = ScheduleRunner()
        XCTAssertEqual(runner.step(at: date("2026-10-16 11:59"), schedule: enabled, isBlack: false, calendar: calendar), .none)
        XCTAssertEqual(runner.step(at: date("2026-10-16 12:00"), schedule: enabled, isBlack: false, calendar: calendar), .blackout)
        XCTAssertEqual(runner.step(at: date("2026-10-16 12:01"), schedule: enabled, isBlack: true, calendar: calendar), .none)
        XCTAssertEqual(runner.step(at: date("2026-10-16 13:30"), schedule: enabled, isBlack: true, calendar: calendar), .restore)
        XCTAssertEqual(runner.step(at: date("2026-10-16 13:31"), schedule: enabled, isBlack: false, calendar: calendar), .none)
    }

    func testEarlyRestoreAndFailedStartSkipThisOccurrenceIncludingRestart() {
        var runner = ScheduleRunner()
        XCTAssertEqual(runner.step(at: date("2026-10-16 12:01"), schedule: enabled, isBlack: false, calendar: calendar), .blackout)
        runner.cancel(at: date("2026-10-16 12:10"), schedule: enabled, calendar: calendar)
        XCTAssertEqual(runner.step(at: date("2026-10-16 12:11"), schedule: enabled, isBlack: false, calendar: calendar), .none)
        var restarted = ScheduleRunner(skippedUntil: runner.skippedUntil)
        XCTAssertEqual(restarted.step(at: date("2026-10-16 12:12"), schedule: enabled, isBlack: false, calendar: calendar), .none)
        XCTAssertEqual(restarted.step(at: date("2026-10-17 12:00"), schedule: enabled, isBlack: false, calendar: calendar), .blackout)
    }

    func testManualBlackoutIsNeverRestoredBySchedule() {
        var runner = ScheduleRunner()
        XCTAssertEqual(runner.step(at: date("2026-10-16 12:00"), schedule: enabled, isBlack: true, calendar: calendar), .none)
        XCTAssertNil(runner.ownedInterval)
        XCTAssertEqual(runner.step(at: date("2026-10-16 13:30"), schedule: enabled, isBlack: true, calendar: calendar), .none)
    }

    func testDisableOrChangeRestoresOwnedBlackout() {
        for disabled in [true, false] {
            var runner = ScheduleRunner()
            _ = runner.step(at: date("2026-10-16 12:00"), schedule: enabled, isBlack: false, calendar: calendar)
            var changed = enabled
            if disabled { changed.enabled = false } else { changed.startMinute = 14 * 60 }
            XCTAssertEqual(runner.step(at: date("2026-10-16 12:01"), schedule: changed, isBlack: true, calendar: calendar), .restore)
        }
    }

    func testDaylightSavingAndLocalTimezone() {
        var local = calendar; local.timeZone = TimeZone(identifier: "America/New_York")!
        var value = enabled; value.startMinute = 23 * 60; value.endMinute = 4 * 60
        let spring = value.interval(at: date("2026-03-08 03:30", calendar: local), calendar: local)
        XCTAssertEqual(spring?.duration, 4 * 3600)
        let fall = value.interval(at: date("2026-11-01 03:30", calendar: local), calendar: local)
        XCTAssertEqual(fall?.duration, 6 * 3600)
        value.startMinute = 2 * 60 + 30
        let missingTime = value.interval(at: date("2026-03-08 03:15", calendar: local), calendar: local)
        XCTAssertEqual(missingTime?.start, date("2026-03-08 03:00", calendar: local))
        XCTAssertNil(enabled.interval(at: date("2026-10-16 12:30"), calendar: local))
    }
}
