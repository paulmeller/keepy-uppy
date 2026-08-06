import AppKit

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let outputDir = "Resources/Assets.xcassets/AppIcon.appiconset"

guard let symbol = NSImage(systemSymbolName: "balloon.fill", accessibilityDescription: nil) else {
    fatalError("balloon.fill symbol not found")
}

for (size, name) in sizes {
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.8, weight: .regular)
    guard let configured = symbol.withSymbolConfiguration(config) else { continue }

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    configured.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    let pngData = rep.representation(using: .png, properties: [:])!
    try! pngData.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
}

print("Wrote iconset PNGs to \(outputDir)")
