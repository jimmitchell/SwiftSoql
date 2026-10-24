import SwiftUI

/// One explorer window: the login screen until connected, then the explorer.
struct ContentView: View {
    @State private var model = ExplorerModel()

    var body: some View {
        Group {
            if let session = model.session {
                VStack(spacing: 8) {
                    Text("Connected to \(session.displayName)")
                        .font(.title2)
                    Text(model.statusText)
                        .foregroundStyle(.secondary)
                    Button("Disconnect") { model.disconnect() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(session.displayName)
                .navigationSubtitle(session.instanceURL.host() ?? "")
            } else {
                LoginView(model: model)
                    .navigationTitle("SwiftSoql")
            }
        }
        .alert(item: $model.error) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
    }
}

#Preview {
    ContentView()
}
