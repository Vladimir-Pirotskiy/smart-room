import AppKit
import Carbon.HIToolbox

/// Everything the keyboard can do to the lights from outside the app.
///
/// Two layers: the ⌃⌥⌘ shortcuts, which are always on, and the number pad, which the Clear key
/// switches between typing digits and controlling the lights. The pad keys are only claimed while
/// that mode is on, so the pad types normally the rest of the time — and whenever the app isn't running.
final class KeyboardControl: ObservableObject {
    /// True while the number pad controls the lights instead of typing.
    @Published private(set) var numpadMode = false

    private let hotKeys = GlobalHotKeys()
    private let store: LightStore
    private static let numpadGroup = "numpad"

    /// Shortcuts another app already owns.
    var unavailable: Set<String> { hotKeys.unavailable }

    init(store: LightStore) {
        self.store = store
        // Physical number keys in keyboard order (their key codes are not consecutive):
        // the presets take 1, 2, 3… and the flows no preset starts continue from there.
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        hotKeys.register(moods(on: digits, bare: false) + [
            .init(id: "toggle", keyCode: kVK_ANSI_L) { store.toggleAll() },
            .init(id: "brighter", keyCode: kVK_ANSI_Equal) { store.nudgeBrightness(10) },
            .init(id: "dimmer", keyCode: kVK_ANSI_Minus) { store.nudgeBrightness(-10) },
            .init(id: "next", keyCode: kVK_ANSI_RightBracket) { store.cyclePreset(1) },
            .init(id: "previous", keyCode: kVK_ANSI_LeftBracket) { store.cyclePreset(-1) },
            // The number pad mode has two triggers. ⌃⌥⌘0 is the dependable one: a key remapper (Karabiner) sends it
            // when Clear is pressed. The bare Clear key is the fallback for a keyboard nothing remaps; macOS treats
            // that key as Num Lock and does not deliver every press of it as a hot key.
            .init(id: "numpad-mode", keyCode: kVK_ANSI_0) { [weak self] in self?.toggleNumpadMode() },
            .init(id: "numpad-mode-clear", keyCode: kVK_ANSI_KeypadClear, modifiers: 0) { [weak self] in self?.toggleNumpadMode() },
        ], group: "always")
    }

    func toggleNumpadMode() {
        setNumpadMode(!numpadMode)
    }

    func setNumpadMode(_ on: Bool) {
        guard on != numpadMode else { return }
        numpadMode = on
        if on {
            hotKeys.register(numpadShortcuts, group: Self.numpadGroup)
        } else {
            hotKeys.unregister(group: Self.numpadGroup)
        }
    }

    /// Presets, then the remaining flows, on consecutive keys.
    private func moods(on keys: [Int], bare: Bool) -> [GlobalHotKeys.Shortcut] {
        let store = store
        let modifiers = bare ? 0 : GlobalHotKeys.chord
        let prefix = bare ? "pad-" : ""
        let presets = zip(RoomPreset.all, keys).map { preset, key in
            GlobalHotKeys.Shortcut(id: prefix + preset.id, keyCode: key, modifiers: modifiers) { store.apply(preset) }
        }
        let flows = zip(RoomPreset.extraFlows, keys.dropFirst(RoomPreset.all.count)).map { flow, key in
            GlobalHotKeys.Shortcut(id: "\(prefix)flow-\(flow.id)", keyCode: key, modifiers: modifiers) { store.startFlowEverywhere(flow) }
        }
        return presets + flows
    }

    private var numpadShortcuts: [GlobalHotKeys.Shortcut] {
        let store = store
        let digits = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                      kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        return moods(on: digits, bare: true) + [
            .init(id: "pad-toggle", keyCode: kVK_ANSI_Keypad0, modifiers: 0) { store.toggleAll() },
            .init(id: "pad-brighter", keyCode: kVK_ANSI_KeypadPlus, modifiers: 0) { store.nudgeBrightness(10) },
            .init(id: "pad-dimmer", keyCode: kVK_ANSI_KeypadMinus, modifiers: 0) { store.nudgeBrightness(-10) },
            .init(id: "pad-next", keyCode: kVK_ANSI_KeypadMultiply, modifiers: 0) { store.cyclePreset(1) },
            .init(id: "pad-previous", keyCode: kVK_ANSI_KeypadDivide, modifiers: 0) { store.cyclePreset(-1) },
            // The two keys with no job are claimed too, so nothing gets typed by accident in this mode. Enter stays Enter.
            .init(id: "pad-decimal", keyCode: kVK_ANSI_KeypadDecimal, modifiers: 0) {},
            .init(id: "pad-equals", keyCode: kVK_ANSI_KeypadEquals, modifiers: 0) {},
        ]
    }
}
