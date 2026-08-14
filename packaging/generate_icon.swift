import AppKit

// Generates the app icon: `swift packaging/generate_icon.swift` from the repo root.
//
// **An app icon is not a menu bar glyph, and this script used to make one of the
// wrong kind.** It drew `balloon.fill` in black on transparency — which is
// exactly right for the status item, where a template image is recoloured by
// the system to match the menu bar — and handed the same thing to the asset
// catalogue as the application icon. The result was a black silhouette with no
// container: an indistinct blob wherever macOS draws the icon small (the
// Shortcuts action list, Spotlight, the Finder sidebar), and nearly invisible
// against a dark background.
//
// What macOS wants instead is full-bleed artwork inside the rounded rectangle
// every other icon on the Dock shares. The proportions below are Apple's: on a
// 1024pt canvas the rounded rect is 824pt with a 185.4pt corner radius, which
// is what makes an icon sit level with its neighbours rather than looking a
// size too big or too small.
let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let outputDir = "Resources/Assets.xcassets/AppIcon.appiconset"

/// Apple's macOS icon grid, as fractions of the full canvas.
let contentFraction: CGFloat = 824.0 / 1024.0
let cornerFraction: CGFloat = 185.4 / 824.0

/// The balloon is the product's one visual idea — it is on the README and it is
/// what fills in the menu bar — so the icon is a balloon too, in the red the
/// README's artwork already uses rather than a second colour nobody chose.
let topColour = NSColor(srgbRed: 0.96, green: 0.36, blue: 0.36, alpha: 1)
let bottomColour = NSColor(srgbRed: 0.80, green: 0.15, blue: 0.20, alpha: 1)

guard let symbol = NSImage(systemSymbolName: "balloon.fill", accessibilityDescription: nil) else {
    fatalError("balloon.fill symbol not found")
}

for (size, name) in sizes {
    let canvas = CGFloat(size)
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
    NSGraphicsContext.current?.imageInterpolation = .high

    let inset = canvas * (1 - contentFraction) / 2
    let plate = NSRect(x: inset, y: inset,
                       width: canvas - inset * 2, height: canvas - inset * 2)
    let radius = plate.width * cornerFraction
    let rounded = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    NSGradient(starting: topColour, ending: bottomColour)?.draw(in: rounded, angle: -90)

    // The glyph is drawn white and generously inset. At 16pt the container is
    // 13pt across, so anything more detailed than a silhouette turns to mush —
    // the balloon's outline is the only thing that survives, and it survives
    // only if it is not crowding the edges.
    let glyphSide = plate.width * 0.56
    let glyphRect = NSRect(x: plate.midX - glyphSide / 2,
                           y: plate.midY - glyphSide / 2,
                           width: glyphSide, height: glyphSide)
    let config = NSImage.SymbolConfiguration(pointSize: glyphSide, weight: .medium)
    if let configured = symbol.withSymbolConfiguration(config) {
        let tinted = NSImage(size: glyphRect.size, flipped: false) { bounds in
            configured.draw(in: bounds)
            NSColor.white.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: glyphRect)
    }

    NSGraphicsContext.restoreGraphicsState()

    let pngData = rep.representation(using: .png, properties: [:])!
    try! pngData.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
    print("wrote \(name).png (\(size)px)")
}
