import SwiftUI

@main
struct KeepyUppyApp: App {
    var body: some Scene {
        MenuBarExtra("Keepy Uppy", systemImage: "balloon") {
            Text("Keepy Uppy is starting up…")
        }
        .menuBarExtraStyle(.menu)
    }
}
