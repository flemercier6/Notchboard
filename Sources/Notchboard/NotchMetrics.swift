import AppKit

/// Real-world geometry of the notch on the active built-in display.
struct NotchMetrics {
    let screenFrame: CGRect
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let hasNotch: Bool

    static func current() -> NotchMetrics {
        let screen = builtInScreen()
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top

        // On notched MacBooks the menu-bar area is split into a left and right
        // region; the gap between them is the notch.
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = max(0, frame.width - left.width - right.width)
            return NotchMetrics(
                screenFrame: frame,
                notchWidth: width,
                notchHeight: topInset,
                hasNotch: true
            )
        }

        // Fallback for displays without a notch: a sensible pill-sized hot zone.
        return NotchMetrics(
            screenFrame: frame,
            notchWidth: 220,
            notchHeight: 32,
            hasNotch: false
        )
    }

    /// Prefer the screen that actually has a notch; fall back to the main screen.
    static func builtInScreen() -> NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first!
    }
}
