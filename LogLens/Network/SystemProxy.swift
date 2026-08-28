import Foundation
import os

/// Points the macOS system web/secure-web proxy at the local MITM port and — above all —
/// puts it back exactly the way it was. Restoration happens on stop, on quit, on SIGTERM/SIGINT,
/// and, if LogLens dies without cleaning up, via a detached watchdog shell and a launch-time check.
///
/// The simulator inherits the host's proxy settings, so this is the only routing step needed.
final class SystemProxy {

    struct ServiceSnapshot: Codable, Equatable {
        struct Entry: Codable, Equatable {
            var enabled: Bool
            var server: String
            var port: Int
        }
        let service: String
        let web: Entry
        let secure: Entry
    }

    struct Snapshot: Codable, Equatable {
        let takenAt: Date
        let ourPort: Int
        let services: [ServiceSnapshot]
    }

    private static let log = Logger(subsystem: "com.hugoprinsloo.LogLens", category: "SystemProxy")
    private static let defaultsKey = "networkProxySnapshot"
    private static let tool = "/usr/sbin/networksetup"

    private(set) var snapshot: Snapshot?
    private var watchdog: Process?
    private let lock = NSLock()

    // MARK: - Apply / restore

    /// Records the current proxy configuration of every enabled network service and points them at `port`.
    func apply(port: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard snapshot == nil else { return }
        let services = try Self.enabledServices()
        guard !services.isEmpty else { throw Failure("No active network services found.") }
        let snap = Snapshot(takenAt: Date(), ourPort: port, services: try services.map(Self.read))
        // Persist BEFORE touching anything so a crash mid-apply is still recoverable on next launch.
        Self.persist(snap)
        snapshot = snap
        startWatchdog(for: snap)
        for s in snap.services {
            try Self.run(["-setwebproxy", s.service, "127.0.0.1", String(port)])
            try Self.run(["-setsecurewebproxy", s.service, "127.0.0.1", String(port)])
            try Self.run(["-setwebproxystate", s.service, "on"])
            try Self.run(["-setsecurewebproxystate", s.service, "on"])
        }
        Self.log.info("System proxy set to 127.0.0.1:\(port) on \(snap.services.count) service(s)")
    }

    /// Restores the snapshot taken by `apply`. Safe to call repeatedly.
    func restore() {
        lock.lock(); defer { lock.unlock() }
        guard let snap = snapshot else { return }
        Self.restore(snap)
        snapshot = nil
        Self.persist(nil)
        stopWatchdog()
    }

    var isApplied: Bool { lock.lock(); defer { lock.unlock() }; return snapshot != nil }

    /// Call once at launch: if a previous LogLens crashed with the proxy applied, undo it.
    static func recoverFromPreviousRun() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        log.warning("Found stale proxy snapshot from \(snap.takenAt); restoring")
        restore(snap)
        persist(nil)
    }

    // MARK: - Internals

    private static func restore(_ snap: Snapshot) {
        for cmd in restoreCommands(snap) {
            do { try run(cmd) } catch { log.error("restore failed: \(cmd.joined(separator: " ")) — \(error.localizedDescription)") }
        }
        log.info("System proxy restored for \(snap.services.count) service(s)")
    }

    /// The exact `networksetup` argument lists that undo `apply`. Shared by in-process restore and the watchdog.
    static func restoreCommands(_ snap: Snapshot) -> [[String]] {
        var cmds: [[String]] = []
        for s in snap.services {
            // networksetup refuses an empty server; when the original had none, leave the address alone and just disable.
            if !s.web.server.isEmpty { cmds.append(["-setwebproxy", s.service, s.web.server, String(s.web.port)]) }
            cmds.append(["-setwebproxystate", s.service, s.web.enabled ? "on" : "off"])
            if !s.secure.server.isEmpty { cmds.append(["-setsecurewebproxy", s.service, s.secure.server, String(s.secure.port)]) }
            cmds.append(["-setsecurewebproxystate", s.service, s.secure.enabled ? "on" : "off"])
        }
        return cmds
    }

    private static func persist(_ snap: Snapshot?) {
        if let snap, let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        UserDefaults.standard.synchronize()
    }

    /// A detached `/bin/sh` loop that waits for our PID to disappear and then restores the proxy.
    /// Survives a crash or `kill -9` of LogLens because it is its own process.
    private func startWatchdog(for snap: Snapshot) {
        stopWatchdog()
        let cmds = Self.restoreCommands(snap).map { args in
            ([Self.tool] + args).map(Self.shellQuote).joined(separator: " ")
        }.joined(separator: "; ")
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 1; done; \(cmds)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); watchdog = p } catch { Self.log.error("watchdog failed to start: \(error.localizedDescription)") }
    }

    private func stopWatchdog() {
        guard let w = watchdog else { return }
        if w.isRunning { w.terminate() }
        watchdog = nil
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func enabledServices() throws -> [String] {
        let out = try run(["-listallnetworkservices"])
        return out.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") && !$0.isEmpty }
    }

    private static func read(_ service: String) throws -> ServiceSnapshot {
        ServiceSnapshot(
            service: service,
            web: try parse(run(["-getwebproxy", service])),
            secure: try parse(run(["-getsecurewebproxy", service]))
        )
    }

    private static func parse(_ text: String) -> ServiceSnapshot.Entry {
        var e = ServiceSnapshot.Entry(enabled: false, server: "", port: 0)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Enabled": e.enabled = parts[1] == "Yes"
            case "Server": e.server = parts[1]
            case "Port": e.port = Int(parts[1]) ?? 0
            default: break
            }
        }
        return e
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    @discardableResult
    private static func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            let e = String(data: errData, encoding: .utf8) ?? ""
            throw Failure("networksetup \(args.first ?? "") failed: \((e.isEmpty ? text : e).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }
}
