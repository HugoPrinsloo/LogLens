import Foundation

/// Finds simulators (via `simctl`) and physical devices (via `devicectl`).
enum SourceDiscovery {

    static func discover() async -> [LogSource] {
        async let sims = simulators()
        async let devices = physicalDevices()
        var all: [LogSource] = [.mac]
        all.append(contentsOf: await sims)
        all.append(contentsOf: await devices)
        return all
    }

    private static func simulators() async -> [LogSource] {
        guard let data = try? await ShellRunner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j", "available"]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]] else { return [] }

        var result: [LogSource] = []
        for (runtimeID, list) in devices {
            let runtime = prettyRuntime(runtimeID)
            for d in list {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { continue }
                let state = (d["state"] as? String) ?? "Unknown"
                result.append(LogSource(id: udid, name: name, kind: .simulator(udid: udid, runtime: runtime, state: state)))
            }
        }
        // Booted first, then by runtime desc, then name.
        return result.sorted { a, b in
            if a.isBooted != b.isBooted { return a.isBooted }
            if a.subtitle != b.subtitle { return a.subtitle > b.subtitle }
            return a.name < b.name
        }
    }

    private static func physicalDevices() async -> [LogSource] {
        guard let data = try? await ShellRunner.run("/usr/bin/xcrun", ["devicectl", "list", "devices", "--json-output", "-", "--timeout", "5"], timeout: 8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else { return [] }

        var out: [LogSource] = []
        for d in devices {
            let hw = d["hardwareProperties"] as? [String: Any]
            let props = d["deviceProperties"] as? [String: Any]
            let reality = (hw?["reality"] as? String) ?? ""
            guard reality == "physical" else { continue }
            let platform = (hw?["platform"] as? String) ?? ""
            guard platform.lowercased().contains("ios") || platform.isEmpty else { continue }
            let udid = (hw?["udid"] as? String) ?? (d["identifier"] as? String) ?? UUID().uuidString
            let name = (props?["name"] as? String) ?? "iOS Device"
            let model = (hw?["marketingName"] as? String) ?? (hw?["productType"] as? String) ?? "Device"
            out.append(LogSource(id: udid, name: name, kind: .physicalDevice(udid: udid, model: model)))
        }
        return out
    }

    private static func prettyRuntime(_ id: String) -> String {
        // com.apple.CoreSimulator.SimRuntime.iOS-27-0 → iOS 27.0
        let tail = id.split(separator: ".").last.map(String.init) ?? id
        var parts = tail.split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return tail }
        let os = parts.removeFirst()
        return "\(os) \(parts.joined(separator: "."))"
    }
}

/// Runs a process to completion and returns stdout.
enum ShellRunner {
    struct Failure: Error { let status: Int32; let stderr: String }

    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 15) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = arguments
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            var resumed = false
            let lock = NSLock()
            func finish(_ r: Result<Data, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(with: r)
            }
            p.terminationHandler = { proc in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    finish(.success(data))
                } else {
                    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    finish(.failure(Failure(status: proc.terminationStatus, stderr: e)))
                }
            }
            do { try p.run() } catch { finish(.failure(error)); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
            }
        }
    }
}
