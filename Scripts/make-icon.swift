// Builds Resources/AppIcon.icns from the artwork in Resources/AppIcon-source.png.
// Run from the project root:  swift Scripts/make-icon.swift
//
// The source art is a rounded square on a solid black background. This finds the rounded
// square, cuts it out onto transparency and places it on Apple's icon grid (an 824pt body in
// a 1024pt canvas, with a soft drop shadow), so the Dock and Finder don't show black corners.
import AppKit

let source = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: "Resources/AppIcon-source.png")))!
let width = source.pixelsWide, height = source.pixelsHigh

func isArt(_ x: Int, _ y: Int) -> Bool {
    guard let c = source.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
    return (c.redComponent + c.greenComponent + c.blueComponent) * 255 > 20
}

// Edges of the rounded square, found along the centre lines (bitmap rows run top to bottom).
let midX = width / 2, midY = height / 2
let left = (0..<midX).first { isArt($0, midY) }!
let right = (midX..<width).reversed().first { isArt($0, midY) }!
let top = (0..<midY).first { isArt(midX, $0) }!
let bottom = (midY..<height).reversed().first { isArt(midX, $0) }!
// Pull the crop in slightly so the art's own anti-aliased rim (half black surround) is left
// out; otherwise a light icon gets a dark outline.
let inset = max(2, (right - left) / 200)
let crop = NSRect(x: left + inset, y: top + inset, width: right - left + 1 - 2 * inset, height: bottom - top + 1 - 2 * inset)
// The tile's own colour just inside its top edge, used under the art so the clip's
// anti-aliased edge blends into the tile rather than into black.
let edgeColor = source.colorAt(x: midX, y: Int(crop.minY) + inset) ?? .black

// Corner radius from where the art starts along the top-left diagonal: a 45° point on a
// corner of radius R sits R·(1 − 1/√2) in from both edges.
let diagonal = (0..<min(Int(crop.width), Int(crop.height)) / 2).first { isArt(left + $0, top + $0) } ?? 0
let sourceRadius = Double(diagonal) / (1 - 1 / 2.0.squareRoot())
print("art bounds \(crop), corner radius ≈ \(Int(sourceRadius))px")

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = size / 1024

    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    // Never smaller than Apple's grid radius, and a touch larger than the art's own corner so
    // none of its black surround survives.
    let scale = body.width / crop.width
    let radius = max(185 * s, CGFloat(sourceRadius) * scale + 2 * s)
    let mask = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    edgeColor.setFill()
    mask.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    mask.addClip()
    // NSImage.draw(from:) takes a bottom-left-origin rect; the crop was measured top-down.
    let from = NSRect(x: crop.minX, y: CGFloat(height) - crop.maxY, width: crop.width, height: crop.height)
    NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
        source.draw(in: rect)
    }.draw(in: body, from: from, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
