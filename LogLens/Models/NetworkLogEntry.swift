import Foundation

/// The bits of a transaction a timeline card needs to render itself (kept small so exports stay sane).
struct NetworkCardData: Hashable, Codable {
    var method: String
    var statusCode: Int?
    var statusReason: String
    var failed: Bool
    var isTunnel: Bool
    var requestBody: String?      // decoded + pretty-printed text, capped
    var requestContent: String    // "json", "form", …
    var responseBody: String?
    var responseContent: String
    var requestSize: Int
    var responseSize: Int

    static let bodyCap = 64 * 1024

    var isSuccess: Bool { !failed && (statusCode ?? 0) < 400 }
    var outcomeText: String {
        if failed && statusCode == nil { return isTunnel ? "Tunnel" : "Failed" }
        if let code = statusCode { return String(code) }
        return isTunnel ? "Tunnel" : "—"
    }
}

/// Turns a finished proxy transaction into a `LogEntry` so it can ride the same pipeline as log events
/// (table, timeline, lanes, facets). IDs live in their own range so they never collide with `log stream` IDs.
extension LogEntry {
    static let networkIDBase = 1_000_000_000
    static let networkSubsystem = "Network"

    static func network(_ tx: NetworkTransaction) -> LogEntry {
        let status: String
        if let code = tx.statusCode { status = tx.statusReason.isEmpty ? String(code) : "\(code) \(tx.statusReason)" }
        else if tx.isTunnel { status = "Tunnel" }
        else { status = "Failed" }

        var fields: [ParsedMessage.Field] = [
            .init(id: 1, key: "Action", value: tx.method),
            .init(id: 2, key: "Status", value: status),
        ]
        if !tx.isTunnel {
            fields.append(.init(id: 3, key: "Duration", value: NetworkStyle.duration(tx.duration)))
            fields.append(.init(id: 4, key: "Size", value: "↑ \(NetworkStyle.bytes(tx.requestBodySize))  ↓ \(NetworkStyle.bytes(tx.responseBodySize))"))
        }
        fields.append(.init(id: 5, key: "Host", value: tx.host))
        if !tx.isTunnel { fields.append(.init(id: 6, key: "Path", value: tx.pathOnly)) }
        if let q = tx.query, !q.isEmpty { fields.append(.init(id: 7, key: "Query", value: q.removingPercentEncoding ?? q)) }
        let type = NetworkStyle.shortType(tx.responseContentType)
        if !type.isEmpty { fields.append(.init(id: 8, key: "Content", value: type)) }   // not "Type": that key drives the event-type badge
        if let error = tx.error { fields.append(.init(id: 9, key: "Error", value: error)) }
        if let note = tx.note { fields.append(.init(id: 10, key: "Note", value: note)) }

        // Decoded, pretty-printed bodies for the card's body boxes (and for search via `message`).
        func bodyText(_ data: Data, encoding: String?, contentType: String) -> String? {
            guard !data.isEmpty else { return nil }
            let decoded = BodyDecoder.decode(data, contentEncoding: encoding).data
            guard let text = BodyDecoder.prettyJSON(decoded) ?? (BodyDecoder.isProbablyText(decoded, contentType: contentType) ? String(data: decoded, encoding: .utf8) : nil) else { return nil }
            return text.utf8.count > NetworkCardData.bodyCap ? String(text.prefix(NetworkCardData.bodyCap)) + "\n… truncated" : text
        }
        let card = NetworkCardData(
            method: tx.method,
            statusCode: tx.statusCode,
            statusReason: tx.statusReason,
            failed: tx.state == .failed,
            isTunnel: tx.isTunnel,
            requestBody: bodyText(tx.requestBody, encoding: tx.requestEncoding, contentType: tx.requestContentType),
            requestContent: NetworkStyle.shortType(tx.requestContentType),
            responseBody: bodyText(tx.responseBody, encoding: tx.responseEncoding, contentType: tx.responseContentType),
            responseContent: type,
            requestSize: tx.requestBodySize,
            responseSize: tx.responseBodySize
        )
        var freeText: [String] = []
        if let r = card.requestBody { freeText.append("↑ Request body"); freeText.append(r) }
        if let r = card.responseBody { freeText.append("↓ Response body"); freeText.append(r) }

        let title = tx.isTunnel ? "CONNECT \(tx.host)" : "\(tx.method) \(tx.host)\(tx.pathOnly)"
        let summary = tx.isTunnel ? (tx.note ?? "TLS tunnel") : "\(status) · \(NetworkStyle.duration(tx.duration)) · ↓ \(NetworkStyle.bytes(tx.responseBodySize))"
        let level: LogLevel
        if tx.state == .failed || (tx.statusCode ?? 0) >= 500 { level = .error }
        else if (tx.statusCode ?? 0) >= 400 { level = .notice }
        else { level = .info }

        return LogEntry(
            id: networkIDBase + tx.id,
            timestamp: tx.startedAt,
            level: level,
            process: tx.clientProcess.isEmpty ? "?" : tx.clientProcess,
            processPath: "",
            processID: Int(tx.clientPID),
            threadID: 0,
            sender: "LogLens Proxy",
            subsystem: networkSubsystem,
            category: tx.host,
            message: ([title + " → " + summary] + freeText).joined(separator: "\n"),
            activityID: nil,
            traceID: nil,
            sourceName: "Proxy",
            // freeText stays empty: the card renders `network` bodies itself; the inspector shows `message`.
            parsed: ParsedMessage(title: title, summary: summary, fields: fields, groups: [], freeText: []),
            isNetwork: true,
            network: card
        )
    }
}
