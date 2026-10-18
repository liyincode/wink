import AppKit
import ServiceManagement
import ScreenCore

final class LoginItemView: NSStackView {
    private let control = NSSwitch()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let approval = NSButton(title: L10n.text("Open Login Items…"), target: nil, action: nil)
    var sizeChanged: (() -> Void)?
    private var observer: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        let label = NSTextField(labelWithString: L10n.text("Launch at Login"))
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, spacer, control])
        row.orientation = .horizontal
        control.target = self; control.action = #selector(change)
        control.setAccessibilityLabel(L10n.text("Launch at Login"))
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        approval.bezelStyle = .rounded
        approval.target = self; approval.action = #selector(openApproval)
        for view in [row, hint, approval] { addArrangedSubview(view) }
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        hint.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func refresh(error: String? = nil) {
        let status = SMAppService.mainApp.status
        control.state = status == .enabled || status == .requiresApproval ? .on : .off
        approval.isHidden = status != .requiresApproval
        let message = error ?? (status == .requiresApproval
            ? L10n.text("Allow Wink in System Settings to launch at login.")
            : "")
        hint.stringValue = message; hint.isHidden = message.isEmpty
        hint.textColor = error == nil ? .secondaryLabelColor : .systemRed
        sizeChanged?()
    }

    @objc private func change() {
        do {
            if control.state == .on {
                if SMAppService.mainApp.status == .requiresApproval { openApproval() }
                else { try SMAppService.mainApp.register() }
            } else { try SMAppService.mainApp.unregister() }
            refresh()
        } catch { refresh(error: L10n.text("Unable to change login startup: %@", error.localizedDescription)) }
    }

    @objc private func openApproval() { SMAppService.openSystemSettingsLoginItems() }
}
