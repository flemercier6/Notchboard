import SwiftUI

/// A panel that hangs from the top edge of the screen like the MacBook notch:
/// the top edge is flush, the top corners curve *outward* (concave / inverse
/// radius), and the bottom corners are normally rounded (convex).
struct NotchShape: Shape {
    /// Concave radius where the flush top edge meets the body (the "notch" flare).
    var topCornerRadius: CGFloat = 12
    /// Convex radius of the two bottom corners.
    var bottomCornerRadius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        let topR = min(topCornerRadius, rect.width / 2, rect.height / 2)
        let bottomR = min(bottomCornerRadius, rect.width / 2 - topR, rect.height - topR)

        var path = Path()

        // Outer top-left corner, flush with the screen top.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left inverse (concave) shoulder.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topR, y: rect.minY + topR),
            control: CGPoint(x: rect.minX + topR, y: rect.minY)
        )

        // Left edge down to the bottom-left corner.
        path.addLine(to: CGPoint(x: rect.minX + topR, y: rect.maxY - bottomR))

        // Bottom-left convex corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topR + bottomR, y: rect.maxY),
            control: CGPoint(x: rect.minX + topR, y: rect.maxY)
        )

        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - topR - bottomR, y: rect.maxY))

        // Bottom-right convex corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topR, y: rect.maxY - bottomR),
            control: CGPoint(x: rect.maxX - topR, y: rect.maxY)
        )

        // Right edge up to the top-right shoulder.
        path.addLine(to: CGPoint(x: rect.maxX - topR, y: rect.minY + topR))

        // Top-right inverse (concave) shoulder.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topR, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

/// Like NotchShape but only the LEFT end is shaped (concave top-left flare,
/// convex bottom-left); the right side is square so it can tuck seamlessly under
/// the compact bar. Used by the email notification that slides out from the bar.
struct NotchTabShape: Shape {
    var topCornerRadius: CGFloat = 10
    var bottomCornerRadius: CGFloat = 13

    func path(in rect: CGRect) -> Path {
        let topR = min(topCornerRadius, rect.width / 2, rect.height / 2)
        let bottomR = min(bottomCornerRadius, rect.width - topR, rect.height - topR)

        var path = Path()
        // Top-left outer corner (flush with the top), then concave shoulder.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topR, y: rect.minY + topR),
            control: CGPoint(x: rect.minX + topR, y: rect.minY)
        )
        // Left edge down to the convex bottom-left corner.
        path.addLine(to: CGPoint(x: rect.minX + topR, y: rect.maxY - bottomR))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topR + bottomR, y: rect.maxY),
            control: CGPoint(x: rect.minX + topR, y: rect.maxY)
        )
        // Flat bottom, square right side, flat top (closeSubpath).
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
