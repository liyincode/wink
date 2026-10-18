import AppKit
import Carbon
import ScreenCore

private final class SettingsContentView: NSView {
    override var isFlipped: Bool { true }
}

final class ShortcutSettings: NSViewController {
    private let recordButton = KeycapButton(title: "", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = NSButton()
    private let resetItem = NSMenuItem(title: L10n.text("Restore Default"), action: nil, keyEquivalent: "")
    private var keyMonitor: Any?
    private var recordingKeys: [String] = []
    private var stack: NSStackView!
    var sizeChanged: (() -> Void)?
    var contentHeight: CGFloat { stack.fittingSize.height }
    private let loginItem = LoginItemView()
    private(set) var isRecording = false
    var current: KeyboardShortcut
    var apply: ((KeyboardShortcut) -> String?)?
    var applySchedule: ((BlackoutSchedule) -> String?)?

    init(current: KeyboardShortcut, schedule: BlackoutSchedule) {
        self.current = current
        super.init(nibName: nil, bundle: nil)
        view = SettingsContentView(frame: NSRect(x: 0, y: 0, width: 272, height: 200))
        let scheduleView = ScheduleSettingsView(schedule: schedule)
        scheduleView.apply = { [weak self] value in self?.applySchedule?(value) }
        scheduleView.layoutChanged = { [weak self] _ in
            self?.notifySizeChanged()
        }
        let separator = NSBox()
        separator.boxType = .separator
        let label = NSTextField(labelWithString: L10n.text("Toggle Shortcut"))
        label.font = .systemFont(ofSize: 13, weight: .medium)
        recordButton.isBordered = false
        recordButton.font = .systemFont(ofSize: 12)
        recordButton.target = self
        recordButton.action = #selector(beginRecording)
        recordButton.setAccessibilityLabel(L10n.text("Record toggle shortcut"))
        let shortcutControl = NSView()
        shortcutControl.addSubview(recordButton)
        shortcutControl.addSubview(cancelButton)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.isBordered = false
        cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.text("Cancel recording"))
        cancelButton.imageScaling = .scaleProportionallyDown
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.toolTip = L10n.text("Cancel recording")
        cancelButton.setAccessibilityLabel(L10n.text("Cancel recording"))
        cancelButton.target = self
        cancelButton.action = #selector(cancelRecording)
        NSLayoutConstraint.activate([
            shortcutControl.widthAnchor.constraint(equalToConstant: 138),
            shortcutControl.heightAnchor.constraint(equalToConstant: 36),
            recordButton.leadingAnchor.constraint(equalTo: shortcutControl.leadingAnchor),
            recordButton.topAnchor.constraint(equalTo: shortcutControl.topAnchor),
            recordButton.widthAnchor.constraint(equalToConstant: 114),
            cancelButton.leadingAnchor.constraint(equalTo: recordButton.trailingAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: shortcutControl.trailingAnchor),
            cancelButton.centerYAnchor.constraint(equalTo: shortcutControl.centerYAnchor),
            cancelButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        let menu = NSMenu()
        menu.autoenablesItems = false
        resetItem.target = self
        resetItem.action = #selector(resetShortcut)
        menu.addItem(resetItem)
        recordButton.menu = menu
        recordButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, spacer, shortcutControl])
        row.orientation = .horizontal; row.spacing = 8
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let loginSeparator = NSBox()
        loginSeparator.boxType = .separator
        stack = NSStackView(views: [row, hint, separator, loginItem, loginSeparator, scheduleView])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scheduleView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            loginSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            loginItem.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        loginItem.sizeChanged = { [weak self] in self?.notifySizeChanged() }
        update(message: "")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    func prepare() { loginItem.refresh() }

    func deactivate() { stopRecording(); recordButton.clearFeedback(); update(message: "") }

    func update(message: String, error: Bool = false) {
        refreshKeys()
        cancelButton.isHidden = !isRecording
        resetItem.isEnabled = current != .defaultToggle
        hint.isHidden = message.isEmpty
        hint.stringValue = message
        hint.textColor = error ? .systemRed : .secondaryLabelColor
        notifySizeChanged()
    }

    private func notifySizeChanged() {
        view.layoutSubtreeIfNeeded()
        sizeChanged?()
    }

    private func shortcutKeys() -> [String] {
        var keys = modifierKeys(current.modifiers)
        keys.append(current.label)
        return keys
    }

    private func modifierKeys(_ modifiers: UInt32) -> [String] {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1)
    }

    private func refreshKeys() {
        recordButton.isRecording = isRecording
        recordButton.keys = isRecording ? recordingKeys : shortcutKeys()
        recordButton.title = isRecording ? L10n.text("Press shortcut…") : current.display
        recordButton.setAccessibilityValue(recordButton.keys.isEmpty ? recordButton.title : recordButton.keys.joined(separator: " "))
        recordButton.needsDisplay = true
    }

    @objc private func beginRecording() {
        stopRecording()
        isRecording = true
        update(message: "")
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
                self.handleRecordingClick(event)
                return event
            }
            guard event.window === self.view.window else { return event }
            return self.handleRecordingEvent(event) ? nil : event
        }
    }

    func handleRecordingClick(_ event: NSEvent) {
        guard isRecording else { return }
        let inside = event.window === view.window && recordButton.bounds.contains(recordButton.convert(event.locationInWindow, from: nil))
        if !inside || event.type == .rightMouseDown { deactivate() }
    }

    @objc private func cancelRecording() { deactivate() }

    @discardableResult
    func handleRecordingEvent(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        if event.type == .keyDown && event.keyCode == UInt16(kVK_Escape) {
            deactivate()
            return true
        }
        if event.type == .keyDown && event.isARepeat { return true }
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let nextModifiers = modifierKeys(modifiers)
        let addedModifier = nextModifiers.contains { !recordingKeys.contains($0) }
        recordingKeys = nextModifiers
        if event.type != .keyDown {
            if event.type == .flagsChanged && addedModifier && !hint.isHidden {
                update(message: "")
            } else {
                refreshKeys()
            }
            return true
        }
        let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3",
            118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let label = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        recordingKeys.append(label)
        refreshKeys()
        self.select(KeyboardShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label))
        return true
    }

    func select(_ shortcut: KeyboardShortcut) {
        if let error = shortcut.validationError {
            let missingModifier = shortcut.modifiers & UInt32(controlKey | optionKey | cmdKey) == 0
            update(message: error, error: !missingModifier)
            return
        }
        if let error = apply?(shortcut) {
            update(message: error, error: true)
            return
        }
        current = shortcut
        recordButton.confirmRecording()
        stopRecording()
        update(message: "")
    }

    func reservedShortcutPressed() { update(message: L10n.text("This is a backup shortcut. Choose another combination."), error: true) }

    @objc private func resetShortcut() { select(.defaultToggle) }
    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil; isRecording = false
        recordingKeys = []
    }
}
