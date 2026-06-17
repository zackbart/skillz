import SwiftUI

extension Color {
    /// Build a Color from a 0xRRGGBB literal.
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Shared, non-agent color tokens (agent colors live on `Agent.color`).
enum Theme {
    static let drift = Color(hex: 0xE5A50A)
}
