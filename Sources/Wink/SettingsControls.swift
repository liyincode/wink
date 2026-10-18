import AppKit

final class TimeSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
}

final class DayButton: NSButton {
    private var selection: CGFloat = 0
    private var selectionTarget: CGFloat = 0
    private var selectionTimer: Timer?
    override var state: NSControl.StateValue {
        didSet {
            let target: CGFloat = state == .on ? 1 : 0
            guard target != selectionTarget else { return }
            selectionTarget = target
            selectionTimer?.invalidate(); selectionTimer = nil
            guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                selection = target; needsDisplay = true; return
            }
            let from = selection
            let started = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.14)
                let eased = progress * progress * (3 - 2 * progress)
                self.selection = from + (target - from) * eased
                self.needsDisplay = true
                if progress >= 1 { self.selectionTimer?.invalidate(); self.selectionTimer = nil }
            }
            selectionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    deinit { selectionTimer?.invalidate() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if isHighlighted && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let transform = NSAffineTransform()
            transform.translateX(by: bounds.midX, yBy: bounds.midY)
            transform.scale(by: 0.96)
            transform.translateX(by: -bounds.midX, yBy: -bounds.midY)
            transform.concat()
        }
        let color = NSColor.quaternaryLabelColor.blended(withFraction: selection, of: .controlAccentColor) ?? .controlAccentColor
        color.withAlphaComponent(isEnabled ? 0.07 + 0.07 * selection : 0.05).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        let foreground: NSColor = !isEnabled ? .tertiaryLabelColor : (selected ? .controlAccentColor : .secondaryLabelColor)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .regular), .foregroundColor: foreground]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
    }
}

final class KeycapButton: NSButton {
    private struct KeyVisual {
        var slot: Int
        var entered: TimeInterval
        var removed: TimeInterval?
    }
    private var visuals: [String: KeyVisual] = [:]
    private var animationTimer: Timer?
    private var confirmedAt: TimeInterval?
    var keys: [String] = [] {
        didSet { updateVisuals() }
    }
    var isRecording = false {
        didSet {
            if isRecording && !oldValue { clearFeedback() }
        }
    }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    deinit { animationTimer?.invalidate() }

    func clearFeedback() {
        animationTimer?.invalidate()
        animationTimer = nil
        visuals.removeAll()
        confirmedAt = nil
        needsDisplay = true
    }

    func confirmRecording() {
        confirmedAt = ProcessInfo.processInfo.systemUptime
        startAnimation()
    }

    private func updateVisuals() {
        let now = ProcessInfo.processInfo.systemUptime
        for key in Array(visuals.keys) where !keys.contains(key) {
            if isRecording && !reduceMotion {
                if visuals[key]?.removed == nil { visuals[key]?.removed = now }
            } else { visuals.removeValue(forKey: key) }
        }
        for key in keys {
            if var visual = visuals[key] {
                if visual.removed != nil { visual.entered = now; visual.removed = nil }
                visuals[key] = visual
            } else {
                let occupied = Set(visuals.values.map(\.slot))
                // Reuse a fading slot if all five positions are occupied.
                let slot = (0..<5).first { !occupied.contains($0) }
                    ?? visuals.values.filter { $0.removed != nil }.map(\.slot).min() ?? 4
                for old in Array(visuals.keys) where visuals[old]?.slot == slot { visuals.removeValue(forKey: old) }
                visuals[key] = KeyVisual(slot: slot, entered: isRecording ? now : now - 1)
            }
        }
        if isRecording { startAnimation() }
        needsDisplay = true
    }

    private func startAnimation() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            for key in Array(self.visuals.keys) {
                if let removed = self.visuals[key]?.removed, now - removed >= 0.08 {
                    self.visuals.removeValue(forKey: key)
                }
            }
            self.needsDisplay = true
            let active = self.visuals.values.contains { $0.removed != nil || now - $0.entered < 0.1 }
            if !active && now - (self.confirmedAt ?? 0) >= 0.24 {
                self.confirmedAt = nil
                self.animationTimer?.invalidate()
                self.animationTimer = nil
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
    override func draw(_ dirtyRect: NSRect) {
        let now = ProcessInfo.processInfo.systemUptime
        let flash = confirmedAt.map { max(0, 1 - (now - $0) / 0.24) } ?? 0
        if keys.isEmpty && visuals.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
            let text = title as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: 4, y: (bounds.height - size.height) / 2), withAttributes: attributes)
            return
        }
        for (key, visual) in visuals {
            let progress = min(1, max(0, (now - visual.entered) / 0.1))
            let opacity = reduceMotion ? 1 : visual.removed.map { max(0, 1 - (now - $0) / 0.08) } ?? progress
            let scale = reduceMotion ? 1 : 0.94 + 0.06 * (1 - pow(1 - progress, 3))
            let pitch = (bounds.width - 8) / 5
            let rect = NSRect(x: 4 + CGFloat(visual.slot) * pitch, y: (bounds.height - 26) / 2, width: pitch - 2, height: 26)
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.scale(by: scale)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
            NSColor.quaternaryLabelColor.withAlphaComponent((isHighlighted ? 0.2 : 0.1) * opacity).setFill()
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            path.fill()
            if flash > 0 {
                NSColor.systemOrange.withAlphaComponent(0.16 * flash * opacity).setFill()
                path.fill()
            }
            if reduceMotion && progress < 1 {
                NSColor.systemOrange.withAlphaComponent(0.14 * (1 - progress)).setFill()
                path.fill()
            }
            let border = isRecording ? NSColor.systemOrange.withAlphaComponent(0.55) : NSColor.separatorColor
            border.withAlphaComponent(border.alphaComponent * opacity).setStroke()
            path.lineWidth = isRecording ? 0.75 : 0.5
            path.stroke()
            let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            let width = (key as NSString).size(withAttributes: [.font: baseFont]).width
            let font = NSFont.monospacedSystemFont(ofSize: 12 * min(1, (rect.width - 3) / max(1, width)), weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(opacity)]
            let size = (key as NSString).size(withAttributes: attributes)
            (key as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
