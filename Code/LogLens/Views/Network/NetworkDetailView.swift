import SwiftUI

/// Inspector for a network row: the full transaction with headers and raw bodies.
struct NetworkDetailView: View {
    let tx: NetworkTransaction

    var body: some View {
        TransactionDetail(tx: tx).id(tx.id)
    }
}

private enum DetailTab: String, CaseIterable, Identifiable {
    case response, request, overview
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private struct TransactionDetail: View {
    let tx: NetworkTransaction
    @State private var tab: DetailTab = .response

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .response: responseTab
                    case .request: requestTab
                    case .overview: overviewTab
                    }
                }
                .padding(16)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Menu {
                    Button("Copy URL") { Pasteboard.copy(tx.url) }
                    Button("Copy as cURL") { Pasteboard.copy(tx.curlCommand) }
                    Button("Copy Response Body") { Pasteboard.copy(tx.decodedResponseText ?? "") }.disabled(tx.responseBody.isEmpty)
                    Button("Copy Request Body") { Pasteboard.copy(tx.decodedRequestText ?? "") }.disabled(tx.requestBody.isEmpty)
                } label: { Image(systemName: "doc.on.doc") }
                .help("Copy")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MethodBadge(method: tx.method)
                StatusBadge(tx: tx)
                if tx.isDecrypted {
                    Label("Decrypted", systemImage: "lock.open").font(.caption2).foregroundStyle(.tertiary).labelStyle(.titleAndIcon)
                }
            }
            Text(tx.isTunnel ? "\(tx.host):\(tx.port)" : tx.url)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Image(systemName: tx.clientIsSimulator ? "iphone" : "desktopcomputer").foregroundStyle(.secondary)
                Text(tx.clientProcess.isEmpty ? "unknown app" : tx.clientProcess).fontWeight(.medium)
                Text("·").foregroundStyle(.tertiary)
                Text(NetworkStyle.duration(tx.duration)).monospacedDigit()
                if !tx.isTunnel {
                    Text("·").foregroundStyle(.tertiary)
                    Text("↑ \(NetworkStyle.bytes(tx.requestBodySize))  ↓ \(NetworkStyle.bytes(tx.responseBodySize))").monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Text(Formatters.fullMillis.string(from: tx.startedAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            if let error = tx.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: Tabs

    @ViewBuilder private var responseTab: some View {
        if tx.isTunnel {
            Text(tx.note ?? "Opaque TLS tunnel — LogLens did not decrypt this connection.").foregroundStyle(.secondary)
        } else if tx.statusCode == nil && tx.state == .pending {
            HStack { ProgressView().controlSize(.small); Text("Waiting for response…").foregroundStyle(.secondary) }
        } else if tx.statusCode == nil {
            Text("No response — the request failed before the server answered.").foregroundStyle(.secondary)
        } else {
            NetworkSection(title: "Headers", symbol: "list.bullet.rectangle", trailing: "\(tx.responseHeaders.count)") {
                HeaderGrid(headers: tx.responseHeaders)
            }
            NetworkSection(title: "Body", symbol: "doc.text", trailing: NetworkStyle.bytes(tx.responseBodySize)) {
                BodyView(data: tx.responseBody, contentType: tx.responseContentType, contentEncoding: tx.responseEncoding, truncated: tx.responseBodyTruncated, onWire: tx.responseBodySize)
            }
        }
    }

    @ViewBuilder private var requestTab: some View {
        if tx.isTunnel {
            Text("CONNECT \(tx.host):\(tx.port)").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
        } else {
            if let q = tx.query, !q.isEmpty {
                NetworkSection(title: "Query", symbol: "questionmark.circle", trailing: "\(queryFields(q).count)") {
                    KeyValueGrid(fields: queryFields(q))
                }
            }
            NetworkSection(title: "Headers", symbol: "list.bullet.rectangle", trailing: "\(tx.requestHeaders.count)") {
                HeaderGrid(headers: tx.requestHeaders)
            }
            NetworkSection(title: "Body", symbol: "doc.text", trailing: NetworkStyle.bytes(tx.requestBodySize)) {
                BodyView(data: tx.requestBody, contentType: tx.requestContentType, contentEncoding: tx.requestEncoding, truncated: tx.requestBodyTruncated, onWire: tx.requestBodySize)
            }
        }
    }

    private var overviewTab: some View {
        NetworkSection(title: "Summary", symbol: "info.circle") {
            KeyValueGrid(fields: overviewFields)
        }
    }

    private var overviewFields: [ParsedMessage.Field] {
        var f: [ParsedMessage.Field] = [
            .init(id: 1, key: "URL", value: tx.url),
            .init(id: 2, key: "Method", value: tx.method),
            .init(id: 3, key: "Status", value: tx.statusCode.map { "\($0) \(tx.statusReason)" } ?? (tx.state == .failed ? "Failed" : "Pending")),
            .init(id: 4, key: "App", value: tx.clientProcess.isEmpty ? "unknown" : "\(tx.clientProcess) (pid \(tx.clientPID))\(tx.clientIsSimulator ? " · simulator" : " · Mac")"),
            .init(id: 5, key: "Transport", value: tx.isTunnel ? "TLS tunnel, not decrypted" : (tx.isDecrypted ? "HTTPS, decrypted by LogLens" : "HTTP")),
            .init(id: 6, key: "Started", value: Formatters.fullMillis.string(from: tx.startedAt)),
            .init(id: 7, key: "Duration", value: NetworkStyle.duration(tx.duration)),
            .init(id: 8, key: "Request", value: "\(NetworkStyle.bytes(tx.requestBodySize))\(tx.requestBodyTruncated ? " (stored copy truncated)" : "")"),
            .init(id: 9, key: "Response", value: "\(NetworkStyle.bytes(tx.responseBodySize))\(tx.responseBodyTruncated ? " (stored copy truncated)" : "")"),
        ]
        if !tx.responseContentType.isEmpty { f.append(.init(id: 10, key: "Content-Type", value: tx.responseContentType)) }
        if let enc = tx.responseEncoding { f.append(.init(id: 11, key: "Encoding", value: enc)) }
        if let error = tx.error { f.append(.init(id: 12, key: "Error", value: error)) }
        return f
    }

    private func queryFields(_ q: String) -> [ParsedMessage.Field] {
        q.split(separator: "&").enumerated().map { i, pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            return .init(id: i, key: kv.first ?? "", value: kv.count > 1 ? kv[1] : "")
        }
    }
}

private struct HeaderGrid: View {
    let headers: [NetworkTransaction.Header]
    var body: some View {
        if headers.isEmpty {
            Text("None").foregroundStyle(.tertiary)
        } else {
            KeyValueGrid(fields: headers.enumerated().map { .init(id: $0.offset, key: $0.element.name, value: $0.element.value) })
        }
    }
}

/// Body viewer: pretty JSON (toggle to raw), plain text, or a hex preview for binary payloads.
struct BodyView: View {
    let data: Data
    let contentType: String
    let contentEncoding: String?
    let truncated: Bool
    let onWire: Int
    @State private var pretty = true
    @State private var showAll = false

    private static let displayCap = 200 * 1024

    var body: some View {
        if data.isEmpty {
            Text(onWire > 0 ? "Body not stored." : "No body").foregroundStyle(.tertiary)
        } else {
            let decoded = BodyDecoder.decode(data, contentEncoding: contentEncoding)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if decoded.wasCompressed {
                        Label(decoded.failed ? "Could not inflate \(contentEncoding ?? "")" : "Inflated from \(contentEncoding ?? "")", systemImage: "arrow.down.left.and.arrow.up.right")
                            .font(.caption).foregroundStyle(decoded.failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    }
                    if truncated {
                        Label("Truncated at \(NetworkStyle.bytes(data.count))", systemImage: "scissors").font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    if prettyJSON(decoded.data) != nil {
                        Picker("", selection: $pretty) {
                            Text("Pretty").tag(true)
                            Text("Raw").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 120)
                    }
                    Button { Pasteboard.copy(text(decoded.data) ?? "") } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy body")
                }
                content(decoded.data)
            }
        }
    }

    @ViewBuilder private func content(_ bytes: Data) -> some View {
        if let s = text(bytes) {
            let capped = !showAll && s.utf8.count > Self.displayCap
            let shown = capped ? String(s.prefix(Self.displayCap)) : s
            MonoBlock(text: shown)
            if capped {
                Button("Show all (\(NetworkStyle.bytes(s.utf8.count)))") { showAll = true }.controlSize(.small)
            }
        } else {
            let preview = bytes.prefix(256).map { String(format: "%02x", $0) }.joined(separator: " ")
            VStack(alignment: .leading, spacing: 6) {
                Text("Binary · \(NetworkStyle.bytes(bytes.count))\(contentType.isEmpty ? "" : " · \(contentType)")").foregroundStyle(.secondary).font(.callout)
                MonoBlock(text: preview + (bytes.count > 256 ? " …" : ""))
            }
        }
    }

    private func prettyJSON(_ bytes: Data) -> String? {
        guard bytes.count <= 8 * 1024 * 1024 else { return nil }
        return BodyDecoder.prettyJSON(bytes)
    }

    private func text(_ bytes: Data) -> String? {
        if pretty, let p = prettyJSON(bytes) { return p }
        guard BodyDecoder.isProbablyText(bytes, contentType: contentType) else { return nil }
        return String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }
}

private struct MonoBlock: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }
}

private struct NetworkSection<Content: View>: View {
    let title: String
    let symbol: String
    var trailing: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.tertiary) }
            }
            content()
        }
    }
}

// MARK: - Export helpers

extension NetworkTransaction {
    var decodedResponseText: String? {
        let d = BodyDecoder.decode(responseBody, contentEncoding: responseEncoding).data
        return BodyDecoder.prettyJSON(d) ?? String(data: d, encoding: .utf8)
    }

    var decodedRequestText: String? {
        let d = BodyDecoder.decode(requestBody, contentEncoding: requestEncoding).data
        return BodyDecoder.prettyJSON(d) ?? String(data: d, encoding: .utf8)
    }

    var curlCommand: String {
        var parts = ["curl", "-X", method, quote(url)]
        for h in requestHeaders where !["content-length", "host", "accept-encoding"].contains(h.name.lowercased()) {
            parts.append("-H")
            parts.append(quote("\(h.name): \(h.value)"))
        }
        if !requestBody.isEmpty {
            let d = BodyDecoder.decode(requestBody, contentEncoding: requestEncoding).data
            if let s = String(data: d, encoding: .utf8) {
                parts.append("--data-binary")
                parts.append(quote(s))
            }
        }
        return parts.joined(separator: " \\\n  ")
    }

    private func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
