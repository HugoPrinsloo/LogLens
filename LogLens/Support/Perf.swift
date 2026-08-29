import Foundation
import os

/// Signposts for the hot paths. Instruments → "Points of Interest" shows each interval; `--replay` makes runs comparable.
enum Perf {
    static let signposter = OSSignposter(logHandle: OSLog(subsystem: "com.hugoprinsloo.LogLens", category: .pointsOfInterest))

    @inline(__always)
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }
}
