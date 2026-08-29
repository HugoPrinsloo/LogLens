import Foundation
import Observation
import SwiftUI
import os

/// Owns the proxy lifecycle (CA → proxy → simulator trust → system proxy) and the captured transactions.
@MainActor
@Observable
final class NetworkStore {

    private static let log = Logger(subsystem: "com.hugoprinsloo.LogLens", category: "NetworkStore")
    static let maxTransactions = 10_000

    // MARK: Data
    /// Full transactions (headers, raw bodies) backing the inspector for the network rows in the log views.
    private(set) var transactions: [NetworkTransaction] = []
    private var indexByID: [NetworkTransaction.ID: Int] = [:]

    func transaction(id: NetworkTransaction.ID) -> NetworkTransaction? {
        guard let i = indexByID[id], i < transactions.count else { return nil }
        return transactions[i]
    }

    // MARK: Capture state
    private(set) var isCapturing = false
    private(set) var isStarting = false
    private(set) var error: String?
    private(set) var statusLine = "Proxy idle"
    private(set) var trustedSimulators: [String] = []
    /// Hosts tunnelled instead of decrypted (learned from pin rejections or chosen by the user). Persisted.
    private(set) var bypassHosts: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(bypassHosts).sorted(), forKey: "networkBypassHosts")
            proxy?.setBypassHosts(bypassHosts)
        }
    }
    private(set) var caFingerprint: String = ""
    private(set) var caPath: String = ""

    var policy: DecryptPolicy = .simulatorOnly {
        didSet {
            UserDefaults.standard.set(policy.rawValue, forKey: "networkDecryptPolicy")
            proxy?.policy = policy
        }
    }
    var port: Int = 9095 {
        didSet { UserDefaults.standard.set(port, forKey: "networkProxyPort") }
    }

    /// Fired on the main actor once a transaction has finished (completed, failed, or a closed tunnel), with the
    /// table/timeline entry the proxy already built for it off the main thread.
    var onFinished: ((LogEntry) -> Void)?
    /// Stored request+response body bytes across `transactions`; oldest bodies are dropped past `bodyBudget`.
    private var bodyBytes = 0
    private var bodyEvictionCursor = 0
    static let bodyBudget = 256 * 1024 * 1024

    private var ca: CertificateAuthority?
    private var proxy: ProxyServer?
    private let systemProxy = SystemProxy()
    /// `networksetup` calls take seconds in total; they run here, serially (so a Stop's restore always lands
    /// before the next Start's apply), never on the main thread.
    private static let proxyQueue = DispatchQueue(label: "com.hugoprinsloo.LogLens.systemproxy", qos: .userInitiated)
    /// Bumped by every start/stop so a start that was overtaken by a stop rolls itself back.
    private var generation = 0
    private var signalSources: [DispatchSourceSignal] = []
    private var dumpHandle: FileHandle?

    init() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "networkDecryptPolicy"), let p = DecryptPolicy(rawValue: raw) { policy = p }
        if d.object(forKey: "networkProxyPort") != nil { port = max(1024, d.integer(forKey: "networkProxyPort")) }
        bypassHosts = Set(d.stringArray(forKey: "networkBypassHosts") ?? [])

        // A previous LogLens may have died with the system proxy pointed at it.
        SystemProxy.recoverFromPreviousRun()
        installTerminationHooks()

        if let i = CommandLine.arguments.firstIndex(of: "--network-dump"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            FileManager.default.createFile(atPath: path, contents: nil)
            dumpHandle = FileHandle(forWritingAtPath: path)
        }
    }

    // MARK: - Lifecycle

    func toggleCapture() {
        if isCapturing { Task { await stopCapture() } } else { Task { await start() } }
    }

    func start() async {
        guard !isCapturing, !isStarting else { return }
        isStarting = true
        error = nil
        generation += 1
        let gen = generation
        defer { isStarting = false }
        do {
            let ca = try self.ca ?? CertificateAuthority.load()
            self.ca = ca
            caFingerprint = ca.fingerprint
            caPath = ca.certificatePath

            let proxy = ProxyServer(ca: ca, policy: policy)
            // Events from a proxy that has since been stopped/replaced are dropped.
            proxy.onEvent = { [weak self, weak proxy] event, entry in
                guard let self, let proxy, proxy === self.proxy else { return }
                handle(event, entry: entry)
            }
            proxy.setBypassHosts(bypassHosts)
            proxy.onBypassLearned = { [weak self] host in self?.bypassHosts.insert(host) }
            proxy.onTrustProblem = { [weak self] host in self?.handleTrustProblem(host) }
            try proxy.start(port: port)
            self.proxy = proxy

            statusLine = "Installing certificate in simulators…"
            let installed = await SimulatorTrust.installInBootedSimulators(certificatePath: ca.certificatePath, fingerprint: ca.fingerprint)
            if !installed.isEmpty { trustedSimulators = installed }

            statusLine = "Pointing the Mac's proxy settings at LogLens…"
            let port = self.port
            try await onProxyQueue { [systemProxy] in try systemProxy.apply(port: port) }
            guard gen == generation, self.proxy === proxy else {
                // Stopped while we were starting: undo.
                proxy.stop()
                if self.proxy === proxy { self.proxy = nil }
                try? await onProxyQueue { [systemProxy] in systemProxy.restore() }
                statusLine = "Proxy idle"
                return
            }
            isCapturing = true
            statusLine = "Proxy on 127.0.0.1:\(String(port))"
            Self.log.info("Network capture started on port \(self.port)")
        } catch {
            self.error = error.localizedDescription
            statusLine = "Proxy failed to start"
            proxy?.stop()
            proxy = nil
            try? await onProxyQueue { [systemProxy] in systemProxy.restore() }
        }
    }

    /// User-initiated stop: tears the proxy down now and restores the Mac proxy off the main thread.
    func stopCapture() async {
        guard isCapturing || proxy != nil || isStarting else { return }
        generation += 1
        proxy?.stop()
        proxy = nil
        isCapturing = false
        statusLine = "Restoring the Mac's proxy settings…"
        try? await onProxyQueue { [systemProxy] in systemProxy.restore() }
        if !isCapturing, !isStarting { statusLine = "Proxy idle" }
        Self.log.info("Network capture stopped")
    }

    /// Synchronous stop for quit / SIGTERM: the process is about to exit, so the restore must finish right here.
    func stop() {
        generation += 1
        proxy?.stop()
        proxy = nil
        isCapturing = false
        statusLine = "Proxy idle"
        Self.proxyQueue.sync { [systemProxy] in systemProxy.restore() }
    }

    private func onProxyQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            Self.proxyQueue.async { c.resume(with: Result { try work() }) }
        }
    }

    /// "Heal": tear everything down and bring it back up — restores the Mac proxy, forgets learned pinned hosts,
    /// re-adds the CA to every booted simulator, restarts the proxy and re-applies the system proxy.
    func repair() async {
        guard !isStarting else { return }
        error = nil
        await stopCapture()
        bypassHosts.removeAll()
        UserDefaults.standard.removeObject(forKey: "networkCAInstalledSimulators")
        statusLine = "Healing…"
        await start()
        if isCapturing { statusLine = "Proxy on 127.0.0.1:\(String(port)) · healed" }
    }

    func clear() {
        transactions.removeAll(keepingCapacity: true)
        indexByID.removeAll()
        bodyBytes = 0
        bodyEvictionCursor = 0
    }

    func dismissError() { error = nil }

    private var lastTrustRepair = Date.distantPast
    private var repairingTrust = false

    /// A simulator client rejected our certificate before any decrypt ever succeeded: the CA isn't trusted there
    /// (erased simulator, or one booted after capture started). Re-add it, at most once every 20 s.
    private func handleTrustProblem(_ host: String) {
        guard isCapturing, !repairingTrust, Date().timeIntervalSince(lastTrustRepair) > 20 else { return }
        repairingTrust = true
        lastTrustRepair = Date()
        statusLine = "Simulator rejected the certificate — reinstalling…"
        Self.log.warning("handshake rejected for \(host, privacy: .public) before any success; reinstalling CA in booted simulators")
        Task {
            await reinstallCertificate()
            statusLine = "Proxy on 127.0.0.1:\(String(port)) · certificate reinstalled"
            repairingTrust = false
        }
    }

    func isBypassed(_ host: String) -> Bool { bypassHosts.contains(host.lowercased()) }
    func setBypass(_ host: String, _ on: Bool) {
        if on { bypassHosts.insert(host.lowercased()) } else { bypassHosts.remove(host.lowercased()) }
    }
    func clearBypassHosts() { bypassHosts.removeAll() }

    /// Re-adds the CA to every booted simulator even if we think it's already there.
    func reinstallCertificate() async {
        guard let ca = (try? self.ca ?? CertificateAuthority.load()) else { return }
        self.ca = ca
        caPath = ca.certificatePath
        caFingerprint = ca.fingerprint
        trustedSimulators = await SimulatorTrust.installInBootedSimulators(certificatePath: ca.certificatePath, fingerprint: ca.fingerprint, force: true)
    }

    func trustOnThisMac() async {
        guard let ca = (try? self.ca ?? CertificateAuthority.load()) else { return }
        self.ca = ca
        do { try await SimulatorTrust.trustOnThisMac(certificatePath: ca.certificatePath) } catch { self.error = "Mac trust failed: \(error.localizedDescription)" }
    }

    /// Restores the system proxy synchronously on quit, SIGTERM, SIGINT and SIGHUP.
    private func installTerminationHooks() {
        // queue: nil → runs synchronously on the posting (main) thread, before the process exits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.stop() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: - Events

    private func handle(_ event: ProxyEvent, entry: LogEntry?) {
        switch event {
        case .began(let tx):
            if let entry, tx.state != .pending { onFinished?(entry) }   // e.g. a rejected handshake reported as a failed CONNECT
            if transactions.count >= Self.maxTransactions {
                // Hysteresis: one shift per ~10 % of the buffer instead of one per event once it's full.
                let drop = transactions.count - Self.maxTransactions + Self.maxTransactions / 10
                for t in transactions.prefix(drop) { bodyBytes -= t.requestBody.count + t.responseBody.count }
                transactions.removeFirst(drop)
                bodyEvictionCursor = max(0, bodyEvictionCursor - drop)
                rebuildIndex()
            }
            indexByID[tx.id] = transactions.count
            transactions.append(tx)
            bodyBytes += tx.requestBody.count + tx.responseBody.count
        case .updated(let tx):
            guard let i = indexByID[tx.id] else { return }
            if let entry, tx.state != .pending, transactions[i].state == .pending { onFinished?(entry) }
            bodyBytes += (tx.requestBody.count + tx.responseBody.count) - (transactions[i].requestBody.count + transactions[i].responseBody.count)
            transactions[i] = tx
        }
        enforceBodyBudget()
        if let dumpHandle, case .updated(let tx) = event, tx.state != .pending {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(tx) {
                dumpHandle.write(data)
                dumpHandle.write(Data([0x0A]))
            }
        }
    }

    /// Drops the oldest stored bodies (metadata stays) until the total is back under budget.
    private func enforceBodyBudget() {
        guard bodyBytes > Self.bodyBudget else { return }
        // Transactions skipped while pending get another look once the cursor has been through the list.
        if bodyEvictionCursor >= transactions.count { bodyEvictionCursor = 0 }
        while bodyBytes > Self.bodyBudget, bodyEvictionCursor < transactions.count {
            let i = bodyEvictionCursor
            bodyEvictionCursor += 1
            let size = transactions[i].requestBody.count + transactions[i].responseBody.count
            guard size > 0, transactions[i].state != .pending else { continue }
            transactions[i].requestBody = Data()
            transactions[i].responseBody = Data()
            transactions[i].requestBodyTruncated = transactions[i].requestBodySize > 0
            transactions[i].responseBodyTruncated = transactions[i].responseBodySize > 0
            bodyBytes -= size
        }
    }

    private func rebuildIndex() {
        indexByID.removeAll(keepingCapacity: true)
        for (i, t) in transactions.enumerated() { indexByID[t.id] = i }
    }
}
