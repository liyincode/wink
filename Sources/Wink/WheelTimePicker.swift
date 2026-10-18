import AppKit
import ScreenCore

/// Compact time button with a transient, keyboard-accessible wheel editor.
final class WheelTimePicker: NSButton, NSPopoverDelegate {
    var dateValue = Date() { didSet { refresh() } }
    private let timeFormatter = DateFormatter()
    private var popover: NSPopover?
    private var wheels: [TimeWheel] = []
    private var usesPeriod: Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: timeFormatter.locale) ?? "HH"
        return format.contains("a") || format.contains("b") || format.contains("B")
    }

    init(locale: Locale = .autoupdatingCurrent) {
        super.init(frame: .zero)
        timeFormatter.locale = locale
        timeFormatter.timeStyle = .short
        isBordered = false
        font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        setContentHuggingPriority(.required, for: .horizontal)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Preserve the owner's target/action for committed changes, not opening the editor.
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        guard isEnabled else { return false }
        if let popover, popover.isShown { popover.close(); return true }
        showEditor()
        return true
    }

    private func refresh() {
        title = timeFormatter.string(from: dateValue)
        setAccessibilityValue(title)
        guard !wheels.isEmpty else { return }
        let hour = Calendar.autoupdatingCurrent.component(.hour, from: dateValue)
        wheels[0].select(usesPeriod ? hour % 12 : hour)
        wheels[1].select(Calendar.autoupdatingCurrent.component(.minute, from: dateValue))
        if usesPeriod { wheels[2].select(hour / 12) }
    }

    private func showEditor() {
        let hourNames = usesPeriod ? (["12"] + (1...11).map { String($0) }) : (0...23).map { String(format: "%02d", $0) }
        wheels = [TimeWheel(values: hourNames), TimeWheel(values: (0...59).map { String(format: "%02d", $0) })]
        if usesPeriod { wheels.append(TimeWheel(values: [timeFormatter.amSymbol, timeFormatter.pmSymbol])) }
        let labels = ["Hour", "Minute", "AM/PM"]
        let stack = NSStackView(views: wheels)
        stack.orientation = .horizontal; stack.spacing = 6
        for (index, wheel) in wheels.enumerated() {
            wheel.setAccessibilityLabel(L10n.text(labels[index]))
            wheel.changed = { [weak self] in self?.commit() }
            wheel.close = { [weak self] in self?.popover?.close() }
        }
        refresh()
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: wheels.count * 64 + 26, height: 176))
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)
        ])
        let editor = NSPopover()
        editor.behavior = .transient
        editor.delegate = self
        editor.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        editor.contentViewController = controller
        popover = editor
        editor.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        editor.contentViewController?.view.window?.makeFirstResponder(wheels[0])
    }

    func popoverWillClose(_ notification: Notification) {
        for wheel in wheels { wheel.finishScrolling() }
    }

    private func commit() {
        let hour = wheels[0].selected + (usesPeriod ? wheels[2].selected * 12 : 0)
        guard let value = Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: wheels[1].selected, second: 0, of: dateValue) else { return }
        dateValue = value
        _ = super.sendAction(action, to: target)
    }
}

/// Continuous scrolling while moving; one snapped value after the gesture settles.
final class TimeWheel: NSView {
    let values: [String]
    private(set) var selected = 0
    var changed: (() -> Void)?
    var close: (() -> Void)?
    private var position: CGFloat = 0
    private var settleTimer: Timer?
    private var snapTimer: Timer?
    private var snapTarget: Int?
    private var digits = ""
    private var lastDigitTime: TimeInterval = 0
    private let rowHeight: CGFloat = 30
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(values: [String]) {
        self.values = values
        super.init(frame: .zero)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 64), heightAnchor.constraint(equalToConstant: 150)])
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { settleTimer?.invalidate(); snapTimer?.invalidate() }

    func select(_ index: Int) {
        settleTimer?.invalidate(); settleTimer = nil
        stopSnap()
        selected = min(max(index, 0), values.count - 1)
        position = CGFloat(selected)
        setAccessibilityValue(values[selected])
        needsDisplay = true
    }

    private func choose(_ index: Int) {
        let previous = selected
        select(index)
        if previous != selected { changed?() }
    }

    private func stopSnap() {
        snapTimer?.invalidate(); snapTimer = nil
        snapTarget = nil
    }

    private func snap(to index: Int) {
        settleTimer?.invalidate(); settleTimer = nil
        stopSnap()
        let target = min(max(index, 0), values.count - 1)
        let from = position
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(from - CGFloat(target)) > 0.001 else { choose(target); return }
        snapTarget = target
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let fraction = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.12)
            let eased = 1 - pow(1 - fraction, 3)
            self.position = from + (CGFloat(target) - from) * eased
            self.needsDisplay = true
            if fraction >= 1 { self.choose(target) }
        }
        snapTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSRect(x: 2, y: 60, width: bounds.width - 4, height: rowHeight)
        NSColor.labelColor.withAlphaComponent(0.055).setFill()
        NSBezierPath(roundedRect: center, xRadius: 8, yRadius: 8).fill()
        let low = max(0, Int(floor(position)) - 3)
        let high = min(values.count - 1, Int(ceil(position)) + 3)
        for index in low...high {
            let distance = CGFloat(index) - position
            let opacity = max(0, 1 - abs(distance) * 0.32)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 19, weight: NSFont.Weight(rawValue: NSFont.Weight.medium.rawValue * max(0, 1 - abs(distance)))),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(opacity)
            ]
            let text = values[index] as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: 75 + distance * rowHeight - size.height / 2), withAttributes: attributes)
        }
        if window?.firstResponder === self {
            NSColor.secondaryLabelColor.withAlphaComponent(0.3).setStroke()
            let ring = NSBezierPath(roundedRect: center.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            ring.lineWidth = 1; ring.stroke()
        }
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        snap(to: Int((position + (point.y - 75) / rowHeight).rounded()))
    }

    override func scrollWheel(with event: NSEvent) {
        window?.makeFirstResponder(self)
        stopSnap()
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 / rowHeight : 1)
        position = min(CGFloat(values.count - 1), max(0, position - delta))
        needsDisplay = true
        settleTimer?.invalidate()
        let timer = Timer(timeInterval: 0.16, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.snap(to: Int(self.position.rounded()))
        }
        settleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: choose(selected - 1)
        case 125: choose(selected + 1)
        case 115: choose(0)
        case 119: choose(values.count - 1)
        case 48: if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
        case 36, 76, 53: cancelOperation(self)
        default:
            guard let text = event.charactersIgnoringModifiers, !text.isEmpty else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastDigitTime > 0.8 { digits = "" }
            lastDigitTime = now
            if text.allSatisfy(\.isNumber) {
                digits += text
                if !values.contains(where: { Int($0) == Int(digits) }) { digits = text }
                if let index = values.firstIndex(where: { Int($0) == Int(digits) }) { choose(index) }
            } else if let index = values.firstIndex(where: { $0.lowercased().hasPrefix(text.lowercased()) }) { choose(index) }
        }
    }
    func finishScrolling() { choose(snapTarget ?? Int(position.rounded())) }
    override func cancelOperation(_ sender: Any?) { close?() }
    override func accessibilityPerformIncrement() -> Bool { choose(selected + 1); return true }
    override func accessibilityPerformDecrement() -> Bool { choose(selected - 1); return true }
}
