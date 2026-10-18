import Carbon
import Foundation

public struct KeyboardShortcut: Codable, Equatable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let label: String

    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }

    public static let defaultToggle = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey | optionKey), label: "B")
    public static let preferenceKey = "toggleShortcut"

    public var display: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + label
    }

    public var validationError: String? {
        let allowed = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        guard modifiers & ~allowed == 0, modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
            return L10n.text("Include Option, Control, or Command to avoid interfering with typing.")
        }
        guard keyCode < 128, !label.isEmpty,
              ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(Int(keyCode)) else {
            return L10n.text("Press a modifier key together with another key.")
        }
        if modifiers == UInt32(controlKey | optionKey | cmdKey), [UInt32(kVK_ANSI_B), UInt32(kVK_ANSI_R)].contains(keyCode) {
            return L10n.text("This combination is reserved for backup controls. Choose another shortcut.")
        }
        return nil
    }

    public static func load(from defaults: UserDefaults = .standard) -> KeyboardShortcut {
        let saved = defaults.data(forKey: preferenceKey)
        guard let data = saved ?? defaults.data(forKey: "restoreShortcut"),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.validationError == nil else {
            return .defaultToggle
        }
        if saved == nil, value.keyCode == UInt32(kVK_Space), value.modifiers == UInt32(optionKey) {
            return .defaultToggle
        }
        return value
    }

    public func save(to defaults: UserDefaults = .standard) throws {
        guard validationError == nil else { throw ScreenError(validationError!) }
        defaults.set(try JSONEncoder().encode(self), forKey: Self.preferenceKey)
    }
}
