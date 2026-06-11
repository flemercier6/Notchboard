import SwiftUI

/// Normalizes a hex color string ("#RGB" or "#RRGGBB") to "#RRGGBB" uppercase,
/// or returns nil if it isn't one. Requires a leading "#" so plain words that
/// happen to be valid hex (e.g. "facade") aren't mistaken for colors.
func parseHexColor(_ string: String) -> String? {
    var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.hasPrefix("#") else { return nil }
    s.removeFirst()
    let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    guard !s.isEmpty, s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    let upper = s.uppercased()
    switch upper.count {
    case 3: return "#" + upper.map { "\($0)\($0)" }.joined()
    case 6: return "#" + upper
    default: return nil
    }
}

extension Color {
    /// Builds a Color from a "#RRGGBB" string.
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Black or white — whichever reads better on the given hex background.
    static func readableText(onHex hex: String) -> Color {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return .white }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.6 ? .black : .white
    }
}
