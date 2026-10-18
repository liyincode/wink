import Foundation
import XCTest
@testable import ScreenCore

final class FakeGamma: GammaDevice {
    var screens = [GammaSnapshot(id: "a", red: [0, 0.7], green: [0, 0.8], blue: [0, 0.9]),
                   GammaSnapshot(id: "b", red: [0, 1], green: [0, 1], blue: [0, 1])]
    var failBlackFor: String?
    var failRestoreFor: String?
    var ignoreBlack = false
    var ignoreRestore = false
    var beforeApply: ((GammaSnapshot) -> Void)?
    func capture() throws -> [GammaSnapshot] { screens }
    func apply(_ snapshot: GammaSnapshot) throws {
        beforeApply?(snapshot)
        if snapshot.peak == 0 && snapshot.id == failBlackFor { throw ScreenError("black failure") }
        if snapshot.peak > 0 && snapshot.id == failRestoreFor { throw ScreenError("restore failure") }
        if snapshot.peak == 0 && ignoreBlack { return }
        if snapshot.peak > 0 && ignoreRestore { return }
        guard let i = screens.firstIndex(where: { $0.id == snapshot.id }) else { throw ScreenError("disconnected") }
        screens[i] = snapshot
    }
}

final class BlackoutTests: XCTestCase {
    var directory: URL!
    var journal: URL { directory.appendingPathComponent("restore.json") }
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testFractionalDimmingUsesOriginalAndCanReverse() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal)
        XCTAssertThrowsError(try session.setDimming(0.5))
        try session.prepareDimming()
        XCTAssertEqual(fake.screens, original)
        fake.beforeApply = { _ in
            XCTAssertTrue(FileManager.default.fileExists(atPath: self.journal.path))
        }
        try session.setDimming(0.75)
        XCTAssertEqual(fake.screens[0].red[1], original[0].red[1] * 0.25, accuracy: 0.00001)
        try session.prepareDimming()
        try session.setDimming(0.25)
        XCTAssertEqual(fake.screens[0].red[1], original[0].red[1] * 0.75, accuracy: 0.00001)
        XCTAssertEqual(session.saved, original)
        for invalid in [Double.nan, .infinity, -0.1, 1.1] {
            XCTAssertThrowsError(try session.setDimming(invalid))
        }
        try session.restore()
        XCTAssertEqual(fake.screens, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testInterruptedFadeRecoversAfterRestart() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal)
        try session.prepareDimming()
        try session.setDimming(0.4)
        try BlackoutSession(device: fake, journal: journal).recover()
        XCTAssertEqual(fake.screens, original)
    }

    func testIntermediateFailureKeepsJournalWhenRollbackFails() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal)
        try session.prepareDimming()
        fake.failRestoreFor = "b"
        XCTAssertThrowsError(try session.setDimming(0.5))
        XCTAssertTrue(session.isActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        fake.failRestoreFor = nil
        try session.restore()
        XCTAssertEqual(fake.screens, original)
    }

    func testRepeatedBlackoutPreservesDistinctOriginalStates() throws {
        let fake = FakeGamma()
        let original = fake.screens
        let actual = BlackoutSession(device: fake, journal: journal)
        try actual.blackout(); try actual.blackout()
        XCTAssertTrue(try actual.isBlack())
        XCTAssertEqual(actual.saved, original)
        try actual.restore()
        XCTAssertEqual(fake.screens, original)
        XCTAssertFalse(actual.isActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testPartialBlackoutFailureRestoresEveryDisplay() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        fake.failBlackFor = "b"
        let session = BlackoutSession(device: fake, journal: journal)
        XCTAssertThrowsError(try session.blackout())
        XCTAssertEqual(fake.screens, original)
        XCTAssertFalse(session.isActive)
    }

    func testIgnoredGammaWriteIsRejected() throws {
        let fake = FakeGamma(); fake.ignoreBlack = true
        let session = BlackoutSession(device: fake, journal: journal)
        XCTAssertThrowsError(try session.blackout())
        XCTAssertFalse(session.isActive)
    }

    func testFailedRestoreKeepsJournalAndCanRetry() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal)
        try session.blackout()
        fake.failRestoreFor = "a"
        XCTAssertThrowsError(try session.restore())
        XCTAssertTrue(session.isActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        fake.failRestoreFor = nil
        try session.restore()
        XCTAssertEqual(fake.screens, original)
    }

    func testNewProcessRecoversJournal() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        try BlackoutSession(device: fake, journal: journal).blackout()
        let restarted = BlackoutSession(device: fake, journal: journal)
        try restarted.recover()
        XCTAssertEqual(fake.screens, original)
        XCTAssertFalse(restarted.isActive)
    }

    func testSilentlyIgnoredRestoreKeepsRecoveryJournal() throws {
        let fake = FakeGamma()
        let session = BlackoutSession(device: fake, journal: journal)
        try session.blackout()
        fake.ignoreRestore = true
        XCTAssertThrowsError(try session.restore())
        XCTAssertTrue(session.isActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        fake.ignoreRestore = false
        try session.restore()
    }

    func testInvalidSnapshotAndAlreadyBlackDoNotStart() throws {
        let fake = FakeGamma()
        fake.screens = fake.screens.map(\.black)
        XCTAssertThrowsError(try BlackoutSession(device: fake, journal: journal).blackout())
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        try Data("[]".utf8).write(to: journal)
        XCTAssertThrowsError(try BlackoutSession(device: fake, journal: journal).recover())
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }

    func testDisplayDisconnectRetainsRecoveryRecord() throws {
        let fake = FakeGamma()
        let session = BlackoutSession(device: fake, journal: journal)
        try session.blackout()
        let disconnected = fake.screens.removeLast()
        try session.synchronizeDisplays()
        XCTAssertTrue(try session.isBlack())
        try session.restore()
        XCTAssertFalse(session.isActive)
        XCTAssertTrue(session.hasPendingRecovery)
        XCTAssertEqual(session.saved.map(\.id), [disconnected.id])
        fake.screens.append(disconnected)
        try session.synchronizeDisplays()
        XCTAssertFalse(session.isActive)
    }

    func testReconnectWhileBlackPreservesOriginal() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal)
        try session.blackout()
        fake.screens.removeLast()
        try session.synchronizeDisplays()
        XCTAssertTrue(session.isActive)
        XCTAssertTrue(session.isDimming)
        XCTAssertEqual(fake.screens[0], original[0].black)
        fake.screens.append(original[1]) // macOS may reset Gamma on reconnection.
        try session.synchronizeDisplays()
        XCTAssertTrue(try session.isBlack())
        XCTAssertEqual(session.saved, original)
        try session.restore()
        XCTAssertEqual(fake.screens, original)
        XCTAssertFalse(session.hasPendingRecovery)
    }

    func testNewDisplayIsJournaledBeforeDarkening() throws {
        let fake = FakeGamma()
        let actual = BlackoutSession(device: fake, journal: journal)
        try actual.blackout()
        let added = GammaSnapshot(id: "c", red: [0, 0.4], green: [0, 0.5], blue: [0, 0.6])
        fake.screens.append(added)
        fake.beforeApply = { snapshot in
            if snapshot.id == "c" {
                let records = try! JSONDecoder().decode([GammaSnapshot].self, from: Data(contentsOf: self.journal))
                XCTAssertTrue(records.contains(added))
            }
        }
        try actual.synchronizeDisplays()
        XCTAssertTrue(try actual.isBlack())
        try actual.restore()
        XCTAssertEqual(fake.screens.last, added)
    }

    func testRestartWithOfflineDisplayRestoresOnlyConnectedThenReconnects() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        try BlackoutSession(device: fake, journal: journal).blackout()
        fake.screens.removeLast()
        let restarted = BlackoutSession(device: fake, journal: journal)
        try restarted.recover()
        XCTAssertFalse(restarted.isActive)
        XCTAssertEqual(fake.screens, [original[0]])
        XCTAssertEqual(restarted.saved, [original[1]])
        fake.screens.append(original[1].black)
        try restarted.synchronizeDisplays()
        XCTAssertEqual(fake.screens, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testToggleAgainWithOfflineRecoveryPreservesBothBaselines() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal)
        try session.blackout()
        fake.screens.removeLast()
        try session.restore()
        try session.blackout()
        XCTAssertEqual(Set(session.saved.map(\.id)), Set(["a", "b"]))
        XCTAssertEqual(fake.screens, [original[0].black])
        fake.screens.append(original[1].black)
        try session.synchronizeDisplays()
        try session.restore()
        XCTAssertEqual(fake.screens, original)
    }

    func testDisconnectDuringGammaWriteDoesNotRestoreOtherScreens() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal)
        try session.prepareDimming()
        fake.beforeApply = { snapshot in
            if snapshot.id == "b" { fake.screens.removeAll { $0.id == "b" } }
        }
        try session.setDimming(1)
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(fake.screens, [original[0].black])
        XCTAssertEqual(session.saved, original)
        fake.beforeApply = nil
        try session.restore()
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.saved, [original[1]])
    }

    func testAllDisconnectedAndReconnectFollowsLatestIntent() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal)
        try session.blackout()
        fake.screens = []
        try session.synchronizeDisplays()
        XCTAssertTrue(session.isActive)
        try session.restore()
        XCTAssertFalse(session.isActive)
        XCTAssertTrue(session.hasPendingRecovery)
        fake.screens = original.map(\.black)
        try session.synchronizeDisplays()
        XCTAssertEqual(fake.screens, original)
    }

    func testReconnectRestoreFailureKeepsOnlyUnrestoredRecordAndCanRetry() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal)
        try session.blackout()
        fake.screens.removeLast()
        try session.restore()
        fake.screens.append(original[1].black)
        fake.failRestoreFor = "b"
        XCTAssertThrowsError(try session.synchronizeDisplays())
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.saved, [original[1]])
        fake.failRestoreFor = nil
        try session.restore()
        XCTAssertEqual(fake.screens, original)
        XCTAssertFalse(session.hasPendingRecovery)
    }

    func testScheduleStillEndsAfterDisconnect() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal)
        var schedule = BlackoutSchedule(); schedule.enabled = true
        var runner = ScheduleRunner()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12))!
        XCTAssertEqual(runner.step(at: start, schedule: schedule, isBlack: session.isActive, calendar: calendar), .blackout)
        try session.blackout()
        fake.screens.removeLast()
        try session.synchronizeDisplays()
        XCTAssertEqual(runner.step(at: start.addingTimeInterval(60), schedule: schedule, isBlack: session.isActive, calendar: calendar), .none)
        XCTAssertNil(runner.skippedUntil)
        XCTAssertEqual(runner.step(at: start.addingTimeInterval(90 * 60), schedule: schedule, isBlack: session.isActive, calendar: calendar), .restore)
        try session.restore()
        XCTAssertEqual(fake.screens, [original[0]])
        fake.screens.append(original[1].black)
        try session.synchronizeDisplays()
        XCTAssertEqual(fake.screens, original)
    }

    func testDisconnectDuringFadeKeepsProgressAndReconnectUsesBaseline() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal)
        try session.prepareDimming()
        try session.setDimming(0.4)
        fake.screens.removeLast()
        try session.setDimming(0.6)
        XCTAssertEqual(fake.screens[0].red[1], original[0].red[1] * 0.4, accuracy: 0.00001)
        fake.screens.append(original[1])
        try session.setDimming(0.8)
        XCTAssertEqual(fake.screens[1].red[1], original[1].red[1] * 0.2, accuracy: 0.00001)
        try session.restore()
        XCTAssertEqual(fake.screens, original)
    }

    func testDelayedGammaResetAfterUnplugKeepsBlackoutIntent() throws {
        var now: TimeInterval = 10
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal, uptime: { now })
        try session.blackout()
        fake.screens.removeLast()
        try session.synchronizeDisplays()
        // Quartz resets the remaining display after the first topology reconciliation.
        fake.screens[0] = original[0]
        now += 0.1
        XCTAssertNoThrow(try session.verifyBlackout())
        try session.synchronizeDisplays()
        XCTAssertEqual(fake.screens, [original[0].black])
        XCTAssertTrue(session.isDimming)
        XCTAssertEqual(session.saved, original)
        now += 3
        XCTAssertNoThrow(try session.verifyBlackout())
        try session.restore()
        XCTAssertEqual(fake.screens, [original[0]])
    }

    func testConfigurationNotificationReappliesWithUnchangedDisplayIDs() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal)
        try session.blackout()
        session.displayConfigurationChanged(beginning: true)
        fake.screens = original
        try session.synchronizeDisplays()
        XCTAssertEqual(fake.screens, original) // Avoid writes while Quartz reconfigures.
        session.displayConfigurationChanged()
        try session.synchronizeDisplays()
        XCTAssertTrue(try session.isBlack())
        fake.screens = original
        try session.synchronizeDisplays()
        XCTAssertTrue(try session.isBlack())
        XCTAssertEqual(session.saved, original)
    }

    func testSettlingWindowDoesNotHidePermanentGammaFailure() throws {
        var now: TimeInterval = 10
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal, uptime: { now })
        try session.blackout()
        session.displayConfigurationChanged()
        fake.screens = original
        fake.ignoreBlack = true
        try session.synchronizeDisplays()
        XCTAssertNoThrow(try session.verifyBlackout())
        now += 2.1
        XCTAssertFalse(session.isSettlingDisplays)
        XCTAssertThrowsError(try session.verifyBlackout())
        try session.restore()
        XCTAssertEqual(fake.screens, original)
    }

    func testManualRestoreDuringSettlingNeverDarkensAgain() throws {
        let fake = FakeGamma(), original = FakeGamma().screens
        let session = BlackoutSession(device: fake, journal: journal)
        try session.blackout()
        fake.screens.removeLast()
        session.displayConfigurationChanged()
        try session.synchronizeDisplays()
        try session.restore()
        try session.synchronizeDisplays()
        XCTAssertEqual(fake.screens, [original[0]])
        XCTAssertFalse(session.isDimming)
        fake.screens.append(original[1].black)
        try session.synchronizeDisplays()
        XCTAssertEqual(fake.screens, original)
        XCTAssertFalse(session.isActive)
    }
}
