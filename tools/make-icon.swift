// Makes Resources/Nostalgy-4-Mail.iconset from the approved artwork (Resources/Icon-source.png).
//
// macOS 26 draws an app icon inside a grey tile unless the image fills the whole square,
// in which case it applies its own rounded shape. The approved artwork has its own rounded
// corners and transparent edges, so this stretches it to fill the square and fills the
// corners with the colour of each half (the system's rounding then removes them).
//
// Usage, from the project folder:
//   swiftc -o /tmp/make-icon tools/make-icon.swift && /tmp/make-icon Resources/Icon-source.png Resources/Nostalgy-4-Mail.iconset
import Cocoa

let args = CommandLine.arguments
guard args.count == 3,
      let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
      let src = NSBitmapImageRep(data: data), src.pixelsWide == 1024, src.pixelsHigh == 1024
else {
    print("usage: make-icon <1024x1024 source.png> <output.iconset>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Opaque area of the artwork in the source image (pixels; x 59...949, y 98...979 from the top).
let art = NSRect(x: 59, y: 1024 - 980, width: 891, height: 882) // bottom-left origin for drawing

// Corner fill colours, sampled from inside each half of the artwork (pixel coordinates from the top).
func colour(_ x: Int, _ y: Int) -> NSColor { src.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)! }
let blueTop = colour(150, 300), blueBottom = colour(150, 900), ivory = colour(850, 750)

let source = NSImage(size: NSSize(width: 1024, height: 1024))
source.addRepresentation(src)

let slots: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
    ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
]
for (name, px) in slots {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let k = CGFloat(px) / 1024
    NSGradient(starting: blueBottom, ending: blueTop)!.draw(in: NSRect(x: 0, y: 0, width: 512 * k, height: 1024 * k), angle: 90)
    ivory.setFill()
    NSRect(x: 512 * k, y: 0, width: 512 * k, height: 1024 * k).fill()
    source.draw(in: NSRect(x: 0, y: 0, width: 1024 * k, height: 1024 * k), from: art, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("icon_\(name).png"))
}
print("Wrote \(slots.count) images to \(outDir.path)")
