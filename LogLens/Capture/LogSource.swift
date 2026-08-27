import Foundation

/// Something LogLens can stream unified-logging output from.
struct LogSource: Identifiable, Hashable {
    enum Kind: Hashable {
        case mac
        case simulator(udid: String, runtime: String, state: String)
        case physicalDevice(udid: String, model: String)
    }

    let id: String
    let name: String
    let kind: Kind

    var isSimulator: Bool { if case .simulator = kind { return true } else { return false } }

    var isBooted: Bool {
        switch kind {
        case .mac: true
        case let .simulator(_, _, state): state == "Booted"
        case .physicalDevice: false
        }
    }

    /// Physical devices need a different transport; not wired up yet.
    var isSupported: Bool {
        if case .physicalDevice = kind { return false }
        return true
    }

    var subtitle: String {
        switch kind {
        case .mac: "This Mac · host unified log"
        case let .simulator(_, runtime, state): "\(runtime) · \(state)"
        case let .physicalDevice(_, model): "\(model) · not supported yet"
        }
    }

    var symbol: String {
        switch kind {
        case .mac: "desktopcomputer"
        case .simulator: "iphone"
        case .physicalDevice: "iphone.radiowaves.left.and.right"
        }
    }

    static let mac = LogSource(id: "mac", name: "This Mac", kind: .mac)
}

/// Restricts what `log stream` emits at the source so noisy system processes never reach the app.
enum CaptureScope: String, CaseIterable, Identifiable, Codable {
    case appsOnly
    case appsAllSubsystems
    case everything
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appsOnly: "App logs only"
        case .appsAllSubsystems: "Apps, incl. Apple subsystems"
        case .everything: "Everything"
        case .custom: "Custom predicate"
        }
    }

    var help: String {
        switch self {
        case .appsOnly: "Logs from installed apps, excluding com.apple.* subsystems. Best for tracking your own events."
        case .appsAllSubsystems: "All logs from installed apps, including networking and UIKit chatter."
        case .everything: "Every process on the device. Very noisy."
        case .custom: "Your own NSPredicate, as accepted by `log stream --predicate`."
        }
    }

    func predicate(for source: LogSource, custom: String) -> String? {
        let appPath: String
        switch source.kind {
        case .mac:
            appPath = #"(processImagePath BEGINSWITH "/Applications/" OR processImagePath CONTAINS "/Build/Products/" OR processImagePath CONTAINS "/DerivedData/")"#
        case .simulator, .physicalDevice:
            appPath = #"processImagePath CONTAINS "/Containers/Bundle/Application/""#
        }
        switch self {
        case .appsOnly: return "\(appPath) AND NOT (subsystem BEGINSWITH \"com.apple.\")"
        case .appsAllSubsystems: return appPath
        case .everything: return nil
        case .custom:
            let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
