import Foundation

/// One HTTP exchange (or an opaque CONNECT tunnel) observed by the proxy.
/// Value type; `id` is assigned by the proxy and is stable for the life of the capture.
struct NetworkTransaction: Identifiable, Hashable, Codable {
    typealias ID = Int

    enum State: String, Codable {
        case pending      // request seen, response not complete
        case completed    // response fully received
        case failed       // upstream/TLS/network error
    }

    struct Header: Hashable, Codable, Identifiable {
        var id: String { name + ":" + value }
        let name: String
        let value: String
    }

    let id: ID
    var startedAt: Date
    var endedAt: Date?
    var state: State = .pending

    // Request
    var method: String
    var scheme: String            // "http" | "https"
    var host: String
    var port: Int
    var path: String              // path + query, as sent
    var httpVersion: String = "HTTP/1.1"
    var requestHeaders: [Header] = []
    var requestBody: Data = Data()
    var requestBodyTruncated = false
    var requestBodySize = 0        // bytes actually on the wire (may exceed stored)

    // Response
    var statusCode: Int?
    var statusReason: String = ""
    var responseHeaders: [Header] = []
    var responseBody: Data = Data()
    var responseBodyTruncated = false
    var responseBodySize = 0

    // Attribution / transport
    var clientPID: Int32 = 0
    var clientProcess: String = ""     // executable name ("Over", "nsurlsessiond")
    var clientIsSimulator = false
    var isTunnel = false               // opaque CONNECT tunnel, not decrypted
    var isDecrypted = false            // TLS was intercepted
    var note: String?                  // e.g. why a tunnel was not decrypted
    var error: String?

    // MARK: Derived

    var url: String {
        let defaultPort = scheme == "https" ? 443 : 80
        let hostPort = port == defaultPort ? host : "\(host):\(port)"
        return "\(scheme)://\(hostPort)\(path)"
    }

    var pathOnly: String { path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path }
    var query: String? {
        guard let q = path.firstIndex(of: "?") else { return nil }
        return String(path[path.index(after: q)...])
    }

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }

    var isJSONResponse: Bool { responseContentType.contains("json") }
    var responseContentType: String { header("Content-Type", in: responseHeaders)?.lowercased() ?? "" }
    var requestContentType: String { header("Content-Type", in: requestHeaders)?.lowercased() ?? "" }
    var responseEncoding: String? { header("Content-Encoding", in: responseHeaders)?.lowercased() }
    var requestEncoding: String? { header("Content-Encoding", in: requestHeaders)?.lowercased() }

    func header(_ name: String, in headers: [Header]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Short human summary for the status column.
    var statusText: String {
        if let error { return error.isEmpty ? "Failed" : "Failed" }
        if let statusCode { return String(statusCode) }
        return isTunnel ? "Tunnel" : "…"
    }
}
