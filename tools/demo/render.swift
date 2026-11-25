// Renders tools/demo/scene.html into build/demo/:
//   demo-light.gif, demo-dark.gif      for the website (its own page background)
//   readme-light.gif, readme-dark.gif  for the README (GitHub's white and dark page backgrounds)
// Copy them to the docs branch to publish them.
//
// Usage, from the project folder (needs ImageMagick, e.g. brew install imagemagick):
//   swiftc -o /tmp/render-demo tools/demo/render.swift && /tmp/render-demo
import Cocoa
import WebKit

let fps = 15.0
let length = 8.0          // seconds; matches T.length in scene.html
let size = NSSize(width: 680, height: 430)
let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let scene = project.appendingPathComponent("tools/demo/scene.html")

final class Renderer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let name: String
    let page: String?         // page background; nil keeps the scene's own
    let frames: URL
    let done: () -> Void
    var frame = 0

    init(name: String, mode: String, page: String?, done: @escaping () -> Void) {
        self.name = name
        self.page = page
        self.done = done
        frames = FileManager.default.temporaryDirectory.appendingPathComponent("nostalgy-\(name)")
        try? FileManager.default.removeItem(at: frames)
        try! FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        web = WKWebView(frame: NSRect(origin: .zero, size: size))
        super.init()
        web.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        web.navigationDelegate = self
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web
        web.loadFileURL(scene, allowingReadAccessTo: scene.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let page else { next(); return }
        web.evaluateJavaScript("document.documentElement.style.setProperty('--page', '\(page)')") { _, _ in self.next() }
    }

    private func next() {
        let total = Int(length * fps)
        guard frame < total else { encode(); return }
        // Start just after the fade-in, so the first frame (the GIF's still image) shows the window;
        // the fade-out and fade-in then run back to back at the end of the loop.
        let t = (Double(frame) / fps + 0.4).truncatingRemainder(dividingBy: length)
        web.evaluateJavaScript("render(\(t))") { _, error in
            if let error { fatalError("render(\(t)): \(error)") }
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = NSNumber(value: Double(size.width * 2)) // 2x for Retina screens
            self.web.takeSnapshot(with: config) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { fatalError("snapshot: \(String(describing: error))") }
                try! png.write(to: self.frames.appendingPathComponent(String(format: "f%04d.png", self.frame)))
                self.frame += 1
                self.next()
            }
        }
    }

    private func encode() {
        let outDir = project.appendingPathComponent("build/demo")
        try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let out = outDir.appendingPathComponent("\(name).gif").path
        let input = frames.appendingPathComponent("f*.png").path
        let palette = frames.appendingPathComponent("palette.png").path
        // One palette for the whole animation, then each frame stores only the area that changed.
        magick(["(", input, "-resize", "1020x", ")", "-append", "-dither", "None", "-colors", "192", "-unique-colors", palette])
        magick(["-delay", "1x\(Int(fps))", input, "-resize", "1020x", "-dither", "None", "-remap", palette,
                "-loop", "0", "-layers", "OptimizePlus", "-layers", "OptimizeTransparency", out])
        print("Wrote \(out)")
        done()
    }

    private func magick(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["magick"] + args
        try! p.run()
        p.waitUntilExit()
        precondition(p.terminationStatus == 0, "magick failed: \(args)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var renderers: [Renderer] = []
let variants: [(name: String, mode: String, page: String?)] = [
    ("demo-light", "light", nil), ("demo-dark", "dark", nil),
    ("readme-light", "light", "#ffffff"), ("readme-dark", "dark", "#0d1117"), // GitHub's page colours
]
var remaining = variants.count
for v in variants {
    renderers.append(Renderer(name: v.name, mode: v.mode, page: v.page) {
        remaining -= 1
        if remaining == 0 { exit(0) }
    })
}
app.run()
