import Foundation
import Observation
import SwiftUI
import os

/// Owns the proxy lifecycle (CA → proxy → simulator trust → system proxy) and the captured transactions.
@MainActor
@Observable
final class NetworkStore {

    private static let log = Logger(subsystem: "com.hugoprinsloo.LogLens", category: "NetworkStore")
    private static let selectLast = CommandLine.arguments.contains("--select-last")
    static let maxTransactions = 10_000

    // MARK: Data
    private(set) var transactions: [NetworkTransaction] = []
    private(set) var filtered: [NetworkTransaction] = []
    private var indexByID: [NetworkTransaction.ID: Int] = [:]
    private(set) var hostCounts: [String: Int] = [:]
    private(set) var processCounts: [String: Int] = [:]

    // MARK: Filter / UI
    var searchText = "" { didSet { refilter() } }
    var hostFilter: String? { didSet { refilter() } }
    var processFilter: String? { didSet { refilter() } }
    var selection: NetworkTransaction.ID? {
        didSet { if selection != nil { showInspector = true } }
    }
    var showInspector = true
    var autoScroll = true

    var selectedTransaction: NetworkTransaction? {
        guard let selection, let i = indexByID[selection], i < transactions.count else { return nil }
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

    /// Fired on the main actor once a transaction has finished (completed, failed, or a closed tunnel).
    var onFinished: ((NetworkTransaction) -> Void)?

    private var ca: CertificateAuthority?
    private var proxy: ProxyServer?
    private let systemProxy = SystemProxy()
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
        // `--network` opens the Network view and starts the proxy; `--proxy` just starts it (dev aids).
        if CommandLine.arguments.contains("--network") || CommandLine.arguments.contains("--proxy") {
            Task { await start() }
        }
    }

    // MARK: - Lifecycle

    func toggleCapture() {
        if isCapturing { stop() } else { Task { await start() } }
    }

    func start() async {
        guard !isCapturing, !isStarting else { return }
        isStarting = true
        error = nil
        defer { isStarting = false }
        do {
            let ca = try self.ca ?? CertificateAuthority.load()
            self.ca = ca
            caFingerprint = ca.fingerprint
            caPath = ca.certificatePath

            let proxy = ProxyServer(ca: ca, policy: policy)
            proxy.onEvent = { [weak self] event in self?.handle(event) }
            proxy.setBypassHosts(bypassHosts)
            proxy.onBypassLearned = { [weak self] host in self?.bypassHosts.insert(host) }
            proxy.onTrustProblem = { [weak self] host in self?.handleTrustProblem(host) }
            try proxy.start(port: port)
            self.proxy = proxy

            statusLine = "Installing certificate in simulators…"
            let installed = await SimulatorTrust.installInBootedSimulators(certificatePath: ca.certificatePath, fingerprint: ca.fingerprint)
            if !installed.isEmpty { trustedSimulators = installed }

            try systemProxy.apply(port: port)
            isCapturing = true
            statusLine = "Proxy on 127.0.0.1:\(String(port))"
            Self.log.info("Network capture started on port \(self.port)")
        } catch {
            self.error = error.localizedDescription
            statusLine = "Proxy failed to start"
            proxy?.stop()
            proxy = nil
            systemProxy.restore()
        }
    }

    func stop() {
        guard isCapturing || proxy != nil else { return }
        systemProxy.restore()
        proxy?.stop()
        proxy = nil
        isCapturing = false
        statusLine = "Proxy idle"
        Self.log.info("Network capture stopped")
    }

    /// "Heal": tear everything down and bring it back up — restores the Mac proxy, forgets learned pinned hosts,
    /// re-adds the CA to every booted simulator, restarts the proxy and re-applies the system proxy.
    func repair() async {
        guard !isStarting else { return }
        error = nil
        stop()
        bypassHosts.removeAll()
        UserDefaults.standard.removeObject(forKey: "networkCAInstalledSimulators")
        statusLine = "Healing…"
        await start()
        if isCapturing { statusLine = "Proxy on 127.0.0.1:\(String(port)) · healed" }
    }

    func clear() {
        transactions.removeAll(keepingCapacity: true)
        filtered.removeAll(keepingCapacity: true)
        indexByID.removeAll()
        hostCounts.removeAll()
        processCounts.removeAll()
        selection = nil
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

    private func handle(_ event: ProxyEvent) {
        switch event {
        case .began(let tx):
            if tx.state != .pending { onFinished?(tx) }   // e.g. a rejected handshake reported as a failed CONNECT
            if transactions.count >= Self.maxTransactions {
                let drop = transactions.count - Self.maxTransactions + 1
                for t in transactions.prefix(drop) { decrement(t) }
                transactions.removeFirst(drop)
                rebuildIndex()
            }
            indexByID[tx.id] = transactions.count
            transactions.append(tx)
            increment(tx)
            if matches(tx) { filtered.append(tx) }
            // `--select-last` keeps the newest request selected (dev/screenshot aid).
            if Self.selectLast, !tx.isTunnel { selection = tx.id }
        case .updated(let tx):
            guard let i = indexByID[tx.id] else { return }
            if tx.state != .pending && transactions[i].state == .pending { onFinished?(tx) }
            transactions[i] = tx
            if let j = filtered.lastIndex(where: { $0.id == tx.id }) {
                if matches(tx) { filtered[j] = tx } else { filtered.remove(at: j) }
            } else if matches(tx) {
                refilter()
            }
        }
        if let dumpHandle, case .updated(let tx) = event, tx.state != .pending {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(tx) {
                dumpHandle.write(data)
                dumpHandle.write(Data([0x0A]))
            }
        }
    }

    private func increment(_ tx: NetworkTransaction) {
        hostCounts[tx.host, default: 0] += 1
        processCounts[tx.clientProcess, default: 0] += 1
    }

    private func decrement(_ tx: NetworkTransaction) {
        if let n = hostCounts[tx.host] { if n <= 1 { hostCounts[tx.host] = nil } else { hostCounts[tx.host] = n - 1 } }
        if let n = processCounts[tx.clientProcess] { if n <= 1 { processCounts[tx.clientProcess] = nil } else { processCounts[tx.clientProcess] = n - 1 } }
    }

    private func rebuildIndex() {
        indexByID.removeAll(keepingCapacity: true)
        for (i, t) in transactions.enumerated() { indexByID[t.id] = i }
    }

    // MARK: - Filtering

    var isFilterActive: Bool { !searchText.isEmpty || hostFilter != nil || processFilter != nil }

    func resetFilter() {
        searchText = ""
        hostFilter = nil
        processFilter = nil
    }

    private func matches(_ tx: NetworkTransaction) -> Bool {
        if let hostFilter, tx.host != hostFilter { return false }
        if let processFilter, tx.clientProcess != processFilter { return false }
        guard !searchText.isEmpty else { return true }
        let q = searchText
        if tx.url.localizedCaseInsensitiveContains(q) { return true }
        if tx.method.localizedCaseInsensitiveContains(q) { return true }
        if let code = tx.statusCode, String(code).contains(q) { return true }
        if tx.clientProcess.localizedCaseInsensitiveContains(q) { return true }
        return false
    }

    private func refilter() {
        filtered = isFilterActive ? transactions.filter(matches) : transactions
    }
}
