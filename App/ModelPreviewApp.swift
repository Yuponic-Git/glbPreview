import SwiftUI

@main
struct ModelPreviewApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Text("Model Preview is installed")
                    .font(.headline)
                Text("Select a .glb or .fbx file in Finder and press Space.")
                    .foregroundStyle(.secondary)
            }
            .padding(32)
        }
        .windowResizability(.contentSize)
    }
}
