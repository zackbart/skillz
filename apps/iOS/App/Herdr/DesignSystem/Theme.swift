import SwiftUI
import HerdrKit

/// Design tokens for Herdr. The app is terminal-native: light, legible chrome
/// for scanning the flock, a genuinely dark terminal surface in the pane view,
/// and monospace type wherever machine data appears (hosts, ids, output).
enum Theme {
    // Brand neutrals, pulled from the ram mark.
    static let ink = Color(hex: 0x23272B)

    // Terminal surface (PaneView) — light mode: a clean near-white paper with
    // dark ink, matching the rest of the app.
    static let terminalBG = Color(hex: 0xFCFCFA)
    static let terminalSurface = Color(hex: 0xEDECE8)
    static let terminalText = Color(hex: 0x23272B)
    static let terminalDim = Color(hex: 0x8A9099)
    /// The prompt accent — echoes the `>-` terminal-prompt eye in the logo.
    static let prompt = Color(hex: 0x57B89E)

    // Status palette — refined tones, but keeping Herdr's documented legend
    // semantics (blocked/working/done/idle/unknown).
    static let blocked = Color(hex: 0xE5484D)
    static let working = Color(hex: 0xE0A52E)
    static let done    = Color(hex: 0x5B8DEF)
    static let idle    = Color(hex: 0x4FA46B)
    static let unknown = Color(hex: 0x868D95)

    // Type. `monospaced` is the scrollback face; `mono(_:_:)` is the utility
    // face for hosts, ids, counts, eyebrows, and the wordmark.
    static let monospaced = Font.system(.callout, design: .monospaced)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    /// Build a color from a 24-bit RGB hex literal, e.g. `Color(hex: 0x23272B)`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// Status presentation, matching Herdr's sidebar legend:
// 🔴 blocked · 🟡 working · 🔵 done · 🟢 idle · ⚪️ unknown.
extension AgentStatus {
    var color: Color {
        switch self {
        case .blocked: return Theme.blocked
        case .working: return Theme.working
        case .done: return Theme.done
        case .idle: return Theme.idle
        case .unknown: return Theme.unknown
        }
    }

    /// Short human label for badges and accessibility.
    var label: String {
        switch self {
        case .blocked: return "Blocked"
        case .working: return "Working"
        case .done: return "Done"
        case .idle: return "Idle"
        case .unknown: return "Unknown"
        }
    }

    /// SF Symbol used alongside the status dot.
    var symbol: String {
        switch self {
        case .blocked: return "exclamationmark.circle.fill"
        case .working: return "circle.dotted"
        case .done: return "checkmark.circle.fill"
        case .idle: return "moon.zzz.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}
