import SwiftUI

/// Add or edit an MCP server. In add mode the user picks the transport, fills connection
/// details, and chooses which harnesses to write into (harnesses that can't express the
/// chosen transport are shown locked, never silently coerced). In edit mode the portable
/// definition is re-applied to every harness the server already lives in, preserving each
/// harness's enabled state and agent-local fields.
struct McpServerSheet: View {
    enum Mode: Equatable { case add; case edit(McpServer) }

    let mode: Mode
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var isRemote: Bool
    @State private var command: String
    @State private var argsText: String
    @State private var url: String
    @State private var remoteTransport: McpTransport
    @State private var envRows: [EnvRow]
    @State private var selected: Set<McpHarness>
    @State private var didSubmit = false

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .add:
            _name = State(initialValue: "")
            _isRemote = State(initialValue: false)
            _command = State(initialValue: "")
            _argsText = State(initialValue: "")
            _url = State(initialValue: "")
            _remoteTransport = State(initialValue: .http)
            _envRows = State(initialValue: [])
            _selected = State(initialValue: Set(McpHarness.allCases))
        case .edit(let s):
            let p = s.representativePortable
            _name = State(initialValue: s.name)
            _isRemote = State(initialValue: p?.kind == .remote)
            _command = State(initialValue: p?.command ?? "")
            _argsText = State(initialValue: (p?.args ?? []).joined(separator: "\n"))
            _url = State(initialValue: p?.url ?? "")
            _remoteTransport = State(initialValue: p?.remoteTransport ?? .http)
            _envRows = State(initialValue: (p?.env ?? [:]).sorted { $0.key < $1.key }
                .map { EnvRow(key: $0.key, value: $0.value.display) })
            _selected = State(initialValue: s.presentIn)
        }
    }

    private var isEdit: Bool { if case .edit = mode { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEdit ? "Edit MCP server" : "Add MCP server").font(.title2).fontWeight(.semibold)

            field("Name") {
                TextField("server name", text: $name).textFieldStyle(.roundedBorder)
                    .disabled(isEdit) // identity is fixed when editing
            }

            Picker("Transport", selection: $isRemote) {
                Text("Local (stdio)").tag(false)
                Text("Remote (URL)").tag(true)
            }
            .pickerStyle(.segmented)

            if isRemote {
                field("URL") {
                    TextField("https://…", text: $url).textFieldStyle(.roundedBorder)
                }
                field("Remote transport") {
                    Picker("", selection: $remoteTransport) {
                        Text("HTTP").tag(McpTransport.http)
                        Text("Streamable HTTP").tag(McpTransport.streamableHttp)
                        Text("SSE").tag(McpTransport.sse)
                        Text("WebSocket").tag(McpTransport.ws)
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
            } else {
                field("Command") {
                    TextField("npx", text: $command).textFieldStyle(.roundedBorder)
                }
                field("Arguments (one per line)") {
                    TextEditor(text: $argsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }
                envEditor
            }

            harnessTargets

            if let msg = state.actionStatus.failureMessage(submitID), didSubmit {
                Text(msg).font(.caption).foregroundStyle(Theme.drift).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(Theme.drift.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEdit ? "Save" : "Add") { submit() }
                    .buttonStyle(.glassProminent)
                    .tint(McpHarness.claudeCode.color)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || state.actionStatus.isRunning)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: state.actionStatus) { _, status in
            if didSubmit, status.didSucceed(submitID) { dismiss() }
        }
    }

    // MARK: - Sub-views

    private var envEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Environment").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { envRows.append(EnvRow()) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).controlSize(.small)
            }
            ForEach($envRows) { $row in
                HStack(spacing: 6) {
                    TextField("KEY", text: $row.key).textFieldStyle(.roundedBorder).frame(width: 130)
                    TextField("value or ${VAR}", text: $row.value).textFieldStyle(.roundedBorder)
                    Button { envRows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
        }
    }

    private var harnessTargets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isEdit ? "Applies to" : "Add to harnesses").font(.caption).foregroundStyle(.secondary)
            ForEach(McpHarness.allCases) { h in
                let unsupported = !h.transportSupport.contains(portable.transport)
                Toggle(isOn: Binding(
                    get: { selected.contains(h) && !unsupported },
                    set: { if $0 { selected.insert(h) } else { selected.remove(h) } }
                )) {
                    HStack(spacing: 6) {
                        Circle().fill(h.color).frame(width: 7, height: 7)
                        Text(h.displayName)
                        if unsupported {
                            Text("· can't express \(portable.transport.label)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(unsupported || (isEdit)) // edit re-applies to existing harnesses only
            }
            if isEdit {
                Text("Editing re-applies the definition to the harnesses this server already lives in.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Logic

    private var submitID: ActionID {
        if case .edit(let s) = mode { return .mcpEdit(s.id) }
        return .mcpAdd
    }

    private var portable: PortableMcpDefinition {
        if isRemote {
            return PortableMcpDefinition(kind: .remote, command: nil, args: [], env: [:], cwd: nil,
                                         url: url.trimmingCharacters(in: .whitespaces),
                                         remoteTransport: remoteTransport)
        }
        let args = argsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var env: [String: McpValueExpr] = [:]
        for r in envRows {
            let k = r.key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { env[k] = McpValueExpr.parse(r.value, dialect: .dollar) }
        }
        return PortableMcpDefinition(kind: .stdio,
                                     command: command.trimmingCharacters(in: .whitespaces),
                                     args: args, env: env, cwd: nil, url: nil, remoteTransport: nil)
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if isRemote {
            guard !url.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        } else {
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        }
        if !isEdit { return !effectiveTargets.isEmpty }
        return true
    }

    /// Selected harnesses minus any that can't express the current transport.
    private var effectiveTargets: [McpHarness] {
        selected.filter { $0.transportSupport.contains(portable.transport) }.sorted { $0.rawValue < $1.rawValue }
    }

    private func submit() {
        didSubmit = true
        switch mode {
        case .add:
            state.addMcpServer(name: name.trimmingCharacters(in: .whitespaces),
                               def: portable, targets: effectiveTargets)
        case .edit(let s):
            state.editMcpServer(s, def: portable)
        }
    }
}

struct EnvRow: Identifiable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}
