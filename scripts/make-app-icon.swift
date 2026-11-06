import AppKit

// Renders the Sharibako SVG master to a full-bleed .iconset at native
// resolution for every size.
//
// Usage, from the repo root:
//
//   swift scripts/make-app-icon.swift xcode/Sharibako/Sharibako.svg /tmp/Sharibako.iconset
//   iconutil -c icns /tmp/Sharibako.iconset -o xcode/Sharibako/Sharibako.icns
//
// FULL-BLEED, DELIBERATELY. Do not add a rounded-rect clip or a transparent
// margin here — macOS applies its own rounding, shadow, and appearance.
//
// Shipping a pre-rounded icon (our own squircle inset on a transparent canvas,
// per Apple's 824/1024 template) makes macOS 26 read the dark mark as a
// separate foreground layer and extrude it: a bevel with specular highlights
// that reads as emboss and mush at Dock size. Verified by experiment against
// this same artwork — the only difference between the embossed render and the
// clean one is whether the source was pre-rounded. A full-bleed opaque square
// passes through untouched.
//
// Every size is rasterised from the vector at its exact pixel dimensions —
// nothing is upscaled from a smaller render.

let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])

guard let master = NSImage(contentsOf: svgURL) else {
    FileHandle.standardError.write(Data("could not load SVG\n".utf8))
    exit(1)
}

/// Rasterises the SVG at exactly `px` × `px` pixels, edge to edge.
func rasterise(_ image: NSImage, px: Int) -> Data? {
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
    return rep.representation(using: .png, properties: [:])
}

// name -> pixel size
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

for (name, px) in entries {
    guard let data = rasterise(master, px: px) else {
        FileHandle.standardError.write(Data("failed at \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outDir.appendingPathComponent(name))
    print("\(name)  \(px)x\(px)  full-bleed")
}
