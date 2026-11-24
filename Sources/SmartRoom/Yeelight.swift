import Foundation
import Network
import SwiftUI

/// Transport for Yeelight "LAN Control": a search over UDP (port 1982) and one JSON-lines TCP
/// connection per lamp (port 55443). Call it from the main queue; callbacks arrive there too.
final class YeelightTransport {
    static let searchPort: UInt16 = 1982
    static let controlPort: UInt16 = 55443

    /// A lamp answered a search: its IP and the reply's headers (names lowercased).
    var onAdvert: ((String, [String: String]) -> Void)?
    /// A line from a lamp's control connection: the reply to a command or a `props` notification.
    var onMessage: ((String, [String: Any]) -> Void)?
    /// A lamp's control connection opened (true) or was lost (false).
    var onLink: ((String, Bool) -> Void)?

    private final class Link {
        let ip: String
        let connection: NWConnection
        var ready = false
        var buffer = Data()
        var budget = YeelightBudget()

        init(ip: String, connection: NWConnection) {
            self.ip = ip
            self.connection = connection
        }
    }

    private let socket = UDPSocket(label: "smartroom.yeelight.rx")
    private var links: [String: Link] = [:]

    init() {
        socket?.onDatagram = { [weak self] ip, data in
            let headers = YeelightCodec.headers(String(decoding: data, as: UTF8.self))
            DispatchQueue.main.async {
                Trace.log("<- \(ip) advert \(headers)")
                self?.onAdvert?(ip, headers)
            }
        }
    }

    /// Asks every Yeelight lamp on the network to announce itself, and the given IPs directly.
    /// A reply carries the lamp's whole state and, unlike a command, costs none of its quota.
    func search(alsoAsking ips: [String]) {
        let request = Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\nMAN: \"ssdp:discover\"\r\nST: wifi_bulb\r\n\r\n".utf8)
        for ip in ["239.255.255.250"] + ips {
            socket?.send(request, to: ip, port: Self.searchPort)
        }
    }

    func isOpen(_ key: String) -> Bool { links[key]?.ready ?? false }

    /// Opens the control connection to a lamp. Does nothing while one to the same IP is open or opening.
    func open(_ key: String, ip: String) {
        if let link = links[key] {
            if link.ip == ip { return }
            drop(key, link)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        tcp.noDelay = true
        // A lamp that loses power never says goodbye; keepalive notices within about 15 seconds.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 8
        tcp.keepaliveInterval = 4
        tcp.keepaliveCount = 2
        guard let port = NWEndpoint.Port(rawValue: Self.controlPort) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: port, using: NWParameters(tls: nil, tcp: tcp))
        let link = Link(ip: ip, connection: connection)
        links[key] = link
        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link, self.links[key] === link else { return }
            switch state {
            case .ready:
                link.ready = true
                Trace.log("== \(ip) connected")
                self.onLink?(key, true)
                self.receive(key, link)
            case .waiting, .failed, .cancelled:
                // Not waiting for the network to come back: the store reopens on its next search.
                self.drop(key, link)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func close(_ key: String) {
        if let link = links[key] { drop(key, link) }
    }

    /// Sends the commands as one batch, or none of them: false means the lamp is not connected or
    /// the batch would exceed what it accepts right now, and the caller should try again shortly.
    /// `reserve` is how much of the lamp's allowance must be left afterwards — for commands that can wait.
    func send(_ key: String, _ commands: [(id: Int, method: String, params: [Any])], reserve: Int = 0) -> Bool {
        guard let link = links[key], link.ready, link.budget.take(commands.count, reserve: reserve) else { return false }
        var payload = Data()
        for command in commands {
            let object: [String: Any] = ["id": command.id, "method": command.method, "params": command.params]
            guard let line = try? JSONSerialization.data(withJSONObject: object) else { continue }
            Trace.log("-> \(link.ip) \(String(decoding: line, as: UTF8.self))")
            payload.append(line)
            payload.append(Data("\r\n".utf8))
        }
        link.connection.send(content: payload, completion: .contentProcessed { _ in })
        return true
    }

    private func receive(_ key: String, _ link: Link) {
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self, weak link] data, _, isComplete, error in
            guard let self, let link, self.links[key] === link else { return }
            if let data {
                link.buffer.append(data)
                while let newline = link.buffer.firstIndex(of: 0x0A) {
                    let line = link.buffer[link.buffer.startIndex..<newline]
                    link.buffer = Data(link.buffer[link.buffer.index(after: newline)...])
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    Trace.log("<- \(link.ip) \(object)")
                    self.onMessage?(key, object)
                }
            }
            if isComplete || error != nil {
                self.drop(key, link)
            } else {
                self.receive(key, link)
            }
        }
    }

    private func drop(_ key: String, _ link: Link) {
        guard links[key] === link else { return }
        links[key] = nil
        link.connection.cancel()
        Trace.log("== \(link.ip) disconnected")
        onLink?(key, false)
    }
}

/// A lamp refuses commands beyond 60 a minute on one connection ("client quota exceeded"; measured
/// on a Lightstrip 1S). This stays under that in any one-minute window while keeping a slider drag
/// responsive at first: a burst, then a steady trickle. Whatever was held back is sent later, so
/// the last value always lands.
struct YeelightBudget {
    private static let burst = 16.0
    private static let perSecond = 42.0 / 60
    /// Minimum gap between batches, so a drag is spread over seconds instead of spent at once.
    private static let gap = 0.25

    private var tokens = YeelightBudget.burst
    private var refilledAt = Date()
    private var lastSend = Date.distantPast

    mutating func take(_ count: Int, reserve: Int = 0, at now: Date = Date()) -> Bool {
        tokens = min(Self.burst, tokens + now.timeIntervalSince(refilledAt) * Self.perSecond)
        refilledAt = now
        guard now.timeIntervalSince(lastSend) >= Self.gap, tokens >= Double(count + reserve) else { return false }
        tokens -= Double(count)
        lastSend = now
        return true
    }
}

/// Translation between this app's vocabulary and the Yeelight one.
enum YeelightCodec {
    /// Properties that describe what a lamp is showing; search replies and notifications use the same names.
    static let stateProps = ["power", "bright", "color_mode", "ct", "rgb", "hue", "sat", "flowing"]
    /// Colour temperatures every colour-capable Yeelight accepts (the Lightstrip 1S rejects anything outside).
    static let kelvinRange = 2700...6500

    private static let fade: [Any] = ["smooth", 300]

    /// Header lines of a search reply, names lowercased.
    static func headers(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            result[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// The key a lamp is known by in the store: "0x0000000012ab34cd" becomes "yeelight-12ab34cd".
    static func key(forID id: String?) -> String? {
        guard let id, id.lowercased().hasPrefix("0x") else { return nil }
        let digits = id.dropFirst(2).drop { $0 == "0" }
        return digits.isEmpty ? nil : "yeelight-\(digits.lowercased())"
    }

    /// These lamps have no white LEDs to blend in, so softness is mixed into the colour itself —
    /// exactly the colour the app shows on screen.
    static func rgbValue(_ color: RGB, softness: Int) -> Int {
        let mixed = color.display(softness: softness)
        func byte(_ value: Double) -> Int { min(max(Int((value * 255).rounded()), 0), 255) }
        return max(byte(mixed.r) << 16 | byte(mixed.g) << 8 | byte(mixed.b), 1)
    }

    /// Inverse of `rgbValue`, for a colour set by another app.
    static func color(rgb: Int) -> (hue: RGB, softness: Int)? {
        Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
            .lampComponents
    }

    static func color(hue: Int, saturation: Int) -> (hue: RGB, softness: Int)? {
        Color(hue: Double(hue) / 360, saturation: Double(saturation) / 100, brightness: 1).lampComponents
    }

    /// One step of a flow: glide to `color` over `seconds`. A lamp takes too few commands a minute
    /// to be stepped several times a second like a WiZ one, so it gets a target every couple of
    /// seconds and does the gliding itself.
    static func flowStep(to color: RGB, softness: Int, seconds: Double) -> (method: String, params: [Any]) {
        ("set_rgb", [rgbValue(color, softness: softness), "smooth", Int(seconds * 1000)])
    }

    /// Turns parameters in the store's (WiZ-shaped) vocabulary into Yeelight commands.
    /// `brightness` is what a lamp gets when it is switched on straight into a look and the
    /// parameters name none.
    static func commands(for params: [String: Any], lampIsOn: Bool, brightness: Int) -> [(method: String, params: [Any])] {
        if params["state"] as? Bool == false { return [("set_power", ["off"] + fade)] }
        let turnOn = params["state"] as? Bool == true && !lampIsOn
        let bright = (params["dimming"] as? Int).map { min(max($0, 1), 100) }
        var commands: [(method: String, params: [Any])] = []
        // set_scene switches the lamp on straight into a colour.
        var look: (scene: [Any], command: (method: String, params: [Any]))?

        if let r = params["r"] as? Int, let g = params["g"] as? Int, let b = params["b"] as? Int {
            let rgb = rgbValue(RGB(r: r, g: g, b: b), softness: params["c"] as? Int ?? 0)
            look = (["color", rgb], ("set_rgb", [rgb] + fade))
        } else if let kelvin = params["temp"] as? Int {
            let ct = min(max(kelvin, kelvinRange.lowerBound), kelvinRange.upperBound)
            look = (["ct", ct], ("set_ct_abx", [ct] + fade))
        }

        if let look, turnOn {
            // Lit at its dimmest already in the new colour, then faded up: no flash of the old one.
            commands.append(("set_scene", look.scene + [1]))
            commands.append(("set_bright", [bright ?? min(max(brightness, 1), 100), "smooth", 500]))
        } else {
            if turnOn { commands.append(("set_power", ["on"] + fade)) }
            if let look { commands.append(look.command) }
            if let bright { commands.append(("set_bright", [bright] + fade)) }
        }
        return commands
    }
}

extension Light {
    static func yeelight(key: String, ip: String) -> Light {
        var light = Light(mac: key, ip: ip)
        light.kind = .yeelight
        light.minKelvin = YeelightCodec.kelvinRange.lowerBound
        light.maxKelvin = YeelightCodec.kelvinRange.upperBound
        return light
    }
}
