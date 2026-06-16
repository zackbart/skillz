import Foundation
import SwiftUI
import HerdrKit

/// Screen 3: read a pane's output and send input, rendered as a light terminal —
/// a near-white scrollback surface and a prompt-style input bar. An iSH-style
/// key bar (sticky Ctrl, a dedicated ⌃B prefix, Esc/Tab/arrows) rides above the
/// keyboard. Scrollback comes from `pane.read`; keys go via `pane.send_keys`.
struct PaneView: View {
    @Environment(SessionModel.self) private var session
    let paneID: PaneID

    @State private var input: String = ""
    @State private var ctrlActive = false
    @FocusState private var inputFocused: Bool

    private var pane: Pane? { session.pane(paneID) }
    private var lines: [String] { session.outputs[paneID] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            scrollback
            Rectangle()
                .fill(Theme.terminalDim.opacity(0.18))
                .frame(height: 1)
            inputBar
        }
        .background(Theme.terminalBG, ignoresSafeAreaEdges: .bottom)
        .navigationTitle(pane?.title ?? paneID.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let pane, pane.isAgent {
                    StatusTag(status: pane.status)
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                keyboardBar
            }
        }
        .task(id: paneID) { await session.loadOutput(for: paneID) }
    }

    private var scrollback: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if lines.isEmpty {
                        Text("— no output yet —")
                            .font(Theme.monospaced)
                            .foregroundStyle(Theme.terminalDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.strippingANSI())
                            .font(Theme.monospaced)
                            .foregroundStyle(Theme.terminalText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(14)
            }
            .background(Theme.terminalBG)
            .onChange(of: lines.count) {
                withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        }
    }

    /// iSH-style key bar that rides above the keyboard. `Ctrl` is sticky and
    /// modifies the next key (a bar key, or the next typed letter).
    @ViewBuilder private var keyboardBar: some View {
        // Herdr's prefix key (Ctrl-B), one tap.
        Button {
            ctrlActive = false
            Task { await session.sendKeys("ctrl+b", to: paneID) }
        } label: {
            Text("⌃B").font(.system(.subheadline, design: .monospaced).weight(.semibold))
        }

        Button { ctrlActive.toggle() } label: {
            Image(systemName: "control")
                .fontWeight(.semibold)
                .foregroundStyle(ctrlActive ? Color.white : Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(ctrlActive ? Theme.prompt : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }

        Button { sendBarKey("Esc") } label: { Image(systemName: "escape") }
        Button { sendBarKey("Tab") } label: { Image(systemName: "arrow.right.to.line") }
        Button { sendBarKey("Left") } label: { Image(systemName: "arrow.left") }
        Button { sendBarKey("Up") } label: { Image(systemName: "arrow.up") }
        Button { sendBarKey("Down") } label: { Image(systemName: "arrow.down") }
        Button { sendBarKey("Right") } label: { Image(systemName: "arrow.right") }

        Spacer()

        Button { inputFocused = false } label: {
            Image(systemName: "keyboard.chevron.compact.down")
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Text(ctrlActive ? "^" : ">")
                    .font(Theme.mono(15, .bold))
                    .foregroundStyle(Theme.prompt)
                TextField("", text: $input,
                          prompt: Text("send input…").foregroundColor(Theme.terminalDim),
                          axis: .vertical)
                    .font(Theme.monospaced)
                    .foregroundStyle(Theme.terminalText)
                    .focused($inputFocused)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .tint(Theme.prompt)
                    .onChange(of: input) { old, new in handleCtrlTyping(old, new) }
                    .onSubmit(send)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.terminalSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.terminalBG)
                    .frame(width: 38, height: 38)
                    .background(canSend ? Theme.prompt : Theme.terminalDim, in: Circle())
            }
            .disabled(!canSend)
        }
        .padding(14)
        .background(Theme.terminalBG)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private let bottomAnchor = "herdr.pane.bottom"

    /// Send a bar key, applying a pending sticky Ctrl as `ctrl+<key>`.
    private func sendBarKey(_ key: String) {
        let resolved = ctrlActive ? "ctrl+\(key.lowercased())" : key
        ctrlActive = false
        Task { await session.sendKeys(resolved, to: paneID) }
    }

    /// When Ctrl is armed, the next typed character is sent as `ctrl+<char>`
    /// instead of being inserted.
    private func handleCtrlTyping(_ old: String, _ new: String) {
        guard ctrlActive else { return }
        guard new.count == old.count + 1, let ch = new.last, ch.isLetter || ch.isNumber else {
            if new.count != old.count { ctrlActive = false } // backspace/paste cancels Ctrl
            return
        }
        ctrlActive = false
        input = String(new.dropLast())
        let combo = "ctrl+\(String(ch).lowercased())"
        Task { await session.sendKeys(combo, to: paneID) }
    }

    private func send() {
        let text = input
        input = ""
        Task { await session.submit(text, to: paneID) }
    }
}

extension String {
    /// Remove ANSI/VT escape sequences so terminal output renders as plain text.
    func strippingANSI() -> String {
        guard contains("\u{1B}") else { return self }
        let pattern = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: "")
    }
}
