import Foundation
import zlib

/// Turns captured bodies into something readable: inflates gzip/deflate and pretty-prints JSON.
enum BodyDecoder {

    struct Decoded {
        var data: Data
        var wasCompressed: Bool
        var failed: Bool
    }

    /// Applies `Content-Encoding` (gzip, x-gzip, deflate). Anything else is returned untouched.
    static func decode(_ data: Data, contentEncoding: String?) -> Decoded {
        guard !data.isEmpty, let enc = contentEncoding?.lowercased() else { return Decoded(data: data, wasCompressed: false, failed: false) }
        guard enc.contains("gzip") || enc.contains("deflate") else { return Decoded(data: data, wasCompressed: false, failed: false) }
        if let out = inflate(data) { return Decoded(data: out, wasCompressed: true, failed: false) }
        return Decoded(data: data, wasCompressed: true, failed: true)
    }

    /// zlib with automatic gzip/zlib header detection; falls back to raw deflate.
    static func inflate(_ input: Data) -> Data? {
        if let d = inflate(input, windowBits: 15 + 32) { return d }
        return inflate(input, windowBits: -15)
    }

    private static func inflate(_ input: Data, windowBits: Int32) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var status: Int32 = Z_OK
        let result: Bool = input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = UInt32(input.count)
            repeat {
                let produced: Int = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = UInt32(chunk)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    return chunk - Int(stream.avail_out)
                }
                if produced > 0 { output.append(buffer, count: produced) }
                if status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR { return false }
                if output.count > 64 * 1024 * 1024 { return false }
            } while status != Z_STREAM_END && stream.avail_in > 0
            return true
        }
        return result && !output.isEmpty ? output : nil
    }

    // MARK: - Presentation

    static func prettyJSON(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: out, encoding: .utf8)
    }

    static func isProbablyText(_ data: Data, contentType: String) -> Bool {
        let ct = contentType.lowercased()
        if ct.hasPrefix("text/") || ct.contains("json") || ct.contains("xml") || ct.contains("javascript") || ct.contains("x-www-form-urlencoded") || ct.contains("html") { return true }
        // Sniff: no NULs in the first KB and valid UTF-8.
        let head = data.prefix(1024)
        return !head.contains(0) && String(data: head, encoding: .utf8) != nil
    }
}
