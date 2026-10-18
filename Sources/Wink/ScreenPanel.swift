import AppKit
import ScreenCore

private final class SettingsButton: NSButton {
    var expanded = false { didSet { needsDisplay = true } }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func draw(_ dirtyRect: NSRect) {
        if expanded {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        }
        super.draw(dirtyRect)
        if window?.firstResponder === self {
            NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
            let outline = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 1
            outline.stroke()
        }
    }
}

private final class SettingsScrollView: NSScrollView {
    var acceptsInput = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsInput ? super.hitTest(point) : (bounds.contains(convert(point, from: superview)) ? self : nil)
    }
}

final class ScreenPanel: NSWindowController, NSWindowDelegate {
    var toggle: (() -> Void)?
    var openSettings: (() -> Void)?
    private let action = MascotButton()
    private let summary = NSTextField(labelWithString: "")
    private let gear = SettingsButton()
    private let scroll = SettingsScrollView()
    private var settings: ShortcutSettings?
    private(set) var settingsExpanded = false
    private var scheduleEnabled = false
    private var progress: CGFloat = 0
    private var timer: Timer?
    private var started: TimeInterval = 0
    private var fromProgress: CGFloat = 0
    private var fromHeight: CGFloat = 270
    private var targetHeight: CGFloat = 270
    private var anchorTop: CGFloat = 0

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 270),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Wink"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(name: "WinkPanelBackground") { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.13, green: 0.125, blue: 0.12, alpha: 1)
                : NSColor(srgbRed: 0.99, green: 0.98, blue: 0.965, alpha: 1)
        }
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        super.init(window: window)
        window.delegate = self
        gear.target = self; gear.action = #selector(settingsPressed)
        gear.isBordered = false; gear.contentTintColor = .secondaryLabelColor
        gear.imageScaling = .scaleNone
        gear.focusRingType = .none
        action.target = self; action.action = #selector(togglePressed)
        summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabelColor
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        for view in [action, summary, scroll, gear] { window.contentView!.addSubview(view) }
        updateGear()
        layoutContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate() }

    func update(isBlack: Bool, recovery: String, schedule: BlackoutSchedule) {
        action.update(isBlack: isBlack); action.shortcut = recovery
        scheduleEnabled = schedule.enabled
        summary.stringValue = L10n.text("Scheduled blackout is on")
        layoutContent()
    }

    func showSettings(_ settings: ShortcutSettings) {
        if self.settings !== settings {
            self.settings = settings
            scroll.documentView = settings.view
            settings.sizeChanged = { [weak self] in
                guard let self, self.settingsExpanded else { return }
                self.transition(animated: true)
            }
        }
        settings.prepare()
        setSettingsExpanded(true)
    }

    func setSettingsExpanded(_ expanded: Bool, animated: Bool = true) {
        guard expanded != settingsExpanded || !animated else { return }
        settingsExpanded = expanded
        if !expanded { settings?.deactivate() }
        window?.makeFirstResponder(NSApp.currentEvent?.type == .keyDown ? gear : nil)
        updateGear()
        transition(animated: animated)
    }

    private func updateGear() {
        let title = L10n.text(settingsExpanded ? "Collapse Settings" : "Open Settings")
        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: title)
        gear.expanded = settingsExpanded
        gear.toolTip = title; gear.setAccessibilityLabel(title)
    }

    private func transition(animated: Bool) {
        guard let window else { return }
        timer?.invalidate(); timer = nil
        fromProgress = progress
        fromHeight = window.contentView!.bounds.height
        let desired = settingsExpanded ? max(290, 130 + (settings?.contentHeight ?? 0) + 24) : 270
        let chrome = window.frame.height - fromHeight
        let visible = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        targetHeight = min(desired, max(270, visible.height - chrome - 16))
        if abs(targetHeight - fromHeight) < 0.5 && progress == (settingsExpanded ? 1 : 0) {
            action.isEnabled = true
            action.setAccessibilityElement(true)
            scroll.acceptsInput = settingsExpanded
            layoutContent()
            return
        }
        anchorTop = min(window.frame.maxY, visible.maxY)
        anchorTop = max(anchorTop, visible.minY + targetHeight + chrome)
        started = ProcessInfo.processInfo.systemUptime
        action.isEnabled = false; scroll.acceptsInput = false
        action.setAccessibilityElement(false)
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            advance(fraction: 1)
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.advance(fraction: min(1, (ProcessInfo.processInfo.systemUptime - self.started) / 0.28))
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func advance(fraction: Double) {
        guard let window else { return }
        let eased = CGFloat(fraction * fraction * (3 - 2 * fraction))
        progress = fromProgress + ((settingsExpanded ? 1 : 0) - fromProgress) * eased
        let height = fromHeight + (targetHeight - fromHeight) * eased
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 320, height: height))
        frame.origin = NSPoint(x: window.frame.minX, y: anchorTop - frame.height)
        window.setFrame(frame, display: true)
        if fraction >= 1 {
            timer?.invalidate(); timer = nil
            action.isEnabled = true
            action.setAccessibilityElement(true)
            scroll.acceptsInput = settingsExpanded
        }
        layoutContent()
    }

    private func layoutContent() {
        guard let content = window?.contentView else { return }
        let height = content.bounds.height
        action.frame = NSRect(x: 24, y: height - 248, width: 272, height: 210)
        action.setSettingsProgress(progress)
        gear.frame = NSRect(x: 280, y: height - 33, width: 28, height: 28)
        summary.sizeToFit()
        summary.setFrameOrigin(NSPoint(x: (320 - summary.frame.width) / 2, y: height - 264))
        summary.isHidden = !scheduleEnabled || progress >= 0.25
        summary.alphaValue = max(0, 1 - progress / 0.25)
        scroll.frame = NSRect(x: 24, y: 24, width: 272, height: max(1, height - 154))
        scroll.alphaValue = max(0, min(1, (progress - 0.2) / 0.8))
        scroll.isHidden = progress == 0 && !settingsExpanded
        if let settings {
            settings.view.frame = NSRect(x: 0, y: 0, width: 272, height: settings.contentHeight)
            settings.view.layoutSubtreeIfNeeded()
        }
    }

    func setEyeClosure(_ progress: Double) { action.setEyeClosure(progress) }
    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { setSettingsExpanded(false, animated: false) }
    func windowDidResignKey(_ notification: Notification) {
        if settings?.isRecording == true { settings?.deactivate() }
    }
    @objc private func togglePressed() {
        guard timer == nil else { return }
        if settings?.isRecording == true { settings?.deactivate() }
        toggle?()
    }
    @objc private func settingsPressed() {
        if settingsExpanded { setSettingsExpanded(false) } else { openSettings?() }
    }
}
