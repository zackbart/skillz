import Foundation
import SwiftUI
import HerdrKit

/// Screen 3: read a pane's output and send input, rendered as a light terminal —
/// a near-white scrollback surface and a prompt-style input bar. An iSH-style
/// key bar (sticky Ctrl, Esc, arrows) rides above the keyboard. Scrollback comes
/// from `pane.read`; keys go via `pane.send_keys`.
struct PaneView: View {
    @Environment(SessionModel.self) private var session
    let paneID: PaneID

    @State private var input: String = ""
    @State private var ctrlActive = false
    @State private var showingRaw = false
    @FocusState private var inputFocused: Bool

    private var pane: Pane? { session.pane(paneID) }
    private var lines: [String] { session.outputs[paneID] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            scrollback
            Rectangle()
                .fill(Theme.terminalDim.opacity(0.18))
                .frame(height: 1)
            if inputFocused {
                keyControlBar
            }
            inputBar
        }
        .background(Theme.terminalBG, ignoresSafeAreaEdges: .bottom)
        .navigationTitle(pane?.title ?? paneID.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let pane, pane.isAgent {
                    StatusTag(status: pane.status)
                }
                Button { showingRaw = true } label: { Image(systemName: "terminal") }
                    .tint(Theme.ink)
                    .accessibilityLabel("Raw terminal")
            }
        }
        .sheet(isPresented: $showingRaw) { RawTerminalSheet(paneID: paneID) }
        // Keep the pane live by re-reading whenever it emits new output. The
        // socket API pushes no pane-output events, but `pane.wait_for_output`
        // lets us block until the screen changes (or the wait times out) instead
        // of polling on a fixed timer — instant on activity, quiet while idle.
        // Re-keyed on `showingRaw` so opening the Raw sheet (which runs its own
        // reader) pauses this loop. `.task` cancels on disappear / id change.
        .task(id: pollKey) {
            guard !showingRaw else { return }
            while !Task.isCancelled {
                await session.refreshPaneDisplay(for: paneID, isAgent: pane?.isAgent == true)
                await session.awaitOutput(for: paneID)
            }
        }
    }

    /// Restart the loop when the pane changes or the Raw sheet opens/closes.
    private var pollKey: String { "\(paneID.rawValue)|\(showingRaw)" }

    /// Pinned, auto-refreshing projection of the agent's status footer (task,
    /// subagents, context, mode), cleaned of grid framing and color-preserved.
    /// Wraps vertically (no horizontal scroll); caps height and scrolls if tall.
    @ViewBuilder private var statusStrip: some View {
        if let pane, pane.isAgent, let status = session.statusLines[paneID], !status.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                SectionEyebrow("status")
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(status.enumerated()), id: \.offset) { _, line in
                            Text(line.ansiAttributed(defaultColor: Theme.terminalText))
                                .font(Theme.mono(12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxHeight: 132)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.terminalSurface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.terminalDim.opacity(0.18)).frame(height: 1)
            }
        }
    }

    private var scrollback: some View {
        ScrollViewReader { proxy in
            // Mobile transcript: cleaned output (frames stripped, footer deduped
            // upstream) wraps vertically — no horizontal scroll. Color preserved.
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if lines.isEmpty {
                        Text("— no output yet —")
                            .font(Theme.monospaced)
                            .foregroundStyle(Theme.terminalDim)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.ansiAttributed(defaultColor: Theme.terminalText))
                            .font(Theme.monospaced)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
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

    /// iSH-style key row pinned directly above the input field — and thus above
    /// the keyboard when it's up, since keyboard avoidance lifts the whole stack.
    /// Living in the layout flow (rather than a `.keyboard` accessory, whose
    /// height SwiftUI doesn't fold into the inset) keeps it from overlapping the
    /// input bar. `Ctrl` is sticky and modifies the next key (a bar key, or the
    /// next typed letter).
    private var keyControlBar: some View {
        HStack(spacing: 0) {
            Button { ctrlActive.toggle() } label: {
                Image(systemName: "control")
                    .fontWeight(.semibold)
                    .foregroundStyle(ctrlActive ? Color.white : Theme.prompt)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(ctrlActive ? Theme.prompt : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            keyButton("escape", sends: "Esc")
            keyButton("arrow.left", sends: "Left")
            keyButton("arrow.up", sends: "Up")
            keyButton("arrow.down", sends: "Down")
            keyButton("arrow.right", sends: "Right")
            Button { inputFocused = false } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .foregroundStyle(Theme.prompt)
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
        }
        .padding(.horizontal, 8)
        .background(Theme.terminalSurface)
    }

    private func keyButton(_ symbol: String, sends key: String) -> some View {
        Button { sendBarKey(key) } label: {
            Image(systemName: symbol)
                .foregroundStyle(Theme.prompt)
                .frame(maxWidth: .infinity, minHeight: 38)
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

/// The "Raw" escape hatch: the exact terminal grid (hard-wrapped to the server
/// width), shown monospaced with 2-axis scrolling for when you need to inspect
/// what the agent's screen literally looks like. Polls like the main view.
private struct RawTerminalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionModel.self) private var session
    let paneID: PaneID
    @State private var raw: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(raw.enumerated()), id: \.offset) { _, line in
                        Text(line.ansiAttributed(defaultColor: Theme.terminalText))
                            .font(Theme.monospaced)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(14)
            }
            .background(Theme.terminalBG)
            .navigationTitle("Raw terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: paneID) {
            while !Task.isCancelled {
                raw = await session.rawTerminal(for: paneID)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

extension String {
    /// Parse ANSI SGR color sequences (16-color, 256-color, and 24-bit truecolor
    /// foreground) into an `AttributedString`, dropping every other escape
    /// (cursor moves, erase, etc.). This restores the color structure an agent's
    /// status footer relies on without a full terminal emulator — background
    /// colors and text attributes (bold/italic) are intentionally ignored.
    func ansiAttributed(defaultColor: Color) -> AttributedString {
        guard contains("\u{1B}") else {
            var plain = AttributedString(self)
            plain.foregroundColor = defaultColor
            return plain
        }
        let pattern = "\u{1B}\\[([0-9;]*)([ -/]*[@-~])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            var plain = AttributedString(TerminalText.stripANSI(self))
            plain.foregroundColor = defaultColor
            return plain
        }
        let ns = self as NSString
        var out = AttributedString()
        var cursor = 0
        var color = defaultColor

        func appendText(_ s: String) {
            guard !s.isEmpty else { return }
            var seg = AttributedString(s)
            seg.foregroundColor = color
            out.append(seg)
        }

        regex.enumerateMatches(in: self, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            if match.range.location > cursor {
                appendText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            cursor = match.range.location + match.range.length
            // Only SGR ('m') affects color; other final bytes are consumed and dropped.
            guard ns.substring(with: match.range(at: 2)) == "m" else { return }
            color = ANSIColor.apply(ns.substring(with: match.range(at: 1)), to: color, default: defaultColor)
        }
        if cursor < ns.length { appendText(ns.substring(from: cursor)) }
        return out
    }
}

/// ANSI SGR foreground-color resolution, tuned to stay legible on the light
/// terminal background.
private enum ANSIColor {
    /// Standard + bright 16-color palette (indices 0–7 then 8–15), darkened where
    /// needed so light colors remain readable on a near-white surface.
    static let palette: [Color] = [
        Color(red: 0.15, green: 0.15, blue: 0.15), // black
        Color(red: 0.78, green: 0.18, blue: 0.18), // red
        Color(red: 0.13, green: 0.55, blue: 0.13), // green
        Color(red: 0.65, green: 0.45, blue: 0.00), // yellow → amber
        Color(red: 0.15, green: 0.40, blue: 0.85), // blue
        Color(red: 0.66, green: 0.20, blue: 0.66), // magenta
        Color(red: 0.00, green: 0.50, blue: 0.55), // cyan → teal
        Color(red: 0.30, green: 0.30, blue: 0.30), // white → dark gray (legible)
        Color(red: 0.40, green: 0.40, blue: 0.40), // bright black → gray
        Color(red: 0.85, green: 0.25, blue: 0.25), // bright red
        Color(red: 0.20, green: 0.62, blue: 0.20), // bright green
        Color(red: 0.72, green: 0.52, blue: 0.05), // bright yellow
        Color(red: 0.22, green: 0.48, blue: 0.92), // bright blue
        Color(red: 0.74, green: 0.28, blue: 0.74), // bright magenta
        Color(red: 0.05, green: 0.58, blue: 0.62), // bright cyan
        Color(red: 0.20, green: 0.20, blue: 0.20), // bright white → near-black
    ]

    /// Apply one SGR parameter list to the current color, returning the new one.
    static func apply(_ params: String, to current: Color, default defaultColor: Color) -> Color {
        let codes = params.split(separator: ";").map { Int($0) ?? 0 }
        if codes.isEmpty { return defaultColor } // bare ESC[m == reset
        var color = current
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0, 39: color = defaultColor
            case 30...37: color = palette[code - 30]
            case 90...97: color = palette[8 + (code - 90)]
            case 38:
                if i + 2 < codes.count, codes[i + 1] == 5 {
                    color = from256(codes[i + 2]); i += 2
                } else if i + 4 < codes.count, codes[i + 1] == 2 {
                    color = Color(.sRGB,
                                  red: Double(codes[i + 2]) / 255,
                                  green: Double(codes[i + 3]) / 255,
                                  blue: Double(codes[i + 4]) / 255)
                    i += 4
                }
            default: break // ignore background (40–49) and attributes (1–9)
            }
            i += 1
        }
        return color
    }

    /// xterm 256-color index → RGB (16 base + 6×6×6 cube + 24 grays).
    private static func from256(_ n: Int) -> Color {
        if n < 16 { return palette[n] }
        if n < 232 {
            let c = n - 16
            let steps = [0.0, 95, 135, 175, 215, 255]
            return Color(.sRGB,
                         red: steps[(c / 36) % 6] / 255,
                         green: steps[(c / 6) % 6] / 255,
                         blue: steps[c % 6] / 255)
        }
        let gray = Double(8 + (n - 232) * 10) / 255
        return Color(.sRGB, red: gray, green: gray, blue: gray)
    }
}
