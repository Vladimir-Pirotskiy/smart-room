import AppKit
import CoreAudio
import Foundation

/// How hard the lights move with the music.
enum ShowStyle: String, CaseIterable, Identifiable {
    case soft, medium, strong

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    /// How many times brighter a WiZ light is at the top of a swell than at rest. A ratio, so the
    /// swell shows as well on a dim light as on a bright one.
    var depth: Double { [.soft: 1.6, .medium: 2.4, .strong: 4.5][self] ?? 2.4 }
    /// How much of a swell is left after each 80 ms of falling.
    var fall: Double { [.soft: 0.9, .medium: 0.82, .strong: 0.62][self] ?? 0.82 }
    /// How far a beat moves the colours on, in hues.
    var push: Double { [.soft: 0.2, .medium: 0.5, .strong: 1][self] ?? 0.5 }
    /// The least time between a light strip's moves, and how long each glide lasts at most, in seconds.
    var stripEvery: Double { [.soft: 3, .medium: 1.7, .strong: 1.5][self] ?? 1.7 }
    var stripGlide: Double { [.soft: 1.2, .medium: 0.5, .strong: 0.12][self] ?? 0.5 }

    var summary: String {
        switch self {
        case .soft: return "A slow, shallow breath on the beat; the strip drifts to a new colour every couple of bars."
        case .medium: return "A clear swell on every beat, the colour moving on; the strip glides to a new colour every bar."
        case .strong: return "A hard hit on every beat in a new colour; the strip snaps to a new colour as often as it can."
        }
    }
}

/// Makes the Spotify scene move with the music: while Spotify plays and the scene is on a lit
/// light, it listens to the sound the Mac is playing and tells the store about every beat.
/// Spotify itself gives no beat or tempo, so the beat is found in the sound.
final class BeatListener: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.key)
            refresh()
        }
    }
    @Published var style: ShowStyle {
        didSet {
            UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey)
            store?.showStyle = style
        }
    }
    /// Moves the lights against the sound, in seconds: negative is earlier. For the delay of the
    /// lights themselves, which the app cannot measure.
    @Published var timing: Double {
        didSet { UserDefaults.standard.set(timing, forKey: Self.timingKey) }
    }
    static let timingRange = -0.1...0.25
    /// Why nothing is happening, when it should be.
    @Published private(set) var problem: String?

    private static let key = "beatSync"
    private static let styleKey = "beatStyle"
    private static let timingKey = "beatTiming"
    private weak var store: LightStore?
    private var tap: SystemAudioTap?
    private var timer: Timer?
    private var startedAt = Date()
    private var heardSound = false
    private var lastKick = Date.distantPast
    private var lastPulse = Date.distantPast
    private var lastSound = Date.distantPast
    private var period = 0.5

    init(store: LightStore) {
        self.store = store
        enabled = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
        style = UserDefaults.standard.string(forKey: Self.styleKey).flatMap(ShowStyle.init) ?? .medium
        timing = min(max(UserDefaults.standard.double(forKey: Self.timingKey), Self.timingRange.lowerBound), Self.timingRange.upperBound)
        store.showStyle = style
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        // Quit in the middle of the show: the lights go back to the brightness they were given first.
        quitting = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopListening()
        }
        // Headphones connected, speakers chosen: the tap is tied to the old output and has to be made again.
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            guard let self, self.tap != nil else { return }
            Trace.log("beat: the sound output changed")
            self.stopListening()
        }
    }

    private var quitting: NSObjectProtocol?

    private func stopListening() {
        tap = nil
        store?.musicBeatsEnded()
    }

    /// When a beat is announced it is this long until the lights should be told: the beats come
    /// a tenth of a second early, the sound reaches the ears late by the output's delay.
    private var wait: Double { max((tap?.outputDelay ?? 0) + timing, 0) }

    private func later(_ work: @escaping () -> Void) {
        let wait = wait
        if wait < 0.005 { work() } else { DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work) }
    }

    private var wanted: Bool {
        enabled && SpotifyLink.isPlaying
            && store?.lights.contains { $0.isOn && $0.mode == .flow(id: LightFlow.music.id) } == true
    }

    private func refresh() {
        guard wanted else {
            if tap != nil {
                Trace.log("beat: stopped listening")
                stopListening()
            }
            if problem != nil { problem = nil }
            return
        }
        if tap == nil {
            startedAt = Date()
            heardSound = false
            lastSound = Date()
            tap = SystemAudioTap(
                onKick: { [weak self] in self?.kick($0) },
                onPulse: { [weak self] in self?.pulse($0, $1) },
                onSound: { [weak self] in
                    self?.heardSound = true
                    self?.lastSound = Date()
                }
            )
            Trace.log("beat: \(tap.map { String(format: "listening, the output is %.0f ms behind", $0.outputDelay * 1000) } ?? "could not start listening")")
        } else if heardSound, Date().timeIntervalSince(lastSound) > 6 {
            // It worked and went quiet while Spotify plays on (the Mac slept, the output went away): start over.
            Trace.log("beat: the sound stopped coming, listening again")
            stopListening()
            return
        }
        let trouble: String?
        if tap == nil {
            trouble = "Smart Room could not start listening to the Mac's sound."
        } else if !heardSound, Date().timeIntervalSince(startedAt) > 6 {
            trouble = "No sound reaches Smart Room. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only."
        } else {
            trouble = nil
        }
        if trouble != problem { problem = trouble }
    }

    /// A quiet passage moves the lights less than a loud one: the show follows the song's own rises and falls.
    private static func strength(_ intensity: Double) -> Double { 0.45 + 0.55 * intensity }

    private func kick(_ intensity: Double) {
        guard tap != nil, let store else { return }
        let now = Date()
        Trace.log(String(format: "beat: kick +%.2f s", min(now.timeIntervalSince(lastKick), 99)))
        lastKick = now
        guard now.timeIntervalSince(lastPulse) < 2 else {
            // No pulse to go by: the lights answer each kick as it is heard.
            later {
                store.musicHit(Self.strength(intensity))
                store.musicStripsLoose(intensity: intensity)
            }
            return
        }
        // With a pulse the lights are already moving on the beats, a moment ahead so that the
        // light arrives with the sound. Only a kick that falls between the beats is answered here.
        let beat = (now.timeIntervalSince(lastPulse) - BeatDetector.lead).truncatingRemainder(dividingBy: period)
        let off = min(abs(beat), abs(period - abs(beat)))
        if off > period * 0.22 { later { store.musicHit(Self.strength(intensity) * 0.7) } }
    }

    private func pulse(_ period: Double, _ intensity: Double) {
        guard tap != nil, let store else { return }
        let now = Date()
        Trace.log(String(format: "beat: pulse +%.2f s, tempo %.1f, intensity %.2f", min(now.timeIntervalSince(lastPulse), 99), 60 / period, intensity))
        lastPulse = now
        self.period = period
        // In a passage without drums the lights just glide; the pulse is played only along with the kicks.
        guard now.timeIntervalSince(lastKick) < 2.5 else { return }
        later {
            store.musicHit(Self.strength(intensity))
            store.musicPulse(period: period, intensity: intensity)
        }
    }
}

/// Finds two things in a stream of sound. Kicks: the moments the bass jumps well above its recent
/// level, wherever they fall. And the pulse: the steady beat under them, found by looking for the
/// spacing at which the last seconds of bass hits repeat — it keeps time through syncopated
/// rhythms, where the kicks themselves do not come evenly.
struct BeatDetector {
    struct Events {
        var kick = false
        /// A beat of the steady pulse; the value is seconds per beat.
        var pulse: Double?
        var sound = false
        /// How loud the music is now against the last half-minute of it: 0 in a quiet passage, 1 at full tilt.
        var intensity = 1.0
        /// The hundredth of a second this was found in, counted from the start: for checking the timing.
        var hop = 0
        var isEmpty: Bool { !kick && pulse == nil && !sound }
    }

    /// How far ahead of a beat of the pulse it is announced, in seconds.
    static let lead = 0.1

    private let smoothing: Double
    private let hop: Int
    private let hopSeconds: Double
    private var low1 = 0.0, low2 = 0.0
    private var energy = 0.0, loudness = 0.0, frames = 0
    private var fast = 0.0, slow = 0.0
    private var armed = true
    private var hopsSinceKick = 100
    private var hopsSinceSound = 0

    /// How sharply the bass rose in each of the last eight seconds' hops; a ring.
    private var onsets = [Double](repeating: 0, count: 800)
    private var head = 0
    private var filled = 0
    private var previousAmplitude = 0.0, previousWhole = 0.0
    /// Loudness over the last second or two, and over the last half-minute.
    private var near = 0.0, far = 0.0
    /// The last few readings of the tempo, in hops per beat: one reading alone is not trusted.
    private var readings: [Double] = []
    /// How many analyses in a row found the beats clearly somewhere else in the bar than the grid has them.
    private var strays = 0
    private var hops = 0
    /// Hops per beat, and the hop at which the next beat of the pulse falls.
    private var period: Double?
    private var nextPulse = 0.0
    private var lastPulse = -1000

    init(sampleRate: Double) {
        // Two gentle low-pass stages at about 120 Hz: what is left is kick drum and bass.
        smoothing = 1 - exp(-2 * Double.pi * 120 / sampleRate)
        hop = max(Int(sampleRate / 100), 1)
        hopSeconds = Double(hop) / sampleRate
    }

    /// Takes one sample (all channels mixed); every hundredth of a second it may have something to say.
    mutating func feed(_ sample: Double) -> Events? {
        low1 += (sample - low1) * smoothing
        low2 += (low1 - low2) * smoothing
        energy += low2 * low2
        loudness += sample * sample
        frames += 1
        guard frames >= hop else { return nil }
        let level = energy / Double(frames), whole = loudness / Double(frames)
        energy = 0
        loudness = 0
        frames = 0
        var events = Events()

        // Kicks: the bass now, against the bass of the last second or so.
        fast += (level - fast) * 0.5
        slow += (level - slow) * 0.012
        hopsSinceKick += 1
        hopsSinceSound += 1
        if fast < slow * 1.15 { armed = true }
        if armed, hopsSinceKick >= 22, fast > slow * 1.7, fast > 1e-7 {
            armed = false
            hopsSinceKick = 0
            events.kick = true
        }
        if level > 1e-9, hopsSinceSound >= 50 {
            hopsSinceSound = 0
            events.sound = true
        }

        // The pulse.
        // Bass hits count most; everything else that starts suddenly (snare, hats) helps to place the beat.
        let amplitude = level.squareRoot(), wholeAmplitude = whole.squareRoot()
        onsets[head] = max(amplitude - previousAmplitude, 0) + max(wholeAmplitude - previousWhole, 0) * 0.4
        previousAmplitude = amplitude
        previousWhole = wholeAmplitude
        near += (wholeAmplitude - near) * 0.007
        far += (wholeAmplitude - far) * max(0.0005, 1 / Double(hops + 1))
        head = (head + 1) % onsets.count
        filled = min(filled + 1, onsets.count)
        hops += 1
        if hops % 50 == 0, filled >= 400 { findPulse() }
        // Said a moment early: a light takes about that long to show what it is told.
        if let period, Double(hops) + Self.lead / hopSeconds >= nextPulse {
            nextPulse += period
            if Double(hops - lastPulse) > period * 0.6 {
                lastPulse = hops
                events.pulse = period * hopSeconds
            }
        }
        events.hop = hops
        // Not in the first seconds: the short average has not caught up yet and would read as a quiet passage.
        events.intensity = far > 1e-9 && hops > 400 ? min(max((near / far - 0.5) / 0.6, 0), 1) : 1
        return events.isEmpty ? nil : events
    }

    private mutating func findPulse() {
        // The last eight seconds, newest first.
        let count = filled
        let recent = (0..<count).map { onsets[(head - 1 - $0 + onsets.count * 2) % onsets.count] }
        let power = recent.reduce(0) { $0 + $1 * $1 } / Double(count)
        guard power > 1e-12 else {
            period = nil
            readings = []
            return
        }
        // At which spacing do the hits repeat? Between 60 and 220 beats a minute, leaning towards 120.
        var repeats = [Double](repeating: 0, count: 102)
        for lag in 26...101 {
            var sum = 0.0
            for index in 0..<(count - lag) { sum += recent[index] * recent[index + lag] }
            repeats[lag] = sum / Double(count - lag)
        }
        var best = 27, bestScore = 0.0
        for lag in 27...100 {
            let octaves = log2(Double(lag) / 50)
            let score = repeats[lag] * exp(-0.5 * (octaves / 0.8) * (octaves / 0.8))
            if score > bestScore { (best, bestScore) = (lag, score) }
        }
        // Music without a beat repeats at no spacing in particular.
        guard repeats[best] > power * 0.08 else {
            period = nil
            readings = []
            return
        }
        let before = repeats[best - 1], after = repeats[best + 1], bend = before - 2 * repeats[best] + after
        var reading = Double(best) + (bend < 0 ? min(max(0.5 * (before - after) / bend, -0.5), 0.5) : 0)
        // The same spacing measured across several beats at once is known that many times finer:
        // a hundredth of a second is 2.5 beats a minute at 120, too coarse to hold a grid steady.
        for multiple in [4, 3, 2] where count - multiple * best - multiple - 3 >= 200 {
            let first = multiple * best - multiple - 2, last = multiple * best + multiple + 2
            var values: [Double] = []
            for lag in first...last {
                var sum = 0.0
                for index in 0..<(count - lag) { sum += recent[index] * recent[index + lag] }
                values.append(sum / Double(count - lag))
            }
            var top = 1
            for index in 1..<(values.count - 1) where values[index] > values[top] { top = index }
            // No clear repeat that far out (the tempo drifts, or the guess was off): keep the coarse reading.
            guard values[top] > repeats[best] * 0.4, values[top] >= values[0], values[top] >= values[values.count - 1] else { break }
            let bend = values[top - 1] - 2 * values[top] + values[top + 1]
            let shift = bend < 0 ? min(max(0.5 * (values[top - 1] - values[top + 1]) / bend, -0.5), 0.5) : 0
            reading = (Double(first + top) + shift) / Double(multiple)
            break
        }
        // A syncopated rhythm repeats at other spacings too, now and then better than at its beat.
        // While the tempo the lights are on still fits nearly as well, it stays.
        if let old = period, abs(reading - old) > 1.5, (27...100).contains(Int(old.rounded())) {
            let lag = Int(old.rounded())
            if max(repeats[lag - 1], repeats[lag], repeats[lag + 1]) > repeats[best] * 0.6 { reading = old }
        }
        // The tempo is what most of the last readings agree on; until they agree there is no pulse.
        readings = Array((readings + [reading]).suffix(7))
        let median = readings.sorted()[readings.count / 2]
        let agreeing = readings.filter { abs($0 - median) < 1 }
        guard readings.count >= 3, agreeing.count * 5 >= readings.count * 3 else {
            if let old = period, abs(old - median) > 1.5 { period = nil }
            return
        }
        let found = agreeing.reduce(0, +) / Double(agreeing.count)

        // Where do the beats fall? The offset at which a comb of that spacing catches the most.
        func comb(_ offset: Double) -> Double {
            var sum = 0.0, tooth = offset
            while Int(tooth.rounded()) < count - 1 {
                let index = Int(tooth.rounded())
                sum += recent[index] + (recent[index + 1] + (index > 0 ? recent[index - 1] : 0)) / 2
                tooth += found
            }
            return sum
        }
        var phase = 0, caught = -1.0
        for offset in 0..<Int(found.rounded()) {
            let sum = comb(Double(offset))
            if sum > caught { (phase, caught) = (offset, sum) }
        }
        let next = Double(hops - phase) + found
        if let old = period, abs(old - found) < 1.5 {
            // The same tempo as before: lean towards the new reading instead of jumping to it.
            period = old + (found - old) * 0.5
            let shift = (next - nextPulse).remainder(dividingBy: found)
            if abs(shift) <= found * 0.12 {
                nextPulse += shift * 0.5
                strays = 0
            } else {
                // The comb sits best elsewhere in the bar. In syncopated music that comes and goes;
                // the grid moves only when the other place is clearly better for two seconds running.
                var ago = (Double(hops) - nextPulse).truncatingRemainder(dividingBy: found)
                if ago < 0 { ago += found }
                strays = caught > comb(ago) * 1.25 ? strays + 1 : 0
                if strays >= 4 {
                    nextPulse = next
                    strays = 0
                }
            }
        } else {
            period = found
            nextPulse = next
            strays = 0
        }
        while nextPulse < Double(hops) { nextPulse += found }
    }
}

/// Everything the Mac is playing, as samples: a system audio tap on a private aggregate device.
/// macOS asks the user once whether Smart Room may record system audio; until they agree the
/// samples are silence. Lives as long as the object does.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "smartroom.beat", qos: .userInitiated)

    /// How long after the tap hears a sound the listener does: the output device's own delay,
    /// small for built-in speakers, a good part of a second for Bluetooth headphones.
    private(set) var outputDelay = 0.0

    init?(onKick: @escaping (Double) -> Void, onPulse: @escaping (Double, Double) -> Void, onSound: @escaping () -> Void) {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Smart Room"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return nil }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32, format.mSampleRate > 0,
              let output = Self.defaultOutput()
        else {
            close()
            return nil
        }

        // The tap needs a device to be read from; the output device gives that device its clock.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Smart Room Listener",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID) == noErr else {
            close()
            return nil
        }

        outputDelay = output.delay
        var detector = BeatDetector(sampleRate: format.mSampleRate)
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buffer = buffers.first, let data = buffer.mData else { return }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let samples = data.assumingMemoryBound(to: Float32.self)
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size / channels
            for frame in 0..<count {
                var mixed = 0.0
                for channel in 0..<channels { mixed += Double(samples[frame * channels + channel]) }
                guard let events = detector.feed(mixed / Double(channels)) else { continue }
                if events.kick || events.pulse != nil { Trace.log("beat: heard \(events.kick ? "kick" : "")\(events.pulse != nil ? "pulse" : "") at \(events.hop)") }
                let intensity = events.intensity
                if events.kick { DispatchQueue.main.async { onKick(intensity) } }
                if let period = events.pulse { DispatchQueue.main.async { onPulse(period, intensity) } }
                if events.sound { DispatchQueue.main.async(execute: onSound) }
            }
        }
        guard status == noErr, let procID, AudioDeviceStart(deviceID, procID) == noErr else {
            close()
            return nil
        }
    }

    deinit { close() }

    private func close() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func defaultOutput() -> (uid: String, delay: Double)? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }

        func number(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> Double {
            var value = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? Double(value) : 0
        }
        var rate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        let frames = number(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
            + number(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)
            + number(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
        return (uid.takeRetainedValue() as String, rate > 0 ? min(frames / rate, 0.6) : 0)
    }
}
