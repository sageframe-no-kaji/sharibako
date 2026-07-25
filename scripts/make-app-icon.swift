import AppKit
import QuartzCore

// Renders the Sharibako SVG master onto Apple's macOS icon grid at native
// resolution for every iconset size.
//
// Usage, from the repo root:
//
//   swift scripts/make-app-icon.swift xcode/Sharibako/Sharibako.svg /tmp/Sharibako.iconset
//   iconutil -c icns /tmp/Sharibako.iconset -o xcode/Sharibako/Sharibako.icns
//
// Every size is rasterised from the vector at its exact pixel dimensions —
// nothing is ever upscaled from a smaller render, which is what made the
// earlier .icns soft at Dock and Finder sizes.
//
// Grid (per Apple's macOS app icon template, 1024pt canvas):
//   content square: 824pt, centred      -> 824/1024 of the canvas
//   corner radius:  185.4pt              -> 185.4/1024 of the canvas
// The SVG is a full-bleed square (cream ground + dark mark), so the rounded
// rect is a clip, not a drawn background.

let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])

guard let master = NSImage(contentsOf: svgURL) else {
    FileHandle.standardError.write(Data("could not load SVG\n".utf8))
    exit(1)
}

let contentRatio: CGFloat = 824.0 / 1024.0
let radiusRatio: CGFloat = 185.4 / 1024.0

/// Rasterises the SVG at exactly `px` × `px` pixels.
func rasterise(_ image: NSImage, px: Int) -> CGImage? {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px,
            pixelsHigh: px,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else { return nil }
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: px, height: px),
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage
}

/// Composes `artwork` onto a transparent `canvas`-sized canvas, clipped to the
/// grid's continuous-corner rounded rect.
func compose(artwork: CGImage, canvas: Int) -> CGImage? {
    let side = CGFloat(canvas)
    let content = (side * contentRatio).rounded()
    let origin = ((side - content) / 2).rounded()
    let radius = side * radiusRatio

    guard
        let ctx = CGContext(
            data: nil,
            width: canvas,
            height: canvas,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return nil }
    ctx.interpolationQuality = .high

    let layer = CALayer()
    layer.bounds = CGRect(x: 0, y: 0, width: content, height: content)
    layer.anchorPoint = .zero
    layer.contents = artwork
    layer.contentsGravity = .resize
    layer.cornerRadius = radius
    layer.cornerCurve = .continuous
    layer.masksToBounds = true
    layer.contentsScale = 1

    // `render(in:)` ignores `position`/`anchorPoint` — it draws the layer at
    // the context's origin, so the centring translation has to be explicit.
    ctx.saveGState()
    ctx.translateBy(x: origin, y: origin)
    layer.render(in: ctx)
    ctx.restoreGState()
    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "makeicon", code: 1)
    }
    try data.write(to: url)
}

// name -> canvas pixel size
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for (name, canvas) in entries {
    // Rasterise the vector at the exact pixel size the content occupies —
    // never upscale a smaller render.
    let contentPx = Int((CGFloat(canvas) * contentRatio).rounded())
    guard let artwork = rasterise(master, px: contentPx),
        let composed = compose(artwork: artwork, canvas: canvas)
    else {
        FileHandle.standardError.write(Data("failed at \(name)\n".utf8))
        exit(1)
    }
    try write(composed, to: outDir.appendingPathComponent(name))
    print("\(name)  canvas=\(canvas)  content=\(contentPx)")
}
