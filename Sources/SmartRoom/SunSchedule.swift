import Foundation

/// Sunrise and sunset, worked out on the Mac: no network and no location permission.
enum Sun {
    /// Roughly where the Mac is: the reference city of its time zone, from the system's own table
    /// (zone.tab). That can be a few hundred kilometres off, which moves the times by up to about
    /// twenty minutes. For the exact place set `sunLatitude` and `sunLongitude` (degrees, north and
    /// east positive) in the app's defaults.
    static func coordinates() -> (latitude: Double, longitude: Double)? {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "sunLatitude") != nil, defaults.object(forKey: "sunLongitude") != nil {
            return (defaults.double(forKey: "sunLatitude"), defaults.double(forKey: "sunLongitude"))
        }
        let zone = TimeZone.current.identifier
        for path in ["/usr/share/zoneinfo/zone.tab", "/var/db/timezone/zoneinfo/zone.tab"] {
            guard let table = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in table.split(separator: "\n") where !line.hasPrefix("#") {
                let fields = line.split(separator: "\t")
                if fields.count >= 3, fields[2] == zone, let place = parse(String(fields[1])) { return place }
            }
        }
        return nil
    }

    /// ISO 6709 as zone.tab writes it: ±DDMM±DDDMM or ±DDMMSS±DDDMMSS.
    private static func parse(_ text: String) -> (latitude: Double, longitude: Double)? {
        guard let split = text.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        func degrees(_ part: Substring, whole: Int) -> Double? {
            let digits = part.dropFirst()
            guard digits.count >= whole + 2, let d = Double(digits.prefix(whole)), let m = Double(digits.dropFirst(whole).prefix(2)) else { return nil }
            let s = Double(digits.dropFirst(whole + 2).prefix(2)) ?? 0
            return (part.hasPrefix("-") ? -1 : 1) * (d + m / 60 + s / 3600)
        }
        guard let latitude = degrees(text[..<split], whole: 2), let longitude = degrees(text[split...], whole: 3) else { return nil }
        return (latitude, longitude)
    }

    /// Sunrise and sunset of the calendar day `day` falls on. Nil where the sun doesn't rise or set that day.
    /// The usual "sunrise equation"; good to about a minute.
    static func times(on day: Date, latitude: Double, longitude: Double) -> (rise: Date, set: Date)? {
        let noon = Calendar.current.startOfDay(for: day).addingTimeInterval(12 * 3600)
        func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }
        // Days since 1 January 2000, 12:00 UTC, counted at the place's own solar noon.
        let n = (noon.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545 + longitude / 360).rounded()
        let meanNoon = n - longitude / 360
        let anomaly = (357.5291 + 0.98560028 * meanNoon).truncatingRemainder(dividingBy: 360)
        let center = 1.9148 * sin(rad(anomaly)) + 0.02 * sin(rad(2 * anomaly)) + 0.0003 * sin(rad(3 * anomaly))
        let lambda = (anomaly + center + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        let transit = 2451545 + meanNoon + 0.0053 * sin(rad(anomaly)) - 0.0069 * sin(rad(2 * lambda))
        let declination = asin(sin(rad(lambda)) * sin(rad(23.44)))
        // -0.833°: the sun's upper edge on the horizon, with refraction.
        let cosHour = (sin(rad(-0.833)) - sin(rad(latitude)) * sin(declination)) / (cos(rad(latitude)) * cos(declination))
        guard abs(cosHour) <= 1 else { return nil }
        let half = acos(cosHour) / (2 * .pi)
        func date(_ julian: Double) -> Date { Date(timeIntervalSince1970: (julian - 2440587.5) * 86400) }
        return (date(transit - half), date(transit + half))
    }
}

/// Switches everything on at sunset and off at sunrise. It acts once, at the moment itself, and
/// never holds the lights in that state: switch them by hand whenever you like, and they stay as
/// you left them until the next sunrise or sunset.
final class SunSchedule: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            // Starts from now: switching this on never acts on a sunset that has already passed.
            handled = Date()
            check()
        }
    }
    /// The next thing it will do, for showing to the user.
    @Published private(set) var next: (isSunrise: Bool, date: Date)?

    private static let enabledKey = "sunSchedule"
    private static let handledKey = "sunScheduleHandled"
    /// A sunrise or sunset noticed later than this (the Mac was asleep, the app wasn't running) is skipped.
    private static let lateness: TimeInterval = 4 * 3600

    private let store: LightStore
    private var timer: Timer?
    private var handled: Date {
        didSet { UserDefaults.standard.set(handled, forKey: Self.handledKey) }
    }

    init(store: LightStore) {
        self.store = store
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        handled = defaults.object(forKey: Self.handledKey) as? Date ?? Date()
        if defaults.object(forKey: Self.handledKey) == nil { defaults.set(handled, forKey: Self.handledKey) }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // The lights need a moment to be found after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check() }
    }

    /// What the menus say about it, e.g. "Off at sunrise, 05:52".
    var nextSummary: String? {
        guard enabled, let next else { return nil }
        return "\(next.isSunrise ? "Off at sunrise" : "On at sunset"), \(next.date.formatted(date: .omitted, time: .shortened))"
    }

    private func check() {
        guard enabled, let place = Sun.coordinates() else {
            if next != nil { next = nil }
            return
        }
        let now = Date()
        var events: [(isSunrise: Bool, date: Date)] = []
        for offset in [-1.0, 0, 1] {
            guard let times = Sun.times(on: now.addingTimeInterval(offset * 86400), latitude: place.latitude, longitude: place.longitude) else { continue }
            events += [(true, times.rise), (false, times.set)]
        }
        events.sort { $0.date < $1.date }
        let upcoming = events.first { $0.date > now }
        if upcoming?.date != next?.date { next = upcoming }

        guard let last = events.last(where: { $0.date <= now }), last.date > handled else { return }
        if now.timeIntervalSince(last.date) > Self.lateness {
            handled = last.date
        } else if !store.onlineLights.isEmpty {
            // No lights yet (just launched, Wi-Fi coming back): try again on the next tick.
            Trace.log("== \(last.isSunrise ? "sunrise: everything off" : "sunset: everything on")")
            store.setAll(on: !last.isSunrise)
            handled = last.date
        }
    }
}
