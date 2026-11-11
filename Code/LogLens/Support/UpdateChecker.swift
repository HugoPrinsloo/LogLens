import AppKit
import Foundation
import Observation
import os

/// Checks the GitHub releases of this repo for a newer version. No auto-install: the user downloads the
/// dmg and drags it over the old app. Automatic checks run at most once a day and never in Debug builds
/// (pass `--check-updates` to force one; `--pretend-version 0.9.0` makes any release look new).
@MainActor
@Observable
final class UpdateChecker {

    struct Release: Equatable {
        var version: String          // "1.3.0" (tag without the leading "v")
        var title: String
        var notes: String
        var pageURL: URL
        var downloadURL: URL?        // the .dmg asset, falling back to the .zip, then the release page
        var publishedAt: Date?
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), failed(String)
    }

    private static let log = Logger(subsystem: "com.hugoprinsloo.LogLens", category: "Updates")
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/HugoPrinsloo/LogLens/releases/latest")!
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private(set) var state: State = .idle
    private(set) var lastChecked: Date? {
        didSet { UserDefaults.standard.set(lastChecked, forKey: "updatesLastChecked") }
    }
    /// Version the user dismissed the banner for; the banner stays hidden for it until a manual check.
    private var skippedVersion: String? {
        didSet { UserDefaults.standard.set(skippedVersion, forKey: "updatesSkippedVersion") }
    }
    /// Result of a user-initiated check, shown as an alert (automatic checks stay silent).
    var manualResult: ManualResult?

    struct ManualResult: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    let currentVersion: String

    init() {
        let d = UserDefaults.standard
        lastChecked = d.object(forKey: "updatesLastChecked") as? Date
        skippedVersion = d.string(forKey: "updatesSkippedVersion")
        if let i = CommandLine.arguments.firstIndex(of: "--pretend-version"), i + 1 < CommandLine.arguments.count {
            currentVersion = CommandLine.arguments[i + 1]
        } else {
            currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        }
    }

    /// The release the banner should offer, if any.
    var availableUpdate: Release? {
        if case .available(let r) = state, r.version != skippedVersion { return r }
        return nil
    }

    var isChecking: Bool { state == .checking }

    // MARK: - Checks

    /// Automatic check on launch: throttled, silent, skipped in Debug builds unless `--check-updates` is passed.
    func checkOnLaunchIfDue() {
        let forced = CommandLine.arguments.contains("--check-updates")
        #if DEBUG
        guard forced else { return }
        #endif
        if !forced, let last = lastChecked, Date().timeIntervalSince(last) < Self.checkInterval { return }
        Task { await check(manual: false) }
    }

    /// "Check for Updates…": always hits the network and reports the outcome via `manualResult`.
    func checkNow() {
        Task { await check(manual: true) }
    }

    func skipAvailableUpdate() {
        if case .available(let r) = state { skippedVersion = r.version }
    }

    func download(_ release: Release) {
        NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
    }

    func openReleaseNotes(_ release: Release) {
        NSWorkspace.shared.open(release.pageURL)
    }

    private func check(manual: Bool) async {
        guard state != .checking else { return }
        state = .checking
        do {
            let release = try await Self.fetchLatest()
            lastChecked = Date()
            if Self.isNewer(release.version, than: currentVersion) {
                state = .available(release)
                if manual {
                    skippedVersion = nil   // the user asked; show the banner even for a previously dismissed version
                    manualResult = .init(title: "LogLens \(release.version) is available",
                                         message: "You have \(currentVersion). Download it from the banner or the release page.")
                }
                Self.log.info("update available: \(release.version, privacy: .public) (running \(self.currentVersion, privacy: .public))")
            } else {
                state = .upToDate
                if manual {
                    manualResult = .init(title: "You’re up to date", message: "LogLens \(currentVersion) is the latest version.")
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
            Self.log.error("update check failed: \(error.localizedDescription, privacy: .public)")
            if manual {
                manualResult = .init(title: "Couldn’t check for updates", message: error.localizedDescription)
            }
        }
    }

    // MARK: - GitHub

    private struct APIRelease: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let published_at: Date?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LogLens", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        guard http.statusCode == 200 else { throw UpdateError.status(http.statusCode) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let api = try decoder.decode(APIRelease.self, from: data)
        let version = api.tag_name.hasPrefix("v") ? String(api.tag_name.dropFirst()) : api.tag_name
        let dmg = api.assets.first { $0.name.hasSuffix(".dmg") } ?? api.assets.first { $0.name.hasSuffix(".zip") }
        return Release(
            version: version,
            title: api.name?.isEmpty == false ? api.name! : "LogLens \(version)",
            notes: api.body ?? "",
            pageURL: api.html_url,
            downloadURL: dmg?.browser_download_url,
            publishedAt: api.published_at
        )
    }

    enum UpdateError: LocalizedError {
        case badResponse, status(Int)
        var errorDescription: String? {
            switch self {
            case .badResponse: "GitHub returned an unexpected response."
            case .status(let code): code == 403 ? "GitHub rate limit reached. Try again in a few minutes." : "GitHub returned HTTP \(code)."
            }
        }
    }

    // MARK: - Versions

    /// Numeric, component-wise compare: 1.10.0 > 1.9.0, 1.3 == 1.3.0. Non-numeric suffixes are ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = components(a), y = components(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(_ s: String) -> [Int] {
        s.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }
}
