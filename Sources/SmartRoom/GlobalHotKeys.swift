import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts: they work while any app is in front, and in any keyboard layout
/// (they are bound to physical keys). Built on Carbon hot keys, the one API for this that needs no
/// Accessibility permission. Shortcuts are registered in named groups so a set of keys can be
/// switched on and off together.
final class GlobalHotKeys {
    struct Shortcut {
        let id: String
        /// Virtual key code (kVK_…).
        let keyCode: Int
        /// Carbon modifier mask; 0 claims the bare key for as long as the shortcut is registered.
        var modifiers: UInt32 = GlobalHotKeys.chord
        let action: () -> Void
    }

    /// Control-Option-Command, the modifiers of every shortcut that is always on.
    static let chord = UInt32(controlKey | optionKey | cmdKey)
    private static let signature: OSType = 0x534D_524D // "SMRM"
    private static let trace = ProcessInfo.processInfo.environment["SMARTROOM_TRACE"] != nil

    /// Shortcuts macOS refused to register — normally because another app already owns the combination.
    private(set) var unavailable: Set<String> = []
    private var shortcuts: [UInt32: Shortcut] = [:]
    private var groups: [String: [(id: UInt32, ref: EventHotKeyRef)]] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == GlobalHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue().fire(hotKey.id)
            return noErr
        }
        InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        groups.values.joined().forEach { UnregisterEventHotKey($0.ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ list: [Shortcut], group: String) {
        for shortcut in list {
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.modifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                shortcuts[id] = shortcut
                groups[group, default: []].append((id, ref))
                unavailable.remove(shortcut.id)
            } else {
                unavailable.insert(shortcut.id)
            }
            if Self.trace { FileHandle.standardError.write(Data("hotkey \(shortcut.id) register status \(status)\n".utf8)) }
        }
    }

    func unregister(group: String) {
        for entry in groups.removeValue(forKey: group) ?? [] {
            UnregisterEventHotKey(entry.ref)
            shortcuts[entry.id] = nil
        }
        if Self.trace { FileHandle.standardError.write(Data("hotkey group \(group) unregistered\n".utf8)) }
    }

    private func fire(_ id: UInt32) {
        guard let shortcut = shortcuts[id] else { return }
        if Self.trace { FileHandle.standardError.write(Data("hotkey \(shortcut.id) fired\n".utf8)) }
        shortcut.action()
    }
}
