import AppKit
import SwiftUI

/// The list of everything the keyboard does, built from the same presets and scenes the shortcuts
/// themselves are, so the two can't drift apart. It shows the keys the user presses; the ⌃⌥⌘
/// combinations behind them (what the Karabiner rule sends) are left out at the user's request.
struct ShortcutsView: View {
    private struct Row: Identifiable {
        let id: String
        /// The function key that does the same (through the Karabiner rule).
        var functionKey = ""
        /// The number-pad key, while the pad controls the lights.
        var pad = ""
    }

    private var rows: [Row] {
        var rows = [
            Row(id: "Lights on / off", functionKey: "F13", pad: "0"),
            Row(id: "Dimmer", functionKey: "F14", pad: "−"),
            Row(id: "Brighter", functionKey: "F15", pad: "+"),
            Row(id: "Previous mood", functionKey: "F16", pad: "/"),
            Row(id: "Next mood", functionKey: "F17", pad: "*"),
        ]
        // The function keys the Karabiner rule gives to single presets.
        let functionKeys = ["day": "F18", "dream": "F19"]
        let moods = RoomPreset.all.map { (name: $0.name, key: functionKeys[$0.id] ?? "") } + RoomPreset.extraFlows.map { (name: $0.name, key: "") }
        for (index, mood) in moods.prefix(9).enumerated() {
            rows.append(Row(id: mood.name, functionKey: mood.key, pad: "\(index + 1)"))
        }
        rows.append(Row(id: "Number pad: digits ↔ lights", functionKey: "Clear", pad: "Clear"))
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Key")
                    Text("Number pad")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider()
                ForEach(rows) { row in
                    GridRow {
                        Text(row.id)
                        Text(row.functionKey).monospaced()
                        Text(row.pad).monospaced()
                    }
                    .font(.callout)
                }
            }
            Text("The keys work from any app while Smart Room is running. Next and previous mood step through Day … Dream and then the scenes, round and round; scenes past Ruby have no key of their own. The number-pad column applies after Clear has switched the pad to the lights — the menu bar icon turns into a key cap; press Clear again to type digits. F13–F19 and Clear come from the Karabiner rule.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 340)
        .fontDesign(.rounded)
    }
}

/// The shortcut list in a small floating window, so it can stay beside whatever you are doing.
enum ShortcutsWindow {
    private static var panel: NSPanel?

    static func show() {
        if panel == nil {
            let panel = NSPanel(contentViewController: NSHostingController(rootView: ShortcutsView()))
            panel.styleMask = [.titled, .closable]
            panel.title = "Smart Room — Keyboard Shortcuts"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.center()
            self.panel = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }
}
