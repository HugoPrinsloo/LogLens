// Renders the LogLens app icon (pre-macOS 26 fallback) from the Liquid Glass layer SVGs in AppIcon.icon.
// Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let layersDir = root.appendingPathComponent("LogLens/Resources/AppIcon.icon/Assets")
let outDir = root.appendingPathComponent("LogLens/Resources/Assets.xcassets/AppIcon.appiconset")
let layerOrder = ["backdrop.svg", "body.svg", "cap.svg", "lens.svg"]   // bottom → top
let layers = layerOrder.map { NSImage(contentsOf: layersDir.appendingPathComponent($0))! }
let canvas: CGFloat = 1024

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))
    ctx.interpolationQuality = .high
    let k = CGFloat(px) / canvas
    ctx.scaleBy(x: k, y: k)
    // macOS icon grid: 824pt squircle on a 1024pt canvas.
    let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: iconRect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape); ctx.clip()
    for img in layers { img.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1) }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let sizes: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
var images: [[String: String]] = []
for (pt, scale) in sizes {
    let name = "icon_\(pt)x\(pt)@\(scale)x.png"
    try! render(pt * scale).write(to: outDir.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: outDir.appendingPathComponent("Contents.json"))
try! render(1024).write(to: root.appendingPathComponent("docs/icon-preview.png"))
print("wrote \(images.count) icons")
