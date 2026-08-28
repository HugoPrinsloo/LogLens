import AppKit

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Puts an image on the pasteboard as PNG (plus TIFF for apps that only read that).
    static func copy(image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var types: [NSPasteboard.PasteboardType] = [.tiff]
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            types.insert(.png, at: 0)
            pb.declareTypes(types, owner: nil)
            pb.setData(png, forType: .png)
            pb.setData(tiff, forType: .tiff)
        } else {
            pb.writeObjects([image])
        }
    }

    static func json(for entry: LogEntry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(entry)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
