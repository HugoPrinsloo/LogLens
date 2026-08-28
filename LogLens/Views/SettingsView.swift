import SwiftUI

struct SettingsView: View {
    @Environment(EventStore.self) private var store
    @Environment(NetworkStore.self) private var network

    var body: some View {
        @Bindable var store = store
        @Bindable var network = network
        Form {
            Section("Capture") {
                Picker("Scope", selection: $store.scope) {
                    ForEach(CaptureScope.allCases) { Text($0.title).tag($0) }
                }
                Text(store.scope.help).font(.caption).foregroundStyle(.secondary)

                if store.scope == .custom {
                    TextField("Predicate", text: $store.customPredicate, prompt: Text(#"subsystem == "com.example.app""#), axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2...6)
                }

                Picker("Minimum level", selection: $store.captureLevel) {
                    Text("Debug (everything)").tag(LogLevel.debug)
                    Text("Info").tag(LogLevel.info)
                    Text("Default").tag(LogLevel.notice)
                }
                Text("Info and debug messages are only visible while streaming live, which is exactly what LogLens does.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Buffer") {
                Picker("Keep at most", selection: $store.maxEntries) {
                    Text("10,000 events").tag(10_000)
                    Text("50,000 events").tag(50_000)
                    Text("100,000 events").tag(100_000)
                    Text("250,000 events").tag(250_000)
                }
            }

            Section("Network Proxy") {
                Picker("Decrypt TLS for", selection: $network.policy) {
                    ForEach(DecryptPolicy.allCases) { Text($0.title).tag($0) }
                }
                Text("Simulator apps trust the LogLens certificate automatically. Decrypting Mac traffic needs the certificate trusted in your login keychain (Trust on This Mac…).")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Proxy port", value: $network.port, format: .number.grouping(.never))
                    .disabled(network.isCapturing)
                HStack {
                    Button("Reinstall Certificate in Simulators") { Task { await network.reinstallCertificate() } }
                    Button("Trust on This Mac…") { Task { await network.trustOnThisMac() } }
                    Button("Reveal Certificate") {
                        if !network.caPath.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: network.caPath)]) }
                    }
                    .disabled(network.caPath.isEmpty)
                }
                .controlSize(.small)
                HStack {
                    Text("Pinned hosts (tunnelled, not decrypted): \(network.bypassHosts.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget Pinned Hosts") { network.clearBypassHosts() }
                        .controlSize(.small)
                        .disabled(network.bypassHosts.isEmpty)
                }
                if !network.caPath.isEmpty {
                    Text(network.caPath).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }

            Section("Command") {
                Text(store.commandPreview)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}
