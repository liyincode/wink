import ScreenCore
import AppKit

enum Mascot {
    static let body = load("mascot-body")
    static let wink = load("mascot-wink")

    private static func load(_ name: String) -> NSImage? {
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        return url.flatMap { NSImage(contentsOf: $0) }
    }

    static func menuIcon(isBlack: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let body = NSBezierPath()
            body.move(to: NSPoint(x: 1, y: 8))
            body.curve(to: NSPoint(x: 5.5, y: 15), controlPoint1: NSPoint(x: 1, y: 12.5), controlPoint2: NSPoint(x: 2.5, y: 15.5))
            body.curve(to: NSPoint(x: 15.5, y: 14), controlPoint1: NSPoint(x: 9, y: 15.5), controlPoint2: NSPoint(x: 11, y: 13.2))
            body.curve(to: NSPoint(x: 19, y: 8), controlPoint1: NSPoint(x: 18, y: 14.5), controlPoint2: NSPoint(x: 19, y: 12))
            body.curve(to: NSPoint(x: 15, y: 3), controlPoint1: NSPoint(x: 19, y: 4.5), controlPoint2: NSPoint(x: 18, y: 3.5))
            body.curve(to: NSPoint(x: 5, y: 3), controlPoint1: NSPoint(x: 12, y: 2.5), controlPoint2: NSPoint(x: 8, y: 2.5))
            body.curve(to: NSPoint(x: 1, y: 8), controlPoint1: NSPoint(x: 2, y: 3), controlPoint2: NSPoint(x: 1, y: 4.5))
            body.close()
            body.fill()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            for x: CGFloat in [6.5, 13.5] {
                if isBlack {
                    let eye = NSBezierPath()
                    eye.move(to: NSPoint(x: x - 1.7, y: 9))
                    eye.curve(to: NSPoint(x: x + 1.7, y: 9), controlPoint1: NSPoint(x: x - 0.8, y: 7.4), controlPoint2: NSPoint(x: x + 0.8, y: 7.4))
                    eye.lineWidth = 1.5; eye.lineCapStyle = .round; eye.stroke()
                } else {
                    NSBezierPath(ovalIn: NSRect(x: x - 1.1, y: 6.8, width: 2.2, height: 4.2)).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = isBlack ? L10n.text("Screens are blacked out") : L10n.text("Displays restored")
        return image
    }
}
