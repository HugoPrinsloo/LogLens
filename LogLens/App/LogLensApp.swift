import SwiftUI

@main
struct LogLensApp: App {
    @State private var store = EventStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Capture") {
                Button(store.isCapturing ? "Stop Capture" : "Start Capture") { store.toggleCapture() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Clear Events") { store.clear() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
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
        }
    }
}
