import SwiftUI

enum LogLevel: Int, CaseIterable, Codable, Comparable, Identifiable, Hashable {
    case debug = 0
    case info
    case notice
    case error
    case fault

    var id: Int { rawValue }

    init(messageType: String?) {
        switch messageType?.lowercased() {
        case "debug": self = .debug
        case "info": self = .info
        case "error": self = .error
        case "fault": self = .fault
        default: self = .notice   // "Default" in unified logging
        }
    }

    var name: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .notice: "Default"
        case .error: "Error"
        case .fault: "Fault"
        }
    }

    /// The value passed to `log stream --level`.
    var streamArgument: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        default: "default"
        }
    }

    var symbol: String {
        switch self {
        case .debug: "ant"
        case .info: "info.circle"
        case .notice: "circle"
        case .error: "exclamationmark.triangle"
        case .fault: "xmark.octagon"
        }
    }

    var color: Color {
        switch self {
        case .debug: .secondary
        case .info: .blue
        case .notice: .green
        case .error: .orange
        case .fault: .red
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}
