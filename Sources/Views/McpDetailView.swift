import SwiftUI

struct McpDetailView: View {
    let server: McpServer
    @EnvironmentObject var state: AppState
    @State private var editing = false
    @State private var confirmRemoveAll = false
    @State private var removeTarget: McpHarness?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                managementRow
                harnessSection
                perHarnessControls
                if server.definitionDiverges { divergenceCard }
                if let portable = server.representativePortable { definitionSection(portable) }
                authSection
                originsSection
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(server.name)
        .sheet(isPresented: $editing) { McpServerSheet(mode: .edit(server)) }
        .confirmationDialog("Remove \(server.name) from all harnesses?",
                            isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove everywhere", role: .destructive) { state.removeMcpServer(server) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the server entry from \(server.presentIn.count) harness config(s). Agent-local auth stays only where it already is.")
        }
        .confirmationDialog(
            "Remove \(server.name) from \(removeTarget?.displayName ?? "")?",
            isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let h = removeTarget { state.removeMcpServer(server, from: [h]); removeTarget = nil }
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        }
    }

    // MARK: - Management

    private var managementRow: some View {
        HStack(spacing: 8) {
            if !server.supportedButMissing.isEmpty {
                Button {
                    state.applyToSupported(server)
                } label: {
                    if state.actionStatus.isRunning(.mcpApply(server.id)) {
                        HStack(spacing: 5) { ProgressView().controlSize(.small); Text("Applying…") }
                    } else {
                        Label("Apply to \(server.supportedButMissing.count) supported", systemImage: "square.on.square")
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .tint(McpHarness.claudeCode.color)
                .disabled(state.actionStatus.isRunning)
                .help("Add this server to every harness that supports its transport but doesn't have it")
            }

            Spacer()

            Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                .buttonStyle(.glass).controlSize(.small)
                .disabled(state.actionStatus.isRunning || server.representativePortable == nil)
                .help("Edit the definition and re-apply it to every harness this server lives in")

            Button(role: .destructive) { confirmRemoveAll = true } label: { Label("Remove…", systemImage: "trash") }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(state.actionStatus.isRunning)
                .help("Remove this server from all harnesses")
        }
    }

    /// Per-harness controls: enable/disable (only where the harness can express it) and a
    /// per-harness remove. Locked harnesses (unsupported / missing) aren't listed here.
    private var perHarnessControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !presentHarnesses.isEmpty { sectionTitle("Manage per harness") }
            ForEach(presentHarnesses, id: \.self) { harness in
                HStack(spacing: 8) {
                    Circle().fill(harness.color).frame(width: 7, height: 7)
                    Text(harness.displayName).font(.callout)
                    Text(server.state(harness).label).font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    if canToggle(harness) {
                        let enabled = server.entries[harness]?.enabled ?? true
                        Button {
                            state.setMcpEnabled(server, harness: harness, enabled: !enabled)
                        } label: {
                            if state.actionStatus.isRunning(.mcpToggle(server.id, harness)) {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(enabled ? "Disable" : "Enable")
                            }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(state.actionStatus.isRunning)
                    }
                    Button(role: .destructive) { removeTarget = harness } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(state.actionStatus.isRunning)
                    .help("Remove from \(harness.displayName)")
                }
            }
        }
    }

    /// Only opencode & Codex can persist a disabled-but-present server; Claude/Cursor would
    /// have to omit it (i.e. remove), so we don't offer a toggle there.
    private func canToggle(_ harness: McpHarness) -> Bool {
        harness == .opencode || harness == .codex
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Text(server.name).font(.largeTitle).fontWeight(.bold)
                if server.definitionDiverges {
                    Tag(text: "diverged", color: Theme.drift)
                        .help("Harnesses define this server differently.")
                }
                if !server.conflictedHarnesses.isEmpty {
                    Tag(text: "conflict", color: Theme.drift)
                        .help("Two config origins for the same harness disagree.")
                }
            }
            if let s = server.summary {
                Text(s).font(.title3).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if case .project = server.scope, !server.logicalLocation.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "folder").font(.caption2)
                    Text(server.logicalLocation).font(.system(.caption, design: .monospaced))
                }
                .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Harness matrix (the four states)

    private var harnessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Across harnesses")
            FlowRow(spacing: 7) {
                ForEach(McpHarness.allCases) { harness in
                    harnessChip(harness)
                }
            }
        }
    }

    @ViewBuilder
    private func harnessChip(_ harness: McpHarness) -> some View {
        let st = server.state(harness)
        switch st {
        case .enabled:
            chip("\(harness.displayName) · enabled", color: harness.color,
                 systemImage: st.systemImage, filled: true)
        case .disabled:
            chip("\(harness.displayName) · disabled", color: harness.color,
                 systemImage: st.systemImage, filled: false)
                .help("Present but turned off in \(harness.displayName).")
        case .missing:
            chip("\(harness.displayName) · missing", color: .secondary,
                 systemImage: st.systemImage, ghost: true)
                .help("Supported by \(harness.displayName) but not configured.")
        case .unsupported:
            chip("\(harness.displayName) · unsupported", color: .secondary,
                 systemImage: st.systemImage, ghost: true)
                .help("\(harness.displayName) can't express this server's transport (\(server.transport?.label ?? "?")).")
        }
    }

    // MARK: - Definition

    private func definitionSection(_ p: PortableMcpDefinition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Definition")
            kv("Transport", p.transport.label)
            switch p.kind {
            case .stdio:
                if let c = p.command { kv("Command", c) }
                if !p.args.isEmpty { kv("Args", p.args.joined(separator: " ")) }
                if let cwd = p.cwd { kv("Cwd", cwd) }
            case .remote:
                if let url = p.url { kv("URL", url) }
            }
            if !p.env.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ENV").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).tracking(0.5)
                    ForEach(p.env.keys.sorted(), id: \.self) { key in
                        kv(key, server.representativePortable?.env[key]?.display ?? "")
                    }
                }
            }
            if server.definitionDiverges {
                Text("Shown from the first harness that defines it — see the divergence above for differences.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Divergence

    private var divergenceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Definitions diverge", systemImage: "arrow.triangle.branch")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(hex: 0x8A6400))
            ForEach(presentHarnesses, id: \.self) { harness in
                if let p = server.entries[harness]?.portable {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(harness.color).frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(harness.displayName).font(.caption.weight(.semibold))
                            Text(p.summary).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Theme.drift.opacity(0.18)), in: .rect(cornerRadius: 12))
    }

    // MARK: - Auth / agent-local fields

    @ViewBuilder
    private var authSection: some View {
        let fieldsByHarness = presentHarnesses.compactMap { h -> (McpHarness, [String])? in
            let fields = server.entries[h]?.agentLocalFields ?? []
            return fields.isEmpty ? nil : (h, fields)
        }
        if !fieldsByHarness.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Auth / harness-local fields")
                ForEach(fieldsByHarness, id: \.0) { harness, fields in
                    kv(harness.displayName, fields.joined(separator: ", "))
                }
                Text("Field names only — values are never read or displayed, and are preserved on edit.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Config origins

    private var originsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Config files")
            ForEach(presentHarnesses, id: \.self) { harness in
                ForEach(server.origins[harness] ?? [], id: \.self) { loc in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(harness.color).frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text("\(harness.displayName) · \(loc.label)").font(.caption.weight(.medium))
                                if let g = server.gitStatusByHarness[harness], loc.isPrimary {
                                    Image(systemName: g.systemImage).font(.system(size: 9))
                                        .foregroundStyle(g.color).help(g.label)
                                }
                            }
                            Text(loc.url.path).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var presentHarnesses: [McpHarness] {
        McpHarness.allCases.filter { server.presentIn.contains($0) }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.caption).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(v).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(_ text: String, color: Color, systemImage: String?,
                      filled: Bool = false, ghost: Bool = false) -> some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.caption2) }
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(ghost ? Color.clear : color.opacity(filled ? 0.18 : 0.10), in: Capsule())
        .overlay {
            if ghost { Capsule().strokeBorder(color.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
        }
        .foregroundStyle(color == .secondary ? .secondary : color)
    }
}

extension McpValueExpr {
    /// How an interpolation expression reads back in the UI (canonical `${VAR}` form, etc.).
    var display: String {
        switch self {
        case .literal(let s): return s
        case .envVar(let v): return "${\(v)}"
        case .envVarDefault(let v, let d): return "${\(v):-\(d)}"
        case .fileRef(let p): return "{file:\(p)}"
        }
    }
}
