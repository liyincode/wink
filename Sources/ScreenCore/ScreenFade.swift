import Foundation

/// One reversible timeline drives both Gamma and the character's eyelids.
public struct ScreenFade {
    public private(set) var progress: Double = 0
    public private(set) var targetBlack = false
    public var isRunning: Bool { progress != (targetBlack ? 1 : 0) }
    public var dimming: Double { progress * progress }
    public var eyeClosure: Double { min(1, progress / 0.8) }

    public init() {}

    public mutating func target(_ black: Bool) { targetBlack = black }

    public mutating func advance(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let step = seconds / 0.5
        progress = targetBlack ? min(1, progress + step) : max(0, progress - step)
    }

    public mutating func reset(isBlack: Bool) {
        progress = isBlack ? 1 : 0
        targetBlack = isBlack
    }
}
