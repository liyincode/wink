import Foundation
import IOKit.pwr_mgt

/// Owns one idle-sleep assertion for the application's open-lid lifetime.
public final class KeepAwake {
    private let acquire: () throws -> IOPMAssertionID
    private let release: (IOPMAssertionID) -> Void
    private var assertion: IOPMAssertionID?
    private var running = false
    private var sleeping = false
    private var lidClosed = true
    public var isActive: Bool { assertion != nil }

    public init(acquire: @escaping () throws -> IOPMAssertionID = {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), L10n.text("Wink is keeping the desktop active") as CFString, &id)
        guard result == kIOReturnSuccess else {
            throw ScreenError(L10n.text("Unable to keep this Mac awake. Try reopening Wink."))
        }
        return id
    }, release: @escaping (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }) {
        self.acquire = acquire; self.release = release
    }

    public func start(lidClosed: Bool) throws {
        running = true
        self.lidClosed = lidClosed
        try refresh()
    }

    public func lidChanged(closed: Bool) throws {
        lidClosed = closed
        try refresh()
    }

    public func willSleep() {
        sleeping = true
        releaseAssertion()
    }

    public func didWake(lidClosed: Bool) throws {
        sleeping = false
        self.lidClosed = lidClosed
        try refresh()
    }

    public func refresh() throws {
        guard running && !sleeping && !lidClosed else { releaseAssertion(); return }
        if assertion == nil { assertion = try acquire() }
    }

    public func stop() {
        running = false
        releaseAssertion()
    }

    private func releaseAssertion() {
        if let id = assertion { release(id); assertion = nil }
    }

    deinit { releaseAssertion() }
}
