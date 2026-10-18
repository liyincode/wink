import AppKit
import ScreenCore

final class ScheduleSettingsView: NSStackView {
    private var schedule: BlackoutSchedule
    var apply: ((BlackoutSchedule) -> String?)?
    var layoutChanged: ((Bool) -> Void)?
    private let enabledSwitch = NSSwitch()
    private let startPicker = WheelTimePicker()
    private let endPicker = WheelTimePicker()
    private let nextDay = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private var details: [NSView] = []
    private var dayButtons: [NSButton] = []
    private var revealTimer: Timer?
    private var detailsVisible = false

    init(schedule: BlackoutSchedule) {
        self.schedule = schedule
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 18
        let title = NSTextField(labelWithString: L10n.text("Scheduled Blackout"))
        title.font = .systemFont(ofSize: 13, weight: .medium)
        enabledSwitch.target = self; enabledSwitch.action = #selector(changed)
        enabledSwitch.setAccessibilityLabel(L10n.text("Enable scheduled blackout"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = row([title, spacer, enabledSwitch])
        addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let times = row([])
        times.distribution = .fillEqually
        for (label, picker) in [(L10n.text("Start"), startPicker), (L10n.text("End"), endPicker)] {
            picker.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
            picker.isBordered = false
            picker.target = self; picker.action = #selector(changed)
            picker.setAccessibilityLabel(label)
            let caption = NSTextField(labelWithString: label)
            caption.font = .systemFont(ofSize: 11, weight: .medium)
            caption.textColor = .secondaryLabelColor
            let captions = row(picker === endPicker ? [caption, nextDay] : [caption])
            let column = NSStackView(views: [captions, picker])
            column.orientation = .vertical; column.alignment = .leading; column.spacing = 6
            let surface = TimeSurface()
            column.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(column)
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
                column.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -8),
                column.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
                surface.heightAnchor.constraint(equalToConstant: 76)
            ])
            times.addArrangedSubview(surface)
        }
        addArrangedSubview(times)
        times.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        nextDay.font = .systemFont(ofSize: 10, weight: .medium)
        nextDay.textColor = .secondaryLabelColor
        let calendar = Calendar.autoupdatingCurrent
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        let names = formatter.veryShortStandaloneWeekdaySymbols!
        for offset in 0..<7 {
            let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
            let button = DayButton(title: names[weekday - 1], target: self, action: #selector(changed))
            button.tag = weekday
            button.setButtonType(.pushOnPushOff)
            button.isBordered = false
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            button.setAccessibilityLabel(formatter.standaloneWeekdaySymbols[weekday - 1])
            dayButtons.append(button)
        }
        let days = row(dayButtons)
        days.distribution = .fillEqually; days.spacing = 4
        addArrangedSubview(days)
        days.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        details = [times, days]
        message.font = .systemFont(ofSize: 12)
        addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { revealTimer?.invalidate() }

    private func revealDetails(animated: Bool) {
        guard detailsVisible != schedule.enabled else { return }
        detailsVisible = schedule.enabled
        revealTimer?.invalidate(); revealTimer = nil
        let opening = schedule.enabled
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            for detail in details { detail.isHidden = !opening; detail.alphaValue = opening ? 1 : 0 }
            return
        }
        let from = details.first.map { $0.isHidden ? 0 : $0.alphaValue } ?? 0
        if opening { for detail in details { detail.isHidden = false; detail.alphaValue = from } }
        let started = ProcessInfo.processInfo.systemUptime
        let duration = opening ? 0.28 : 0.12
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let fraction = min(1, elapsed / duration)
            let reveal = opening ? max(0, (fraction - 0.2) / 0.8) : fraction
            let eased = reveal * reveal * (3 - 2 * reveal)
            for detail in self.details { detail.alphaValue = from + ((opening ? 1 : 0) - from) * eased }
            if fraction >= 1 {
                self.revealTimer?.invalidate(); self.revealTimer = nil
                if !opening {
                    for detail in self.details { detail.isHidden = true }
                    self.layoutChanged?(false)
                }
            }
        }
        revealTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .horizontal; result.spacing = 12; result.alignment = .centerY
        return result
    }

    private func refresh(error: String? = nil, animated: Bool = false) {
        enabledSwitch.state = schedule.enabled ? .on : .off
        if !animated && !schedule.enabled { for detail in details { detail.isHidden = true; detail.alphaValue = 0 } }
        revealDetails(animated: animated)
        let calendar = Calendar.autoupdatingCurrent
        for (picker, minute) in [(startPicker, schedule.startMinute), (endPicker, schedule.endMinute)] {
            picker.dateValue = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date())!
            picker.isEnabled = schedule.enabled
        }
        for button in dayButtons {
            button.state = schedule.weekdays.contains(button.tag) ? .on : .off
            button.isEnabled = schedule.enabled
            button.needsDisplay = true
        }
        nextDay.stringValue = schedule.endMinute < schedule.startMinute ? L10n.text("Next day") : ""
        message.textColor = error == nil ? .secondaryLabelColor : .systemRed
        message.stringValue = error ?? ""
        message.isHidden = error == nil
        layoutChanged?(error != nil)
    }

    @objc private func changed() {
        var value = schedule
        value.enabled = enabledSwitch.state == .on
        let calendar = Calendar.autoupdatingCurrent
        value.startMinute = calendar.component(.hour, from: startPicker.dateValue) * 60 + calendar.component(.minute, from: startPicker.dateValue)
        value.endMinute = calendar.component(.hour, from: endPicker.dateValue) * 60 + calendar.component(.minute, from: endPicker.dateValue)
        value.weekdays = Set(dayButtons.filter { $0.state == .on }.map(\.tag))
        save(value)
    }

    private func save(_ value: BlackoutSchedule) {
        if let error = value.validationError ?? apply?(value) { refresh(error: error, animated: true); return }
        schedule = value
        refresh(animated: true)
    }
}
