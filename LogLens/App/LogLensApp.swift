import SwiftUI

@main
struct LogLensApp: App {
    @State private var store: EventStore
    @State private var network: NetworkStore
    @State private var updates = UpdateChecker()

    init() {
        let store = EventStore()
        let network = NetworkStore()
        // One recording: Record starts the log stream and the proxy together, and finished HTTP
        // transactions become entries in the same table/timeline.
        store.network = network
        network.onFinished = { [weak store] tx in store?.appendNetwork(tx) }
        _store = State(initialValue: store)
        _network = State(initialValue: network)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(network)
                .environment(updates)
                .frame(minWidth: 1000, minHeight: 600)
                .task { updates.checkOnLaunchIfDue() }
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkNow() }
                    .disabled(updates.isChecking)
            }
            CommandMenu("Capture") {
                Button(store.isCapturing ? "Stop Recording" : "Record") { store.toggleCapture() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Clear Events") { store.clear() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Heal Network Connection") { Task { await network.repair() } }
                    .disabled(!store.isCapturing || !store.captureNetwork || network.isStarting)
                Divider()
                Toggle("Capture HTTP(S) Requests", isOn: Binding(get: { store.captureNetwork }, set: { store.captureNetwork = $0 }))
                Toggle("Auto-scroll to Newest", isOn: Binding(get: { store.autoScroll }, set: { store.autoScroll = $0 }))
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Star Selected") { if let id = store.selection { store.toggleStar(id) } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.selection == nil)
                Button("Reset Filters") { store.resetFilter() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Toggle("Show Inspector", isOn: Binding(get: { store.showInspector }, set: { store.showInspector = $0 }))
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
