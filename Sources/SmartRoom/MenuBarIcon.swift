import AppKit

/// The menu bar icon. Two independent signals: the bulb is filled while any light is on, and it sits
/// inside a key cap while the number pad controls the lights.
///
/// Every state is drawn on the same canvas, so switching modes never changes the width of the
/// status item or nudges its neighbours.
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]
    private static let canvas = NSSize(width: 19, height: 18)

    static func image(lit: Bool, numpad: Bool) -> NSImage {
        let key = "\(lit)-\(numpad)"
        if let cached = cache[key] { return cached }
        let image = numpad ? keyCap(lit: lit) : bulb(lit: lit)
        image.isTemplate = true
        cache[key] = image
        return image
    }

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? NSImage()
    }

    private static func centered(_ image: NSImage, in size: NSSize, dy: CGFloat = 0) -> NSRect {
        NSRect(x: (size.width - image.size.width) / 2, y: (size.height - image.size.height) / 2 + dy,
               width: image.size.width, height: image.size.height)
    }

    private static func bulb(lit: Bool) -> NSImage {
        let glyph = symbol(lit ? "lightbulb.fill" : "lightbulb", size: 15, weight: .regular)
        return NSImage(size: canvas, flipped: false) { _ in
            glyph.draw(in: centered(glyph, in: canvas))
            return true
        }
    }

    private static func keyCap(lit: Bool) -> NSImage {
        let glyph = symbol(lit ? "lightbulb.fill" : "lightbulb", size: 9, weight: lit ? .medium : .bold)
        return NSImage(size: canvas, flipped: false) { _ in
            // A key seen slightly from above: a rounded cap whose lower edge is thicker than the rest.
            let cap = NSRect(x: (canvas.width - 17) / 2, y: 0.5, width: 17, height: 17)
            NSBezierPath(roundedRect: cap, xRadius: 4.5, yRadius: 4.5).fill()
            let top = NSRect(x: cap.minX + 1.25, y: cap.minY + 2.75, width: cap.width - 2.5, height: cap.height - 4)
            if let context = NSGraphicsContext.current?.cgContext {
                context.setBlendMode(.destinationOut)
                NSBezierPath(roundedRect: top, xRadius: 3.25, yRadius: 3.25).fill()
                context.setBlendMode(.normal)
            }
            var spot = centered(glyph, in: canvas)
            spot.origin.y = top.midY - glyph.size.height / 2
            glyph.draw(in: spot)
            return true
        }
    }
}
