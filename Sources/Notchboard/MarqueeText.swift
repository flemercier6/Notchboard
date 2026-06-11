import SwiftUI

/// Single-line text that auto-scrolls (ping-pong) when it's wider than the space
/// it's given. Used by the email notification banner.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 12, weight: .semibold)
    var color: Color = .white
    /// Scroll speed in points per second.
    var speed: Double = 55

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(key: MarqueeWidthKey.self, value: inner.size.width)
                    }
                )
                .offset(x: offset)
                .frame(width: geo.size.width, alignment: .leading)
                .clipped()
                .onPreferenceChange(MarqueeWidthKey.self) { width in
                    guard abs(width - textWidth) > 0.5 else { return }
                    textWidth = width
                    startScrolling(overflow: max(0, width - geo.size.width))
                }
        }
    }

    private func startScrolling(overflow: CGFloat) {
        offset = 0
        guard overflow > 1 else { return }
        withAnimation(
            .linear(duration: Double(overflow) / speed)
                .delay(0.5)
                .repeatForever(autoreverses: true)
        ) {
            offset = -overflow
        }
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
