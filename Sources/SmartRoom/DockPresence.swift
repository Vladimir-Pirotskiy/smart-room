import AppKit

/// The app lives in the menu bar and is in the Dock only while its window is open.
/// Closing the window — or quitting while the window is open (⌘Q, Quit in the Dock menu) — takes it
/// out of the Dock and leaves the menu-bar item running; quitting again, or "Quit Smart Room" in
/// the menu-bar item's right-click menu, really quits.
final class DockPresence: NSObject, NSApplicationDelegate {
    /// The scene id of the main window; SwiftUI builds the window's identifier from it.
    static let windowID = "main"

    /// What the menu-bar item shows and controls; set by the app before it finishes launching.
    static var model: (store: LightStore, keyboard: KeyboardControl)?

    private static var quittingForReal = false
    private var statusItem: StatusItemController?

    static func quit() {
        quittingForReal = true
        NSApp.terminate(nil)
    }

    /// Shows the main window and brings the app back into the Dock.
    static func openWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindows.first(where: \.isVisible) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // The window is SwiftUI's to create; opening the app again is what makes it do so.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func isMainWindow(_ object: Any?) -> Bool {
        (object as? NSWindow)?.identifier?.rawValue.hasPrefix(windowID) ?? false
    }

    private static var mainWindows: [NSWindow] { NSApp.windows.filter { isMainWindow($0) } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let model = Self.model { statusItem = StatusItemController(store: model.store, keyboard: model.keyboard) }
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard Self.isMainWindow(note.object) else { return }
            NSApp.setActivationPolicy(.accessory)
        }
        // However the window comes back (the menu-bar panel, opening the app again), the Dock icon comes with it.
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard Self.isMainWindow(note.object), NSApp.activationPolicy() != .regular else { return }
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Logging out, restarting or shutting down: never stand in the way.
        let systemAsked = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason) != nil
        guard !Self.quittingForReal, !systemAsked, NSApp.activationPolicy() == .regular else { return .terminateNow }
        Self.mainWindows.forEach { $0.close() }
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }
}
