import AppKit
import ScreenCore

enum AppInfo {
    static var aboutOptions: [NSApplication.AboutPanelOptionKey: Any] {
        [ .applicationName: "Wink", .applicationIcon: Mascot.wink ?? NSImage(),
          .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0",
          .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2",
          .credits: NSAttributedString(string: L10n.text("Darken your screens while tasks keep running."),
                                      attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12)]) ]
    }
}
