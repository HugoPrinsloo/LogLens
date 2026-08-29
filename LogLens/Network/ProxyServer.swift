import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import os

/// Which clients get their TLS intercepted (everything else is tunnelled untouched).
enum DecryptPolicy: String, CaseIterable, Identifiable {
    case simulatorOnly, everything, nothing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .simulatorOnly: "Simulator apps only"
        case .everything: "Everything (needs Mac trust)"
        case .nothing: "Nothing (tunnel only)"
        }
    }
}

enum ProxyEvent {
    case began(NetworkTransaction)
    case updated(NetworkTransaction)
}

/// Local HTTP(S) forward proxy on 127.0.0.1 that records every exchange it sees.
/// CONNECT tunnels from simulator apps are terminated with a LogLens-signed leaf cert
/// and re-established upstream with HTTP/1.1, so both bodies are visible in the clear.
final class ProxyServer {

    static let log = Logger(subsystem: "com.hugoprinsloo.LogLens", category: "Proxy")
    static let maxStoredBody = 4 * 1024 * 1024

    let ca: CertificateAuthority
    var policy: DecryptPolicy
    /// Delivered on the main queue. For transactions that are no longer pending the matching timeline/table
    /// `LogEntry` is built first, on `entryQueue` (body inflate + pretty-print), so the main thread never does it.
    var onEvent: ((ProxyEvent, LogEntry?) -> Void)?
    /// Serial so events reach the main queue in emission order.
    private let entryQueue = DispatchQueue(label: "loglens.proxy.entries", qos: .userInitiated)

    private(set) var port: Int = 0
    private var group: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private let idLock = NSLock()
    private var nextID = 1

    /// Hosts that are tunnelled instead of decrypted: learned from pin rejections, or set by the user.
    /// Wildcards allowed ("*.push.apple.com"). Persisted by NetworkStore.
    private let bypassLock = NSLock()
    private var bypassHosts: Set<String> = []
    /// Called on the main queue whenever a host is added automatically.
    var onBypassLearned: ((String) -> Void)?
    /// Called on the main queue when a handshake is rejected before any decrypted request has succeeded —
    /// almost always "the simulator doesn't trust our CA" rather than pinning.
    var onTrustProblem: ((String) -> Void)?
    /// Set once any client completed a TLS handshake with a LogLens-minted certificate.
    private(set) var sawSuccessfulHandshake = false
    func noteSuccessfulHandshake() { sawSuccessfulHandshake = true }

    /// Apple services in the simulator that always pin; decrypting them only breaks them.
    static let builtInBypass: [String] = ["*.push.apple.com", "gsa.apple.com", "*.ls.apple.com", "*.icloud.com", "*.apple-cloudkit.com", "*.icloud-content.com"]

    func setBypassHosts(_ hosts: Set<String>) { bypassLock.lock(); bypassHosts = hosts; bypassLock.unlock() }
    func addBypassHost(_ host: String) { bypassLock.lock(); bypassHosts.insert(host.lowercased()); bypassLock.unlock() }
    func removeBypassHost(_ host: String) { bypassLock.lock(); bypassHosts.remove(host.lowercased()); bypassLock.unlock() }

    func isBypassed(_ host: String) -> Bool {
        let h = host.lowercased()
        bypassLock.lock(); defer { bypassLock.unlock() }
        if bypassHosts.contains(h) { return true }
        for pattern in bypassHosts + Self.builtInBypass where pattern.hasPrefix("*.") {
            let suffix = pattern.dropFirst(1)   // ".push.apple.com"
            if h.hasSuffix(suffix) || h == suffix.dropFirst() { return true }
        }
        return Self.builtInBypass.contains(h)
    }

    /// A client rejected our certificate for `host`. If decryption has worked for other hosts, this one pins →
    /// tunnel it from now on. If nothing has ever succeeded, the CA probably isn't trusted at all.
    func learnPinned(host: String) {
        guard sawSuccessfulHandshake else {
            DispatchQueue.main.async { [onTrustProblem] in onTrustProblem?(host) }
            return
        }
        let h = host.lowercased()
        bypassLock.lock()
        let isNew = bypassHosts.insert(h).inserted
        bypassLock.unlock()
        if isNew {
            Self.log.notice("\(h, privacy: .public) rejected the LogLens certificate; tunnelling it from now on")
            DispatchQueue.main.async { [onBypassLearned] in onBypassLearned?(h) }
        }
    }

    init(ca: CertificateAuthority, policy: DecryptPolicy) {
        self.ca = ca
        self.policy = policy
    }

    var isRunning: Bool { serverChannel != nil }

    func start(port: Int) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { [weak self] channel in
                // The server can be stopped while accepted connections are still draining; never touch a dead one.
                guard let self else { return channel.close() }
                return channel.pipeline.configureHTTPServerPipeline(
                    withPipeliningAssistance: true,
                    withErrorHandling: false,
                    withOutboundHeaderValidation: false
                ).flatMap {
                    channel.pipeline.addHandler(ProxyHTTPHandler(server: self, mode: .plain, owner: nil))
                }
            }
        do {
            serverChannel = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
            self.port = port
            Self.log.info("Proxy listening on 127.0.0.1:\(port)")
        } catch {
            try? group.syncShutdownGracefully()
            self.group = nil
            throw error
        }
    }

    func stop() {
        try? serverChannel?.close().wait()
        serverChannel = nil
        group?.shutdownGracefully { _ in }
        group = nil
    }

    func allocateID() -> Int {
        idLock.lock(); defer { idLock.unlock() }
        defer { nextID += 1 }
        return nextID
    }

    func emit(_ event: ProxyEvent) {
        let tx: NetworkTransaction
        switch event {
        case .began(let t), .updated(let t): tx = t
        }
        entryQueue.async { [onEvent] in
            let entry = tx.state == .pending ? nil : Perf.measure("proxy.entry") { LogEntry.network(tx) }
            DispatchQueue.main.async { onEvent?(event, entry) }
        }
    }
}

// MARK: - Front (client-facing) handler

/// Sits behind the HTTP/1.1 server codec. In `.plain` mode it answers absolute-URI requests and CONNECTs;
/// after a decrypted CONNECT a second instance in `.tls` mode sits behind the TLS handler.
final class ProxyHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    enum Mode { case plain, tls(host: String, port: Int) }

    /// Strong on purpose: `ProxyServer.stop()` closes the listener, but accepted connections keep reading until the
    /// event-loop group finishes shutting down. An `unowned` reference here crashed on the next upstream response
    /// after Stop (swift_abortRetainUnowned in `shouldRecord`).
    private let server: ProxyServer
    private let mode: Mode
    private var owner: ProcessLookup.Owner?
    private var ownerResolved: Bool
    private var buffered: [HTTPServerRequestPart] = []
    private var context: ChannelHandlerContext?

    private var upstream: Upstream?
    private var exchange: Exchange?
    private var connectTarget: (host: String, port: Int)?
    private var sawRequest = false

    final class Upstream {
        let key: String
        let channel: Channel
        var ready = false
        var closeAfterResponse = false
        init(key: String, channel: Channel) { self.key = key; self.channel = channel }
    }

    final class Exchange {
        var tx: NetworkTransaction
        var queued: [HTTPClientRequestPart] = []
        var requestDone = false
        var responseHeadSent = false
        var closeClientAfter = false
        /// Binary bodies (images, video, fonts, octet-stream) are only kept up to a small sniffable prefix.
        var storeRequestBody = true
        var storeResponseBody = true
        init(tx: NetworkTransaction) { self.tx = tx }
    }

    /// Keep full bodies only for content we can show as text; a session of image/video traffic through the
    /// proxy otherwise pins hundreds of MB.
    static func shouldStoreBody(contentType: String?) -> Bool {
        guard let ct = contentType?.lowercased(), !ct.isEmpty else { return true }
        // Same positive list as `BodyDecoder.isProbablyText` (so image/svg+xml is kept as text, for example).
        if ct.hasPrefix("text/") || ct.contains("json") || ct.contains("xml") || ct.contains("javascript") || ct.contains("x-www-form-urlencoded") || ct.contains("html") { return true }
        for prefix in ["image/", "video/", "audio/", "font/"] where ct.hasPrefix(prefix) { return false }
        for needle in ["octet-stream", "zip", "protobuf", "pdf", "x-font", "woff"] where ct.contains(needle) { return false }
        return true
    }
    static let binaryBodyPrefix = 512

    init(server: ProxyServer, mode: Mode, owner: ProcessLookup.Owner?) {
        self.server = server
        self.mode = mode
        self.owner = owner
        if case .tls = mode { ownerResolved = true } else { ownerResolved = false }
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

    // MARK: Inbound

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        guard ownerResolved else {
            buffered.append(part)
            if buffered.count == 1 { resolveOwner(context: context) }
            return
        }
        handle(part, context: context)
    }

    /// Attribute the connection to a process (off the event loop, libproc scans can take a few ms), then replay.
    private func resolveOwner(context: ChannelHandlerContext) {
        let loop = context.eventLoop
        guard let port = context.remoteAddress?.port else { finishOwner(nil, context: context); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let owner = ProcessLookup.owner(ofLocalPort: UInt16(port))
            loop.execute { self?.finishOwner(owner, context: context) }
        }
    }

    private func finishOwner(_ owner: ProcessLookup.Owner?, context: ChannelHandlerContext) {
        guard self.context != nil else { return }
        self.owner = owner
        ownerResolved = true
        let parts = buffered
        buffered.removeAll()
        for p in parts { handle(p, context: context) }
    }

    private var shouldDecrypt: Bool {
        switch server.policy {
        case .everything: true
        case .nothing: false
        case .simulatorOnly: owner?.isSimulator == true
        }
    }

    /// Non-simulator traffic is invisible unless the user opted into "everything".
    private var shouldRecord: Bool { server.policy == .everything || owner?.isSimulator == true }

    private func handle(_ part: HTTPServerRequestPart, context: ChannelHandlerContext) {
        switch part {
        case .head(let head):
            if head.method == .CONNECT {
                handleConnect(head, context: context)
            } else {
                beginRequest(head, context: context)
            }
        case .body(let buf):
            guard let exchange else { return }
            exchange.tx.requestBodySize += buf.readableBytes
            let cap = exchange.storeRequestBody ? ProxyServer.maxStoredBody : Self.binaryBodyPrefix
            if exchange.tx.requestBody.count < cap {
                exchange.tx.requestBody.append(contentsOf: buf.readableBytesView.prefix(cap - exchange.tx.requestBody.count))
            }
            if exchange.tx.requestBody.count < exchange.tx.requestBodySize { exchange.tx.requestBodyTruncated = true }
            send(.body(.byteBuffer(buf)))
        case .end:
            if connectTarget != nil { finishConnect(context: context); return }
            guard let exchange else { return }
            exchange.requestDone = true
            send(.end(nil))
            server.emit(.updated(exchange.tx))
        }
    }

    // MARK: Regular requests

    private func beginRequest(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        if case .tls = mode, !sawRequest { server.noteSuccessfulHandshake() }
        sawRequest = true
        var headers = head.headers
        headers.remove(name: "Proxy-Connection")
        headers.remove(name: "Proxy-Authorization")
        // We only decode gzip/deflate for display; steer servers away from brotli/zstd.
        if let ae = headers.first(name: "Accept-Encoding"), ae.contains("br") || ae.contains("zstd") {
            headers.replaceOrAdd(name: "Accept-Encoding", value: "gzip, deflate")
        }

        let scheme: String, host: String, port: Int, path: String
        switch mode {
        case let .tls(h, p):
            scheme = "https"; host = h; port = p; path = head.uri
        case .plain:
            // Absolute-form URI: http://host[:port]/path?query
            guard let url = URL(string: head.uri), let h = url.host, url.scheme?.lowercased() == "http" else {
                respondError(status: .badRequest, message: "LogLens proxy expects absolute URIs or CONNECT.", context: context)
                return
            }
            scheme = "http"; host = h; port = url.port ?? 80
            var p = url.path.isEmpty ? "/" : url.path
            if let q = url.query { p += "?" + q }
            path = p
            if headers.first(name: "Host") == nil {
                headers.add(name: "Host", value: port == 80 ? host : "\(host):\(port)")
            }
        }

        var tx = NetworkTransaction(
            id: server.allocateID(), startedAt: Date(),
            method: head.method.rawValue, scheme: scheme, host: host, port: port, path: path
        )
        tx.httpVersion = "HTTP/\(head.version.major).\(head.version.minor)"
        tx.requestHeaders = headers.map { .init(name: $0.name, value: $0.value) }
        tx.clientPID = owner?.pid ?? 0
        tx.clientProcess = owner?.name ?? ""
        tx.clientIsSimulator = owner?.isSimulator ?? false
        if case .tls = mode { tx.isDecrypted = true }

        let ex = Exchange(tx: tx)
        ex.closeClientAfter = !head.isKeepAlive
        ex.storeRequestBody = Self.shouldStoreBody(contentType: headers.first(name: "Content-Type"))
        exchange = ex
        if shouldRecord { server.emit(.began(tx)) }

        var outHead = head
        outHead.uri = path
        outHead.headers = headers
        send(.head(outHead))
        ensureUpstream(scheme: scheme, host: host, port: port, context: context)
    }

    /// Queues client request parts until the upstream connection is ready, then streams them through.
    private func send(_ part: HTTPClientRequestPart) {
        guard let exchange else { return }
        if let upstream, upstream.ready {
            if case .end = part {
                upstream.channel.writeAndFlush(part, promise: nil)
            } else {
                upstream.channel.write(part, promise: nil)
            }
        } else {
            exchange.queued.append(part)
        }
    }

    private func ensureUpstream(scheme: String, host: String, port: Int, context: ChannelHandlerContext) {
        let key = "\(scheme)://\(host):\(port)"
        if let up = upstream, up.key == key, up.channel.isActive { flushQueued(); return }
        if let old = upstream { old.channel.close(mode: .all, promise: nil); upstream = nil }

        let tls = scheme == "https"
        let ca = server.ca
        let bootstrap = ClientBootstrap(group: context.eventLoop)
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .connectTimeout(.seconds(20))
            .channelInitializer { [weak self] channel in
                do {
                    if tls {
                        let sni = IPv4Address(host) == nil ? host : nil
                        try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: ca.clientContext, serverHostname: sni))
                    }
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    try channel.pipeline.syncOperations.addHandler(UpstreamHandler(front: self))
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        let pendingKey = key
        bootstrap.connect(host: host, port: port).whenComplete { [weak self] result in
            guard let self, self.context != nil else {
                if case .success(let ch) = result { ch.close(promise: nil) }
                return
            }
            switch result {
            case .success(let channel):
                let up = Upstream(key: pendingKey, channel: channel)
                up.ready = true
                self.upstream = up
                self.flushQueued()
            case .failure(let error):
                let detail = Self.describe(error)
                ProxyServer.log.error("upstream connect to \(host):\(port) failed: \(detail)")
                self.failExchange("Could not connect to \(host):\(port) — \(detail)", context: context)
            }
        }
    }

    private func flushQueued() {
        guard let exchange, let upstream, upstream.ready else { return }
        let parts = exchange.queued
        exchange.queued.removeAll()
        for p in parts { upstream.channel.write(p, promise: nil) }
        upstream.channel.flush()
    }

    // MARK: Upstream → client

    func upstreamRead(_ part: HTTPClientResponsePart) {
        guard let context, let exchange else { return }
        switch part {
        case .head(let head):
            exchange.tx.statusCode = Int(head.status.code)
            exchange.tx.statusReason = head.status.reasonPhrase
            exchange.tx.responseHeaders = head.headers.map { .init(name: $0.name, value: $0.value) }
            exchange.storeResponseBody = Self.shouldStoreBody(contentType: head.headers.first(name: "Content-Type"))
            if !head.isKeepAlive { upstream?.closeAfterResponse = true }
            var out = HTTPResponseHead(version: head.version, status: head.status, headers: head.headers)
            out.headers.remove(name: "Proxy-Connection")
            exchange.responseHeadSent = true
            context.write(wrapOutboundOut(.head(out)), promise: nil)
            if shouldRecord { server.emit(.updated(exchange.tx)) }
        case .body(let buf):
            exchange.tx.responseBodySize += buf.readableBytes
            let cap = exchange.storeResponseBody ? ProxyServer.maxStoredBody : Self.binaryBodyPrefix
            if exchange.tx.responseBody.count < cap {
                exchange.tx.responseBody.append(contentsOf: buf.readableBytesView.prefix(cap - exchange.tx.responseBody.count))
            }
            if exchange.tx.responseBody.count < exchange.tx.responseBodySize { exchange.tx.responseBodyTruncated = true }
            context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        case .end:
            exchange.tx.endedAt = Date()
            exchange.tx.state = .completed
            if shouldRecord { server.emit(.updated(exchange.tx)) }
            let closeClient = exchange.closeClientAfter
            self.exchange = nil
            if upstream?.closeAfterResponse == true {
                upstream?.channel.close(mode: .all, promise: nil)
                upstream = nil
            }
            let promise = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
            if closeClient { promise.futureResult.whenComplete { _ in context.close(promise: nil) } }
        }
    }

    func upstreamClosed() {
        upstream = nil
        if let exchange, exchange.tx.state == .pending, let context {
            failExchange("Upstream closed the connection before the response completed.", context: context)
        }
    }

    func upstreamError(_ error: Error) {
        // A peer that drops TCP without close_notify (common with Google/CDN edges) is just EOF for us:
        // let the decoder's channelInactive path deliver `.end` for close-delimited bodies, or fail via upstreamClosed.
        if let e = error as? NIOSSLError, case .uncleanShutdown = e {
            upstream?.channel.close(mode: .all, promise: nil)
            return
        }
        upstream?.channel.close(mode: .all, promise: nil)
        upstream = nil
        if let exchange, exchange.tx.state == .pending, let context {
            failExchange(Self.describe(error), context: context)
        }
    }

    private func failExchange(_ message: String, context: ChannelHandlerContext) {
        guard let exchange else { return }
        exchange.tx.state = .failed
        exchange.tx.error = message
        exchange.tx.endedAt = Date()
        if shouldRecord { server.emit(.updated(exchange.tx)) }
        self.exchange = nil
        if exchange.responseHeadSent {
            context.close(promise: nil)
        } else {
            respondError(status: .badGateway, message: "LogLens proxy: \(message)", context: context)
        }
    }

    private func respondError(status: HTTPResponseStatus, message: String, context: ChannelHandlerContext) {
        var buf = context.channel.allocator.buffer(capacity: message.utf8.count)
        buf.writeString(message)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: String(buf.readableBytes))
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }

    // MARK: CONNECT

    private func handleConnect(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        let parts = head.uri.split(separator: ":", maxSplits: 1)
        guard let host = parts.first.map(String.init), !host.isEmpty else {
            respondError(status: .badRequest, message: "Malformed CONNECT target.", context: context)
            return
        }
        let port = parts.count > 1 ? Int(parts[1]) ?? 443 : 443
        connectTarget = (host, port)
    }

    private func finishConnect(context: ChannelHandlerContext) {
        guard let (host, port) = connectTarget else { return }
        connectTarget = nil
        let bypassed = server.isBypassed(host)
        if shouldDecrypt && !bypassed {
            let sslContext: NIOSSLContext
            do { sslContext = try server.ca.serverContext(for: host) } catch {
                respondError(status: .internalServerError, message: "Could not mint certificate for \(host): \(error)", context: context)
                return
            }
            let established = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .custom(code: 200, reasonPhrase: "Connection Established")))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: established)
            let next = ProxyHTTPHandler(server: server, mode: .tls(host: host, port: port), owner: owner)
            established.futureResult.whenSuccess { [self] in
                swapPipeline(context: context) { pipeline in
                    pipeline.addHandler(NIOSSLServerHandler(context: sslContext), position: .last).flatMap {
                        pipeline.configureHTTPServerPipeline(position: .last, withPipeliningAssistance: true, withErrorHandling: false, withOutboundHeaderValidation: false)
                    }.flatMap {
                        pipeline.addHandler(next, position: .last)
                    }
                }
            }
        } else {
            // Opaque tunnel: connect upstream first so a failure can still be reported as 502.
            let recorded: NetworkTransaction? = shouldRecord ? {
                var tx = NetworkTransaction(id: server.allocateID(), startedAt: Date(), method: "CONNECT", scheme: "https", host: host, port: port, path: "")
                tx.isTunnel = true
                if bypassed { tx.note = "Not decrypted: this host rejects the LogLens certificate (pinned)." }
                tx.clientPID = owner?.pid ?? 0
                tx.clientProcess = owner?.name ?? ""
                tx.clientIsSimulator = owner?.isSimulator ?? false
                return tx
            }() : nil
            if let recorded { server.emit(.began(recorded)) }
            let frontChannel = context.channel
            ClientBootstrap(group: context.eventLoop)
                .channelOption(.socketOption(.tcp_nodelay), value: 1)
                .connectTimeout(.seconds(20))
                .connect(host: host, port: port)
                .whenComplete { [self] result in
                    guard self.context != nil else { if case .success(let ch) = result { ch.close(promise: nil) }; return }
                    switch result {
                    case .failure(let error):
                        if var tx = recorded {
                            tx.state = .failed; tx.error = Self.describe(error); tx.endedAt = Date()
                            server.emit(.updated(tx))
                        }
                        respondError(status: .badGateway, message: "LogLens proxy: could not reach \(host):\(port) — \(Self.describe(error))", context: context)
                    case .success(let upChannel):
                        let server = self.server
                        let finish: () -> Void = {
                            guard var tx = recorded else { return }
                            tx.state = .completed; tx.endedAt = Date()
                            server.emit(.updated(tx))
                        }
                        let relayToFront = TunnelRelayHandler(peer: frontChannel, onClose: finish)
                        _ = upChannel.pipeline.addHandler(relayToFront)
                        let established = context.eventLoop.makePromise(of: Void.self)
                        context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .custom(code: 200, reasonPhrase: "Connection Established")))), promise: nil)
                        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: established)
                        established.futureResult.whenSuccess { [self] in
                            swapPipeline(context: context) { pipeline in
                                pipeline.addHandler(TunnelRelayHandler(peer: upChannel, onClose: nil), position: .last)
                            }
                        }
                    }
                }
        }
    }

    /// Replaces the HTTP codec + this handler with whatever `install` appends. The old handlers' contexts are
    /// captured first so the lookup-by-type can't pick up the freshly added codec; the request decoder goes last.
    private func swapPipeline(context: ChannelHandlerContext, install: @escaping (ChannelPipeline) -> EventLoopFuture<Void>) {
        let pipeline = context.pipeline
        let sync = pipeline.syncOperations
        let decoder = try? sync.context(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self)
        let encoder = try? sync.context(handlerType: HTTPResponseEncoder.self)
        let pipelining = try? sync.context(handlerType: HTTPServerPipelineHandler.self)
        let selfContext = context
        install(pipeline)
            .flatMap { encoder.map { pipeline.removeHandler(context: $0) } ?? pipeline.eventLoop.makeSucceededVoidFuture() }
            .flatMap { pipelining.map { pipeline.removeHandler(context: $0) } ?? pipeline.eventLoop.makeSucceededVoidFuture() }
            .flatMap { pipeline.removeHandler(context: selfContext) }
            .flatMap { decoder.map { pipeline.removeHandler(context: $0) } ?? pipeline.eventLoop.makeSucceededVoidFuture() }
            .whenFailure { error in
                ProxyServer.log.error("pipeline swap failed: \(error)")
                pipeline.close(promise: nil)
            }
    }

    // MARK: Lifecycle

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.channel.close(mode: .all, promise: nil)
        upstream = nil
        if let exchange, exchange.tx.state == .pending {
            exchange.tx.state = .failed
            exchange.tx.error = "Client closed the connection."
            exchange.tx.endedAt = Date()
            if shouldRecord { server.emit(.updated(exchange.tx)) }
            self.exchange = nil
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if case let .tls(host, port) = mode, !sawRequest, shouldRecord, Self.isHandshakeFailure(error) {
            var tx = NetworkTransaction(id: server.allocateID(), startedAt: Date(), method: "CONNECT", scheme: "https", host: host, port: port, path: "")
            tx.state = .failed
            tx.isDecrypted = true
            tx.endedAt = tx.startedAt
            tx.clientPID = owner?.pid ?? 0
            tx.clientProcess = owner?.name ?? ""
            tx.clientIsSimulator = owner?.isSimulator ?? false
            if server.sawSuccessfulHandshake {
                tx.error = "\(owner?.name ?? "The app") rejected the LogLens certificate for \(host) (pinned). Further connections to this host are tunnelled untouched so the app keeps working."
            } else {
                tx.error = "The simulator doesn't trust the LogLens certificate yet — reinstalling it. Retry in a moment (relaunch the app if it keeps failing)."
            }
            server.emit(.began(tx))
            server.learnPinned(host: host)
            sawRequest = true   // one report per connection
        } else if let exchange, exchange.tx.state == .pending {
            exchange.tx.state = .failed
            if let e = error as? NIOSSLError, case .uncleanShutdown = e {
                exchange.tx.error = "Client closed the connection before the response completed."
            } else {
                exchange.tx.error = Self.describe(error)
            }
            exchange.tx.endedAt = Date()
            if shouldRecord { server.emit(.updated(exchange.tx)) }
            self.exchange = nil
        }
        upstream?.channel.close(mode: .all, promise: nil)
        upstream = nil
        context.close(promise: nil)
    }

    private static func isHandshakeFailure(_ error: Error) -> Bool {
        if let e = error as? NIOSSLError {
            switch e {
            case .handshakeFailed, .uncleanShutdown: return true
            default: return false
            }
        }
        if error is BoringSSLError { return true }
        return false
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? NIOSSLError {
            switch e {
            case .handshakeFailed(let inner): return "TLS handshake failed: \(inner)"
            case .uncleanShutdown: return "TLS connection closed uncleanly"
            default: return "TLS error: \(e)"
            }
        }
        if let e = error as? IOError { return e.description }
        if let e = error as? NIOConnectionError {
            var parts: [String] = []
            if let a = e.dnsAError { parts.append("A lookup: \(a)") }
            if let aaaa = e.dnsAAAAError { parts.append("AAAA lookup: \(aaaa)") }
            for c in e.connectionErrors { parts.append("\(c.target): \(describe(c.error))") }
            return parts.isEmpty ? "No addresses for \(e.host)" : parts.joined(separator: "; ")
        }
        if let e = error as? ChannelError { return "Channel error: \(e)" }
        return String(describing: error)
    }
}

// MARK: - Upstream handler

/// Runs in the upstream channel (same event loop as the front) and hands response parts back to the front handler.
final class UpstreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    private weak var front: ProxyHTTPHandler?

    init(front: ProxyHTTPHandler?) { self.front = front }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        front?.upstreamRead(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        front?.upstreamClosed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        front?.upstreamError(error)
        context.close(promise: nil)
    }
}

// MARK: - Tunnel relay

/// Byte pump for undecrypted CONNECT tunnels: whatever arrives is written to the peer channel.
final class TunnelRelayHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    private let peer: Channel
    private var onClose: (() -> Void)?

    init(peer: Channel, onClose: (() -> Void)?) {
        self.peer = peer
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(mode: .all, promise: nil)
        onClose?()
        onClose = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(mode: .all, promise: nil)
        context.close(promise: nil)
    }
}
