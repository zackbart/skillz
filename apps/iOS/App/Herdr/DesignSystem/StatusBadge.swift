import SwiftUI
import HerdrKit

/// A small colored dot for a single agent status, optionally pulsing while the
/// agent is actively working.
struct StatusDot: View {
    let status: AgentStatus
    var size: CGFloat = 9
    var pulses: Bool = false
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .opacity(pulses && status == .working ? (animate ? 0.35 : 1) : 1)
            .animation(
                pulses && status == .working
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: animate
            )
            .onAppear { animate = true }
            .accessibilityLabel(status.label)
    }
}

/// A compact row of "<dot> <count>" pairs summarizing how many agents sit in
/// each status within a workspace.
struct StatusSummary: View {
    let counts: [AgentStatus: Int]

    private var ordered: [(AgentStatus, Int)] {
        AgentStatus.allCases
            .compactMap { status in counts[status].map { (status, $0) } }
            .filter { $0.1 > 0 }
            .sorted { $0.0.priority > $1.0.priority }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ordered, id: \.0) { status, count in
                HStack(spacing: 4) {
                    StatusDot(status: status, size: 7)
                    Text("\(count)")
                        .font(Theme.mono(12, .medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("\(count) \(status.label)")
            }
        }
    }
}

/// A status pill — a pulsing dot plus a mono label on a faintly tinted capsule.
/// Used in pane rows and the pane toolbar.
struct StatusTag: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(status: status, size: 7, pulses: true)
            Text(status.label.uppercased())
                .font(Theme.mono(10, .semibold))
                .tracking(0.5)
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status.color.opacity(0.13), in: Capsule())
    }
}

/// A small uppercase monospace section label — the structural eyebrow used for
/// list section headers.
struct SectionEyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(11, .semibold))
            .tracking(1.5)
            .foregroundStyle(.secondary)
    }
}
