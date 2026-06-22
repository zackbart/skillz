import SwiftUI
import HerdrKit

/// Entry screen: pick a saved host to connect over SSH, add a new one, or open
/// the in-memory demo.
struct ConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var editingHost: Host?
    @State private var showingNewHost = false

    private var store: ConnectionStore { app.connections }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    BrandHero()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 28, leading: 16, bottom: 12, trailing: 16))
                }

                Section {
                    Button {
                        Task { await app.connectDemo() }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.fill")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(Theme.prompt)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Open demo workspace")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("Realistic sample data — no server")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(app.isConnecting)
                } header: {
                    SectionEyebrow("quick start")
                }

                Section {
                    if store.hosts.isEmpty {
                        Text("No hosts yet. Add the machine where Herdr runs.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.hosts) { host in
                        Button {
                            Task { await app.connect(to: host) }
                        } label: {
                            HostRow(host: host)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { store.remove(host) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { editingHost = host } label: {
                                Label("Edit", systemImage: "pencil")
                            }.tint(Theme.ink)
                        }
                    }
                } header: {
                    SectionEyebrow("hosts")
                }

                if case .failed(let message) = app.phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.blocked)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNewHost = true } label: { Image(systemName: "plus") }
                        .tint(Theme.ink)
                }
            }
            .overlay {
                if case .connecting(let label) = app.phase {
                    ConnectingOverlay(label: label)
                }
            }
            .sheet(isPresented: $showingNewHost) {
                HostEditor(host: Host()) { host, secret in
                    store.upsert(host, secret: secret)
                }
            }
            .sheet(item: $editingHost) { host in
                HostEditor(host: host) { updated, secret in
                    store.upsert(updated, secret: secret)
                }
            }
        }
        .tint(Theme.prompt)
    }
}

/// The logo mark, mono wordmark, and tagline — the app's identity, shown once
/// at the top of the connect screen.
private struct BrandHero: View {
    var body: some View {
        VStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 78, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.ink.opacity(0.08))
                )
                .shadow(color: Theme.ink.opacity(0.18), radius: 10, y: 5)

            VStack(spacing: 3) {
                Text("herdr")
                    .font(Theme.mono(32, .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.ink)
                Text("mind the flock from anywhere")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HostRow: View {
    let host: Host
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.callout)
                .foregroundStyle(Theme.ink.opacity(0.55))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).font(.body.weight(.medium))
                Text(host.subtitle).font(Theme.mono(12)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct ConnectingOverlay: View {
    let label: String
    var body: some View {
        ZStack {
            Color(.systemBackground).opacity(0.75).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                Text("Connecting to \(label)…")
                    .font(Theme.mono(13))
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

/// Add/edit a host. The secret field stores the private key or password in the
/// Keychain on save.
private struct HostEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var host: Host
    @State private var secret: String = ""
    let onSave: (Host, String?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Nickname (optional)", text: $host.nickname)
                    TextField("Hostname", text: $host.hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $host.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $host.port, format: .number)
                        .keyboardType(.numberPad)
                }

                Section("Authentication") {
                    Picker("Method", selection: $host.authMethod) {
                        ForEach(AuthMethod.allCases) { Text($0.title).tag($0) }
                    }
                    switch host.authMethod {
                    case .privateKey:
                        TextField("Paste private key (PEM)", text: $secret, axis: .vertical)
                            .font(.caption.monospaced())
                            .lineLimit(3...8)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    case .password:
                        SecureField("Password", text: $secret)
                    }
                }

                Section {
                    TextField("Socket path (optional)", text: $host.socketPath)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Herdr socket")
                } footer: {
                    Text("Leave blank to auto-detect. Herdr's socket is found automatically under ~/.config/herdr — set this only to target a specific session or a non-standard path.")
                }
            }
            .navigationTitle(host.hostname.isEmpty ? "New host" : host.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(host, secret.isEmpty ? nil : secret)
                        dismiss()
                    }
                    .disabled(host.hostname.isEmpty || host.username.isEmpty)
                }
            }
        }
    }
}
