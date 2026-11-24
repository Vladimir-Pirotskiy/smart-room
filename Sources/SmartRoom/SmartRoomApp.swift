import Carbon.HIToolbox
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--sun") {
            // Today's sunrise and sunset as the app works them out, for checking against an almanac.
            guard let place = Sun.coordinates(), let times = Sun.times(on: Date(), latitude: place.latitude, longitude: place.longitude) else {
                print("No sunrise or sunset: the place is unknown, or the sun doesn't rise or set there today.")
                return
            }
            print("time zone \(TimeZone.current.identifier): sunrise \(times.rise.formatted(date: .omitted, time: .shortened)), sunset \(times.set.formatted(date: .omitted, time: .shortened))")
        } else if let index = CommandLine.arguments.firstIndex(of: "--cover"), index + 1 < CommandLine.arguments.count {
            // The lamp colours the Spotify scene would take from a picture, for checking by eye.
            let hues = (try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))).flatMap(CoverPalette.hues)
            print(hues.map { $0.map { "(\($0.r),\($0.g),\($0.b)) hue \(Int($0.hsb.h * 360))" }.joined(separator: "  ") } ?? "no colour in it: the plain warm palette is used")
        } else if CommandLine.arguments.contains("--scan") {
            CommandLineScan.run()
        } else {
            SmartRoomApp.main()
        }
    }
}

struct SmartRoomApp: App {
    @NSApplicationDelegateAdaptor(DockPresence.self) private var dockPresence
    @StateObject private var store: LightStore
    @StateObject private var keyboard: KeyboardControl
    @StateObject private var sun: SunSchedule
    private let spotify: SpotifyLink
    @StateObject private var beat: BeatListener

    /// ⌃⌥⌘ plus a key. The same combinations are shown next to the items of the Lights menu.
    private static let globalModifiers: SwiftUI.EventModifiers = [.control, .option, .command]

    init() {
        let store = LightStore()
        _store = StateObject(wrappedValue: store)
        let keyboard = KeyboardControl(store: store)
        _keyboard = StateObject(wrappedValue: keyboard)
        let sun = SunSchedule(store: store)
        _sun = StateObject(wrappedValue: sun)
        spotify = SpotifyLink(store: store)
        _beat = StateObject(wrappedValue: BeatListener(store: store))
        // The menu-bar item is AppKit's; the app delegate creates it once the app has launched.
        DockPresence.model = (store, keyboard)
    }

    /// Menu title, with a note when another app already owns the global shortcut.
    private func title(_ text: String, _ id: String) -> String {
        keyboard.unavailable.contains(id) ? "\(text) (shortcut taken by another app)" : text
    }

    var body: some Scene {
        Window("Smart Room", id: DockPresence.windowID) {
            RoomView()
                .environmentObject(store)
                .environmentObject(sun)
                .environmentObject(beat)
                .frame(minWidth: 400, idealWidth: 420, minHeight: 360, idealHeight: 560)
        }
        .defaultSize(width: 420, height: 680)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Everything the window's buttons do, reachable from the keyboard and discoverable in the menu bar.
            CommandMenu("Lights") {
                // Everything in this menu except the search works from any app: the system delivers the keys to GlobalHotKeys, and the
                // shortcuts shown here are the same combinations, so the menu doubles as the cheat sheet.
                Button(title(store.anyOn ? "Turn Everything Off" : "Turn Everything On", "toggle")) { store.toggleAll() }
                    .keyboardShortcut("l", modifiers: Self.globalModifiers)
                Button(title("Brighter", "brighter")) { store.nudgeBrightness(10) }
                    .keyboardShortcut("=", modifiers: Self.globalModifiers)
                Button(title("Dimmer", "dimmer")) { store.nudgeBrightness(-10) }
                    .keyboardShortcut("-", modifiers: Self.globalModifiers)
                Button(title("Next Mood", "next")) { store.cyclePreset(1) }
                    .keyboardShortcut("]", modifiers: Self.globalModifiers)
                Button(title("Previous Mood", "previous")) { store.cyclePreset(-1) }
                    .keyboardShortcut("[", modifiers: Self.globalModifiers)
                Divider()
                ForEach(Array(RoomPreset.all.enumerated()), id: \.element.id) { index, preset in
                    Button(title(preset.name, preset.id)) { store.apply(preset) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: Self.globalModifiers)
                }
                ForEach(Array(RoomPreset.extraFlows.enumerated()), id: \.element.id) { index, flow in
                    let number = RoomPreset.all.count + index + 1
                    // Only nine number keys: flows past them are in the menu without a shortcut.
                    if number <= 9 {
                        Button(title("\(flow.name) Flow", "flow-\(flow.id)")) { store.startFlowEverywhere(flow) }
                            .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: Self.globalModifiers)
                    } else {
                        Button("\(flow.name) Flow") { store.startFlowEverywhere(flow) }
                    }
                }
                Divider()
                // The Clear key does the same from any app; the menu bar icon shows which mode is on.
                Toggle(title("Number Pad Controls Lights (Clear)", "numpad-mode"),
                       isOn: Binding(get: { keyboard.numpadMode }, set: { keyboard.setNumpadMode($0) }))
                    .keyboardShortcut("0", modifiers: Self.globalModifiers)
                Toggle("On at Sunset, Off at Sunrise", isOn: Binding(get: { sun.enabled }, set: { sun.enabled = $0 }))
                if let next = sun.nextSummary { Text("Next: \(next)") }
                Divider()
                Button("Keyboard Shortcuts…") { ShortcutsWindow.show() }
                Button("Search for Lights") { store.refresh() }
                    .keyboardShortcut("r")
            }
        }
    }
}

/// `SmartRoom --scan [--dim N] [--preset ID]` — finds lights from the terminal using the same code path as the app.
enum CommandLineScan {
    static func run() {
        let store = LightStore()
        spin(3)
        report(store, title: "Lights found: \(store.lights.count)")

        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--preset"), index + 1 < arguments.count,
           let preset = RoomPreset.all.first(where: { $0.id == arguments[index + 1] }) {
            store.apply(preset)
            spin(8)
            report(store, title: "After preset \(preset.name) (active: \(store.isActive(preset))):")
        }
        if let index = arguments.firstIndex(of: "--dim"), index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
            for light in store.onlineLights {
                store.setDimming(light.mac, value)
            }
            spin(3)
            store.refresh()
            spin(2)
            report(store, title: "After setting brightness to \(value)%:")
        }
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func report(_ store: LightStore, title: String) {
        print(title)
        for light in store.lights {
            print("  \(store.name(for: light))  mac=\(light.mac)  ip=\(light.ip)  module=\(light.module ?? "?")"
                + "  online=\(store.isOnline(light))  on=\(light.isOn)  dim=\(light.dimming)  mode=\(light.mode)"
                + "  cct=\(light.minKelvin)-\(light.maxKelvin)")
        }
    }
}
