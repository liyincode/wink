import Foundation
import XCTest
@testable import ScreenCore

final class LocalizationTests: XCTestCase {
    func testLanguageSelection() {
        XCTAssertEqual(L10n.language(for: ["zh-Hans"]), "zh-Hans")
        XCTAssertEqual(L10n.language(for: ["zh-CN"]), "zh-Hans")
        XCTAssertEqual(L10n.language(for: ["en-GB"]), "en")
        XCTAssertEqual(L10n.language(for: ["fr"]), "en")
        XCTAssertEqual(L10n.language(for: []), "en")
    }
    func testLanguagesHaveMatchingKeysAndFormatArguments() throws {
        func strings(_ language: String) throws -> [String: String] {
            let path = try XCTUnwrap(Bundle.module.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try strings("en"), chinese = try strings("zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        XCTAssertEqual(chinese["Black Out"], "黑屏")
        XCTAssertEqual(chinese["Restore Display"], "恢复显示")
        for key in english.keys {
            XCTAssertFalse(chinese[key]!.isEmpty, key)
            XCTAssertEqual(english[key]!.components(separatedBy: "%@").count,
                           chinese[key]!.components(separatedBy: "%@").count, key)
        }
    }

    func testLocalizedFormattingAndUnknownKeyFallback() {
        XCTAssertEqual(L10n.text("Missing translation %@", "value"), "Missing translation value")
        let value = L10n.text("Unable to read display Gamma for %@ (error %@).", "DISPLAY", "42")
        XCTAssertTrue(value.contains("DISPLAY") && value.contains("42"))
        XCTAssertFalse(value.contains("%@"))
    }
}
