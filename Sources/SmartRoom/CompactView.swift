import SwiftUI

/// The small panel under the menu-bar item: the room as one thing. On/off, one brightness for
/// everything that is lit, the moods and the scenes. Anything per light is in the window.
struct CompactView: View {
    @EnvironmentObject private var store: LightStore
    let openWindow: () -> Void

    private var activeMood: String? {
        RoomPreset.all.first { store.isActive($0) }?.name ?? (LightFlow.all + [LightFlow.music]).first { store.isEverywhere($0) }?.name
    }

    private var status: String {
        let online = store.onlineLights, lit = online.filter(\.isOn).count
        if online.isEmpty { return "No lights found" }
        if lit == 0 { return "Everything is off" }
        let count = lit == online.count ? (lit == 1 ? "1 light on" : "All \(lit) lights on") : "\(lit) of \(online.count) lights on"
        return activeMood.map { "\($0) · \(count)" } ?? count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Smart Room")
                        .font(.headline)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    store.toggleAll()
                } label: {
                    Image(systemName: "power")
                        .font(.body.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(store.onlineLights.isEmpty)
                .help(store.anyOn ? "Turn everything off" : "Turn everything on")
                .accessibilityLabel(store.anyOn ? "Turn everything off" : "Turn everything on")
            }

            if !store.onlineLights.isEmpty {
                BrightnessPill(percent: store.roomBrightness, minimum: 1) { store.setRoomBrightness($0) }
                    .disabled(!store.anyOn)
                    .opacity(store.anyOn ? 1 : 0.4)
                    .help("Brightness of everything that is on")

                grid(columns: 3) {
                    ForEach(RoomPreset.all) { preset in
                        chip(preset.name, colors: nil, icon: preset.icon, selected: store.isActive(preset), hint: preset.summary) {
                            store.apply(preset)
                        }
                    }
                }

                if store.onlineLights.contains(where: \.supportsColor) {
                    grid(columns: 4) {
                        ForEach(LightFlow.pairs) { flow in
                            chip(flow.name, colors: flow.swatchColors, icon: nil, selected: store.isEverywhere(flow), hint: flow.summary) {
                                store.startFlowEverywhere(flow)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Open Smart Room", systemImage: "macwindow", action: openWindow)
                    .help("Each light on its own: colour, white, scenes, softness and speed")
                Button("Shortcuts", systemImage: "keyboard") { ShortcutsWindow.show() }
                    .help("The list of keyboard shortcuts")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        }
        .padding(14)
        .frame(width: 360)
        .fontDesign(.rounded)
    }

    private func grid(columns: Int, @ViewBuilder content: () -> some View) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6, content: content)
    }

    private func chip(_ title: String, colors: [Color]?, icon: String?, selected: Bool, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ChipLabel(title: title, colors: colors, systemImage: icon, selected: selected)
        }
        .buttonStyle(PressableStyle())
        .help(hint)
        .accessibilityHint(hint)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
