import ScreenCore
import AppKit
import QuartzCore

private final class MascotButtonCell: NSButtonCell {
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        super.highlight(flag, withFrame: cellFrame, in: controlView)
        (controlView as? MascotButton)?.updateScale(pressed: flag)
    }
}

final class MascotButton: NSButton {
    var shortcut = "" { didSet { needsDisplay = true } }
    private let portrait = CALayer()
    private let bodyImage = Mascot.body?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    private lazy var hitBitmap = bodyImage.map { NSBitmapImageRep(cgImage: $0) }
    private var bodyRenders: [Int: CGImage] = [:]
    private var bodyPixelSize = 0
    private var tracking: NSTrackingArea?
    private weak var trackingHost: NSView?
    private var hovering = false
    private var petting = false
    private var gaze = CGPoint.zero
    private var eyeClosure: Double = 0
    private var pressing = false
    private var settingsProgress: CGFloat = 0
    private var feedbackScale: CGFloat = 1
    private let eyes = [CAShapeLayer(), CAShapeLayer()]
    private var textTimer: Timer?
    private var textBlend: CGFloat = 0
    private var textFrom: CGFloat = 0
    private var textTarget: CGFloat = 0
    private var textStarted: TimeInterval = 0

    init() {
        super.init(frame: .zero)
        cell = MascotButtonCell(textCell: "")
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .exterior
        wantsLayer = true
        portrait.contentsGravity = .resizeAspect
        portrait.minificationFilter = .trilinear
        portrait.magnificationFilter = .linear
        portrait.allowsEdgeAntialiasing = true
        layer?.addSublayer(portrait)
        portrait.contents = bodyImage
        for eye in eyes {
            eye.fillColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
            eye.shadowColor = NSColor.black.cgColor
            eye.shadowOpacity = 0.12
            eye.shadowRadius = 0.7
            eye.shadowOffset = CGSize(width: 0, height: -0.5)
            portrait.addSublayer(eye)
        }
        setEyeClosure(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        textTimer?.invalidate()
        if let tracking { trackingHost?.removeTrackingArea(tracking) }
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { isEnabled }

    private var portraitBounds: NSRect {
        let side = 200 * (1 - 0.65 * settingsProgress)
        return NSRect(x: bounds.midX - side / 2, y: 115 + 65 * settingsProgress - side / 2, width: side, height: side)
    }

    private static let labelFont = NSFont.systemFont(ofSize: 18, weight: .medium)
    private static let shortcutFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private var textLayout: (labels: [NSString], sizes: [NSSize], label: NSSize, key: NSSize, gap: CGFloat, scale: CGFloat, origin: NSPoint) {
        let labels = [L10n.text("Black Out") as NSString, L10n.text("Restore Display") as NSString]
        let sizes = labels.map { $0.size(withAttributes: [.font: Self.labelFont]) }
        let label = NSSize(width: sizes.map(\.width).max()!, height: sizes.map(\.height).max()!)
        let key = (shortcut as NSString).size(withAttributes: [.font: Self.shortcutFont])
        let gap: CGFloat = shortcut.isEmpty ? 0 : 12
        let width = label.width + gap + key.width
        let scale = min(1, (bounds.width - 16) / max(1, width))
        return (labels, sizes, label, key, gap, scale, NSPoint(x: (bounds.width - width * scale) / 2, y: 13))
    }

    private var textBounds: NSRect {
        let layout = textLayout
        let size = (title as NSString).size(withAttributes: [.font: Self.labelFont])
        return NSRect(x: layout.origin.x + (layout.label.width - size.width) * layout.scale / 2,
                      y: layout.origin.y, width: size.width * layout.scale, height: size.height * layout.scale)
    }

    private func containsAction(_ point: NSPoint) -> Bool {
        guard isEnabled, bounds.contains(point) else { return false }
        if settingsProgress == 0 && textBounds.contains(point) { return true }
        let rect = portraitBounds
        guard rect.contains(point), let bitmap = hitBitmap else { return false }
        let x = min(bitmap.pixelsWide - 1, Int((point.x - rect.minX) / rect.width * CGFloat(bitmap.pixelsWide)))
        let y = min(bitmap.pixelsHigh - 1, Int((1 - (point.y - rect.minY) / rect.height) * CGFloat(bitmap.pixelsHigh)))
        return (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsAction(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard containsAction(convert(event.locationInWindow, from: nil)), let window else { return }
        highlight(true)
        defer { highlight(false) }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = containsAction(convert(next.locationInWindow, from: nil))
            highlight(inside)
            if next.type == .leftMouseUp {
                if inside { sendAction(action, to: target) }
                return
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layout()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Keep layout independent of the hover/press transform.
        portrait.bounds = NSRect(x: 0, y: 0, width: 200, height: 200)
        portrait.position = NSPoint(x: bounds.midX, y: 115 + 65 * settingsProgress)
        let scale = (1 - 0.65 * settingsProgress) * feedbackScale
        portrait.transform = bodyTransform(scale: scale)
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        portrait.contentsScale = backingScale
        updateBodyImage(pixelSize: Int(((settingsProgress == 1 ? 70 : 200) * backingScale).rounded()))
        for eye in eyes { eye.contentsScale = backingScale; eye.allowsEdgeAntialiasing = true }
        CATransaction.commit()
    }

    private func updateBodyImage(pixelSize: Int) {
        guard pixelSize > 0, pixelSize != bodyPixelSize, let bodyImage else { return }
        if bodyRenders[pixelSize] == nil {
            guard let context = CGContext(data: nil, width: pixelSize, height: pixelSize,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: bodyImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(bodyImage, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
            guard let image = context.makeImage() else { return }
            bodyRenders[pixelSize] = image
        }
        portrait.contents = bodyRenders[pixelSize]
        bodyPixelSize = pixelSize
    }

    func setSettingsProgress(_ progress: CGFloat) {
        let next = min(1, max(0, progress))
        guard next != settingsProgress else { return }
        settingsProgress = next
        petting = false
        gaze = .zero
        applyEyeFeedback(animated: false)
        feedbackScale = 1
        portrait.removeAnimation(forKey: "feedback")
        if next == 0 {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            portrait.transform = CATransform3DIdentity
            CATransaction.commit()
            hovering = false
        }
        layout(); needsDisplay = true
        if next == 0 || next == 1 {
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
    }

    func update(isBlack: Bool) {
        let nextTitle = isBlack ? L10n.text("Restore Display") : L10n.text("Black Out")
        if title != nextTitle {
            let animate = !title.isEmpty && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            advanceText()
            textTimer?.invalidate(); textTimer = nil
            textFrom = textBlend
            textTarget = isBlack ? 1 : 0
            textStarted = ProcessInfo.processInfo.systemUptime
            if animate {
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.advanceText() }
                textTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            } else {
                textBlend = textTarget
            }
        }
        title = nextTitle
        setAccessibilityLabel(title)
        setAccessibilityHelp(isBlack ? L10n.text("Restore the previous display state") : L10n.text("Darken your screens while tasks keep running."))
        needsDisplay = true
    }

    private func advanceText() {
        guard textTimer != nil else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - textStarted
        let progress = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : min(1, elapsed / 0.15)
        let eased = CGFloat(progress * progress * (3 - 2 * progress))
        textBlend = textFrom + (textTarget - textFrom) * eased
        if progress >= 1 {
            textBlend = textTarget
            textTimer?.invalidate(); textTimer = nil
        }
        needsDisplay = true
    }

    func setEyeClosure(_ progress: Double) {
        let value = max(0, min(1, progress))
        let wasOpen = eyeClosure == 0
        eyeClosure = value
        if value > 0 && wasOpen {
            petting = false; gaze = .zero
            updateScale(pressed: false)
        }
        let closure = CGFloat(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? (value >= 0.5 ? 1 : 0) : value)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, eye) in eyes.enumerated() {
            let x: CGFloat = index == 0 ? 65 : 133
            let y: CGFloat = 94
            let radius = 12 + 10 * closure
            let top = 30 * (1 - closure) - 8 * closure
            let bottom = -30 * (1 - closure) - 15 * closure
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x - radius, y: y))
            path.addCurve(to: CGPoint(x: x + radius, y: y), control1: CGPoint(x: x - radius, y: y + top), control2: CGPoint(x: x + radius, y: y + top))
            path.addCurve(to: CGPoint(x: x - radius, y: y), control1: CGPoint(x: x + radius, y: y + bottom), control2: CGPoint(x: x - radius, y: y + bottom))
            path.closeSubpath()
            eye.path = path
        }
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = textLayout
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: NSColor.labelColor]
        let shortcutAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.shortcutFont,
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(1 - settingsProgress)
        ]
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: layout.origin.x, yBy: layout.origin.y)
        transform.scale(by: layout.scale)
        transform.concat()
        for (index, text) in layout.labels.enumerated() {
            var fadingAttributes = attributes
            let opacity = index == 0 ? max(0, 1 - textBlend * 2) : max(0, textBlend * 2 - 1)
            fadingAttributes[.foregroundColor] = NSColor.labelColor.withAlphaComponent(opacity * (1 - settingsProgress))
            text.draw(at: NSPoint(x: (layout.label.width - layout.sizes[index].width) / 2, y: 0), withAttributes: fadingAttributes)
        }
        (shortcut as NSString).draw(at: NSPoint(x: layout.label.width + layout.gap, y: (layout.label.height - layout.key.height) / 2), withAttributes: shortcutAttributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    override var focusRingMaskBounds: NSRect { settingsProgress == 1 ? portraitBounds : portraitBounds.union(textBounds) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 20, yRadius: 20).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { trackingHost?.removeTrackingArea(tracking) }
        guard let host = window?.contentView else { tracking = nil; trackingHost = nil; return }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow], owner: self)
        host.addTrackingArea(area)
        trackingHost = host
        tracking = area
    }

    override func resetCursorRects() {}
    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inside = containsAction(point)
        if inside || hovering { (inside ? NSCursor.pointingHand : NSCursor.arrow).set() }
        let canReact = isEnabled && eyeClosure == 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let touching = canReact && inside && portraitBounds.contains(point)
        let radius: CGFloat = settingsProgress == 1 ? 75 : 170
        let dx = point.x - portraitBounds.midX
        let dy = point.y - (portraitBounds.midY - 6 * (1 - 0.65 * settingsProgress))
        let previousGaze = gaze
        if canReact {
            let amplitude: CGFloat = settingsProgress == 1 ? 0.65 : 1
            gaze = CGPoint(x: max(-1, min(1, dx / (radius * 0.6))) * 4.5 * amplitude,
                           y: max(-1, min(1, dy / (radius * 0.6))) * 3 * amplitude)
        } else { gaze = .zero }
        if hovering != inside || petting != touching || previousGaze != gaze {
            hovering = inside; petting = touching; updateScale(pressed: false)
        }
    }
    override func cursorUpdate(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) {
        hovering = false; petting = false; gaze = .zero
        updateScale(pressed: false); NSCursor.arrow.set()
    }

    private func bodyTransform(scale: CGFloat) -> CATransform3D {
        let active = eyeClosure == 0 && !pressing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let amount: CGFloat = petting && active
            ? (settingsProgress == 1 ? 0.012 : 0.025) : 0
        let direction = gaze.x / 4.5
        let lean = active && !petting ? max(0, (abs(direction) - 0.25) / 0.75) * (direction < 0 ? -1 : 1) : 0
        let vertical = active && !petting ? gaze.y / 3 : 0
        var transform = CATransform3DMakeTranslation(lean * 1.5, vertical, 0)
        transform = CATransform3DRotate(transform, -lean * .pi / 90, 0, 0, 1)
        return CATransform3DScale(transform, scale * (1 + amount), scale * (1 - amount), 1)
    }

    private func applyEyeFeedback(animated: Bool) {
        let active = eyeClosure == 0 && !pressing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let squint: CGFloat = active && petting ? (settingsProgress == 1 ? 0.9 : 0.82) : 1
        for eye in eyes {
            let previous = eye.presentation()?.transform ?? eye.transform
            // Scale around the eye centre, rather than the layer's origin.
            var target = CATransform3DMakeTranslation(active ? gaze.x : 0, (active ? gaze.y : 0) + 94 * (1 - squint), 0)
            target = CATransform3DScale(target, 1, squint, 1)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            eye.transform = target
            CATransaction.commit()
            eye.removeAnimation(forKey: "attention")
            if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let animation = CABasicAnimation(keyPath: "transform")
                animation.fromValue = NSValue(caTransform3D: previous)
                animation.toValue = NSValue(caTransform3D: target)
                animation.duration = 0.16
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                eye.add(animation, forKey: "attention")
            }
        }
    }

    fileprivate func updateScale(pressed: Bool) {
        guard isEnabled else { return }
        pressing = pressed
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        feedbackScale = reduced ? 1 : (pressed ? 0.97 : 1)
        let scale = (1 - 0.65 * settingsProgress) * feedbackScale
        let previous = portrait.presentation()?.transform ?? portrait.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        portrait.transform = bodyTransform(scale: scale)
        CATransaction.commit()
        portrait.removeAnimation(forKey: "feedback")
        if !reduced {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: previous)
            animation.toValue = NSValue(caTransform3D: portrait.transform)
            animation.duration = pressed || petting ? 0.12 : 0.24
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            portrait.add(animation, forKey: "feedback")
        }
        applyEyeFeedback(animated: !pressed && eyeClosure == 0)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if !event.isARepeat { performClick(nil) }
        } else {
            super.keyDown(with: event)
        }
    }
}
