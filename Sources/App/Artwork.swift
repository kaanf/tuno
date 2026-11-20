//
//  Artwork.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit

/// Artwork prepared for the menu bar: a small thumbnail, its greyscale twin
/// for the paused state, and the tint the waveform takes from it.
struct Artwork {
    let image: NSImage
    let paused: NSImage
    let tint: Tint

    /// Edge length the thumbnail is rendered at: 16 pt at up to 3x.
    private static let thumbnailPixels = 48

    init?(_ source: NSImage) {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let small = Self.render(cg, side: Self.thumbnailPixels, gray: false),
              let gray = Self.render(cg, side: Self.thumbnailPixels, gray: true) else { return nil }
        let size = NSSize(width: 16, height: 16)
        image = NSImage(cgImage: small, size: size)
        paused = NSImage(cgImage: gray, size: size)
        tint = Tint(dominantIn: cg)
    }

    private static func render(_ image: CGImage, side: Int, gray: Bool) -> CGImage? {
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha = gray ? CGImageAlphaInfo.none : .premultipliedLast
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: aspectFill(image, side: CGFloat(side)))
        return context.makeImage()
    }

    private static func aspectFill(_ image: CGImage, side: CGFloat) -> CGRect {
        let scale = max(side / CGFloat(image.width), side / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        return CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h)
    }
}

/// The artwork's most vivid colour, kept as HSB so it can be adjusted to
/// read well on either menu bar appearance.
struct Tint {
    let hue: CGFloat
    let saturation: CGFloat
    let brightness: CGFloat

    /// Below this the artwork is effectively greyscale and the tint stays neutral.
    private static let neutralSaturation: CGFloat = 0.12

    init(dominantIn image: CGImage) {
        // Sample a tiny downscale and keep the pixel with the most colour.
        // An average would turn most artwork into brown.
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var best: (score: CGFloat, h: CGFloat, s: CGFloat, b: CGFloat) = (-1, 0, 0, 0.5)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let color = NSColor(srgbRed: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                                blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            // Near-black pixels have unstable hue; don't let them win.
            let score = b < 0.18 ? 0 : s * b
            if score > best.score { best = (score, h, s, b) }
        }
        hue = best.h
        saturation = best.s
        brightness = best.b
    }

    init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    func color(onDark dark: Bool) -> NSColor {
        let neutral = saturation < Self.neutralSaturation
        let s = neutral ? 0 : max(saturation, 0.5)
        let b = dark ? min(max(brightness, 0.78), 0.95) : min(max(brightness, 0.42), 0.6)
        return NSColor(hue: hue, saturation: s, brightness: neutral ? (dark ? 0.85 : 0.35) : b, alpha: 1)
    }
}
