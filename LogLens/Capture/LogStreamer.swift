import Foundation

/// Wraps a `log stream --style ndjson` process and turns its output into `LogEntry` batches.
///
/// Dev/bench mode: `LogLens --replay <file.ndjson> [--rate <lines per second>] [--replay-loop]` feeds a captured
/// file through the exact same parse path instead of spawning `log`, so performance runs are reproducible.
final class LogStreamer {

    struct Configuration {
        var source: LogSource
        var scope: CaptureScope
        var customPredicate: String
        var level: LogLevel
    }

    /// Called on the main queue with batches of decoded entries. Batches are coalesced for ~16 ms after the first
    /// line arrives (leading edge), with a 100 ms timer as the fallback under sustained load.
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
    private var flushScheduled = false
    private var nextID: Int
    private var expectedStop = false
    private let decoder = LogLineDecoder()
    private let parseQueue = DispatchQueue(label: "loglens.stream.parse", qos: .userInitiated)

    // Replay (see type doc).
    private var replayTimer: DispatchSourceTimer?
    private var replayData = Data()
    private var replayOffset = 0

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
        buffer = Data()
        expectedStop = false
        stderrText = ""
        if let path = Self.replayPath {
            try startReplay(path: path, sourceName: config.source.name)
            return
        }
        let cmd = Self.command(for: config)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd.path)
        p.arguments = cmd.args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        stdout = out
        stderr = err

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
            self.parseQueue.async { self.finish(status: proc.terminationStatus) }
        }

        try p.run()
        process = p
        isRunning = true
        startFallbackTimer()
    }

    func stop() {
        flushTimer?.cancel()
        flushTimer = nil
        replayTimer?.cancel()
        replayTimer = nil
        lock.lock(); expectedStop = true; lock.unlock()
        if let p = process {
            if p.isRunning { p.terminate() }
            process = nil
        } else if isRunning {
            // Replay: no process to wait for.
            parseQueue.async { self.finish(status: 0) }
        }
    }

    private func startFallbackTimer() {
        let timer = DispatchSource.makeTimerSource(queue: parseQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        flushTimer = timer
    }

    private func finish(status: Int32) {
        flush()
        lock.lock()
        let text = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = expectedStop
        lock.unlock()
        DispatchQueue.main.async {
            self.isRunning = false
            self.onTerminate?(status, text, expected)
        }
    }

    // MARK: - Replay

    private static let replayPath: String? = argument(after: "--replay")
    private static let replayRate: Int = argument(after: "--rate").flatMap(Int.init) ?? 500
    private static let replayLoop = CommandLine.arguments.contains("--replay-loop")

    private static func argument(after flag: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    private func startReplay(path: String, sourceName: String) throws {
        replayData = try Data(contentsOf: URL(fileURLWithPath: path))
        replayOffset = 0
        isRunning = true
        let perTick = max(1, Self.replayRate / 20)   // 20 ticks/s
        let timer = DispatchSource.makeTimerSource(queue: parseQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var lines = 0
            var end = replayOffset
            while lines < perTick, end < replayData.count {
                if let nl = replayData[end...].firstIndex(of: 0x0A) { end = nl + 1 } else { end = replayData.count }
                lines += 1
            }
            if end > replayOffset {
                consume(replayData[replayOffset..<end], sourceName: sourceName)
                replayOffset = end
            }
            if replayOffset >= replayData.count {
                if Self.replayLoop { replayOffset = 0 } else { DispatchQueue.main.async { self.stop() } }
            }
        }
        timer.resume()
        replayTimer = timer
        startFallbackTimer()
    }

    // MARK: - Parsing

    private func consume(_ data: Data, sourceName: String) {
        buffer.append(data)
        var batch: [LogEntry] = []
        // Walk with a cursor; the old `removeSubrange` per line shifted the whole buffer once per line.
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            let lineData = buffer[start..<nl]
            start = nl + 1
            if lineData.isEmpty { continue }
            if let entry = decoder.decode(lineData, id: nextID, sourceName: sourceName) {
                nextID += 1
                batch.append(entry)
            }
        }
        buffer = start < buffer.endIndex ? Data(buffer[start...]) : Data()
        guard !batch.isEmpty else { return }
        lock.lock(); pending.append(contentsOf: batch); lock.unlock()
        if !flushScheduled {
            flushScheduled = true
            parseQueue.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
                self?.flushScheduled = false
                self?.flush()
            }
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

    /// Repeated values (process, subsystem, category, paths) share one heap buffer per distinct string:
    /// fewer allocations per line, less memory, and `==` hits its identity fast path in the facet matcher.
    private var intern: [String: String] = [:]
    private func interned(_ s: String) -> String {
        if let hit = intern[s] { return hit }
        if intern.count > 4096 { intern.removeAll(keepingCapacity: true) }
        intern[s] = s
        return s
    }

    func decode(_ data: Data, id: Int, sourceName: String) -> LogEntry? {
        guard data.first == UInt8(ascii: "{"), let line = try? json.decode(Line.self, from: data) else { return nil }
        guard line.eventType == nil || line.eventType == "logEvent" else { return nil }
        let message = line.eventMessage ?? ""
        let processPath = interned(line.processImagePath ?? "")
        let process = interned(processPath.split(separator: "/").last.map(String.init) ?? "?")
        let sender = interned((line.senderImagePath ?? "").split(separator: "/").last.map(String.init) ?? "")
        let subsystem = interned(line.subsystem ?? "")
        let category = interned(line.category ?? "")

        var date = Date()
        var timeText = ""
        if let ts = line.timestamp {
            if let fast = Self.parseTimestamp(ts) {
                date = fast.date
                timeText = fast.timeText
            } else if let slow = dateFormatter.date(from: ts) {
                date = slow
                timeText = Formatters.time.string(from: slow)
            }
        }
        if timeText.isEmpty { timeText = Formatters.time.string(from: date) }

        let parsed = MessageParser.parse(message)
        var entry = LogEntry(
            id: id,
            timestamp: date,
            level: LogLevel(messageType: line.messageType),
            process: process,
            processPath: processPath,
            processID: line.processID ?? 0,
            threadID: line.threadID ?? 0,
            sender: sender,
            subsystem: subsystem,
            category: category,
            message: message,
            activityID: line.activityIdentifier,
            traceID: line.traceID,
            sourceName: sourceName,
            parsed: parsed
        )
        entry.searchKey = LogEntry.makeSearchKey(title: parsed.title, message: message, process: process, subsystem: subsystem, category: category)
        entry.timeText = timeText
        return entry
    }

    // MARK: Fast timestamp

    /// `log` emits a fixed "yyyy-MM-dd HH:mm:ss.SSSSSS±HHMM". Hand-parsing the bytes is ~100× cheaper than
    /// `DateFormatter` (ICU) and gives us the "HH:mm:ss.SSS" display string for free.
    private static var dayCache: (y: Int, m: Int, d: Int, days: Int)?

    static func parseTimestamp(_ s: String) -> (date: Date, timeText: String)? {
        var u = Array(s.utf8)
        // "2026-08-28 21:14:03.123456+0200" = 31 bytes; tolerate "Z" (a trailing zero offset).
        guard u.count >= 26 else { return nil }
        if u.count == 27, u[26] == UInt8(ascii: "Z") { u.replaceSubrange(26..<27, with: Array("+0000".utf8)) }
        guard u.count >= 31 else { return nil }
        @inline(__always) func digit(_ i: Int) -> Int? {
            let b = u[i]; return b >= 48 && b <= 57 ? Int(b - 48) : nil
        }
        @inline(__always) func num(_ from: Int, _ len: Int) -> Int? {
            var v = 0
            for i in from..<(from + len) { guard let d = digit(i) else { return nil }; v = v * 10 + d }
            return v
        }
        guard u[4] == UInt8(ascii: "-"), u[7] == UInt8(ascii: "-"), u[10] == UInt8(ascii: " "),
              u[13] == UInt8(ascii: ":"), u[16] == UInt8(ascii: ":"), u[19] == UInt8(ascii: "."),
              let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2), let micro = num(20, 6) else { return nil }
        let sign: Int
        switch u[26] {
        case UInt8(ascii: "+"): sign = 1
        case UInt8(ascii: "-"): sign = -1
        default: return nil
        }
        guard let oh = num(27, 2), let om = num(29, 2) else { return nil }

        let days: Int
        if let c = dayCache, c.y == y, c.m == mo, c.d == d {
            days = c.days
        } else {
            days = daysFromCivil(y, mo, d)
            dayCache = (y, mo, d, days)
        }
        let offset = sign * (oh * 3600 + om * 60)
        let seconds = Double(days * 86_400 + h * 3600 + mi * 60 + se - offset) + Double(micro) / 1_000_000
        let timeText = String(decoding: u[11..<23], as: UTF8.self)   // HH:mm:ss.SSS
        return (Date(timeIntervalSince1970: seconds), timeText)
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
