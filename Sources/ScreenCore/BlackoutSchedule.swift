import Foundation

public struct BlackoutSchedule: Codable, Equatable {
    public var enabled = false
    public var startMinute = 12 * 60
    public var endMinute = 13 * 60 + 30
    // Calendar weekday values: Sunday = 1, Saturday = 7.
    public var weekdays: Set<Int> = Set(1...7)
    public init() {}

    public var validationError: String? {
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute) else { return L10n.text("Choose a valid time.") }
        guard startMinute != endMinute else { return L10n.text("Start and end times must be different.") }
        guard !weekdays.isEmpty, weekdays.isSubset(of: Set(1...7)) else { return L10n.text("Select at least one day.") }
        return nil
    }

    public func interval(at now: Date, calendar: Calendar = .autoupdatingCurrent) -> DateInterval? {
        guard enabled, validationError == nil else { return nil }
        let today = calendar.startOfDay(for: now)
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let endDay = calendar.date(byAdding: .day, value: endMinute < startMinute ? 1 : 0, to: day),
                  let start = calendar.date(bySettingHour: startMinute / 60, minute: startMinute % 60, second: 0, of: day),
                  let end = calendar.date(bySettingHour: endMinute / 60, minute: endMinute % 60, second: 0, of: endDay),
                  start < end else { continue }
            if now >= start && now < end { return DateInterval(start: start, end: end) }
        }
        return nil
    }

    public static let preferenceKey = "blackoutSchedule"
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: preferenceKey),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.validationError == nil else { return Self() }
        return value
    }

    public func save(to defaults: UserDefaults = .standard) throws {
        if let error = validationError { throw ScreenError(error) }
        defaults.set(try JSONEncoder().encode(self), forKey: Self.preferenceKey)
    }
}

/// Decides actions without changing displays; the caller reports failed starts by cancelling.
public struct ScheduleRunner {
    public enum Action: Equatable { case blackout, restore, none }
    public private(set) var ownedInterval: DateInterval?
    public private(set) var skippedUntil: Date?
    public init(skippedUntil: Date? = nil) { self.skippedUntil = skippedUntil }

    public mutating func cancel(at now: Date, schedule: BlackoutSchedule, calendar: Calendar = .autoupdatingCurrent) {
        let end = schedule.interval(at: now, calendar: calendar)?.end ?? ownedInterval?.end
        if let end { skippedUntil = max(skippedUntil ?? end, end) }
        ownedInterval = nil
    }

    public mutating func step(at now: Date, schedule: BlackoutSchedule, isBlack: Bool,
                              calendar: Calendar = .autoupdatingCurrent) -> Action {
        let interval = schedule.interval(at: now, calendar: calendar)
        if let ownedInterval {
            if ownedInterval != interval {
                self.ownedInterval = nil
                return isBlack ? .restore : .none
            }
            if !isBlack { cancel(at: now, schedule: schedule, calendar: calendar) }
            return .none
        }
        guard let interval, skippedUntil.map({ now >= $0 }) ?? true else { return .none }
        if isBlack {
            // A manually started blackout must never become owned by the schedule.
            skippedUntil = interval.end
            return .none
        }
        ownedInterval = interval
        return .blackout
    }
}
