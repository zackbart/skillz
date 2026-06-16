import SwiftUI

@main
struct SkillzApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Skills") { state.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
