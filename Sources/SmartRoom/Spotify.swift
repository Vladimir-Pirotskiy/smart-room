import AppKit
import Foundation

/// Follows the Spotify desktop app while the "Spotify" scene is on a light: the scene's colours
/// are taken from the cover of what is playing, and they hold still while playback is paused.
/// Nothing is asked of Spotify (and no permission is asked of the user) until the scene is used.
///
/// The app is asked through AppleScript, in a helper process so a slow answer — or the system's
/// permission question — never stalls the lights. Spotify gives no tempo or beat this way.
final class SpotifyLink {
    /// Spotify is playing right now, and the Spotify scene is in use.
    private(set) static var isPlaying = false

    private weak var store: LightStore?
    private var timer: Timer?
    private var asking = false
    private var trackID: String?
    private var summary = LightFlow.musicIdleSummary
    private var fade: Timer?

    private static let script = [
        "tell application \"Spotify\"",
        "if player state is stopped then return \"stopped\"",
        "set t to current track",
        "set art to \"\"",
        "try",
        "set art to artwork url of t",
        "end try",
        "return (player state as string) & linefeed & (id of t) & linefeed & art & linefeed & (name of t) & linefeed & (artist of t)",
        "end tell",
    ]

    init(store: LightStore) {
        self.store = store
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        // Spotify announces play, pause and track changes; asking right then makes the lights answer at once.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard let store, store.lights.contains(where: { $0.isOn && $0.mode == .flow(id: LightFlow.music.id) }) else {
            show(LightFlow.musicIdleSummary, holds: false)
            return
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else {
            show("Spotify is not open — play something there and the lights take the colours of its cover", holds: false)
            return
        }
        guard !asking else { return }
        asking = true
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = Self.script.flatMap { ["-e", $0] }
        process.standardOutput = output
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] process in
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let failed = process.terminationStatus != 0
            DispatchQueue.main.async {
                self?.asking = false
                self?.answered(failed ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        do { try process.run() } catch { asking = false }
    }

    private func answered(_ text: String?) {
        guard let text else {
            show("Smart Room is not allowed to ask Spotify what is playing: System Settings → Privacy & Security → Automation", holds: false)
            return
        }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 5 else {
            show("Nothing is playing in Spotify — the lights take the colours of the cover once something is", holds: false)
            return
        }
        let playing = lines[0] == "playing", title = "\(lines[3]) — \(lines[4])"
        show(playing ? "Colours of the cover: \(title)" : "Paused: \(title). The colours hold still until it plays again", holds: !playing)
        Self.isPlaying = playing
        guard lines[1] != trackID else { return }
        trackID = lines[1]
        Trace.log("spotify: \(lines[0]) \(lines[1]) \(lines[2])")
        guard let url = URL(string: lines[2]), url.scheme == "https" else {
            glide(to: CoverPalette.plain)
            return
        }
        let id = lines[1]
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let hues = data.flatMap(CoverPalette.hues) ?? CoverPalette.plain
            DispatchQueue.main.async {
                guard let self, self.trackID == id else { return }
                Trace.log("spotify: palette \(hues.map { "(\($0.r),\($0.g),\($0.b))" }.joined(separator: " "))")
                self.glide(to: hues)
            }
        }.resume()
    }

    private func show(_ summary: String, holds: Bool) {
        LightFlow.musicHolds = holds
        Self.isPlaying = false
        guard summary != self.summary else { return }
        self.summary = summary
        LightFlow.music = .music(hues: LightFlow.music.hues, summary: summary)
        store?.objectWillChange.send()
    }

    /// A new cover fades in over a few seconds instead of snapping the room to new colours.
    private func glide(to target: [RGB]) {
        fade?.invalidate()
        let from = LightFlow.music.hues
        guard from.count == target.count else {
            LightFlow.music = .music(hues: target, summary: summary)
            return
        }
        var step = 0
        fade = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            step += 1
            let t = min(Double(step) / 20, 1)
            LightFlow.music = .music(hues: zip(from, target).map { RGB.blend($0, $1, t) }, summary: self?.summary ?? "")
            if t >= 1 {
                timer.invalidate()
                self?.store?.objectWillChange.send()
            }
        }
    }
}

/// The colours a cover is made of, as lamp hues: always four, so one cover can fade into the next.
enum CoverPalette {
    /// For a cover with no colour in it (black and white, or one that could not be fetched).
    static let plain = [RGB(r: 255, g: 150, b: 60), RGB(r: 255, g: 110, b: 80), RGB(r: 255, g: 170, b: 70), RGB(r: 255, g: 120, b: 50)]

    static func hues(from data: Data) -> [RGB]? {
        let side = 32
        guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let pixels = context.data?.bindMemory(to: UInt8.self, capacity: side * side * 4) else { return nil }

        // How much of the cover each 10° of the hue wheel holds; greys, near-blacks and washed-out
        // areas say nothing about colour and are left out.
        var bins = [Double](repeating: 0, count: 36)
        for index in stride(from: 0, to: side * side * 4, by: 4) {
            let color = RGB(r: Int(pixels[index]), g: Int(pixels[index + 1]), b: Int(pixels[index + 2])).hsb
            guard color.s > 0.25, color.b > 0.2 else { continue }
            bins[Int(color.h * 36) % 36] += color.s * color.s * color.b
        }
        guard bins.reduce(0, +) > Double(side * side) * 0.02 else { return nil }
        let score = (0..<36).map { bins[($0 + 35) % 36] / 2 + bins[$0] + bins[($0 + 1) % 36] / 2 }

        // The strongest colours that are at least 40° apart, weak ones dropped.
        var picks: [Int] = []
        while picks.count < 4 {
            let free = (0..<36).filter { bin in picks.allSatisfy { min(abs(bin - $0), 36 - abs(bin - $0)) >= 4 } }
            guard let best = free.max(by: { score[$0] < score[$1] }), score[best] > 0,
                  picks.first.map({ score[best] >= score[$0] * 0.12 }) ?? true
            else { break }
            picks.append(best)
        }
        // Round the wheel in order, so neighbours in the flow are neighbours in colour.
        let h = picks.sorted().map { (Double($0) + 0.5) / 36 }
        let wheel: [Double]
        switch h.count {
        case 1: wheel = [h[0], h[0] + 0.04, h[0], h[0] + 0.96]
        case 2: wheel = [h[0], h[1], h[0], h[1]]
        case 3: wheel = [h[0], h[1], h[2], h[1]]
        default: wheel = h
        }
        return wheel.map { RGB.fromHSB(h: $0.truncatingRemainder(dividingBy: 1), s: 1, b: 1) }
    }
}
