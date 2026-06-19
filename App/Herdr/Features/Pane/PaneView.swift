import Foundation
import SwiftUI
import HerdrKit

/// How a pane's terminal output is laid out on a phone screen. A terminal is a
/// fixed-width grid; reflowing it to phone width scrambles box-drawn / columnar
/// TUI layouts, so the grid modes (`fit`, `scroll`) render the raw grid faithfully
/// and only `reader` reflows (for long plain prose).
enum PaneRenderMode: String, CaseIterable {
    /// Faithful grid, font auto-shrunk so the whole width fits — no scrolling.
    case fit
    /// Faithful grid at a fixed readable font; pan left/right to see the rest.
    case scroll
    /// Cleaned, unwrapped output reflowed to phone width — layout not preserved.
    case reader

    var label: String {
        switch self {
        case .fit: return "Fit"
        case .scroll: return "Scroll"
        case .reader: return "Reader"
        }
    }

    var icon: String {
        switch self {
        case .fit: return "arrow.down.right.and.arrow.up.left"
        case .scroll: return "arrow.left.and.right"
        case .reader: return "text.alignleft"
        }
    }

    /// Next mode in the cycle, for the single toggle button.
    var next: PaneRenderMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Screen 3: read a pane's output and send input, rendered as a light terminal.
/// Output renders in one of three `PaneRenderMode`s (cycle button in the toolbar); an
/// iSH-style key bar (sticky Ctrl, Esc, arrows) rides above the keyboard. Grid
/// modes read the raw hard-wrapped grid (`recent`, with history; `visible` for
/// alt-screen TUIs); reader reads `recent_unwrapped`.
struct PaneView: View {
    @Environment(SessionModel.self) private var session
    let paneID: PaneID

    @State private var input: String = ""
    @State private var ctrlActive = false
    @AppStorage("paneRenderMode") private var mode: PaneRenderMode = .fit
    /// Readable font size for Scroll/Reader modes (Fit auto-sizes, so it's exempt).
    @AppStorage("paneFontSize") private var fontSize: Double = 13
    /// Raw terminal grid lines for the `fit`/`scroll` modes (uncleaned `recent`).
    @State private var gridLines: [String] = []
    /// Whether the scroll view is parked near the bottom — gates auto-stick so new
    /// output doesn't yank the user off history they've scrolled up to read.
    @State private var isPinned = true
    /// Bumped on every accepted key/send to drive one-shot haptic feedback.
    @State private var hapticTick = 0
    @FocusState private var inputFocused: Bool

    private var pane: Pane? { session.pane(paneID) }
    private var lines: [String] { session.outputs[paneID] ?? [] }
    /// Monospace advance ≈ 0.6em for the system monospaced font.
    // ponytail: fixed ratio, not measured — fine for SF Mono; revisit if a
    // proportional or CJK-heavy font ever sneaks in.
    private let monoAdvance = 0.6

    var body: some View {
        VStack(spacing: 0) {
            content
            Rectangle()
                .fill(Theme.terminalDim.opacity(0.18))
                .frame(height: 1)
            if inputFocused {
                keyControlBar
            }
            inputBar
        }
        .background(Theme.terminalBG, ignoresSafeAreaEdges: .bottom)
        .sensoryFeedback(.impact(weight: .light), trigger: hapticTick)
        .navigationTitle(pane?.title ?? paneID.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if mode != .fit { fontSizeButtons }
                modeButton
                if let pane, pane.isAgent {
                    StatusTag(status: pane.status)
                }
            }
        }
        // Keep the pane live by re-reading whenever it emits new output. The
        // socket API pushes no pane-output events, but `pane.wait_for_output`
        // lets us block until the screen changes (or the wait times out) instead
        // of polling on a fixed timer — instant on activity, quiet while idle.
        // Re-keyed on `mode` so flipping modes re-reads the right source. `.task`
        // cancels on disappear / id change.
        .task(id: pollKey) {
            while !Task.isCancelled {
                if mode == .reader {
                    await session.refreshPaneDisplay(for: paneID, isAgent: pane?.isAgent == true)
                    await session.awaitOutput(for: paneID, source: PaneReadSource.recentUnwrapped)
                } else {
                    let fresh = await session.rawTerminal(for: paneID)
                    if Task.isCancelled { return } // don't clobber a newer pane/mode's grid
                    // Keep the last good grid only on a read *failure* (nil), as
                    // Reader does via its `outputs[pane]` fallback — but let a
                    // genuinely empty screen through so a cleared pane isn't pinned.
                    if let fresh { gridLines = fresh }
                    // Wait on `recent` — the source the grid now reads — so new
                    // scrollback wakes us. (Alt-screen panes, served from `visible`,
                    // just fall back to the wait's timeout poll.)
                    await session.awaitOutput(for: paneID, source: PaneReadSource.recent)
                }
            }
        }
    }

    /// Restart the read loop when the pane or render mode changes — each mode
    /// reads a different `pane.read` source.
    private var pollKey: String { "\(paneID.rawValue)|\(mode.rawValue)" }

    /// Single toolbar button that cycles fit → scroll → reader, replacing the
    /// space-hungry segmented control. Shows the current mode so the next tap is
    /// predictable.
    private var modeButton: some View {
        Button { mode = mode.next } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.icon)
                Text(mode.label)
            }
            .font(Theme.mono(11, .semibold))
        }
        .tint(Theme.prompt)
        .accessibilityLabel("Layout: \(mode.label). Tap to change.")
    }

    /// A−/A+ pair for the Scroll/Reader font, clamped to a legible range.
    private var fontSizeButtons: some View {
        HStack(spacing: 2) {
            Button { fontSize = max(9, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                .disabled(fontSize <= 9)
                .accessibilityLabel("Smaller text")
            Button { fontSize = min(22, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                .disabled(fontSize >= 22)
                .accessibilityLabel("Larger text")
        }
        .tint(Theme.prompt)
    }

    /// The user-sized monospace face for Scroll/Reader.
    private var paneFont: Font { .system(size: fontSize, design: .monospaced) }

    /// Background probe: the content's bottom edge sits at/above the viewport
    /// bottom (plus an 80pt slack) ⇒ we're pinned. Lives in `.background` so it's
    /// always measured regardless of lazy realization.
    private func pinReader(viewportHeight: CGFloat) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: PinnedToBottomKey.self,
                value: geo.frame(in: .named(scrollSpace)).maxY <= viewportHeight + 80
            )
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .fit: fitGrid
        case .scroll: scrollGrid
        case .reader: scrollback
        }
    }

    private var scrollback: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                // Mobile transcript: cleaned output (frames stripped) wraps
                // vertically — no horizontal scroll. Color preserved.
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if lines.isEmpty {
                            Text("— no output yet —")
                                .font(paneFont)
                                .foregroundStyle(Theme.terminalDim)
                        }
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.ansiAttributed(defaultColor: Theme.terminalText, surface: Theme.terminalBG))
                                .font(paneFont)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .padding(14)
                    .background(pinReader(viewportHeight: geo.size.height))
                }
                .background(Theme.terminalBG)
                .coordinateSpace(.named(scrollSpace))
                .onPreferenceChange(PinnedToBottomKey.self) { isPinned = $0 }
                .onChange(of: lines.count) {
                    if isPinned { withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) } }
                }
                .onAppear { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
        }
    }

    /// Fit mode: the raw grid with the font auto-shrunk so the widest line fits
    /// the screen — vertical scroll only, no horizontal pan. Faithful layout,
    /// small font at high column counts (≈7–8pt at 80 cols on a phone).
    private var fitGrid: some View {
        GeometryReader { geo in
            // Size the font from the widest line so cols * advance * size fits.
            // 0.97 leaves a hair of slack against advance-ratio error.
            // ponytail: Character count, not terminal display width — CJK/emoji
            // (width 2) would under-count and overflow slightly. Agent TUIs are
            // overwhelmingly width-1 box/ASCII; add a wcwidth pass if that breaks.
            let cols = max(1, gridLines.map { TerminalText.stripANSI($0).count }.max() ?? 1)
            // Floor at 4pt (not 5) so a ~124-col agent grid fits the width fully
            // instead of clipping its last chars — small is the point of Fit.
            let size = max(4, min(15, (geo.size.width - 28) * 0.97 / (Double(cols) * monoAdvance)))
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    // Eager VStack — the grid is bounded (a few hundred rows at
                    // most) so lazy layout buys nothing and complicates sizing.
                    VStack(alignment: .leading, spacing: 0) {
                        gridPlaceholder
                        ForEach(Array(gridLines.enumerated()), id: \.offset) { _, line in
                            // One uniform size for every row keeps columns aligned —
                            // no per-row minimumScaleFactor (it would scale wide rows
                            // independently and break the grid). A pathologically wide
                            // line truncates rather than shrinking out of alignment.
                            Text(line.ansiAttributed(defaultColor: Theme.terminalText, surface: Theme.terminalBG))
                                .font(.system(size: size, design: .monospaced))
                                .lineLimit(1)
                        }
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .padding(14)
                    .background(pinReader(viewportHeight: geo.size.height))
                }
                .coordinateSpace(.named(scrollSpace))
                .onPreferenceChange(PinnedToBottomKey.self) { isPinned = $0 }
                .onChange(of: gridLines.count) {
                    if isPinned { withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) } }
                }
            }
        }
        .background(Theme.terminalBG)
    }

    /// Scroll mode: the raw grid at a fixed readable font, panned in both axes —
    /// the faithful terminal view (what the agent's screen literally looks like).
    private var scrollGrid: some View {
        ScrollView([.vertical, .horizontal]) {
            // Eager VStack, spacing 0 so multi-row ANSI backgrounds tile without
            // gaps. (LazyVStack also mis-measures width inside a two-axis
            // ScrollView, so eager is the safe choice here regardless.)
            VStack(alignment: .leading, spacing: 0) {
                gridPlaceholder
                ForEach(Array(gridLines.enumerated()), id: \.offset) { _, line in
                    Text(line.ansiAttributed(defaultColor: Theme.terminalText, surface: Theme.terminalBG))
                        .font(paneFont)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(14)
        }
        .background(Theme.terminalBG)
    }

    @ViewBuilder private var gridPlaceholder: some View {
        if gridLines.isEmpty {
            Text("— no output yet —")
                .font(Theme.monospaced)
                .foregroundStyle(Theme.terminalDim)
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
            keyButton("return", sends: "Enter")
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
    private let scrollSpace = "herdr.pane.scroll"

    /// Send a bar key, applying a pending sticky Ctrl as `ctrl+<key>`.
    private func sendBarKey(_ key: String) {
        let resolved = ctrlActive ? "ctrl+\(key.lowercased())" : key
        ctrlActive = false
        hapticTick += 1
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
        hapticTick += 1
        let combo = "ctrl+\(String(ch).lowercased())"
        Task { await session.sendKeys(combo, to: paneID) }
    }

    private func send() {
        let text = input
        input = ""
        hapticTick += 1
        Task { await session.submit(text, to: paneID) }
    }
}

/// Reports whether a vertical scroll view is parked near its bottom. Read from a
/// `.background` GeometryReader (always laid out, unlike a lazy child sentinel) so
/// it stays correct even when the bottom row is recycled out of a `LazyVStack`.
private struct PinnedToBottomKey: PreferenceKey {
    static let defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

extension String {
    /// Parse ANSI SGR sequences — fg/bg (16-color, 256-color, 24-bit truecolor),
    /// inverse video, and dim — into an `AttributedString`, dropping every other
    /// escape (cursor moves, erase, …). Renders both foreground and background so
    /// filled/inverse regions (e.g. an agent's block-art logo) look right.
    /// `defaultColor` is the fallback fg; `surface` is the terminal background,
    /// used to resolve inverse video. Bold is not weight-rendered.
    func ansiAttributed(defaultColor: Color, surface: Color) -> AttributedString {
        guard contains("\u{1B}") else {
            var plain = AttributedString(self)
            plain.foregroundColor = defaultColor
            return plain
        }
        // Match the full CSI parameter range (`[0-?]`, incl. private `?`) so a
        // non-SGR sequence like ESC[?25l is consumed, not rendered literally.
        // Style is only applied when the final byte is `m` (see below).
        let pattern = "\u{1B}\\[([0-?]*)([ -/]*[@-~])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            var plain = AttributedString(TerminalText.stripANSI(self))
            plain.foregroundColor = defaultColor
            return plain
        }
        let ns = self as NSString
        var out = AttributedString()
        var cursor = 0
        var style = ANSIStyle()

        func appendText(_ s: String) {
            guard !s.isEmpty else { return }
            var seg = AttributedString(s)
            let (fg, bg) = style.resolved(defaultFg: defaultColor, surface: surface)
            seg.foregroundColor = fg
            if let bg { seg.backgroundColor = bg }
            out.append(seg)
        }

        regex.enumerateMatches(in: self, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            if match.range.location > cursor {
                appendText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            cursor = match.range.location + match.range.length
            // Only SGR ('m') affects style; other final bytes are consumed and dropped.
            guard ns.substring(with: match.range(at: 2)) == "m" else { return }
            style.applySGR(ns.substring(with: match.range(at: 1)))
        }
        if cursor < ns.length { appendText(ns.substring(from: cursor)) }
        return out
    }
}

/// Mutable SGR style state accumulated while scanning a line: foreground,
/// background, inverse, and dim. `nil` fg/bg mean "use the defaults".
private struct ANSIStyle {
    var fg: Color?
    var bg: Color?
    var inverse = false
    var dim = false

    /// Resolve to a concrete (foreground, optional background) for a run —
    /// applying inverse (swap fg/bg, defaulting bg to the surface) and dim (fade).
    func resolved(defaultFg: Color, surface: Color) -> (Color, Color?) {
        var f = inverse ? (bg ?? surface) : (fg ?? defaultFg)
        let b: Color? = inverse ? (fg ?? defaultFg) : bg
        if dim { f = f.opacity(0.55) }
        return (f, b)
    }

    mutating func applySGR(_ params: String) {
        // Keep empty fields (`ESC[31;m` → 31 then an empty reset param == 0).
        let codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        if codes.isEmpty { self = ANSIStyle(); return } // bare ESC[m == reset
        var i = 0
        while i < codes.count {
            let c = codes[i]
            switch c {
            case 0: self = ANSIStyle()
            case 1: dim = false             // bold: not weight-rendered, but clears dim
            case 2: dim = true
            case 22: dim = false
            case 7: inverse = true
            case 27: inverse = false
            case 30...37: fg = ANSIColor.palette[c - 30]
            case 90...97: fg = ANSIColor.palette[8 + (c - 90)]
            case 39: fg = nil
            case 40...47: bg = ANSIColor.palette[c - 40]
            case 100...107: bg = ANSIColor.palette[8 + (c - 100)]
            case 49: bg = nil
            // On a malformed/truncated 38/48 spec, consume the rest rather than
            // letting a stray operand (e.g. the `2` in `ESC[38;2m`) act as an SGR.
            case 38: if let (col, adv) = ANSIColor.extended(codes, i) { fg = col; i += adv } else { i = codes.count }
            case 48: if let (col, adv) = ANSIColor.extended(codes, i) { bg = col; i += adv } else { i = codes.count }
            default: break
            }
            i += 1
        }
    }
}

/// ANSI SGR color resolution, tuned to stay legible on the light terminal
/// background.
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

    /// Parse an extended-color spec (`38/48;5;n` or `38/48;2;r;g;b`) where `i` is
    /// the `38`/`48` index. Returns the color and how many extra codes it consumed.
    /// Truecolor is used verbatim (not palette-darkened) so e.g. a `0;0;0` logo
    /// background renders truly black.
    static func extended(_ codes: [Int], _ i: Int) -> (Color, Int)? {
        if i + 2 < codes.count, codes[i + 1] == 5 {
            let n = codes[i + 2]
            return (0...255).contains(n) ? (from256(n), 2) : nil
        } else if i + 4 < codes.count, codes[i + 1] == 2 {
            return (Color(.sRGB,
                          red: Double(codes[i + 2]) / 255,
                          green: Double(codes[i + 3]) / 255,
                          blue: Double(codes[i + 4]) / 255), 4)
        }
        return nil
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
