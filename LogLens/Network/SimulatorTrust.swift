import Foundation
import os

/// Installs the LogLens root CA into simulators (silent; no prompts) and, on request, into the Mac's login keychain.
enum SimulatorTrust {
    private static let log = Logger(subsystem: "com.hugoprinsloo.LogLens", category: "Trust")
    private static let installedKey = "networkCAInstalledSimulators"   // [udid: fingerprint]

    /// Adds the CA to every booted simulator. Always re-adds (idempotent, ~1 s): an "Erase All Content and Settings"
    /// wipes the simulator's trust store without telling us, and a stale "already installed" cache then breaks every handshake.
    /// Returns the UDIDs that were installed.
    @discardableResult
    static func installInBootedSimulators(certificatePath: String, fingerprint: String, force: Bool = true) async -> [String] {
        guard let data = try? await ShellRunner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j", "booted"]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]] else { return [] }
        let booted = devices.values.flatMap { $0 }.compactMap { $0["udid"] as? String }
        var installed = UserDefaults.standard.dictionary(forKey: installedKey) as? [String: String] ?? [:]
        var done: [String] = []
        for udid in booted where force || installed[udid] != fingerprint {
            do {
                _ = try await ShellRunner.run("/usr/bin/xcrun", ["simctl", "keychain", udid, "add-root-cert", certificatePath], timeout: 30)
                installed[udid] = fingerprint
                done.append(udid)
                log.info("Installed root CA into simulator \(udid)")
            } catch {
                log.error("add-root-cert failed for \(udid): \(error)")
            }
        }
        UserDefaults.standard.set(installed, forKey: installedKey)
        return done
    }

    /// Trusts the CA for the current macOS user (login keychain). macOS shows one password prompt.
    static func trustOnThisMac(certificatePath: String) async throws {
        let keychain = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
        _ = try await ShellRunner.run("/usr/bin/security", ["add-trusted-cert", "-r", "trustRoot", "-k", keychain, certificatePath], timeout: 120)
    }
}
