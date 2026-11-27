import SwiftUI

@main
struct HarnessApp: App {
    @State private var model = HarnessModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            // A scan needs the app in the foreground; note when it leaves, to explain a jam or a lock.
            if phase != .active, model.isScanning { model.log("app went to the background (\(phase)) while scanning") }
        }
    }
}
