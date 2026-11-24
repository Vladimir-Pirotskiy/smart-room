import AppKit
import Combine
import SwiftUI

/// The menu-bar item. A click opens a small panel with the controls for the room as a whole;
/// a right-click (or Control-click) opens a plain menu with the same moods and the app's own commands.
/// Built on NSStatusItem because a SwiftUI MenuBarExtra can't tell the two clicks apart.
final class StatusItemController: NSObject {
    private let store: LightStore
    private let keyboard: KeyboardControl
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var watchers: Set<AnyCancellable> = []
    private var shownIcon: String?

    init(store: LightStore, keyboard: KeyboardControl) {
        self.store = store
        self.keyboard = keyboard
        super.init()

        popover.behavior = .transient
        let panel = CompactView(openWindow: { [weak self] in
            self?.popover.performClose(nil)
            DockPresence.openWindow()
        })
        let host = NSHostingController(rootView: panel.environmentObject(store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Smart Room — right-click for more"
        }
        store.objectWillChange.merge(with: keyboard.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &watchers)
        refreshIcon()
    }

    private func refreshIcon() {
        let lit = store.anyOn, numpad = keyboard.numpadMode
        let key = "\(lit)-\(numpad)"
        guard key != shownIcon else { return }
        shownIcon = key
        item.button?.image = MenuBarIcon.image(lit: lit, numpad: numpad)
        item.button?.setAccessibilityLabel(numpad ? "Smart Room, number pad controls the lights" : "Smart Room")
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            // Active, so that a click anywhere else closes the panel.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        popover.performClose(nil)
        // Attached only for this one click: a status item with a menu would show it on every click.
        item.menu = menu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func menu() -> NSMenu {
        let store = store, keyboard = keyboard
        let hasLights = !store.onlineLights.isEmpty
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(ActionItem(store.anyOn ? "Turn Everything Off" : "Turn Everything On", enabled: hasLights) { store.toggleAll() })
        menu.addItem(ActionItem("Brighter", enabled: store.anyOn) { store.nudgeBrightness(10) })
        menu.addItem(ActionItem("Dimmer", enabled: store.anyOn) { store.nudgeBrightness(-10) })
        menu.addItem(.separator())

        for preset in RoomPreset.all {
            menu.addItem(ActionItem(preset.name, checked: store.isActive(preset), enabled: hasLights) { store.apply(preset) })
        }
        let scenes = NSMenu()
        scenes.autoenablesItems = false
        for flow in LightFlow.pairs + LightFlow.all.filter({ !$0.isPair }) {
            if flow.id == LightFlow.all.first(where: { !$0.isPair })?.id { scenes.addItem(.separator()) }
            scenes.addItem(ActionItem(flow.name, checked: store.isEverywhere(flow), enabled: hasLights) { store.startFlowEverywhere(flow) })
        }
        let scenesItem = NSMenuItem(title: "Scenes", action: nil, keyEquivalent: "")
        scenesItem.submenu = scenes
        menu.addItem(scenesItem)
        menu.addItem(.separator())

        menu.addItem(ActionItem("Number Pad Controls Lights", checked: keyboard.numpadMode) { keyboard.toggleNumpadMode() })
        menu.addItem(ActionItem("Keyboard Shortcuts…") { ShortcutsWindow.show() })
        menu.addItem(ActionItem("Search for Lights") { store.refresh() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Open Smart Room") { DockPresence.openWindow() })
        menu.addItem(ActionItem("Quit Smart Room") { DockPresence.quit() })
        return menu
    }
}

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}
