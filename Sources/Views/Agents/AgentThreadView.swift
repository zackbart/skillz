import SwiftUI
import HerdrKit
import AgentContentKit

/// Renders a selected pane's transcript as a T3 Code–style thread:
/// a slim identity bar, a centered prose column where assistant messages are
/// borderless full-width prose and user messages are right-aligned bubbles, and
/// tool calls collapsed into a quiet, expandable "work log" of one-line rows.
/// Plan blocks render inline; a visual-only composer sits at the bottom.
/// Presentation only — no behavior/data changes.
struct AgentThreadView: View {
    @ObservedObject var model: AgentsSessionModel

    private var selectedPane: AgentInfo? {
        guard let id = model.selectedPaneID else { return nil }
        return model.panes.first { $0.paneID == id }
    }

    var body: some View {
        if let pane = selectedPane {
            VStack(spacing: 0) {
                topBar(pane)
                Divider()
                thread(pane)
                composer(pane)
            }
        } else {
            ContentUnavailableView(
                "Select an agent",
                systemImage: "bubble.left.and.bubble.right",
                description: Text(model.status ?? "\(model.panes.count) live panes")
            )
        }
    }

    // MARK: - Slim identity bar (T3 top action bar, sans git actions)

    @ViewBuilder
    private func topBar(_ pane: AgentInfo) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(AgentStyle.identityColor(pane.agent))
                .frame(width: 11, height: 11)
            Text(pane.agent ?? "agent")
                .font(.system(size: 15, weight: .semibold))
            Text("#\(pane.paneID.rawValue)")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            statusPill(pane.status)
            Spacer(minLength: 8)
            if let cwd = pane.cwd ?? pane.foregroundCwd {
                chip(key: "cwd", value: AgentStyle.shortCwd(cwd))
            }
            if let uuid = pane.agentSession?.value, !uuid.isEmpty {
                chip(key: "session", value: String(uuid.prefix(8)))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusPill(_ status: AgentStatus) -> some View {
        let color = AgentStyle.statusColor(status)
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(AgentStyle.statusLabel(status).capitalized)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 2.5)
        .background(color.opacity(0.16), in: Capsule())
        .foregroundStyle(color)
    }

    private func chip(key: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(key).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
    }

    // MARK: - Thread (centered prose column)

    @ViewBuilder
    private func thread(_ pane: AgentInfo) -> some View {
        ScrollView {
            if model.blocks.isEmpty {
                ContentUnavailableView(
                    "Nothing to show",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(model.status ?? "Transcript is empty.")
                )
                .frame(maxWidth: .infinity).padding(.top, 48)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(items(model.blocks)) { item in
                        switch item {
                        case let .message(_, role, text):
                            MessageRow(role: role, text: text, agentName: pane.agent)
                        case let .plan(_, planItems):
                            PlanSection(items: planItems)
                        case let .workLog(_, blocks):
                            WorkLogSection(blocks: blocks)
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 18)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)   // center the column
            }
        }
    }

    /// Group the flat block list into thread items, collapsing consecutive
    /// tool/diff blocks into a single work-log run.
    private func items(_ blocks: [TranscriptBlock]) -> [ThreadItem] {
        var out: [ThreadItem] = []
        var pending: [TranscriptBlock] = []
        var idx = 0
        func flush() {
            guard !pending.isEmpty else { return }
            out.append(.workLog(id: idx, blocks: pending)); pending = []; idx += 1
        }
        for block in blocks {
            switch block {
            case let .message(role, text):
                flush(); out.append(.message(id: idx, role: role, text: text)); idx += 1
            case let .plan(planItems):
                flush(); out.append(.plan(id: idx, items: planItems)); idx += 1
            case .toolCall, .diff:
                pending.append(block)
            }
        }
        flush()
        return out
    }

    // MARK: - Composer (T3-style, visual stub)

    @ViewBuilder
    private func composer(_ pane: AgentInfo) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ask for follow-up changes…")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                HStack(spacing: 8) {
                    composerPill(icon: "sparkle", "Claude Opus 4.8", chevron: true)
                    Divider().frame(height: 16)
                    composerPill(icon: "lock", "Full access", chevron: true)
                    composerPill(icon: "hammer", "Build")
                    composerPill(icon: "checklist", "Tasks")
                    Spacer(minLength: 6)
                    contextRing
                    sendButton
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 9)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary))
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 12)
        .background(.bar)
    }

    private func composerPill(icon: String, _ label: String, chevron: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(icon == "sparkle" ? AnyShapeStyle(AgentStyle.identityColor("claude")) : AnyShapeStyle(.secondary))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            if chevron {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.secondary.opacity(0.001), in: RoundedRectangle(cornerRadius: 7))
    }

    private var contextRing: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 2.5).frame(width: 22, height: 22)
            Circle().trim(from: 0, to: 0.32)
                .stroke(Color(hex: 0x1D4ED8), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 22, height: 22)
            Text("7").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }
    }

    private var sendButton: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Color(hex: 0x1D4ED8), in: Circle())
    }
}

// MARK: - Thread item model

private enum ThreadItem: Identifiable {
    case message(id: Int, role: String, text: String)
    case plan(id: Int, items: [PlanItem])
    case workLog(id: Int, blocks: [TranscriptBlock])

    var id: Int {
        switch self {
        case let .message(id, _, _): return id
        case let .plan(id, _): return id
        case let .workLog(id, _): return id
        }
    }
}

// MARK: - Message row (asymmetric: user bubble right, assistant prose left)

private struct MessageRow: View {
    let role: String
    let text: String
    let agentName: String?

    private var isUser: Bool { role.lowercased() == "user" }

    var body: some View {
        if isUser {
            HStack {
                Spacer(minLength: 40)
                markdown(text)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
            }
        } else {
            markdown(text)
                .font(.system(size: 14))
                .foregroundStyle(.primary.opacity(0.82))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(2)
        }
    }

    private func markdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }
}

// MARK: - Work log (collapsed, expandable one-line tool rows)

private struct WorkLogSection: View {
    let blocks: [TranscriptBlock]

    private var label: String {
        blocks.count == 1 ? "1 tool call" : "\(blocks.count) tool calls"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 2).padding(.bottom, 2)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                WorkRow(block: block)
            }
        }
    }
}

private struct WorkRow: View {
    let block: TranscriptBlock
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if hasBody { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(heading)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.82))
                        .fixedSize()
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if hasBody {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                body(for: block)
                    .padding(.leading, 11)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(width: 1)
                    }
                    .padding(.leading, 25)
                    .padding(.top, 3).padding(.bottom, 6)
            }
        }
    }

    // Row metadata derived from the block.
    private var symbol: String {
        switch block {
        case let .toolCall(name, _, _): return AgentStyle.toolSymbol(name)
        case .diff: return "square.and.pencil"
        default: return "wrench.and.screwdriver"
        }
    }
    private var heading: String {
        switch block {
        case let .toolCall(name, _, _): return name
        case .diff: return "Edit"
        default: return "Tool"
        }
    }
    private var preview: String {
        switch block {
        case let .toolCall(_, title, _): return title
        case let .diff(file, _): return file
        default: return ""
        }
    }
    private var hasBody: Bool {
        switch block {
        case let .toolCall(_, _, detail): return !(detail ?? "").isEmpty
        case let .diff(_, lines): return !lines.isEmpty
        default: return false
        }
    }

    @ViewBuilder
    private func body(for block: TranscriptBlock) -> some View {
        switch block {
        case let .toolCall(_, _, detail):
            if let detail, !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        case let .diff(_, lines):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    DiffRow(line: line)
                }
            }
        default:
            EmptyView()
        }
    }
}

private struct DiffRow: View {
    let line: DiffLine

    var body: some View {
        let (bg, fg, gutter): (Color, Color, String)
        switch line.kind {
        case .add: (bg, fg, gutter) = (Color(hex: 0x2BA160).opacity(0.10), Color(hex: 0x1A7A47), "+")
        case .del: (bg, fg, gutter) = (Color(hex: 0xE5484D).opacity(0.08), Color(hex: 0xC0363A), "-")
        case .context: (bg, fg, gutter) = (.clear, .secondary, " ")
        }
        return HStack(spacing: 0) {
            Text(gutter)
                .frame(width: 18, alignment: .trailing)
                .foregroundStyle(fg.opacity(0.6))
            Text(line.text)
                .foregroundStyle(fg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.vertical, 1)
        .background(bg)
        .textSelection(.enabled)
    }
}

// MARK: - Plan (inline checklist; rail treatment is a follow-up)

private struct PlanSection: View {
    let items: [PlanItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Plan")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                PlanRow(item: item)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

private struct PlanRow: View {
    let item: PlanItem

    var body: some View {
        let status = item.status.lowercased()
        let done = status == "completed" || status == "done"
        let active = status == "in_progress" || status == "active"
        let green = Color(hex: 0x2BA160)
        return HStack(spacing: 9) {
            Group {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(green, in: RoundedRectangle(cornerRadius: 4))
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(active ? AgentStyle.identityColor("claude") : Color.secondary.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                }
            }
            Text(item.text)
                .font(.system(size: 13))
                .foregroundStyle(done ? .tertiary : (active ? .primary : .secondary))
                .strikethrough(done, color: Color.secondary.opacity(0.5))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
