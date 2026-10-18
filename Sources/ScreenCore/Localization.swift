import Foundation

public enum L10n {
    private static let resources: Bundle = {
        if let url = Bundle.main.url(forResource: "Wink_ScreenCore", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    static func language(for preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: preferences).first ?? "en"
    }

    private static let localized: Bundle = {
        let selectedLanguage = language(for: Locale.preferredLanguages)
        let directory = resources.localizations.first { $0.caseInsensitiveCompare(selectedLanguage) == .orderedSame } ?? "en"
        guard let path = resources.path(forResource: directory, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return resources }
        return bundle
    }()

    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = localized.localizedString(forKey: key, value: key, table: nil)
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
