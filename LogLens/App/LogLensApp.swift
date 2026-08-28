import SwiftUI

@main
struct LogLensApp: App {
    @State private var store: EventStore
    @State private var network: NetworkStore

    init() {
        let store = EventStore()
        let network = NetworkStore()
        // Finished HTTP transactions become entries in the log table/timeline too.
        network.onFinished = { [weak store] tx in store?.appendNetwork(tx) }
        _store = State(initialValue: store)
        _network = State(initialValue: network)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(network)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Capture") {
                // ⌘R / ⌘K act on whichever inspector is showing: logs, or the network proxy.
                if store.viewMode == .network {
                    Button(network.isCapturing ? "Stop Network Capture" : "Start Network Capture") { network.toggleCapture() }
                        .keyboardShortcut("r", modifiers: .command)
                    Button("Clear Requests") { network.clear() }
                        .keyboardShortcut("k", modifiers: .command)
                } else {
                    Button(store.isCapturing ? "Stop Capture" : "Start Capture") { store.toggleCapture() }
                        .keyboardShortcut("r", modifiers: .command)
                    Button("Clear Events") { store.clear() }
                        .keyboardShortcut("k", modifiers: .command)
                }
                Divider()
                Toggle("Auto-scroll to Newest", isOn: Binding(
                    get: { store.viewMode == .network ? network.autoScroll : store.autoScroll },
                    set: { if store.viewMode == .network { network.autoScroll = $0 } else { store.autoScroll = $0 } }
                ))
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Star Selected") { if let id = store.selection { store.toggleStar(id) } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.selection == nil)
                Button("Reset Filters") { store.resetFilter() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Toggle("Show Inspector", isOn: Binding(
                    get: { store.viewMode == .network ? network.showInspector : store.showInspector },
                    set: { if store.viewMode == .network { network.showInspector = $0 } else { store.showInspector = $0 } }
                ))
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(network)
        }
    }
}
