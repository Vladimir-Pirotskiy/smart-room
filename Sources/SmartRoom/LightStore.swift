import Foundation
import SwiftUI

/// Which group of controls a light card is showing.
enum LightPanel: Hashable {
    case white, color, scenes
}

/// Discovers WiZ and Yeelight lights on the local network, mirrors their state and sends commands.
/// Commands are queued in WiZ's parameter vocabulary; `YeelightCodec` translates them for Yeelight lights.
/// All access happens on the main thread.
final class LightStore: ObservableObject {
    @Published private(set) var lights: [Light] = []
    @Published private(set) var names: [String: String] = [:]
    @Published private(set) var now = Date()
    @Published private(set) var networkAvailable = true

    /// Rename dialog state. Kept here rather than in view-local @State: the @State macro plugin
    /// ships only with full Xcode, and this project must build with the Command Line Tools alone.
    @Published var renamingMac: String?
    @Published var renameDraft = ""

    /// A tab the user opened on a card without choosing anything in it yet. Cleared as soon as the
    /// lamp's mode changes, so the card otherwise always shows the controls for the active mode.
    @Published private var peekedPanels: [String: LightPanel] = [:]

    private let transport: WizTransport?
    private let yeelight = YeelightTransport()
    /// What each Yeelight lamp last reported about itself, by property name.
    private var yeelightState: [String: [String: String]] = [:]
    /// The last colour sent to each Yeelight lamp, to read it back exactly: softness is mixed into
    /// the colour these lamps get, and un-mixing a reported colour is only approximate.
    private var yeelightSentColor: [String: (rgb: Int, hue: RGB, softness: Int)] = [:]
    private static let yeelightCommandID = 1
    private static let yeelightPropsID = 2
    private var pollTimer: Timer?
    private var flushTimer: Timer?
    private var flowTimer: Timer?

    /// Flows this app is currently animating: which flow each light runs, and which place it has
    /// among the lights sharing it (see `LightFlow.color(at:place:)`).
    private var flowRuns: [String: (id: String, place: Int)] = [:]
    /// One clock per running flow, shared by its lights so they keep their distance from each other.
    /// `position` is how many hues the flow has travelled; it advances while any of its lamps is lit.
    private var flowClocks: [String: (position: Double, lastTick: Date)] = [:]
    /// Speed the user chose for each flow, percent of normal. Per flow, not per light: lights in
    /// one flow have to move at one speed to stay together.
    @Published private var flowSpeed: [String: Int] = [:]
    /// When each Yeelight lamp was last given a flow step.
    private var lastFlowStep: [String: Date] = [:]
    /// How far apart the flow steps for a Yeelight lamp are; it glides for this long between them.
    private static let lampStepInterval: TimeInterval = 2
    /// The softness the user last chose for each light. Swatches and flows start from it, so colours
    /// come out pastel by default even when the lamp was left on a vivid colour by another app.
    @Published private var softnessChoice: [String: Int] = [:]
    /// Held while a flow runs so App Nap doesn't stall the animation when the window is closed.
    private var flowActivity: NSObjectProtocol?

    /// Parameters waiting to be sent, coalesced per light so slider drags don't flood the lamp.
    private var pending: [String: [String: Any]] = [:]
    /// Last command sent to each light, kept until the lamp acknowledges it.
    private var inflight: [String: (params: [String: Any], sentAt: Date, attempts: Int)] = [:]
    /// While the user is adjusting a light, polled state is ignored so controls don't jump back.
    private var localChangeAt: [String: Date] = [:]

    private static let namesKey = "lightNames"
    private static let knownKey = "knownLights"
    private static let flowsKey = "activeFlows"
    private static let softnessKey = "softness"
    private static let flowSpeedKey = "flowSpeedByFlow"
    private static let flowStep: TimeInterval = 0.25

    init() {
        transport = WizTransport()
        networkAvailable = transport != nil
        names = UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        restoreKnownLights()

        transport?.onMessage = { [weak self] ip, message in
            self?.handle(ip: ip, message: message)
        }
        yeelight.onAdvert = { [weak self] ip, headers in
            self?.handleYeelightAdvert(ip: ip, headers: headers)
        }
        yeelight.onMessage = { [weak self] key, message in
            self?.handleYeelight(key: key, message: message)
        }
        yeelight.onLink = { [weak self] key, isOpen in
            // Search replies don't say whether a flow is running; ask once per connection.
            if isOpen { _ = self?.yeelight.send(key, [(Self.yeelightPropsID, "get_prop", YeelightCodec.stateProps)]) }
        }

        let poll = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll

        // .common mode keeps commands flowing while a slider is being dragged.
        let flush = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.flush() }
        RunLoop.main.add(flush, forMode: .common)
        flushTimer = flush

        let flow = Timer(timeInterval: Self.flowStep, repeats: true) { [weak self] _ in self?.tickFlows() }
        RunLoop.main.add(flow, forMode: .common)
        flowTimer = flow

        poll.fire()
    }

    // MARK: - Queries

    func name(for light: Light) -> String {
        names[light.mac] ?? light.defaultName
    }

    func isOnline(_ light: Light) -> Bool {
        light.isOnline(now: now)
    }

    var onlineLights: [Light] { lights.filter { isOnline($0) } }
    var anyOn: Bool { onlineLights.contains { $0.isOn } }

    func panel(for light: Light) -> LightPanel {
        let wanted: LightPanel
        if let peeked = peekedPanels[light.mac] {
            wanted = peeked
        } else {
            switch light.mode {
            case .color: wanted = .color
            case .scene, .flow: wanted = .scenes
            case .white, .unknown: wanted = .white
            }
        }
        return wanted == .color && !light.supportsColor ? .white : wanted
    }

    func showPanel(_ panel: LightPanel, for mac: String) {
        peekedPanels[mac] = panel
    }

    /// True when every reachable lamp already looks the way the preset would make it.
    func isActive(_ preset: RoomPreset) -> Bool {
        let online = onlineLights
        guard !online.isEmpty else { return false }
        return online.allSatisfy { light in
            guard light.isOn, light.dimming == preset.dimming else { return false }
            guard let look = look(preset, for: light) else { return true }
            return light.mode == look
        }
    }

    /// What a preset asks of one light, given what that light can do; nil when only the brightness applies.
    private func look(_ preset: RoomPreset, for light: Light) -> LightMode? {
        if let flowId = preset.flowId, light.supportsColor, LightFlow.named(flowId) != nil { return .flow(id: flowId) }
        if let sceneId = preset.sceneId, light.supportsScenes { return .scene(id: sceneId) }
        if let kelvin = preset.kelvin, light.supportsWhiteTemperature {
            return .white(kelvin: min(max(kelvin, light.minKelvin), light.maxKelvin))
        }
        return nil
    }

    // MARK: - Commands

    func refresh() {
        poll()
    }

    func rename(_ mac: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names.removeValue(forKey: mac)
        } else {
            names[mac] = trimmed
        }
        UserDefaults.standard.set(names, forKey: Self.namesKey)
        sortLights()
    }

    func beginRename(_ light: Light) {
        renameDraft = name(for: light)
        renamingMac = light.mac
    }

    func commitRename() {
        if let mac = renamingMac {
            rename(mac, to: renameDraft)
        }
        renamingMac = nil
    }

    func forget(_ mac: String) {
        lights.removeAll { $0.mac == mac }
        pending.removeValue(forKey: mac)
        inflight.removeValue(forKey: mac)
        peekedPanels.removeValue(forKey: mac)
        softnessChoice.removeValue(forKey: mac)
        UserDefaults.standard.set(softnessChoice, forKey: Self.softnessKey)
        if flowRuns.removeValue(forKey: mac) != nil { flowsChanged() }
        yeelight.close(mac)
        yeelightState.removeValue(forKey: mac)
        yeelightSentColor.removeValue(forKey: mac)
        persistKnownLights()
    }

    func setPower(_ mac: String, on: Bool) {
        update(mac) { $0.isOn = on }
        enqueue(mac, ["state": on])
    }

    func setDimming(_ mac: String, _ value: Int) {
        guard let light = lights.first(where: { $0.mac == mac }) else { return }
        let clamped = min(max(value, light.minDimming), 100)
        update(mac) {
            $0.dimming = clamped
            $0.isOn = true
        }
        enqueue(mac, ["state": true, "dimming": clamped])
        if pulsing.contains(mac) { saveBaselines() }
    }

    func setKelvin(_ mac: String, _ kelvin: Int) {
        guard let light = lights.first(where: { $0.mac == mac }) else { return }
        let clamped = min(max(kelvin, light.minKelvin), light.maxKelvin)
        update(mac) {
            $0.mode = .white(kelvin: clamped)
            $0.isOn = true
        }
        enqueue(mac, ["state": true, "temp": clamped], replacing: ["r", "g", "b", "c", "w", "sceneId", "flow"])
    }

    /// Softness that swatches and flows will use for this light.
    func preferredSoftness(for mac: String) -> Int {
        softnessChoice[mac] ?? LightFlow.defaultSoftness
    }

    /// Sets a solid colour. `softness` nil uses the light's preferred softness.
    func setColor(_ mac: String, r: Int, g: Int, b: Int, softness: Int? = nil) {
        guard lights.contains(where: { $0.mac == mac }) else { return }
        let soft = min(max(softness ?? preferredSoftness(for: mac), 0), 100)
        update(mac) {
            $0.mode = .color(r: r, g: g, b: b)
            $0.softness = soft
            $0.isOn = true
        }
        enqueue(mac, Self.colorParams(RGB(r: r, g: g, b: b), softness: soft, power: true), replacing: ["temp", "sceneId", "flow"])
    }

    /// How pastel the colour is. Works for a solid colour and for a running flow.
    func setSoftness(_ mac: String, _ value: Int) {
        guard let light = lights.first(where: { $0.mac == mac }) else { return }
        let soft = min(max(value, 0), 100)
        softnessChoice[mac] = soft
        UserDefaults.standard.set(softnessChoice, forKey: Self.softnessKey)
        switch light.mode {
        case .color(let r, let g, let b):
            setColor(mac, r: r, g: g, b: b, softness: soft)
        case .flow:
            update(mac) { $0.softness = soft }
            // Through the coalescing queue, so dragging the slider doesn't flood the lamp.
            lastFlowSoftness[mac] = soft
            if let color = light.flowColor {
                enqueue(mac, Self.colorParams(color, softness: soft, power: false))
            } else {
                localChangeAt[mac] = Date()
            }
        case .white, .scene, .unknown:
            break
        }
    }

    /// Animation speed of what the light is showing, percent of normal — nil when nothing is animating.
    func speed(for light: Light) -> Int? {
        switch light.mode {
        case .flow(let id): return flowSpeed[id] ?? 100
        case .scene: return light.sceneSpeed
        case .white, .color, .unknown: return nil
        }
    }

    func setSpeed(_ mac: String, _ value: Int) {
        guard let light = lights.first(where: { $0.mac == mac }) else { return }
        let speed = min(max(value, LightFlow.speedRange.lowerBound), LightFlow.speedRange.upperBound)
        switch light.mode {
        case .flow(let id):
            flowSpeed[id] = speed
            UserDefaults.standard.set(flowSpeed, forKey: Self.flowSpeedKey)
        case .scene(let id) where light.sceneSpeed != nil:
            update(mac) { $0.sceneSpeed = speed }
            enqueue(mac, ["sceneId": id, "speed": speed], replacing: ["temp", "r", "g", "b", "c", "w"])
        case .scene, .white, .color, .unknown:
            break
        }
    }

    func startFlow(_ mac: String, _ flow: LightFlow) {
        guard let light = lights.first(where: { $0.mac == mac }), light.supportsColor else { return }
        let soft = preferredSoftness(for: mac)
        // Joins the flow where it is now.
        let place = freePlace(for: light, in: flow)
        flowRuns[mac] = (flow.id, place)
        if flowClocks[flow.id] == nil { flowClocks[flow.id] = (0, Date()) }
        let color = flow.color(at: flowClocks[flow.id]?.position ?? 0, place: place)
        update(mac) {
            $0.mode = .flow(id: flow.id)
            $0.flowColor = color
            $0.softness = soft
            $0.isOn = true
        }
        // The first colour goes through the acknowledged queue; tickFlows takes over from there.
        enqueue(mac, Self.colorParams(color, softness: soft, power: true), replacing: ["temp", "sceneId"])
        lastFlowStep[mac] = nil
        flowsChanged()
    }

    private static func colorParams(_ color: RGB, softness: Int, power: Bool) -> [String: Any] {
        // Pastel = the colour LEDs plus an even mix of the lamp's cold and warm white LEDs.
        var params: [String: Any] = ["r": color.r, "g": color.g, "b": color.b, "c": softness, "w": softness]
        if power { params["state"] = true }
        return params
    }

    func setScene(_ mac: String, _ sceneId: Int) {
        guard lights.first(where: { $0.mac == mac })?.supportsScenes == true else { return }
        update(mac) {
            if $0.mode != .scene(id: sceneId) { $0.sceneSpeed = nil }
            $0.mode = .scene(id: sceneId)
            $0.isOn = true
        }
        enqueue(mac, ["state": true, "sceneId": sceneId], replacing: ["temp", "r", "g", "b", "c", "w", "speed"])
        // The lamp says whether this scene is animated (and how fast) in its next status report.
        pollSoonAt = Date().addingTimeInterval(0.6)
    }

    /// Briefly dips the brightness so you can tell which physical lamp this is.
    func identify(_ mac: String) {
        guard let light = lights.first(where: { $0.mac == mac }) else { return }
        switch light.kind {
        case .wiz:
            transport?.send(["method": "pulse", "params": ["delta": -60, "duration": 600]], to: light.ip)
        case .yeelight:
            // Two dips to the lowest brightness in the colour it is showing; the lamp then goes
            // back to what it showed before.
            let step: String
            if case .white(let kelvin) = light.mode {
                step = "2,\(kelvin)"
            } else {
                let tint = light.tintRGB
                step = "1,\(max(Int(tint.r * 255) << 16 | Int(tint.g * 255) << 8 | Int(tint.b * 255), 1))"
            }
            let dips = "300,\(step),1,300,\(step),\(light.dimming)"
            _ = yeelight.send(mac, [(Self.yeelightCommandID, "start_cf", [4, 0, dips])])
        }
    }

    func setAll(on: Bool) {
        for light in onlineLights {
            setPower(light.mac, on: on)
        }
    }

    /// Makes every lit lamp brighter or dimmer by `delta` percent.
    func nudgeBrightness(_ delta: Int) {
        for light in onlineLights where light.isOn {
            setDimming(light.mac, light.dimming + delta)
        }
    }

    /// Average brightness of the lamps that are on — what a single slider for the room shows.
    var roomBrightness: Int {
        let lit = onlineLights.filter(\.isOn)
        return lit.isEmpty ? 0 : lit.map(\.dimming).reduce(0, +) / lit.count
    }

    /// Brings every lamp that is on to one brightness.
    func setRoomBrightness(_ value: Int) {
        for light in onlineLights where light.isOn {
            setDimming(light.mac, value)
        }
    }

    func toggleAll() {
        setAll(on: !anyOn)
    }

    /// Steps to the next (or previous) mood, starting from the one that is active now: the presets
    /// in order, then the scenes for all lights, then round again.
    func cyclePreset(_ step: Int) {
        let presets = RoomPreset.all, scenes = LightFlow.pairs
        let count = presets.count + scenes.count
        guard count > 0 else { return }
        let current = presets.firstIndex { isActive($0) } ?? scenes.firstIndex { isEverywhere($0) }.map { $0 + presets.count }
        let next: Int
        if let current {
            next = ((current + step) % count + count) % count
        } else {
            next = step >= 0 ? 0 : count - 1
        }
        if next < presets.count {
            apply(presets[next])
        } else {
            startFlowEverywhere(scenes[next - presets.count])
        }
    }

    /// True when every lamp that can show colour is running this flow.
    func isEverywhere(_ flow: LightFlow) -> Bool {
        let lamps = onlineLights.filter(\.supportsColor)
        return !lamps.isEmpty && lamps.allSatisfy { $0.isOn && $0.mode == .flow(id: flow.id) }
    }

    /// Starts a flow on every lamp that can show colour. Each lamp keeps its brightness unless
    /// the flow comes with one of its own.
    func startFlowEverywhere(_ flow: LightFlow) {
        for light in onlineLights where light.supportsColor && light.mode != .flow(id: flow.id) {
            startFlow(light.mac, flow)
            if let dimming = flow.dimming { setDimming(light.mac, dimming) }
        }
    }

    func apply(_ preset: RoomPreset) {
        for light in onlineLights {
            switch look(preset, for: light) {
            case .flow(let id)?:
                // Re-applying the preset shouldn't restart a flow that is already drifting.
                if light.mode != .flow(id: id), let flow = LightFlow.named(id) { startFlow(light.mac, flow) }
            case .scene(let id)?:
                setScene(light.mac, id)
            case .white(let kelvin)?:
                setKelvin(light.mac, kelvin)
            default:
                break
            }
            setDimming(light.mac, preset.dimming)
        }
    }

    // MARK: - Flows

    /// The place a light takes in a flow: a strip goes for the accent palette when the flow has
    /// one, anything else for the main one; whoever finds theirs taken gets the first free place.
    private func freePlace(for light: Light, in flow: LightFlow) -> Int {
        let taken = flowRuns.filter { $0.key != light.mac && $0.value.id == flow.id }.map(\.value.place)
        let wanted = flow.accent != nil && light.isStrip ? 1 : 0
        if !taken.contains(wanted) { return wanted }
        return (0...taken.count).first { !taken.contains($0) } ?? 0
    }

    /// Advances every running flow one small step. Steps are sent unacknowledged: a lost one is
    /// simply superseded by the next. A flow pauses while all its lamps are off or unreachable.
    private func tickFlows() {
        guard !flowRuns.isEmpty else { return }
        let current = Date()
        func isLit(_ mac: String) -> Bool {
            lights.first { $0.mac == mac }.map { $0.isOn && $0.isOnline(now: current) } ?? false
        }
        /// Hues per second.
        func pace(_ flow: LightFlow) -> Double { Double(flowSpeed[flow.id] ?? 100) / 100 / flow.secondsPerColor }

        for (id, clock) in flowClocks {
            guard let flow = LightFlow.named(id), flowRuns.contains(where: { $0.value.id == id && isLit($0.key) }),
                  !(id == LightFlow.music.id && LightFlow.musicHolds)
            else {
                flowClocks[id]?.lastTick = current
                continue
            }
            // Capped so a sleeping Mac or a stalled timer resumes where it left off instead of jumping ahead.
            let elapsed = min(current.timeIntervalSince(clock.lastTick), 1)
            flowClocks[id] = (clock.position + elapsed * pace(flow), current)
        }

        for (mac, run) in flowRuns where isLit(mac) {
            guard let light = lights.first(where: { $0.mac == mac }), let flow = LightFlow.named(run.id),
                  let clock = flowClocks[run.id]
            else { continue }
            let position = clock.position
            let color = flow.color(at: position, place: run.place)
            let changed = color != light.flowColor
            update(mac) { $0.flowColor = color }
            // Never interleave with a user command that is still waiting to be sent or acknowledged.
            guard pending[mac] == nil, inflight[mac] == nil else { continue }
            switch light.kind {
            case .wiz:
                if changed || lastFlowSoftness[mac] != light.softness {
                    transport?.send(["method": "setPilot", "params": Self.colorParams(color, softness: light.softness, power: false)], to: light.ip)
                    lastFlowSoftness[mac] = light.softness
                }
            case .yeelight:
                // Aimed at where the flow will be one interval from now; the lamp glides there by itself.
                let interval = Self.lampStepInterval
                // A strip following the music is left to it.
                guard current.timeIntervalSince(lastFlowStep[mac] ?? .distantPast) >= interval,
                      current >= (stripBusyUntil[mac] ?? .distantPast)
                else { continue }
                let target = flow.color(at: position + interval * pace(flow), place: run.place)
                let step = YeelightCodec.flowStep(to: target, softness: light.softness, seconds: interval)
                // A step can wait; what the user asks for can't, so part of the lamp's allowance is kept for that.
                if yeelight.send(mac, [(Self.yeelightCommandID, step.method, step.params)], reserve: 6) {
                    lastFlowStep[mac] = current
                }
            }
        }
    }

    private var lastFlowSoftness: [String: Int] = [:]

    // MARK: Music

    /// Lights whose brightness is being flashed with the beat.
    private var pulsing: Set<String> = [] {
        didSet { if pulsing != oldValue { saveBaselines() } }
    }
    /// The brightness the user chose for each light the show is moving, kept on disk: if the app
    /// goes away in the middle of a swell, the next launch puts the lights back instead of taking
    /// the swell for the user's choice.
    private static let baselineKey = "showBaseline"
    private var leftover = UserDefaults.standard.dictionary(forKey: LightStore.baselineKey) as? [String: Int] ?? [:]

    private func saveBaselines() {
        var kept = leftover
        for mac in pulsing { kept[mac] = lights.first { $0.mac == mac }?.dimming }
        if kept.isEmpty { UserDefaults.standard.removeObject(forKey: Self.baselineKey) } else { UserDefaults.standard.set(kept, forKey: Self.baselineKey) }
    }

    /// What a light says its brightness is, unless it was left in the middle of the show last time.
    private func brightness(reported: Int, for mac: String, isOn: Bool) -> Int {
        guard let kept = leftover.removeValue(forKey: mac) else { return reported }
        saveBaselines()
        // Through the usual queue: it retries until the light has taken it, and holds off the
        // light's own reports of the old value meanwhile.
        if isOn, kept != reported { DispatchQueue.main.async { [weak self] in self?.setDimming(mac, kept) } }
        return kept
    }
    private var beatsEnd: DispatchWorkItem?

    /// The swell a kick sets off: 1 at its top, fading to 0. And how far the colours still have to
    /// travel for the kicks so far, in hues.
    var showStyle = ShowStyle.medium
    private var swell = 0.0
    private var colourPush = 0.0
    private var lastKick = Date.distantPast
    private var swellTimer: Timer?
    private var lastSwellDimming: [String: Int] = [:]
    private var pulses = 0

    /// The lights in the Spotify scene play different parts of the music.
    ///
    /// A beat (or a kick heard between beats, with less `strength`): a WiZ light swells — at once
    /// to the top, then falling back to rest — and its colour moves on. How deep and how fast is
    /// the show's style.
    func musicHit(_ strength: Double) {
        guard flowClocks[LightFlow.music.id] != nil else { return }
        lastKick = Date()
        colourPush += showStyle.push * strength
        swell = max(swell, strength)
        sendSwell()
        if swellTimer == nil {
            swellTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.swellTick() }
        }
        // When the beats stop coming, the lights go back to gliding at the brightness they were given.
        beatsEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in self?.musicBeatsEnded() }
        beatsEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: end)
    }

    /// A kick while there is no steady pulse: light strips take a new colour on one now and then.
    func musicStripsLoose(intensity: Double) {
        guard let flow = LightFlow.named(LightFlow.music.id) else { return }
        stepStrips(flow, now: Date(), glide: showStyle.stripGlide, spacing: max(showStyle.stripEvery, 1.8), intensity: intensity)
    }

    /// A beat of the steady pulse, `period` seconds long. A light strip moves to a colour from
    /// the other side of the cover on the first beat of every bar or two — as often as the
    /// commands it takes a minute allow — in a short soft glide.
    func musicPulse(period: Double, intensity: Double) {
        guard let flow = LightFlow.named(LightFlow.music.id) else { return }
        pulses += 1
        let style = showStyle
        let every = [2, 4, 8, 16].first { Double($0) * period >= style.stripEvery } ?? 16
        if pulses % every == 0 { stepStrips(flow, now: Date(), glide: min(period * Double(every) * 0.5, style.stripGlide), spacing: 1.5, intensity: intensity) }
    }

    /// A strip's turn. Usually a new colour; when the music has grown much louder or quieter since
    /// the strip's brightness was last set, the turn goes to its brightness instead — a strip in a
    /// quiet passage sits at about half of what the user chose.
    private func stepStrips(_ flow: LightFlow, now: Date, glide: Double, spacing: Double, intensity: Double) {
        guard let position = flowClocks[flow.id]?.position else { return }
        for (mac, run) in flowRuns where run.id == flow.id {
            guard let light = lights.first(where: { $0.mac == mac }), light.kind == .yeelight, light.isOn, light.isOnline(now: now),
                  pending[mac] == nil, inflight[mac] == nil,
                  now.timeIntervalSince(lastFlowStep[mac] ?? .distantPast) >= spacing
            else { continue }
            let level = 0.5 + 0.5 * intensity
            if abs(level - (stripLevel[mac] ?? 1)) > 0.2 {
                let bright = max(1, Int((Double(light.dimming) * level).rounded()))
                if yeelight.send(mac, [(Self.yeelightCommandID, "set_bright", [bright, "smooth", 900])], reserve: 6) {
                    stripLevel[mac] = level
                    lastFlowStep[mac] = now
                    stripBusyUntil[mac] = now.addingTimeInterval(4)
                    pulsing.insert(mac)
                }
                continue
            }
            stripTurn[mac, default: 0] += 1
            // Two hues ahead of the bulb, and a hue further at every turn: never the bulb's own colour.
            let color = flow.color(at: position.rounded() + 2 + Double(stripTurn[mac, default: 0] % 2), place: 0)
            update(mac) { $0.flowColor = color }
            let step = YeelightCodec.flowStep(to: color, softness: light.softness, seconds: glide)
            if yeelight.send(mac, [(Self.yeelightCommandID, step.method, step.params)], reserve: 6) {
                lastFlowStep[mac] = now
                stripBusyUntil[mac] = now.addingTimeInterval(4)
            }
        }
    }

    private var stripTurn: [String: Int] = [:]
    /// The share of its brightness each strip was last set to for the music.
    private var stripLevel: [String: Double] = [:]
    /// While a strip is following the music, the flow's own slow steps leave it alone.
    private var stripBusyUntil: [String: Date] = [:]

    private func swellTick() {
        swell *= showStyle.fall
        sendSwell()
        if swell < 0.01, colourPush < 0.01, Date().timeIntervalSince(lastKick) > 1 { endSwell() }
    }

    private func sendSwell() {
        let id = LightFlow.music.id, now = Date()
        guard let clock = flowClocks[id], let flow = LightFlow.named(id) else {
            endSwell()
            return
        }
        let move = colourPush * 0.4
        colourPush -= move
        let position = clock.position + move
        flowClocks[id] = (position, clock.lastTick)
        for (mac, run) in flowRuns where run.id == id {
            guard let light = lights.first(where: { $0.mac == mac }), light.kind == .wiz, light.isOn, light.isOnline(now: now),
                  pending[mac] == nil, inflight[mac] == nil
            else { continue }
            // Rest and top sit either side of the brightness the user chose, as far apart as the
            // style asks and the light allows.
            let depth = showStyle.depth, floor = Double(light.minDimming)
            var low = Double(light.dimming) / depth.squareRoot(), high = Double(light.dimming) * depth.squareRoot()
            if high > 100 { (low, high) = (max(100 / depth, floor), 100) }
            if low < floor { (low, high) = (floor, min(floor * depth, 100)) }
            let dimming = Int((low + (high - low) * swell).rounded())
            let color = flow.color(at: position, place: 0)
            guard dimming != lastSwellDimming[mac] || color != light.flowColor else { continue }
            update(mac) { $0.flowColor = color }
            var params = Self.colorParams(color, softness: light.softness, power: false)
            params["dimming"] = dimming
            transport?.send(["method": "setPilot", "params": params], to: light.ip)
            lastSwellDimming[mac] = dimming
            pulsing.insert(mac)
        }
    }

    private func endSwell() {
        swellTimer?.invalidate()
        swellTimer = nil
        swell = 0
        colourPush = 0
    }

    func musicBeatsEnded() {
        beatsEnd?.cancel()
        beatsEnd = nil
        endSwell()
        let macs = pulsing
        pulsing = []
        lastSwellDimming = [:]
        stripBusyUntil = [:]
        let levels = stripLevel
        stripLevel = [:]
        for mac in macs {
            guard let light = lights.first(where: { $0.mac == mac }), light.isOn, pending[mac] == nil, inflight[mac] == nil else { continue }
            switch light.kind {
            case .wiz:
                transport?.send(["method": "setPilot", "params": ["dimming": light.dimming]], to: light.ip)
            case .yeelight:
                if levels[mac] != nil { _ = yeelight.send(mac, [(Self.yeelightCommandID, "set_bright", [light.dimming, "smooth", 600])]) }
            }
        }
    }

    /// Call after `flowRuns` changes: persists it and keeps the App Nap exemption in step.
    private func flowsChanged() {
        flowClocks = flowClocks.filter { clock in flowRuns.contains { $0.value.id == clock.key } }
        UserDefaults.standard.set(flowRuns.mapValues { $0.id }, forKey: Self.flowsKey)
        if flowRuns.isEmpty, let activity = flowActivity {
            ProcessInfo.processInfo.endActivity(activity)
            flowActivity = nil
        } else if !flowRuns.isEmpty, flowActivity == nil {
            flowActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                                 reason: "Animating a light flow")
        }
    }

    // MARK: - Sending

    private func enqueue(_ mac: String, _ params: [String: Any], replacing conflicting: [String] = []) {
        var merged = pending[mac] ?? [:]
        for key in conflicting {
            merged.removeValue(forKey: key)
        }
        merged.merge(params) { _, new in new }
        pending[mac] = merged
        localChangeAt[mac] = Date()
    }

    private var pollSoonAt: Date?

    private func flush() {
        let current = Date()
        if let due = pollSoonAt, current >= due {
            pollSoonAt = nil
            poll()
        }

        for (mac, params) in pending {
            guard let light = lights.first(where: { $0.mac == mac }) else {
                pending[mac] = nil
                continue
            }
            switch light.kind {
            case .wiz:
                transport?.send(["method": "setPilot", "params": params], to: light.ip)
                inflight[mac] = (params, current, 1)
                pending[mac] = nil
            case .yeelight:
                // Stays queued while the lamp can't take it — but not for long: a command that
                // lands much later than it was given would be a surprise.
                let waited = current.timeIntervalSince(localChangeAt[mac] ?? .distantPast)
                if sendToYeelight(light, params) || waited > 6 { pending[mac] = nil }
            }
        }

        // UDP gives no delivery guarantee: resend anything the lamp hasn't acknowledged.
        for (mac, entry) in inflight where current.timeIntervalSince(entry.sentAt) > 0.4 {
            guard entry.attempts < 4, let light = lights.first(where: { $0.mac == mac }) else {
                inflight.removeValue(forKey: mac)
                continue
            }
            transport?.send(["method": "setPilot", "params": entry.params], to: light.ip)
            inflight[mac] = (entry.params, current, entry.attempts + 1)
        }
    }

    private func poll() {
        now = Date()
        let request: [String: Any] = ["method": "getPilot", "params": [String: Any]()]
        transport?.broadcast(request)
        // Lamps we already know are also asked directly, in case broadcast is filtered by the router.
        for light in lights where light.kind == .wiz {
            transport?.send(request, to: light.ip)
        }
        let known = lights.filter { $0.kind == .yeelight }
        yeelight.search(alsoAsking: known.map(\.ip))
        for light in known {
            yeelight.open(light.mac, ip: light.ip)
        }
    }

    // MARK: - Yeelight

    /// Sends what is queued for a Yeelight light. False means it has to stay queued: the lamp is
    /// not connected, or has had as many commands as it accepts for the moment.
    private func sendToYeelight(_ light: Light, _ params: [String: Any]) -> Bool {
        let mac = light.mac
        let commands = YeelightCodec.commands(for: params, lampIsOn: yeelightState[mac]?["power"] == "on", brightness: light.dimming)
        guard !commands.isEmpty else { return true }
        guard yeelight.send(mac, commands.map { (Self.yeelightCommandID, $0.method, $0.params) }) else { return false }
        if let r = params["r"] as? Int, let g = params["g"] as? Int, let b = params["b"] as? Int {
            let hue = RGB(r: r, g: g, b: b), softness = params["c"] as? Int ?? 0
            yeelightSentColor[mac] = (YeelightCodec.rgbValue(hue, softness: softness), hue, softness)
        }
        // Assumed until the lamp confirms, so a command right behind this one isn't another switch-on.
        if let power = params["state"] as? Bool { yeelightState[mac, default: [:]]["power"] = power ? "on" : "off" }
        localChangeAt[mac] = Date()
        // The lamp is gliding towards this now; let it finish before the flow moves it on.
        lastFlowStep[mac] = Date().addingTimeInterval(0.4 - Self.lampStepInterval)
        return true
    }

    private func handleYeelightAdvert(ip: String, headers: [String: String]) {
        guard let key = YeelightCodec.key(forID: headers["id"]) else { return }
        if !lights.contains(where: { $0.mac == key }) {
            lights.append(.yeelight(key: key, ip: ip))
        }
        let before = lights.first { $0.mac == key }
        update(key) { light in
            light.ip = ip
            if let model = headers["model"] { light.module = model }
            if let support = headers["support"] { light.methods = Set(support.split(separator: " ").map(String.init)) }
        }
        if let after = lights.first(where: { $0.mac == key }),
           after.ip != before?.ip || after.module != before?.module || after.methods != before?.methods {
            sortLights()
            persistKnownLights()
        }
        yeelight.open(key, ip: ip)
        yeelightReported(key, headers.filter { YeelightCodec.stateProps.contains($0.key) })
    }

    private func handleYeelight(key: String, message: [String: Any]) {
        if message["method"] as? String == "props", let params = message["params"] as? [String: Any] {
            yeelightReported(key, params.mapValues { "\($0)" })
        } else if message["id"] as? Int == Self.yeelightPropsID, let values = message["result"] as? [Any] {
            yeelightReported(key, Dictionary(uniqueKeysWithValues: zip(YeelightCodec.stateProps, values.map { "\($0)" })))
        }
    }

    /// Folds in what a Yeelight lamp reported — a search reply, a notification or an answer to
    /// get_prop, so possibly only some properties — and mirrors the result onto the light.
    private func yeelightReported(_ key: String, _ props: [String: String]) {
        yeelightState[key, default: [:]].merge(props) { _, new in new }
        guard let state = yeelightState[key] else { return }
        // As for WiZ: what the user just asked for wins over what the lamp still reports.
        let holdOff = pending[key] != nil || (localChangeAt[key].map { Date().timeIntervalSince($0) < 2 } ?? false)
        let run = flowRuns[key], sent = yeelightSentColor[key], flowSoftness = preferredSoftness(for: key)
        update(key) { light in
            light.lastSeen = Date()
            guard !holdOff else { return }
            if let power = state["power"] { light.isOn = power == "on" }
            if let bright = state["bright"].flatMap({ Int($0) }), !pulsing.contains(key) {
                light.dimming = brightness(reported: bright, for: key, isOn: light.isOn)
            }

            // A lamp running one of our flows just reports whatever colour the flow last sent.
            if let run, state["color_mode"] != "2" {
                if light.mode != .flow(id: run.id) { light.softness = flowSoftness }
                light.mode = .flow(id: run.id)
                return
            }
            var color: (hue: RGB, softness: Int)?
            switch state["color_mode"] {
            case "1":
                guard let rgb = state["rgb"].flatMap({ Int($0) }) else { break }
                color = sent?.rgb == rgb ? sent.map { ($0.hue, $0.softness) } : YeelightCodec.color(rgb: rgb)
            case "2":
                if let kelvin = state["ct"].flatMap({ Int($0) }) { light.mode = .white(kelvin: kelvin) }
            case "3":
                if let hue = state["hue"].flatMap({ Int($0) }), let saturation = state["sat"].flatMap({ Int($0) }) {
                    color = YeelightCodec.color(hue: hue, saturation: saturation)
                }
            default:
                break
            }
            if let color {
                light.mode = .color(r: color.hue.r, g: color.hue.g, b: color.hue.b)
                light.softness = color.softness
            }
        }
        now = Date()
    }

    // MARK: - Receiving

    private func handle(ip: String, message: [String: Any]) {
        guard let method = message["method"] as? String else { return }

        if method == "setPilot" {
            if let light = lights.first(where: { $0.ip == ip }) {
                inflight.removeValue(forKey: light.mac)
            }
            return
        }

        guard let result = message["result"] as? [String: Any],
              let mac = result["mac"] as? String
        else {
            if method == "getModelConfig", let result = message["result"] as? [String: Any] {
                applyModelConfig(result, ip: ip)
            }
            return
        }

        switch method {
        case "getPilot":
            applyPilot(result, mac: mac, ip: ip)
        case "getSystemConfig":
            if let module = result["moduleName"] as? String {
                update(mac) { $0.module = module }
                persistKnownLights()
            }
        default:
            break
        }
    }

    private func applyPilot(_ result: [String: Any], mac: String, ip: String) {
        let isNew = !lights.contains { $0.mac == mac }
        if isNew {
            lights.append(Light(mac: mac, ip: ip))
            sortLights()
        }

        let holdOff = localChangeAt[mac].map { Date().timeIntervalSince($0) < 2 } ?? false
        update(mac) { light in
            light.ip = ip
            light.lastSeen = Date()
            guard !holdOff else {
                // Right after picking a scene the only news we take from the lamp is whether it animates.
                if case .scene(let id) = light.mode, light.sceneSpeed == nil, result["sceneId"] as? Int == id {
                    light.sceneSpeed = result["speed"] as? Int
                }
                return
            }

            if let state = result["state"] as? Bool { light.isOn = state }
            // A light flashing with the music reports the flash, not the brightness the user chose.
            if let dimming = result["dimming"] as? Int, !pulsing.contains(mac) {
                light.dimming = brightness(reported: dimming, for: mac, isOn: light.isOn)
            }

            let sceneId = result["sceneId"] as? Int ?? 0
            if sceneId > 0 {
                light.mode = .scene(id: sceneId)
                light.sceneSpeed = result["speed"] as? Int
            } else if let kelvin = result["temp"] as? Int {
                light.mode = .white(kelvin: kelvin)
            } else if let r = result["r"] as? Int, let g = result["g"] as? Int, let b = result["b"] as? Int {
                let white = (result["c"] as? Int ?? 0) + (result["w"] as? Int ?? 0)
                light.softness = min((white + 1) / 2, 100)
                // A lamp running one of our flows just reports whatever colour the flow last sent.
                if let run = self.flowRuns[mac] {
                    light.mode = .flow(id: run.id)
                } else {
                    light.mode = .color(r: r, g: g, b: b)
                }
            }
        }

        let module = lights.first { $0.mac == mac }?.module
        if isNew || module == nil {
            transport?.send(["method": "getSystemConfig", "params": [String: Any]()], to: ip)
            transport?.send(["method": "getModelConfig", "params": [String: Any]()], to: ip)
            persistKnownLights()
        }
        now = Date()
    }

    private func applyModelConfig(_ result: [String: Any], ip: String) {
        // cctRange is [min, warmest native, coolest native, max].
        guard let range = result["cctRange"] as? [Int], let low = range.first, let high = range.last, low < high,
              let mac = lights.first(where: { $0.ip == ip })?.mac
        else { return }
        update(mac) {
            $0.minKelvin = low
            $0.maxKelvin = high
        }
    }

    private func update(_ mac: String, _ change: (inout Light) -> Void) {
        guard let index = lights.firstIndex(where: { $0.mac == mac }) else { return }
        var light = lights[index]
        change(&light)
        // Anything that takes the lamp out of flow mode (a preset, another colour, another app) ends the flow.
        if case .scene = light.mode {} else { light.sceneSpeed = nil }
        if case .flow = light.mode {} else {
            light.flowColor = nil
            if light.mode != .unknown, flowRuns.removeValue(forKey: mac) != nil { flowsChanged() }
        }
        if light != lights[index] {
            if light.mode != lights[index].mode {
                peekedPanels.removeValue(forKey: mac)
            }
            lights[index] = light
        }
    }

    private func sortLights() {
        lights.sort { name(for: $0).localizedStandardCompare(name(for: $1)) == .orderedAscending }
    }

    // MARK: - Persistence

    /// Remembered lights show up immediately (as offline) even before they answer.
    private func persistKnownLights() {
        let known = lights.map {
            ["mac": $0.mac, "ip": $0.ip, "module": $0.module ?? "", "kind": $0.kind.rawValue,
             "methods": $0.methods.sorted().joined(separator: " ")]
        }
        UserDefaults.standard.set(known, forKey: Self.knownKey)
    }

    private func restoreKnownLights() {
        guard let known = UserDefaults.standard.array(forKey: Self.knownKey) as? [[String: String]] else { return }
        for entry in known {
            guard let mac = entry["mac"], let ip = entry["ip"] else { continue }
            var light = entry["kind"] == LightKind.yeelight.rawValue ? Light.yeelight(key: mac, ip: ip) : Light(mac: mac, ip: ip)
            light.module = entry["module"].flatMap { $0.isEmpty ? nil : $0 }
            light.methods = Set((entry["methods"] ?? "").split(separator: " ").map(String.init))
            light.lastSeen = .distantPast
            lights.append(light)
        }
        sortLights()

        // A flow that was running when the app quit resumes if the lamp is still showing a colour.
        let defaults = UserDefaults.standard
        softnessChoice = defaults.dictionary(forKey: Self.softnessKey) as? [String: Int] ?? [:]
        let saved = defaults.dictionary(forKey: Self.flowsKey) as? [String: String] ?? [:]
        for light in lights {
            guard let flow = saved[light.mac].flatMap(LightFlow.named) else { continue }
            flowRuns[light.mac] = (flow.id, freePlace(for: light, in: flow))
            flowClocks[flow.id] = (0, Date())
        }
        flowSpeed = defaults.dictionary(forKey: Self.flowSpeedKey) as? [String: Int] ?? [:]
        if !flowRuns.isEmpty { flowsChanged() }
    }
}
