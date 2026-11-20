//
//  render-icon.swift
//  Tuno
//
//  Created by Kaan Firat.
//
//  Usage: render-icon <icon.svg> <output.iconset>
//
//  Draws the SVG once at 1024 pt in WebKit, which renders its blur and
//  drop-shadow filters (CoreSVG doesn't), on a transparent background, then
//  writes every size an .iconset needs by scaling that image down.
//

import Cocoa
import WebKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: render-icon <icon.svg> <output.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let svg = try String(contentsOfFile: arguments[1], encoding: .utf8)
let output = URL(fileURLWithPath: arguments[2])
let canvas: CGFloat = 1024

final class Renderer: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: canvas, height: canvas))

    func start() {
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        // Inline, so no file access is needed for the SVG.
        web.loadHTMLString("""
            <html><body style="margin:0;background:transparent">
            <div style="width:\(Int(canvas))px;height:\(Int(canvas))px">\(svg)</div>
            </body></html>
            """, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give filters a beat to paint before taking the picture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: canvas, height: canvas)
            webView.takeSnapshot(with: config) { image, error in
                guard let image else {
                    FileHandle.standardError.write("snapshot failed: \(String(describing: error))\n".data(using: .utf8)!)
                    exit(1)
                }
                do {
                    try self.writeIconset(from: image)
                    exit(0)
                } catch {
                    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
        }
    }

    func writeIconset(from image: NSImage) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try png(from: image, pixels: pixels).write(to: output.appendingPathComponent(name))
            }
        }
    }

    func png(from image: NSImage, pixels: Int) throws -> Data {
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "render-icon", code: 1)
        }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "render-icon", code: 2)
        }
        return data
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer()
renderer.start()
app.run()
