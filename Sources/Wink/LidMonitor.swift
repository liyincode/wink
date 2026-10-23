import Foundation
import IOKit
import IOKit.pwr_mgt
import ScreenCore

/// Observe the lid itself: an external display can keep the system awake after closure.
final class LidMonitor {
    // IOPM.h: iokit_family_msg(sub_iokit_powermanagement, 0x100).
    // Swift cannot import this C macro; its public message value is 0xe0034100.
    private static let clamshellStateChanged: natural_t = 0xe0034100
    private var root: io_service_t = 0
    private var notification: io_object_t = 0
    private var port: IONotificationPortRef?
    private var onChange: ((Bool) -> Void)?

    func start(onChange: @escaping (Bool) -> Void) throws -> Bool {
        stop()
        self.onChange = onChange
        root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            stop(); throw unavailable()
        }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, type, _ in
            guard type == LidMonitor.clamshellStateChanged, let context else { return }
            let monitor = Unmanaged<LidMonitor>.fromOpaque(context).takeUnretainedValue()
            do { monitor.onChange?(try monitor.isClosed()) }
            catch {
                // If lid state becomes unreadable, release the assertion conservatively.
                NSLog("Wink lid state unavailable: %@", error.localizedDescription)
                monitor.onChange?(true)
            }
        }, Unmanaged.passUnretained(self).toOpaque(), &notification)
        guard result == kIOReturnSuccess else { stop(); throw unavailable() }
        do { return try isClosed() }
        catch { stop(); throw error }
    }

    func isClosed() throws -> Bool {
        guard root != 0 else { throw unavailable() }
        guard let value = IORegistryEntryCreateCFProperty(root, kAppleClamshellStateKey as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return false // The public SDK defines a missing property as hardware without a lid.
        }
        guard let closed = value as? Bool else { throw unavailable() }
        return closed
    }

    func stop() {
        onChange = nil
        if notification != 0 { IOObjectRelease(notification); notification = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
        if root != 0 { IOObjectRelease(root); root = 0 }
    }

    private func unavailable() -> ScreenError {
        ScreenError(L10n.text("Unable to monitor the laptop lid. Wink will not prevent sleep. Try reopening Wink."))
    }

    deinit { stop() }
}
