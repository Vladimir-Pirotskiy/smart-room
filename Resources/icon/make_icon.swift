import AppKit

// Renders the Smart Room app icon as a 1024×1024 PNG.
// usage: swift make_icon.swift <output.png>
// Layout follows the macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.

let canvas: CGFloat = 1024
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Superellipse ("squircle") outline — closer to the system icon shape than a plain rounded rect.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func radialGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, stops: [(NSColor, CGFloat)]) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: stops.map { $0.0.cgColor } as CFArray, locations: stops.map { $0.1 })!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

guard CommandLine.arguments.count > 1 else {
    print("usage: make_icon <output.png>")
    exit(64)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: canvas, height: canvas)
let graphics = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = graphics
let ctx = graphics.cgContext
let shape = squircle(in: plate)

// Drop shadow under the plate.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(shape)
ctx.setFillColor(color(0x1A1238).cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// Dusk-coloured room: violet at the top, deep navy at the bottom.
let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                            colors: [color(0x6A45F0).cgColor, color(0x3A2496).cgColor, color(0x140E33).cgColor] as CFArray,
                            locations: [0, 0.45, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: [])

// Glows are screened so they add light instead of muddying the violet underneath.
ctx.setBlendMode(.screen)
// Coloured light pooling in the corners — the room's other lamps.
radialGlow(ctx, center: CGPoint(x: plate.minX + 90, y: plate.minY + 110), radius: 430,
           stops: [(color(0xFF4FA3, 0.55), 0), (color(0xFF4FA3, 0), 1)])
radialGlow(ctx, center: CGPoint(x: plate.maxX - 70, y: plate.minY + 170), radius: 400,
           stops: [(color(0x27D3FF, 0.45), 0), (color(0x27D3FF, 0), 1)])

// Warm glow of the bulb itself.
let bulbCenter = CGPoint(x: canvas / 2, y: canvas / 2 + 30)
radialGlow(ctx, center: bulbCenter, radius: 400,
           stops: [(color(0xFFE08A, 0.9), 0), (color(0xFFA53D, 0.45), 0.4), (color(0xFF7A3D, 0), 1)])

ctx.setBlendMode(.normal)

// The bulb glyph, filled with a soft warm-white gradient.
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let size = symbol.size
    let rect = CGRect(x: bulbCenter.x - size.width / 2, y: bulbCenter.y - size.height / 2, width: size.width, height: size.height)

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70, color: color(0xFFF1C4, 0.9).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    symbol.draw(in: rect)
    ctx.setBlendMode(.sourceAtop)
    let fill = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xFFFFFF).cgColor, color(0xFFF3CF).cgColor, color(0xFFD98A).cgColor] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// Glass rim: a highlight along the top edge fading out towards the bottom.
ctx.addPath(shape)
ctx.setLineWidth(10)
ctx.replacePathWithStrokedPath()
ctx.clip()
let rim = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                     colors: [color(0xFFFFFF, 0.55).cgColor, color(0xFFFFFF, 0.08).cgColor, color(0xFFFFFF, 0.18).cgColor] as CFArray,
                     locations: [0, 0.5, 1])!
ctx.drawLinearGradient(rim, start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.minY), options: [])
ctx.restoreGState()

graphics.flushGraphics()
guard let png = rep.representation(using: .png, properties: [:]) else {
    print("could not encode PNG")
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
