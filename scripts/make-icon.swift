// Builds Resources/AppIcon.icns from docs/logo.svg.
// Run from the repo root:  swift scripts/make-icon.swift
//
// WebKit draws the SVG (it supports the logo's blur and shadow filters), then the
// artwork is clipped to a rounded square and placed on the standard 1024 px macOS icon
// canvas: 824 px of artwork with a soft shadow. sips makes the smaller sizes and
// iconutil packs them into an .icns file.
import AppKit
import WebKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svg = root.appendingPathComponent("docs/logo.svg")
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let work = FileManager.default.temporaryDirectory.appendingPathComponent("glassvinyl-icon")
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

// WebKit only loads local files from the folder it's given, so render a copy next to a page.
let artwork: CGFloat = 824, canvas: CGFloat = 1024
try FileManager.default.copyItem(at: svg, to: work.appendingPathComponent("logo.svg"))
let page = work.appendingPathComponent("logo.html")
try "<html><body style='margin:0'><img src='logo.svg' width='\(Int(artwork))' height='\(Int(artwork))'></body></html>"
    .write(to: page, atomically: true, encoding: .utf8)

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("\(tool) failed") }
}

/// Clips the rendered logo to a rounded square and places it on the icon canvas.
func compose(_ logo: NSImage) -> Data {
    let pixels = Int(canvas)
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let inset = (canvas - artwork) / 2
    let rect = CGRect(x: inset, y: inset + 8, width: artwork, height: artwork)  // a little high, room for the shadow
    let shape = CGPath(roundedRect: rect, cornerWidth: artwork * 0.2237, cornerHeight: artwork * 0.2237, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.4))
    context.addPath(shape)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.addPath(shape)
    context.clip()
    var proposed = CGRect(origin: .zero, size: logo.size)
    if let image = logo.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
        context.draw(image, in: rect)
    }
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

final class Renderer: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give WebKit a moment to finish drawing the filters.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            webView.takeSnapshot(with: nil) { image, error in
                guard let image else { fatalError("Snapshot failed: \(String(describing: error))") }
                let iconset = work.appendingPathComponent("AppIcon.iconset")
                try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
                let master = work.appendingPathComponent("icon_1024.png")
                try! compose(image).write(to: master)

                for size in [16, 32, 128, 256, 512] {
                    for scale in [1, 2] {
                        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                        let pixels = String(size * scale)
                        run("/usr/bin/sips", ["-z", pixels, pixels, master.path, "--out", iconset.appendingPathComponent(name).path])
                    }
                }
                run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output.path])
                print("Wrote \(output.path)")
                exit(0)
            }
        }
    }
}

let app = NSApplication.shared
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: artwork, height: artwork))
let renderer = Renderer()
webView.navigationDelegate = renderer
webView.loadFileURL(page, allowingReadAccessTo: work)
app.run()
