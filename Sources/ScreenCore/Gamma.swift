import CoreGraphics
import ColorSync
import Foundation

public struct GammaSnapshot: Codable, Equatable {
    public let id: String
    public let red: [Float]
    public let green: [Float]
    public let blue: [Float]

    public init(id: String, red: [Float], green: [Float], blue: [Float]) {
        self.id = id; self.red = red; self.green = green; self.blue = blue
    }

    public var valid: Bool {
        !red.isEmpty && red.count <= 4096 && red.count == green.count && red.count == blue.count
            && (red + green + blue).allSatisfy { $0.isFinite && $0 >= 0 }
    }

    public var peak: Float { (red + green + blue).max() ?? 0 }

    public var black: GammaSnapshot {
        let zeros = [Float](repeating: 0, count: red.count)
        return GammaSnapshot(id: id, red: zeros, green: zeros, blue: zeros)
    }
}

public struct ScreenError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public protocol GammaDevice {
    func read() throws -> GammaRead
    func apply(_ snapshot: GammaSnapshot) throws
}

public struct GammaRead {
    public let snapshots: [GammaSnapshot]
    public let failures: [String: ScreenError]
    public init(snapshots: [GammaSnapshot], failures: [String: ScreenError] = [:]) {
        self.snapshots = snapshots; self.failures = failures
    }
    public var onlineIDs: Set<String> { Set(snapshots.map(\.id)).union(failures.keys) }
}

/// A display is still online but cannot be read; keep other displays and recovery records intact.
public struct DisplayUnavailableError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public extension GammaDevice {
    func capture() throws -> [GammaSnapshot] {
        let reading = try read()
        if let id = reading.failures.keys.sorted().first { throw reading.failures[id]! }
        return reading.snapshots
    }
}

public final class SystemGamma: GammaDevice {
    public init() {}

    private func displays() throws -> [(String, CGDirectDisplayID)] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else {
            throw ScreenError(L10n.text("No connected displays were found."))
        }
        if count == 0 { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            throw ScreenError(L10n.text("Unable to list connected displays."))
        }
        return try ids.prefix(Int(count)).compactMap { id -> (String, CGDirectDisplayID)? in
            guard CGDisplayIsOnline(id) != 0 else { return nil }
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
                if CGDisplayIsOnline(id) == 0 { return nil }
                throw ScreenError(L10n.text("Unable to read the display identifier."))
            }
            return (CFUUIDCreateString(nil, uuid) as String, id)
        }
    }

    public func read() throws -> GammaRead {
        var snapshots: [GammaSnapshot] = []
        var failures: [String: ScreenError] = [:]
        for (uuid, id) in try displays() {
            let capacity: UInt32 = 4096
            var r = [Float](repeating: 0, count: Int(capacity))
            var g = r, b = r, count: UInt32 = 0
            let result = CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count)
            guard result == .success, count > 0, count <= capacity else {
                if CGDisplayIsOnline(id) == 0 { continue }
                failures[uuid] = ScreenError(L10n.text("Unable to read display Gamma for %@ (error %@).", uuid, String(result.rawValue)))
                continue
            }
            let snapshot = GammaSnapshot(id: uuid, red: Array(r.prefix(Int(count))),
                                         green: Array(g.prefix(Int(count))), blue: Array(b.prefix(Int(count))))
            guard snapshot.valid else {
                failures[uuid] = ScreenError(L10n.text("The display returned invalid Gamma data."))
                continue
            }
            snapshots.append(snapshot)
        }
        return GammaRead(snapshots: snapshots, failures: failures)
    }

    public func apply(_ snapshot: GammaSnapshot) throws {
        guard snapshot.valid else { throw ScreenError(L10n.text("The recovery record contains invalid Gamma data.")) }
        guard let id = try displays().first(where: { $0.0 == snapshot.id })?.1 else {
            throw ScreenError(L10n.text("Display %@ is disconnected. Reconnect it to restore its state.", String(snapshot.id)))
        }
        let result = CGSetDisplayTransferByTable(id, UInt32(snapshot.red.count), snapshot.red, snapshot.green, snapshot.blue)
        guard result == .success else { throw ScreenError(L10n.text("Unable to apply display Gamma (error %@).", String(result.rawValue))) }
    }
}

public final class BlackoutSession {
    private let device: GammaDevice
    public let journal: URL
    public private(set) var saved: [GammaSnapshot] = []
    public private(set) var isActive = false
    public var hasPendingRecovery: Bool { !saved.isEmpty }
    public var isDimming: Bool { dimmingAmount != nil }
    private var dimmingAmount: Double?
    private var connectedIDs: Set<String> = []
    private let uptime: () -> TimeInterval
    private var configurationUntil: TimeInterval = 0
    private var configurationBeginning = false
    private var unavailableSince: [String: TimeInterval] = [:]
    public var hasUnavailableDisplays: Bool { !unavailableSince.isEmpty }
    public var isSettlingDisplays: Bool { uptime() < configurationUntil }
    public var isReconfiguringDisplays: Bool { configurationBeginning && isSettlingDisplays }

    public func displayConfigurationChanged(beginning: Bool = false) {
        configurationBeginning = beginning
        configurationUntil = uptime() + 2
    }

    public init(device: GammaDevice = SystemGamma(), journal: URL,
                uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.device = device; self.journal = journal; self.uptime = uptime
    }

    public func recover() throws {
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let records = try JSONDecoder().decode([GammaSnapshot].self, from: Data(contentsOf: journal))
        guard !records.isEmpty, records.allSatisfy(\.valid), Set(records.map(\.id)).count == records.count else {
            throw ScreenError(L10n.text("The recovery record is invalid. Displays were not changed."))
        }
        saved = records
        try restore()
    }

    public func blackout() throws {
        guard !isActive else { return }
        try prepareDimming()
        try setDimming(1)
    }

    public func prepareDimming() throws {
        guard !isActive else { return }
        guard hasPendingRecovery || !FileManager.default.fileExists(atPath: journal.path) else {
            throw ScreenError(L10n.text("A recovery record is still pending. Restore your displays first."))
        }
        let current = try device.capture()
        guard !current.isEmpty else { throw ScreenError(L10n.text("No connected displays were found.")) }
        try remember(current)
        connectedIDs = Set(current.map(\.id))
        isActive = true
        dimmingAmount = 0
    }

    private func persist(_ records: [GammaSnapshot]) throws {
        if records.isEmpty {
            if FileManager.default.fileExists(atPath: journal.path) { try FileManager.default.removeItem(at: journal) }
        } else {
            try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: journal, options: .atomic)
        }
        saved = records
    }

    private func remember(_ current: [GammaSnapshot]) throws {
        let additions = current.filter { screen in !saved.contains(where: { $0.id == screen.id }) }
        guard additions.allSatisfy({ $0.valid && $0.peak > 0.02 }) else {
            throw ScreenError(L10n.text("The display is already too dark or does not support Gamma. Increase brightness and try again."))
        }
        // New displays must have a durable baseline before their first Gamma write.
        if !additions.isEmpty { try persist(saved + additions) }
    }

    private func applyIfConnected(_ snapshot: GammaSnapshot) throws {
        do { try device.apply(snapshot) }
        catch {
            // A cable can be removed between enumeration and the Gamma write.
            let reading = try readDisplays()
            guard reading.onlineIDs.contains(snapshot.id) else { return }
            if reading.failures[snapshot.id] != nil {
                try reportUnavailable(reading)
                return
            }
            throw error
        }
    }

    private func readDisplays() throws -> GammaRead {
        let reading = try device.read()
        unavailableSince = unavailableSince.filter { reading.failures[$0.key] != nil }
        for id in reading.failures.keys where unavailableSince[id] == nil {
            unavailableSince[id] = uptime()
            NSLog("Wink display read deferred: %@", reading.failures[id]!.message)
        }
        return reading
    }

    private func reportUnavailable(_ reading: GammaRead, relevantIDs: Set<String>? = nil) throws {
        let expired = reading.failures.keys.filter {
            (relevantIDs == nil || relevantIDs!.contains($0)) && uptime() - (unavailableSince[$0] ?? uptime()) >= 5
        }
        guard !expired.isEmpty else { return }
        throw DisplayUnavailableError(message: expired.sorted().map {
            L10n.text("Display %@ is temporarily unavailable. Wink will keep retrying. Other displays are unchanged.", $0)
        }.joined(separator: "\n"))
    }

    /// Reconcile hot-plug changes without altering the user's current blackout intent.
    public func synchronizeDisplays() throws {
        guard isDimming || hasPendingRecovery else { return }
        guard !isReconfiguringDisplays else { return }
        let wasUnavailable = hasUnavailableDisplays
        let reading = try readDisplays()
        let ids = reading.onlineIDs
        let changed = ids != connectedIDs
        if changed { displayConfigurationChanged() }
        guard changed || isSettlingDisplays || wasUnavailable || hasUnavailableDisplays
            || (!isDimming && hasPendingRecovery) else { return }
        connectedIDs = ids
        if let amount = dimmingAmount { try setDimming(amount) }
        else if hasPendingRecovery { try restore() }
    }

    public func setDimming(_ amount: Double) throws {
        guard amount.isFinite, (0...1).contains(amount), isActive else {
            throw ScreenError(L10n.text("Invalid dimming progress or missing recovery record."))
        }
        let factor = Float(1 - amount)
        do {
            let reading = try readDisplays()
            let current = reading.snapshots
            try remember(current)
            let ids = reading.onlineIDs
            if ids != connectedIDs { displayConfigurationChanged() }
            connectedIDs = ids
            dimmingAmount = amount
            let readableIDs = Set(current.map(\.id))
            for screen in saved where readableIDs.contains(screen.id) {
                try applyIfConnected(GammaSnapshot(id: screen.id, red: screen.red.map { $0 * factor },
                                               green: screen.green.map { $0 * factor }, blue: screen.blue.map { $0 * factor }))
            }
            if amount > 0 { try reportUnavailable(reading) }
            if amount == 1 { try verifyBlackout() }
        } catch let error as DisplayUnavailableError {
            throw error
        } catch {
            let original = error.localizedDescription
            do { try restore() } catch {
                let recovery = error.localizedDescription
                throw ScreenError(recovery == original ? original : original + L10n.text(" Recovery still required: ") + recovery)
            }
            throw ScreenError(original)
        }
    }

    public func isBlack() throws -> Bool {
        // Status queries must not consume a pending reconciliation when a display becomes ready.
        let reading = try device.read()
        return isActive && reading.failures.isEmpty && reading.snapshots.allSatisfy {
            screen in saved.contains(where: { $0.id == screen.id }) && screen.peak < 0.002
        }
    }

    public func verifyBlackout() throws {
        // Quartz may reset Gamma after reporting a configuration change. Reapply while
        // settling, then resume strict verification; a permanently ignored write still fails.
        guard !isSettlingDisplays else { return }
        let reading = try readDisplays()
        try reportUnavailable(reading)
        let current = reading.snapshots
        // A topology change during verification is handled by the next reconciliation.
        guard reading.onlineIDs == connectedIDs else { return }
        guard current.allSatisfy({ $0.peak < 0.002 }) else {
            throw ScreenError(L10n.text("The display did not accept the blackout settings. Restoration was attempted."))
        }
    }

    public func restore() throws {
        dimmingAmount = nil
        guard hasPendingRecovery else { isActive = false; unavailableSince = [:]; return }
        // Failures remain active; offline-only records do not determine the UI state.
        isActive = true
        let before = try readDisplays()
        connectedIDs = before.onlineIDs
        let readableIDs = Set(before.snapshots.map(\.id))
        var failures: [String: String] = [:]
        for snapshot in saved where readableIDs.contains(snapshot.id) {
            do { try applyIfConnected(snapshot) } catch { failures[snapshot.id] = error.localizedDescription }
        }
        let reading = try readDisplays()
        let current = reading.snapshots
        connectedIDs = reading.onlineIDs
        var remaining: [GammaSnapshot] = []
        for original in saved {
            guard let restored = current.first(where: { $0.id == original.id }) else {
                failures[original.id] = nil
                remaining.append(original)
                continue
            }
            let matches = restored.red.count == original.red.count
                && restored.green.count == original.green.count && restored.blue.count == original.blue.count
            let originalSamples = original.red + original.green + original.blue
            let restoredSamples = restored.red + restored.green + restored.blue
            let delta: Float = zip(originalSamples, restoredSamples)
                .map { abs($0 - $1) }.max() ?? .infinity
            if failures[original.id] != nil || !matches || delta >= 0.002 {
                remaining.append(original)
                failures[original.id] = failures[original.id] ?? L10n.text("The display was not restored to its original state. The recovery record has been kept. Try restoring again.")
            }
        }
        // Remove only individually verified baselines; unplugged displays stay recoverable.
        if remaining != saved { try persist(remaining) }
        if saved.isEmpty { unavailableSince = [:] }
        isActive = !failures.isEmpty || !Set(saved.map(\.id)).isDisjoint(with: reading.failures.keys)
        if !failures.isEmpty { throw ScreenError(Array(Set(failures.values)).sorted().joined(separator: "\n")) }
        try reportUnavailable(reading, relevantIDs: Set(saved.map(\.id)))
    }
}
