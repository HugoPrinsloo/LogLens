import Foundation

/// Wraps a `log stream --style ndjson` process and turns its output into `LogEntry` batches.
final class LogStreamer {

    struct Configuration {
        var source: LogSource
        var scope: CaptureScope
        var customPredicate: String
        var level: LogLevel
    }

    /// Called on the main queue with batches of decoded entries (~10×/second at most).
    var onBatch: (([LogEntry]) -> Void)?
    /// Called on the main queue when the process ends. `expected` is true for user-initiated stops.
    var onTerminate: ((_ status: Int32, _ stderr: String, _ expected: Bool) -> Void)?

    private(set) var isRunning = false
    private var process: Process?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var stderrText = ""
    private var buffer = Data()
    private var pending: [LogEntry] = []
    private let lock = NSLock()
    private var flushTimer: DispatchSourceTimer?
    private var nextID: Int
    private var expectedStop = false
    private let decoder = LogLineDecoder()
    private let parseQueue = DispatchQueue(label: "loglens.stream.parse", qos: .userInitiated)

    init(startingID: Int = 1) { nextID = startingID }

    static func command(for config: Configuration) -> (path: String, args: [String]) {
        var args: [String] = []
        let path: String
        switch config.source.kind {
        case .mac:
            path = "/usr/bin/log"
            args = ["stream"]
        case let .simulator(udid, _, _):
            path = "/usr/bin/xcrun"
            args = ["simctl", "spawn", udid, "log", "stream"]
        case let .physicalDevice(udid, _):
            path = "/usr/bin/xcrun"
            args = ["devicectl", "device", "unsupported", udid] // never launched; see LogSource.isSupported
        }
        args += ["--style", "ndjson", "--level", config.level.streamArgument, "--type", "log"]
        if let predicate = config.scope.predicate(for: config.source, custom: config.customPredicate) {
            args += ["--predicate", predicate]
        }
        return (path, args)
    }

    func start(_ config: Configuration) throws {
        stop()
        let cmd = Self.command(for: config)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd.path)
        p.arguments = cmd.args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        stdout = out
        stderr = err
        stderrText = ""
        buffer = Data()
        expectedStop = false

        let sourceName = config.source.name
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.parseQueue.async { self.consume(data, sourceName: sourceName) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            self.lock.lock(); self.stderrText += s; self.lock.unlock()
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            self.parseQueue.async {
                self.flush()
                self.lock.lock()
                let text = self.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                let expected = self.expectedStop
                self.lock.unlock()
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.onTerminate?(proc.terminationStatus, text, expected)
                }
            }
        }

        try p.run()
        process = p
        isRunning = true

        let timer = DispatchSource.makeTimerSource(queue: parseQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        flushTimer = timer
    }

    func stop() {
        flushTimer?.cancel()
        flushTimer = nil
        guard let p = process else { return }
        lock.lock(); expectedStop = true; lock.unlock()
        if p.isRunning { p.terminate() }
        process = nil
    }

    // MARK: - Parsing

    private func consume(_ data: Data, sourceName: String) {
        buffer.append(data)
        var batch: [LogEntry] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if lineData.isEmpty { continue }
            if let entry = decoder.decode(lineData, id: nextID, sourceName: sourceName) {
                nextID += 1
                batch.append(entry)
            }
        }
        if !batch.isEmpty {
            lock.lock(); pending.append(contentsOf: batch); lock.unlock()
        }
    }

    private func flush() {
        lock.lock()
        let out = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !out.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onBatch?(out) }
    }
}

/// Decodes one NDJSON line from `log stream`.
final class LogLineDecoder {

    private struct Line: Decodable {
        let eventType: String?
        let messageType: String?
        let timestamp: String?
        let subsystem: String?
        let category: String?
        let eventMessage: String?
        let processImagePath: String?
        let senderImagePath: String?
        let processID: Int?
        let threadID: Int?
        let activityIdentifier: Int?
        let traceID: UInt64?
    }

    private let json = JSONDecoder()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()

    func decode(_ data: Data, id: Int, sourceName: String) -> LogEntry? {
        guard data.first == UInt8(ascii: "{"), let line = try? json.decode(Line.self, from: data) else { return nil }
        guard line.eventType == nil || line.eventType == "logEvent" else { return nil }
        let message = line.eventMessage ?? ""
        let processPath = line.processImagePath ?? ""
        let process = processPath.split(separator: "/").last.map(String.init) ?? "?"
        let sender = (line.senderImagePath ?? "").split(separator: "/").last.map(String.init) ?? ""
        let date = line.timestamp.flatMap { dateFormatter.date(from: $0) } ?? Date()

        return LogEntry(
            id: id,
            timestamp: date,
            level: LogLevel(messageType: line.messageType),
            process: process,
            processPath: processPath,
            processID: line.processID ?? 0,
            threadID: line.threadID ?? 0,
            sender: sender,
            subsystem: line.subsystem ?? "",
            category: line.category ?? "",
            message: message,
            activityID: line.activityIdentifier,
            traceID: line.traceID,
            sourceName: sourceName,
            parsed: MessageParser.parse(message)
        )
    }
}
