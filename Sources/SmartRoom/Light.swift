import Foundation
import SwiftUI

enum LightMode: Equatable {
    case white(kelvin: Int)
    case color(r: Int, g: Int, b: Int)
    case scene(id: Int)
    /// A slow colour drift animated by this app (see `LightFlow`); the lamp itself just sees colour changes.
    case flow(id: String)
    case unknown
}

struct RGB: Hashable {
    var r: Int
    var g: Int
    var b: Int

    /// How a lamp colour looks on screen once `softness` percent of white is blended in.
    func display(softness: Int) -> (r: Double, g: Double, b: Double) {
        let k = Light.whiteShare(softness: softness)
        func mix(_ value: Int) -> Double { let v = Double(value) / 255; return v + (1 - v) * k }
        return (mix(r), mix(g), mix(b))
    }

    func displayColor(softness: Int) -> Color {
        let rgb = display(softness: softness)
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// Hue (0..<1), saturation and brightness.
    var hsb: (h: Double, s: Double, b: Double) {
        let r = Double(r) / 255, g = Double(g) / 255, b = Double(b) / 255
        let high = max(r, g, b), span = high - min(r, g, b)
        guard span > 0 else { return (0, 0, high) }
        let sector: Double
        if high == r { sector = ((g - b) / span).truncatingRemainder(dividingBy: 6) }
        else if high == g { sector = (b - r) / span + 2 }
        else { sector = (r - g) / span + 4 }
        return ((sector / 6 + 1).truncatingRemainder(dividingBy: 1), span / high, high)
    }

    static func fromHSB(h: Double, s: Double, b: Double) -> RGB {
        let sector = h * 6, index = Int(sector) % 6, f = sector - sector.rounded(.down)
        let p = b * (1 - s), q = b * (1 - s * f), t = b * (1 - s * (1 - f))
        let rgb = [(b, t, p), (q, b, p), (p, b, t), (p, q, b), (t, p, b), (b, p, q)][index]
        return RGB(r: Int((rgb.0 * 255).rounded()), g: Int((rgb.1 * 255).rounded()), b: Int((rgb.2 * 255).rounded()))
    }

    /// The colour `t` (0...1) of the way from `a` to `b`, going the short way around the colour
    /// wheel. A straight line through RGB space passes through a dull, greyish colour whenever the
    /// two ends are far apart; this stays as vivid as the ends are.
    static func blend(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let from = a.hsb, to = b.hsb
        var turn = to.h - from.h
        if turn > 0.5 { turn -= 1 } else if turn < -0.5 { turn += 1 }
        let hue = (from.h + turn * t + 1).truncatingRemainder(dividingBy: 1)
        return fromHSB(h: hue, s: from.s + (to.s - from.s) * t, b: from.b + (to.b - from.b) * t)
    }
}

/// Which local protocol a light speaks.
enum LightKind: String {
    case wiz, yeelight
}

struct Light: Identifiable, Equatable {
    /// The light's unique key: the MAC address of a WiZ lamp, "yeelight-<device id>" for a Yeelight one.
    let mac: String
    var ip: String
    var kind = LightKind.wiz
    /// WiZ module name or Yeelight model, once the light has reported it.
    var module: String?
    /// Commands a Yeelight light says it supports; empty until it has answered a search.
    var methods: Set<String> = []
    var isOn = false
    var dimming = 100
    var mode: LightMode = .unknown
    /// 0...100: how much white the lamp blends into its colour. 0 is vivid, higher is pastel.
    /// Sent to the lamp as its cold- and warm-white channel levels alongside r/g/b.
    var softness = 0
    /// The colour a running flow is showing right now.
    var flowColor: RGB?
    /// Animation speed (10...200, 100 is normal) the lamp reports for its animated built-in scenes;
    /// nil for a still scene and for every other mode.
    var sceneSpeed: Int?
    var minKelvin = 2200
    var maxKelvin = 6500
    var lastSeen = Date()

    var id: String { mac }

    /// WiZ module names encode the hardware: ..._SHRGB_... (colour), ..._SHTW_... (tunable white), ..._SHDW_... (dimmable).
    var supportsColor: Bool {
        switch kind {
        case .wiz: return module.map { $0.contains("RGB") } ?? true
        case .yeelight: return methods.isEmpty || methods.contains("set_rgb")
        }
    }

    var supportsWhiteTemperature: Bool {
        switch kind {
        case .wiz: return module.map { $0.contains("RGB") || $0.contains("TW") } ?? true
        case .yeelight: return methods.isEmpty || methods.contains("set_ct_abx")
        }
    }

    /// The numbered built-in scenes are a WiZ feature.
    var supportsScenes: Bool { kind == .wiz }

    /// Lowest brightness the light accepts, in percent.
    var minDimming: Int { kind == .wiz ? 10 : 1 }

    var isStrip: Bool { kind == .yeelight && (module?.hasPrefix("strip") ?? false) }

    var kindLabel: String {
        switch kind {
        case .wiz:
            guard let module else { return "WiZ" }
            if module.contains("RGB") { return "WiZ · color" }
            if module.contains("TW") { return "WiZ · tunable white" }
            if module.contains("DW") { return "WiZ · white" }
            return "WiZ"
        case .yeelight:
            if isStrip { return "Yeelight · light strip" }
            return supportsColor ? "Yeelight · color" : "Yeelight"
        }
    }

    var defaultName: String {
        switch kind {
        case .wiz: return "WiZ \(mac.suffix(4).uppercased())"
        case .yeelight: return isStrip ? "Light Strip" : "Yeelight \(mac.suffix(4).uppercased())"
        }
    }

    func isOnline(now: Date = Date()) -> Bool { now.timeIntervalSince(lastSeen) < 16 }

    /// Approximate sRGB colour of the light the lamp is currently emitting (0...1 components).
    var tintRGB: (r: Double, g: Double, b: Double) {
        switch mode {
        case .white(let kelvin): return Color.kelvinRGB(kelvin)
        case .color(let r, let g, let b): return RGB(r: r, g: g, b: b).display(softness: softness)
        case .flow(let id):
            let color = flowColor ?? LightFlow.named(id)?.hues.first ?? RGB(r: 150, g: 0, b: 255)
            return color.display(softness: softness)
        case .scene(let id):
            // A scene has no single colour; its swatch is the closest honest hint.
            guard let hex = WizScene.all.first(where: { $0.id == id })?.swatch.first else { return (1.0, 0.78, 0.35) }
            return (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
        case .unknown: return (1.0, 0.78, 0.35)
        }
    }

    /// Screen approximation of the white channels: full softness still leaves a quarter of the colour.
    static func whiteShare(softness: Int) -> Double {
        0.75 * Double(min(max(softness, 0), 100)) / 100
    }

    var tint: Color {
        let rgb = tintRGB
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// How strongly this lamp colours the window background: vivid colours wash the whole window,
    /// near-white light only adds a faint glow (a full-strength beige wash just looks muddy).
    var ambientStrength: Double {
        let rgb = tintRGB
        let high = max(rgb.r, rgb.g, rgb.b), low = min(rgb.r, rgb.g, rgb.b)
        let saturation = high > 0 ? (high - low) / high : 0
        return 0.2 + 0.8 * saturation * saturation
    }

    /// Whether dark content reads better than light content on top of `tint`.
    var tintIsLight: Bool {
        let rgb = tintRGB
        return 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b > 0.55
    }

    var modeLabel: String {
        switch mode {
        case .white(let kelvin): return "\(kelvin)K"
        case .color: return "Color"
        case .scene(let id): return WizScene.name(for: id)
        case .flow(let id): return LightFlow.named(id).map { "\($0.name) flow" } ?? "Flow"
        case .unknown: return ""
        }
    }
}

struct WizScene: Identifiable, Hashable {
    let id: Int
    let name: String
    /// Two sRGB hex colours that hint at what the scene looks like.
    let swatch: [UInt32]

    var swatchColors: [Color] { swatch.map { Color(hex: $0) } }

    static let all: [WizScene] = [
        WizScene(id: 6, name: "Cozy", swatch: [0xFFB45A, 0xFF8A3C]),
        WizScene(id: 16, name: "Relax", swatch: [0xFFD9A0, 0xFFB070]),
        WizScene(id: 15, name: "Focus", swatch: [0xFFFFFF, 0xCFE4FF]),
        WizScene(id: 18, name: "TV time", swatch: [0x7A5CFF, 0x2D8CFF]),
        WizScene(id: 5, name: "Fireplace", swatch: [0xFF7A1A, 0xD9281E]),
        WizScene(id: 3, name: "Sunset", swatch: [0xFF9A3C, 0xFF4F81]),
        WizScene(id: 1, name: "Ocean", swatch: [0x2BB5FF, 0x1A4DFF]),
        WizScene(id: 11, name: "Warm white", swatch: [0xFFE2B8, 0xFFC98A]),
        WizScene(id: 12, name: "Daylight", swatch: [0xFFFFFF, 0xFFF4E0]),
        WizScene(id: 13, name: "Cool white", swatch: [0xFFFFFF, 0xD6E6FF]),
        WizScene(id: 14, name: "Night light", swatch: [0xFFB060, 0x7A3A10]),
        WizScene(id: 29, name: "Candlelight", swatch: [0xFFC06A, 0xFF8A2A]),
        WizScene(id: 2, name: "Romance", swatch: [0xFF5FA0, 0xB03CFF]),
        WizScene(id: 7, name: "Forest", swatch: [0x4CD964, 0x1E8F4E]),
        WizScene(id: 24, name: "Jungle", swatch: [0x9BE15D, 0x00B37A]),
        WizScene(id: 23, name: "Deep dive", swatch: [0x1E5BFF, 0x5A1EFF]),
        WizScene(id: 25, name: "Mojito", swatch: [0xC6F26B, 0x35C759]),
        WizScene(id: 8, name: "Pastel", swatch: [0xFFC6E0, 0xBFD9FF]),
        WizScene(id: 20, name: "Spring", swatch: [0xB6F09C, 0xFFB8D9]),
        WizScene(id: 21, name: "Summer", swatch: [0xFFD84A, 0xFF8C42]),
        WizScene(id: 22, name: "Fall", swatch: [0xE8842C, 0xA8431E]),
        WizScene(id: 4, name: "Party", swatch: [0xFF3CAC, 0x2B86C5]),
        WizScene(id: 26, name: "Club", swatch: [0xB23CFF, 0x00E0FF]),
        WizScene(id: 31, name: "Pulse", swatch: [0xFF375F, 0xFF9F0A]),
        WizScene(id: 32, name: "Steampunk", swatch: [0xC98A3C, 0x7A4A1E]),
    ]

    /// Scenes shown as one-tap chips; the rest live in the "More" menu.
    static let featured: [WizScene] = Array(all.prefix(7))
    static let others: [WizScene] = Array(all.dropFirst(7))

    static func name(for id: Int) -> String {
        all.first { $0.id == id }?.name ?? "Scene \(id)"
    }
}

/// A slow, looping drift through a few related colours. The app steps the lamp through it in small
/// increments, so a flow runs only while the app is open (the menu-bar item keeps it alive).
struct LightFlow: Identifiable {
    let id: String
    let name: String
    let summary: String
    /// Fully saturated lamp colours; how pastel they look is set separately by the light's softness.
    let hues: [RGB]
    let secondsPerColor: Double
    /// How many hues apart each further light in the same flow runs. Lights in one flow share a
    /// clock, so this distance holds: the room shows neighbouring colours instead of one colour twice.
    var stagger = 0.5
    /// A second palette, for a scene written for two lights: step by step it is the colour that
    /// goes with `hues`, so each moment is a chosen pair. Light strips take it when there is a
    /// choice — they are the accent, the bulb is the room's wash. Nil: every light runs `hues`.
    var accent: [RGB]? = nil
    /// A brightness that is part of the scene: set on every light when the scene is started for
    /// the room. Nil: the lights keep the brightness they have.
    var dimming: Int? = nil
    /// Made to be seen on two lights at once; offered for the whole room rather than light by light.
    var isPair: Bool { accent != nil || stagger >= 1 }

    /// Softness a flow starts with until the user picks their own.
    static let defaultSoftness = 35

    /// Speed range shared with the lamp's own animated scenes: percent of normal speed.
    static let speedRange = 10...200

    /// `position` counts hues travelled since the flow started: 1.5 is halfway from the second hue to the third.
    /// `place` is which of the lights sharing the flow this is: 0 for the first, 1 for the second…
    func color(at position: Double, place: Int = 0) -> RGB {
        let hues = palette(place: place)
        guard hues.count > 1 else { return hues.first ?? RGB(r: 255, g: 255, b: 255) }
        let position = max(position + offset(place: place), 0)
        let index = Int(position) % hues.count
        // Cosine easing: the colour lingers on each hue and glides between them.
        let t = (1 - cos((position - position.rounded(.down)) * .pi)) / 2
        return RGB.blend(hues[index], hues[(index + 1) % hues.count], t)
    }

    private func palette(place: Int) -> [RGB] { (place % 2 == 1 ? accent : nil) ?? hues }

    /// How many hues ahead of the flow's clock a place runs. With an accent palette the first two
    /// lights move in step, each through its own colours.
    private func offset(place: Int) -> Double { Double(accent == nil ? place : place / 2) * stagger }

    var swatchColors: [Color] {
        let picks = accent.map { hues.prefix(2) + $0.prefix(2) } ?? hues.prefix(4)
        return picks.map { $0.displayColor(softness: Self.defaultSoftness) }
    }

    /// Flows written for two lights, and the one that follows the music.
    static var pairs: [LightFlow] { all.filter(\.isPair) + [music] }

    /// The one flow whose colours are not written here: `SpotifyLink` fills them in from the cover
    /// of what is playing. Main thread only.
    static var music = LightFlow.music(hues: [RGB(r: 170, g: 0, b: 255), RGB(r: 255, g: 0, b: 170), RGB(r: 140, g: 0, b: 255), RGB(r: 255, g: 0, b: 110)],
                                       summary: musicIdleSummary)
    /// True while the music is paused: the scene's colours stand still.
    static var musicHolds = false
    static let musicIdleSummary = "Follows Spotify: the lights take the colours of the cover of what is playing"

    static func music(hues: [RGB], summary: String) -> LightFlow {
        LightFlow(id: "spotify", name: "Spotify", summary: summary, hues: hues, secondsPerColor: 8, stagger: 1)
    }

    static let all: [LightFlow] = [
        LightFlow(id: "violet", name: "Violet", summary: "Violet drifting through orchid, pink and periwinkle",
                  hues: [RGB(r: 150, g: 0, b: 255), RGB(r: 205, g: 0, b: 255), RGB(r: 255, g: 0, b: 190),
                         RGB(r: 170, g: 20, b: 255), RGB(r: 95, g: 30, b: 255), RGB(r: 70, g: 90, b: 255)],
                  secondsPerColor: 9),
        LightFlow(id: "candy", name: "Candy", summary: "Pastel pink, peach, butter, mint, sky and lilac",
                  hues: [RGB(r: 255, g: 0, b: 120), RGB(r: 255, g: 90, b: 0), RGB(r: 255, g: 190, b: 0),
                         RGB(r: 0, g: 255, b: 140), RGB(r: 0, g: 160, b: 255), RGB(r: 150, g: 0, b: 255)],
                  secondsPerColor: 10),
        LightFlow(id: "aurora", name: "Aurora", summary: "Mint, aqua, periwinkle and violet",
                  hues: [RGB(r: 0, g: 255, b: 150), RGB(r: 0, g: 200, b: 255), RGB(r: 40, g: 90, b: 255), RGB(r: 150, g: 0, b: 255)],
                  secondsPerColor: 11),
        LightFlow(id: "dusk", name: "Dusk", summary: "Peach, coral, rose and lilac",
                  hues: [RGB(r: 255, g: 110, b: 0), RGB(r: 255, g: 40, b: 40), RGB(r: 255, g: 0, b: 130), RGB(r: 170, g: 0, b: 255)],
                  secondsPerColor: 11),
        // The rest are written for two lights.
        //
        // Duet: one palette, walked from pink to azure and back the same way, the second light two
        // hues ahead. The pair drifts apart to pink-against-violet or violet-against-azure, then
        // closes up and meets on one colour (blue, later orchid) before parting again. No greens
        // or yellows, so neither light jumps in brightness on the way.
        LightFlow(id: "duet", name: "Duet", summary: "Pink, violet, blue and azure — the two lights drift apart, then meet on one colour",
                  hues: [RGB(r: 255, g: 0, b: 150), RGB(r: 200, g: 0, b: 255), RGB(r: 120, g: 0, b: 255), RGB(r: 30, g: 60, b: 255),
                         RGB(r: 0, g: 150, b: 255), RGB(r: 30, g: 60, b: 255), RGB(r: 120, g: 0, b: 255), RGB(r: 200, g: 0, b: 255)],
                  secondsPerColor: 10, stagger: 2),
        // Bloom: violet to pink and back, the two lights at opposite ends of the same walk — one
        // is violet while the other is pink, they cross in fuchsia and trade places.
        LightFlow(id: "bloom", name: "Bloom", summary: "Violet against pink — the two lights cross in fuchsia and trade places",
                  hues: [RGB(r: 140, g: 0, b: 255), RGB(r: 195, g: 0, b: 255), RGB(r: 255, g: 0, b: 230),
                         RGB(r: 255, g: 0, b: 150), RGB(r: 255, g: 0, b: 230), RGB(r: 195, g: 0, b: 255)],
                  secondsPerColor: 10, stagger: 3),
        // Ruby: the cool reds, and nothing warmer than pure red — orange belongs to Ember. The bulb
        // stays close to red; the strip answers in raspberry.
        LightFlow(id: "ruby", name: "Ruby", summary: "Cool reds — red and crimson on one light, raspberry on the other",
                  hues: [RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 0, b: 45), RGB(r: 255, g: 0, b: 15),
                         RGB(r: 255, g: 0, b: 60), RGB(r: 255, g: 0, b: 25), RGB(r: 255, g: 0, b: 5)],
                  secondsPerColor: 9,
                  accent: [RGB(r: 255, g: 0, b: 90), RGB(r: 255, g: 0, b: 40), RGB(r: 255, g: 0, b: 120),
                           RGB(r: 255, g: 0, b: 60), RGB(r: 255, g: 0, b: 100), RGB(r: 255, g: 0, b: 30)]),
        // The two deep ones are a single colour that is barely alive: a few degrees of hue either
        // side, slowly, so the room reads as red (or violet) and nothing else. No pink, no orange,
        // no blue. They look deepest with softness at 0 and the brightness turned down.
        LightFlow(id: "deepred", name: "Deep Red", summary: "Pure deep red, barely moving — no pink and no orange in it",
                  hues: [RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 0, b: 10), RGB(r: 255, g: 6, b: 0), RGB(r: 255, g: 0, b: 4)],
                  secondsPerColor: 14,
                  accent: [RGB(r: 255, g: 0, b: 14), RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 0, b: 22), RGB(r: 255, g: 4, b: 0)]),
        LightFlow(id: "deepviolet", name: "Deep Violet", summary: "Pure deep violet, barely moving — no pink and no blue in it",
                  hues: [RGB(r: 120, g: 0, b: 255), RGB(r: 140, g: 0, b: 255), RGB(r: 105, g: 0, b: 255), RGB(r: 130, g: 0, b: 255)],
                  secondsPerColor: 14,
                  accent: [RGB(r: 100, g: 0, b: 255), RGB(r: 118, g: 0, b: 255), RGB(r: 145, g: 0, b: 255), RGB(r: 110, g: 0, b: 255)]),
        // Twilight: a dim purple room that a wave of red passes through — it reaches the second
        // light a moment after the first, then the purple closes over it again. Most of the loop
        // is purple; red is the visitor. The only scene that sets its own brightness: it is
        // meant as half-darkness.
        LightFlow(id: "twilight", name: "Twilight", summary: "Dim purple half-light with a slow wave of red passing through it",
                  hues: [RGB(r: 190, g: 0, b: 255), RGB(r: 230, g: 0, b: 230), RGB(r: 255, g: 0, b: 130),
                         RGB(r: 255, g: 0, b: 20), RGB(r: 255, g: 0, b: 110), RGB(r: 225, g: 0, b: 235)],
                  secondsPerColor: 12, stagger: 1.5, dimming: 25),
        // Horizon (not "Sunset": the WiZ bulb has a scene of that name): the bulb is the low sun, amber sinking to rose and rising again; the strip is the
        // sky above it, pink deepening to indigo at the moment the sun is reddest. Warm against cool.
        LightFlow(id: "horizon", name: "Horizon", summary: "A low amber-to-rose sun under a sky that deepens from pink to indigo",
                  hues: [RGB(r: 255, g: 150, b: 0), RGB(r: 255, g: 100, b: 0), RGB(r: 255, g: 50, b: 30),
                         RGB(r: 255, g: 20, b: 90), RGB(r: 255, g: 50, b: 30), RGB(r: 255, g: 100, b: 0)],
                  secondsPerColor: 11,
                  accent: [RGB(r: 255, g: 0, b: 130), RGB(r: 220, g: 0, b: 255), RGB(r: 150, g: 0, b: 255),
                           RGB(r: 80, g: 40, b: 255), RGB(r: 150, g: 0, b: 255), RGB(r: 230, g: 0, b: 200)]),
        // Lagoon: neighbours on the colour wheel, so it is the calmest of the pairs. Deep water on
        // the bulb, light on the surface along the strip.
        LightFlow(id: "lagoon", name: "Lagoon", summary: "Deep blue water with mint and aqua light moving over it",
                  hues: [RGB(r: 20, g: 60, b: 255), RGB(r: 0, g: 130, b: 255), RGB(r: 0, g: 90, b: 255), RGB(r: 60, g: 40, b: 255)],
                  secondsPerColor: 12,
                  accent: [RGB(r: 0, g: 255, b: 170), RGB(r: 0, g: 230, b: 255), RGB(r: 0, g: 255, b: 130), RGB(r: 0, g: 200, b: 255)]),
        // Ember: the bulb barely moves — a steady amber glow that only breathes — while the strip
        // wanders between red and orange like coals. Quicker than the others, but never a flicker.
        LightFlow(id: "ember", name: "Ember", summary: "A steady amber glow with coals shifting between red and orange",
                  hues: [RGB(r: 255, g: 130, b: 0), RGB(r: 255, g: 110, b: 0), RGB(r: 255, g: 150, b: 10),
                         RGB(r: 255, g: 120, b: 0), RGB(r: 255, g: 100, b: 0), RGB(r: 255, g: 140, b: 0)],
                  secondsPerColor: 7,
                  accent: [RGB(r: 255, g: 40, b: 0), RGB(r: 255, g: 90, b: 0), RGB(r: 255, g: 20, b: 0),
                           RGB(r: 255, g: 70, b: 0), RGB(r: 255, g: 30, b: 10), RGB(r: 255, g: 100, b: 0)]),
        // Polar: a night sky of indigo and violet on the bulb, northern lights in mint and aqua
        // sweeping along the strip.
        LightFlow(id: "polar", name: "Polar", summary: "An indigo night sky with northern lights in mint and aqua",
                  hues: [RGB(r: 70, g: 30, b: 255), RGB(r: 130, g: 0, b: 255), RGB(r: 30, g: 50, b: 255),
                         RGB(r: 110, g: 0, b: 255), RGB(r: 60, g: 60, b: 255)],
                  secondsPerColor: 12,
                  accent: [RGB(r: 0, g: 255, b: 150), RGB(r: 0, g: 210, b: 255), RGB(r: 0, g: 255, b: 110),
                           RGB(r: 0, g: 255, b: 200), RGB(r: 0, g: 180, b: 255)]),
        // Sorbet: the warm, flattering one — apricot on the bulb, raspberry pink on the strip.
        LightFlow(id: "sorbet", name: "Sorbet", summary: "Apricot and peach with raspberry pink beside them",
                  hues: [RGB(r: 255, g: 130, b: 0), RGB(r: 255, g: 80, b: 30), RGB(r: 255, g: 110, b: 0), RGB(r: 255, g: 60, b: 50)],
                  secondsPerColor: 11,
                  accent: [RGB(r: 255, g: 0, b: 110), RGB(r: 255, g: 0, b: 170), RGB(r: 255, g: 0, b: 90), RGB(r: 255, g: 30, b: 150)]),
    ]

    static func named(_ id: String) -> LightFlow? { id == music.id ? music : all.first { $0.id == id } }
}

/// A one-tap look for the whole room.
struct RoomPreset: Identifiable {
    let id: String
    let name: String
    let icon: String
    let dimming: Int
    let kelvin: Int?
    /// A WiZ scene; lights without those scenes use `kelvin` instead.
    let sceneId: Int?
    /// A flow to start on lamps that can show colour; other lamps just take the brightness.
    var flowId: String? = nil

    /// What the preset does, in words — shown as a tooltip so the names aren't a guessing game.
    var summary: String {
        if let flow = flowId.flatMap(LightFlow.named) { return "\(flow.summary), \(dimming)% brightness" }
        if let sceneId { return "All lights: \(WizScene.name(for: sceneId).lowercased()), \(dimming)% brightness" }
        if let kelvin { return "All lights: white \(kelvin)K, \(dimming)% brightness" }
        return "All lights: \(dimming)% brightness"
    }

    /// Flows that no preset starts; they get keyboard shortcuts of their own, numbered after the
    /// presets for as long as the number keys last — the scenes for two lights first.
    static let extraFlows: [LightFlow] = {
        let flows = LightFlow.all.filter { flow in !all.contains { $0.flowId == flow.id } }
        return flows.filter(\.isPair) + flows.filter { !$0.isPair }
    }()

    static let all: [RoomPreset] = [
        RoomPreset(id: "day", name: "Day", icon: "sun.max.fill", dimming: 100, kelvin: 4200, sceneId: nil),
        RoomPreset(id: "focus", name: "Focus", icon: "desktopcomputer", dimming: 100, kelvin: 5500, sceneId: nil),
        RoomPreset(id: "evening", name: "Evening", icon: "sunset.fill", dimming: 60, kelvin: 2700, sceneId: nil),
        RoomPreset(id: "movie", name: "Movie", icon: "film", dimming: 15, kelvin: 2200, sceneId: nil),
        RoomPreset(id: "night", name: "Night", icon: "moon.fill", dimming: 10, kelvin: 2200, sceneId: 14),
        RoomPreset(id: "dream", name: "Dream", icon: "sparkles", dimming: 70, kelvin: nil, sceneId: nil, flowId: "violet"),
    ]
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// Approximate on-screen colour of a black-body light source (Tanner Helland's fit).
    static func kelvin(_ kelvin: Int) -> Color {
        let rgb = kelvinRGB(kelvin)
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    static func kelvinRGB(_ kelvin: Int) -> (r: Double, g: Double, b: Double) {
        let t = Double(min(max(kelvin, 1000), 12000)) / 100
        var r: Double, g: Double, b: Double
        if t <= 66 {
            r = 255
            g = 99.4708025861 * log(t) - 161.1195681661
            b = t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
        } else {
            r = 329.698727446 * pow(t - 60, -0.1332047592)
            g = 288.1221695283 * pow(t - 60, -0.0755148492)
            b = 255
        }
        r = min(max(r, 0), 255)
        g = min(max(g, 0), 255)
        b = min(max(b, 0), 255)
        return (r / 255, g / 255, b / 255)
    }

    /// Splits a picked colour into what the lamp needs: a fully saturated hue plus a softness that
    /// stands in for the missing saturation. Brightness is dropped — the lamp's dimming drives that.
    /// Inverse of `RGB.display(softness:)`.
    var lampComponents: (hue: RGB, softness: Int)? {
        guard let converted = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let color = NSColor(hue: converted.hueComponent, saturation: 1, brightness: 1, alpha: 1)
        let hue = RGB(r: Int((color.redComponent * 255).rounded()),
                      g: Int((color.greenComponent * 255).rounded()),
                      b: Int((color.blueComponent * 255).rounded()))
        let softness = Int(((1 - converted.saturationComponent) / 0.75 * 100).rounded())
        return (hue, min(max(softness, 0), 100))
    }
}
