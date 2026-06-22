import SwiftUI

@main
struct LoadoutApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
    }
}

/// Switches between the connect screen and the connected session.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.phase {
        case .connected(let session):
            WorkspaceListView()
                .environment(session)
        default:
            ConnectView()
        }
    }
}
