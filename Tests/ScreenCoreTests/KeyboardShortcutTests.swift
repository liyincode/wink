import Carbon
import XCTest
@testable import ScreenCore

final class KeyboardShortcutTests: XCTestCase {
    func testLegacyShortcutMigrationAndNewPreferencePriority() throws {
        let name = "local.wink.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let legacy = KeyboardShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), label: "Space")
        defaults.set(try JSONEncoder().encode(legacy), forKey: "restoreShortcut")
        XCTAssertEqual(KeyboardShortcut.load(from: defaults), .defaultToggle)
        let custom = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey), label: "K")
        defaults.set(try JSONEncoder().encode(custom), forKey: "restoreShortcut")
        XCTAssertEqual(KeyboardShortcut.load(from: defaults), custom)
        try legacy.save(to: defaults)
        XCTAssertEqual(KeyboardShortcut.load(from: defaults), legacy)
        defaults.set(Data("invalid".utf8), forKey: KeyboardShortcut.preferenceKey)
        XCTAssertEqual(KeyboardShortcut.load(from: defaults), .defaultToggle)
    }

    func testDefaultAndModifierDisplay() {
        XCTAssertNil(KeyboardShortcut.defaultToggle.validationError)
        XCTAssertEqual(KeyboardShortcut.defaultToggle.display, "⌃⌥B")
        XCTAssertEqual(KeyboardShortcut.defaultToggle.keyCode, UInt32(kVK_ANSI_B))
        XCTAssertEqual(KeyboardShortcut(keyCode: 0, modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), label: "A").display, "⌃⌥⇧⌘A")
    }

    func testUnsafeOrReservedCombinationsAreRejected() {
        for modifiers in [UInt32(0), UInt32(shiftKey), UInt32(optionKey | 1)] {
            XCTAssertNotNil(KeyboardShortcut(keyCode: 0, modifiers: modifiers, label: "A").validationError)
        }
        for key in [54, 55, 58, 63, 128] {
            XCTAssertNotNil(KeyboardShortcut(keyCode: UInt32(key), modifiers: UInt32(optionKey), label: "A").validationError)
        }
        for key in [kVK_ANSI_B, kVK_ANSI_R] {
            XCTAssertNotNil(KeyboardShortcut(keyCode: UInt32(key), modifiers: UInt32(controlKey | optionKey | cmdKey), label: "R").validationError)
        }
    }

    func testPreferenceRoundTripAndInvalidFallback() throws {
        let name = "local.wink.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(KeyboardShortcut.load(from: defaults), .defaultToggle)
        let custom = KeyboardShortcut(keyCode: 40, modifiers: UInt32(controlKey | optionKey), label: "K")
        try custom.save(to: defaults)
        XCTAssertEqual(KeyboardShortcut.load(from: defaults), custom)
        let invalid = KeyboardShortcut(keyCode: 0, modifiers: 0, label: "A")
        XCTAssertThrowsError(try invalid.save(to: defaults))
        XCTAssertEqual(KeyboardShortcut.load(from: defaults), custom)
        defaults.set(Data("invalid".utf8), forKey: KeyboardShortcut.preferenceKey)
        XCTAssertEqual(KeyboardShortcut.load(from: defaults), .defaultToggle)
    }
}
