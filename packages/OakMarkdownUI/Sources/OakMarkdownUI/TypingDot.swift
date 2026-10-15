import AppKit
import QuartzCore

/// The breathing dot ChatGPT shows while it works (`OAIMarkdown.TypingDotView`):
/// alone while waiting for the first word, then at the end of the text as it
/// streams. One animation for both, so they read as the same thing.
public enum TypingDot {
    /// Start the breathing animation on `layer`, or leave it still under Reduce Motion.
    public static func animate(_ layer: CALayer) {
        layer.removeAnimation(forKey: "typing-dot")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.72
        scale.toValue = 1.0
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.55
        opacity.toValue = 1.0
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 0.6
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "typing-dot")
    }
}
