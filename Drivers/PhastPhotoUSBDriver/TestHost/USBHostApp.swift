import SwiftUI

/// A minimal iPad app that embeds the PhastPhoto USB driver and exercises it: is the driver running, INFO and
/// STATUS, and a scan of one stack. For on-device checks of the driver (roadmap 7.5), not an example UI.
@main
struct USBHostApp: App {
    @StateObject private var check = USBCheck()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section {
                        Text(check.driverBundleID).font(.footnote.monospaced())
                        Button("Is the driver running?") { check.run(.presence) }
                        Button("INFO and STATUS over USB") { check.run(.info) }
                        Button("Scan one stack over USB (single-sided, face down)") { check.run(.scan) }
                        Button("Scan one stack over USB (duplex, face up)") { check.run(.duplex) }
                    } footer: {
                        Text("Turn the driver on in Settings > General > Drivers (or Settings > PhastPhoto USB > Drivers), then connect the scanner.")
                    }
                    Section("Log") {
                        ForEach(Array(check.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.footnote.monospaced())
                        }
                    }
                }
                .navigationTitle("PhastPhoto USB")
                .disabled(check.running)
            }
            .task { check.autorun() }
        }
    }
}
