import SwiftUI

// Note: no view-local @State anywhere in this file — the @State macro plugin ships only with full
// Xcode, and this project must build with the Command Line Tools alone. Transient UI state lives in LightStore.

struct RoomView: View {
    @EnvironmentObject private var store: LightStore
    @EnvironmentObject private var sun: SunSchedule
    @EnvironmentObject private var beat: BeatListener

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                if store.lights.isEmpty {
                    emptyState
                } else {
                    presets
                    if store.onlineLights.filter(\.supportsColor).count > 1 { pairScenes }
                    // The show's settings sit by the scene they belong to, while it is on.
                    if store.lights.contains(where: { $0.mode == .flow(id: LightFlow.music.id) }) { music }
                    ForEach(store.lights) { light in
                        LightCard(light: light)
                    }
                    automation
                    Text("Missing a light? Switch it on at the wall and it will show up here by itself.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.top, 4)
                }
            }
            .padding(16)
            .fontDesign(.rounded)
        }
        .background {
            AmbientBackground(glows: store.onlineLights.filter(\.isOn).map { AmbientGlow(color: $0.tint, strength: $0.ambientStrength) })
                .ignoresSafeArea()
        }
        .containerBackground(.thickMaterial, for: .window)
        .alert("Light name", isPresented: Binding(
            get: { store.renamingMac != nil },
            set: { if !$0 { store.renamingMac = nil } }
        )) {
            TextField("Name", text: $store.renameDraft)
            Button("Save") { store.commitRename() }
            Button("Cancel", role: .cancel) { store.renamingMac = nil }
        }
    }

    /// The menu-bar panel is all there is of the app while it is out of the Dock.
    private var greeting: String {
        switch Calendar.current.component(.hour, from: store.now) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        case 18..<23: return "Good evening"
        default: return "Good night"
        }
    }

    private var summary: String {
        guard !store.lights.isEmpty else { return store.networkAvailable ? "Looking for your lights…" : "Can't reach the network" }
        let total = store.lights.count
        let online = store.onlineLights
        let on = online.filter(\.isOn).count
        let offline = total - online.count
        guard offline < total else { return total == 1 ? "Your light isn't responding" : "No lights are responding" }
        var text: String
        if on == 0 {
            text = total == 1 ? "Your light is off" : "All lights are off"
        } else if total == 1 {
            text = "Your light is on"
        } else if on == total {
            text = "All \(total) lights are on"
        } else {
            text = "\(on) of \(total) lights are on"
        }
        if offline > 0 { text += " · \(offline) not responding" }
        return text
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button {
                ShortcutsWindow.show()
            } label: {
                Image(systemName: "keyboard")
                    .font(.body.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Keyboard shortcuts")
            .accessibilityLabel("Keyboard shortcuts")

            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Search for lights again")
            .accessibilityLabel("Search for lights again")

            powerButton
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    @ViewBuilder private var powerButton: some View {
        let icon = Image(systemName: "power")
            .font(.body.weight(.bold))
            .frame(width: 24, height: 24)
        if store.anyOn {
            Button {
                store.setAll(on: false)
            } label: {
                icon.foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(Color.primary.opacity(0.92))
            .help("Turn everything off")
            .accessibilityLabel("Turn everything off")
        } else {
            Button {
                store.setAll(on: true)
            } label: {
                icon
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(store.onlineLights.isEmpty)
            .help("Turn everything on")
            .accessibilityLabel("Turn everything on")
        }
    }

    /// Settings that run by themselves. In the window only: the menu-bar panel is for the everyday controls.
    private var automation: some View {
        Toggle(isOn: Binding(get: { sun.enabled }, set: { sun.enabled = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("On at sunset, off at sunrise")
                    .font(.callout.weight(.semibold))
                Text(sun.nextSummary.map { "Next: \($0). Switch the lights by hand whenever you like — they stay as you left them until then." }
                     ?? "The lights change only when you switch them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private var music: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { beat.enabled }, set: { beat.enabled = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spotify scene moves with the beat")
                        .font(.callout.weight(.semibold))
                    Text(beat.problem ?? "While Spotify plays, Smart Room listens to the Mac's sound. The bulb follows the drum, the strip keeps the bars in a colour from the other side of the cover.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            if beat.enabled {
                Picker("Show", selection: Binding(get: { beat.style }, set: { beat.style = $0 })) {
                    ForEach(ShowStyle.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("How strong the show is")
                Text(beat.style.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("Light timing")
                        .font(.caption.weight(.semibold))
                    Text("earlier").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { beat.timing }, set: { beat.timing = ($0 * 100).rounded() / 100 }), in: BeatListener.timingRange)
                        .accessibilityLabel("Light timing against the sound")
                    Text("later").font(.caption2).foregroundStyle(.secondary)
                    Text("\(beat.timing >= 0 ? "+" : "−")\(Int((abs(beat.timing) * 1000).rounded())) ms")
                        .font(.caption.monospacedDigit())
                        .frame(width: 58, alignment: .trailing)
                }
                .help("If the lights seem to move before the sound, slide later; if after, earlier.")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    /// Scenes written for two lights, started on all of them at once at the brightness they have.
    private var pairScenes: some View {
        let active = LightFlow.pairs.first { store.isEverywhere($0) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Scenes for all lights together")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(LightFlow.pairs) { flow in
                    let selected = store.isEverywhere(flow)
                    Button {
                        store.startFlowEverywhere(flow)
                    } label: {
                        ChipLabel(title: flow.name, colors: flow.swatchColors, systemImage: nil, selected: selected)
                    }
                    .buttonStyle(PressableStyle())
                    .help(flow.summary)
                    .accessibilityHint(flow.summary)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            // Says what the chips do, then what the chosen one is doing.
            Text(active?.summary ?? "Each light plays its own colours, moving in step.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
        }
    }

    private var presets: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(RoomPreset.all) { preset in
                    PresetButton(preset: preset, isActive: store.isActive(preset)) {
                        store.apply(preset)
                    }
                    .disabled(store.onlineLights.isEmpty)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: store.networkAvailable ? "lightbulb.slash" : "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(store.networkAvailable ? "No lights found" : "No network access")
                .font(.title3.weight(.semibold))
            Text("Make sure the lights are switched on at the wall and connected to the same Wi‑Fi network as this Mac. If macOS asked about local network access, it has to be allowed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Search Again") { store.refresh() }
                .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }
}

struct PresetButton: View {
    let preset: RoomPreset
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isActive {
                Button(action: action) {
                    label.foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
                .buttonStyle(.glassProminent)
                .tint(Color.primary.opacity(0.92))
            } else {
                Button(action: action) { label }
                    .buttonStyle(.glass)
            }
        }
        .buttonBorderShape(.roundedRectangle(radius: 18))
        .help(preset.summary)
        .accessibilityLabel(preset.name)
        .accessibilityHint(preset.summary)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var label: some View {
        VStack(spacing: 5) {
            Image(systemName: preset.icon)
                .font(.title3)
                .frame(height: 22)
            Text(preset.name)
                .font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

/// Soft glows in the colours the lamps are currently emitting, so the window echoes the room.
struct AmbientGlow: Equatable {
    let color: Color
    let strength: Double
}

struct AmbientBackground: View {
    let glows: [AmbientGlow]

    private static let anchors: [UnitPoint] = [
        UnitPoint(x: 0.15, y: 0.1), UnitPoint(x: 0.95, y: 0.45), UnitPoint(x: 0.2, y: 0.95), UnitPoint(x: 0.85, y: 0.0),
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                ForEach(Array(glows.prefix(Self.anchors.count).enumerated()), id: \.offset) { index, glow in
                    Rectangle()
                        .fill(RadialGradient(
                            colors: [0.5, 0.16, 0.05].map { glow.color.opacity($0 * glow.strength) },
                            center: Self.anchors[index],
                            startRadius: 0,
                            endRadius: max(size.width, size.height) * 1.05
                        ))
                }
            }
        }
        .animation(.smooth(duration: 0.8), value: glows)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct LightCard: View {
    @EnvironmentObject private var store: LightStore
    let light: Light

    /// Lamp hues; the softness bar decides how pastel they come out.
    private static let swatches: [(name: String, r: Int, g: Int, b: Int)] = [
        ("Coral", 255, 45, 30), ("Peach", 255, 115, 0), ("Butter", 255, 200, 0), ("Mint", 0, 255, 130),
        ("Sky", 0, 190, 255), ("Periwinkle", 50, 80, 255), ("Violet", 150, 0, 255), ("Rose", 255, 0, 150),
    ]

    private var online: Bool { store.isOnline(light) }
    private var lit: Bool { online && light.isOn }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleRow
            if lit {
                BrightnessPill(percent: light.dimming, minimum: light.minDimming) { value in
                    if value != light.dimming { store.setDimming(light.mac, value) }
                }
                if light.supportsWhiteTemperature {
                    panelPicker
                    switch store.panel(for: light) {
                    case .white: temperaturePill
                    case .color: colorRow
                    case .scenes: scenesGrid
                    }
                }
            }
        }
        .padding(16)
        .glassEffect(lit ? .regular.tint(light.tint.opacity(0.2)) : .regular, in: .rect(cornerRadius: 26))
        .opacity(online ? 1 : 0.6)
        .animation(.smooth(duration: 0.3), value: lit)
        .animation(.linear(duration: 0.6), value: light.flowColor)
        .animation(.smooth(duration: 0.25), value: store.panel(for: light))
        .contextMenu { actions }
    }

    private var status: String {
        guard online else { return "Not responding" }
        guard light.isOn else { return "Off" }
        let mode = light.modeLabel
        return mode.isEmpty ? "\(light.dimming)%" : "\(light.dimming)% · \(mode)"
    }

    @ViewBuilder private var actions: some View {
        Button("Rename…", systemImage: "pencil") { store.beginRename(light) }
        Button("Blink to Identify", systemImage: "wave.3.right") { store.identify(light.mac) }
            .disabled(!online)
        Divider()
        Button("Remove from List", systemImage: "trash", role: .destructive) { store.forget(light.mac) }
    }

    private var titleRow: some View {
        HStack(spacing: 12) {
            Button {
                store.setPower(light.mac, on: !light.isOn)
            } label: {
                ZStack {
                    Circle()
                        .fill(lit ? AnyShapeStyle(light.tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.1)))
                    Image(systemName: lit ? "lightbulb.fill" : "lightbulb")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(lit ? (light.tintIsLight ? Color.black.opacity(0.75) : Color.white) : Color.secondary)
                }
                .frame(width: 42, height: 42)
                .shadow(color: lit ? light.tint.opacity(0.6) : .clear, radius: 10)
                .contentShape(Circle())
                .hoverHighlight(in: Circle(), scale: 1.06)
            }
            .buttonStyle(PressableStyle())
            .disabled(!online)
            .help(light.isOn ? "Turn off" : "Turn on")
            .accessibilityLabel(light.isOn ? "Turn off \(store.name(for: light))" : "Turn on \(store.name(for: light))")

            VStack(alignment: .leading, spacing: 2) {
                Text(store.name(for: light))
                    .font(.headline)
                    .lineLimit(1)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { store.beginRename(light) }
            .help("\(light.kindLabel) · \(light.ip) — double-click to rename")

            Spacer(minLength: 4)

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions")
            .accessibilityLabel("Actions")

            Toggle("Power", isOn: Binding(
                get: { light.isOn },
                set: { store.setPower(light.mac, on: $0) }
            ))
            .toggleStyle(.switch)
            // The switch glows in the lamp's own colour, darkened a touch so the white knob stays visible.
            .tint(light.tint.mix(with: .black, by: 0.25))
            .labelsHidden()
            .disabled(!online)
        }
    }

    private var panelPicker: some View {
        var options: [(panel: LightPanel, title: String)] = [(.white, "White")]
        if light.supportsColor { options.append((.color, "Color")) }
        if light.supportsScenes {
            options.append((.scenes, "Scenes"))
        } else if light.supportsColor {
            options.append((.scenes, "Flows"))
        }
        return PanelTabs(options: options, selection: store.panel(for: light)) { panel in
            store.showPanel(panel, for: light.mac)
        }
    }

    private var currentScene: Int? {
        if case .scene(let id) = light.mode { return id }
        return nil
    }

    private var currentFlow: String? {
        if case .flow(let id) = light.mode { return id }
        return nil
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    @ViewBuilder private var scenesGrid: some View {
        // Section labels only when there are two sections to tell apart.
        let both = light.supportsColor && light.supportsScenes
        VStack(alignment: .leading, spacing: 8) {
            if light.supportsColor {
                if both { sectionLabel("Soft flows") }
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        // Scenes for two lights are started for the whole room, from the Together row.
                        ForEach(LightFlow.all.filter { !$0.isPair }) { flowChip($0) }
                    }
                }
            }
            if light.supportsScenes {
                if both {
                    sectionLabel("Lamp scenes")
                        .padding(.top, 4)
                }
                builtInScenes
            }
            adjustments
        }
    }

    /// Adjustments for whatever is running sit below the chips, side by side, so the chips never shift.
    @ViewBuilder private var adjustments: some View {
        if currentFlow != nil || store.speed(for: light) != nil {
            HStack(alignment: .bottom, spacing: 12) {
                if currentFlow != nil { softnessPill }
                speedPill
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder private var speedPill: some View {
        if let speed = store.speed(for: light) {
            LabeledBar("Speed", value: String(format: "%g×", Double(speed) / 100)) {
                SpeedPill(percent: speed) { value in
                    if value != speed { store.setSpeed(light.mac, value) }
                }
            }
        }
    }

    private func flowChip(_ flow: LightFlow) -> some View {
        let selected = flow.id == currentFlow
        return Button {
            store.startFlow(light.mac, flow)
        } label: {
            ChipLabel(title: flow.name, colors: flow.swatchColors, systemImage: nil, selected: selected)
        }
        .buttonStyle(PressableStyle())
        .help("\(flow.summary). Runs while Smart Room is open.")
        .accessibilityHint(flow.summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var softnessPill: some View {
        let hue: RGB = {
            if case .color(let r, let g, let b) = light.mode { return RGB(r: r, g: g, b: b) }
            return light.flowColor ?? RGB(r: 150, g: 0, b: 255)
        }()
        return LabeledBar("Softness", value: "\(light.softness)%") {
            SoftnessPill(percent: light.softness, hue: hue) { value in
                if value != light.softness { store.setSoftness(light.mac, value) }
            }
        }
    }

    private var builtInScenes: some View {
        let featured = WizScene.featured
        let other = WizScene.others.first { $0.id == currentScene }
        return Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                ForEach(featured.prefix(4)) { sceneChip($0) }
            }
            GridRow {
                ForEach(featured.dropFirst(4)) { sceneChip($0) }
                Menu {
                    ForEach(WizScene.others) { scene in
                        Button {
                            store.setScene(light.mac, scene.id)
                        } label: {
                            if scene.id == currentScene {
                                Label(scene.name, systemImage: "checkmark")
                            } else {
                                Text(scene.name)
                            }
                        }
                    }
                } label: {
                    ChipLabel(title: other?.name ?? "More", colors: other?.swatchColors, systemImage: "ellipsis", selected: other != nil)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("More scenes")
            }
        }
    }

    private func sceneChip(_ scene: WizScene) -> some View {
        let selected = scene.id == currentScene
        return Button {
            store.setScene(light.mac, scene.id)
        } label: {
            ChipLabel(title: scene.name, colors: scene.swatchColors, systemImage: nil, selected: selected)
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var temperaturePill: some View {
        let kelvin: Int? = {
            if case .white(let value) = light.mode { return value }
            return nil
        }()
        return LabeledBar("Warmth", value: kelvin.map { "\($0)K" } ?? "") {
            TemperaturePill(kelvin: kelvin, range: light.minKelvin...light.maxKelvin) { value in
                if value != kelvin { store.setKelvin(light.mac, value) }
            }
        }
    }

    private var isColorMode: Bool {
        if case .color = light.mode { return true }
        return false
    }

    @ViewBuilder private var colorRow: some View {
        swatchRow
        // Softness adjusts the colour that is showing, so it appears once there is one.
        if isColorMode { softnessPill }
    }

    private var swatchRow: some View {
        HStack(spacing: 0) {
            ForEach(Self.swatches, id: \.name) { swatch in
                let selected = light.mode == .color(r: swatch.r, g: swatch.g, b: swatch.b)
                Button {
                    store.setColor(light.mac, r: swatch.r, g: swatch.g, b: swatch.b)
                } label: {
                    Circle()
                        .fill(RGB(r: swatch.r, g: swatch.g, b: swatch.b).displayColor(softness: store.preferredSoftness(for: light.mac)).gradient)
                        .frame(width: 27, height: 27)
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                        .padding(4)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 2))
                        .contentShape(Circle())
                        .hoverHighlight(in: Circle(), scale: 1.12, wash: 0)
                }
                .buttonStyle(PressableStyle())
                .help(swatch.name)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
                Spacer(minLength: 2)
            }
            ColorPicker("Custom color", selection: Binding(
                get: {
                    if case .color(let r, let g, let b) = light.mode {
                        return RGB(r: r, g: g, b: b).displayColor(softness: light.softness)
                    }
                    return .white
                },
                set: { color in
                    if let picked = color.lampComponents {
                        store.setColor(light.mac, r: picked.hue.r, g: picked.hue.g, b: picked.hue.b, softness: picked.softness)
                    }
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .help("Custom color")
        }
    }
}

/// Full-width capsule tabs. Deliberately quieter than the brightness bar so the card keeps one focal point.
struct PanelTabs: View {
    let options: [(panel: LightPanel, title: String)]
    let selection: LightPanel
    let onSelect: (LightPanel) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.panel) { option in
                let selected = option.panel == selection
                Button {
                    onSelect(option.panel)
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(Color.primary.opacity(selected ? 0.16 : 0), in: Capsule())
                        .contentShape(Capsule())
                        .hoverHighlight(in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .animation(.snappy(duration: 0.2), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Light mode")
    }
}

/// Capsule used for scene chips: a colour dot (or a symbol) and a short name.
struct ChipLabel: View {
    let title: String
    let colors: [Color]?
    let systemImage: String?
    let selected: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let colors {
                Circle()
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
            }
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 28)
        .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : Color.primary)
        .background(Color.primary.opacity(selected ? 0.92 : 0.1), in: Capsule())
        .contentShape(Capsule())
        .hoverHighlight(in: Capsule())
    }
}

/// Control Center–style brightness bar: the whole capsule is the control.
struct BrightnessPill: View {
    let percent: Int
    /// Lowest brightness the light accepts.
    let minimum: Int
    let onChange: (Int) -> Void

    private let height: CGFloat = 32

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                Rectangle()
                    .fill(Color.primary.opacity(0.92))
                    .frame(width: max(height, width * CGFloat(percent) / 100))
                HStack {
                    Image(systemName: percent > 55 ? "sun.max.fill" : "sun.min.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: height)
                    Spacer()
                    Text("\(percent)%")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(percent > 82 ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                        .padding(.trailing, 14)
                }
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                let fraction = min(max(gesture.location.x / max(width, 1), 0), 1)
                onChange(min(max(Int((fraction * 100).rounded()), minimum), 100))
            })
        }
        .frame(height: height)
        .animation(.snappy(duration: 0.15), value: percent)
        .help("Brightness")
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(percent) }, set: { onChange(Int($0.rounded())) }), in: Double(minimum)...100) {
                Text("Brightness")
            }
        }
    }
}

/// A capsule track showing a gradient with a round thumb; reports the dragged position as 0...1.
struct GradientPill: View {
    let colors: [Color]
    /// Thumb position, or nil to hide the thumb.
    let fraction: Double?
    let leadingIcon: String
    let trailingIcon: String
    var iconColor = Color.black.opacity(0.45)
    let onChange: (Double) -> Void

    private let height: CGFloat = 32

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let thumb = height - 8
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                HStack {
                    Image(systemName: leadingIcon)
                    Spacer()
                    Image(systemName: trailingIcon)
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(iconColor)
                .padding(.horizontal, 13)
                if let fraction {
                    Circle()
                        .fill(.white)
                        .frame(width: thumb, height: thumb)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: 4 + CGFloat(min(max(fraction, 0), 1)) * (width - thumb - 8))
                }
            }
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                let usable = max(width - thumb - 8, 1)
                onChange(Double(min(max((gesture.location.x - 4 - thumb / 2) / usable, 0), 1)))
            })
        }
        .frame(height: height)
        .animation(.snappy(duration: 0.15), value: fraction)
    }
}

/// Warm-to-cool white bar. The thumb is shown only while the lamp is actually in white mode.
struct TemperaturePill: View {
    let kelvin: Int?
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    private var span: Double { Double(max(range.upperBound - range.lowerBound, 1)) }

    private func snapped(_ fraction: Double) -> Int {
        Int(((Double(range.lowerBound) + fraction * span) / 100).rounded()) * 100
    }

    var body: some View {
        let steps = 6
        GradientPill(
            colors: (0...steps).map { Color.kelvin(range.lowerBound + (range.upperBound - range.lowerBound) * $0 / steps) },
            fraction: kelvin.map { Double(min(max($0, range.lowerBound), range.upperBound) - range.lowerBound) / span },
            leadingIcon: "flame.fill",
            trailingIcon: "snowflake"
        ) { onChange(snapped($0)) }
        .help("White temperature: warm to cool")
        .accessibilityRepresentation {
            Slider(
                value: Binding(get: { Double(kelvin ?? range.lowerBound) }, set: { onChange(Int(($0 / 100).rounded()) * 100) }),
                in: Double(range.lowerBound)...Double(range.upperBound)
            ) {
                Text("White temperature")
            }
        }
    }
}

/// Vivid-to-pastel bar for the colour the lamp is showing.
struct SoftnessPill: View {
    let percent: Int
    let hue: RGB
    let onChange: (Int) -> Void

    var body: some View {
        GradientPill(
            colors: [0, 50, 100].map { hue.displayColor(softness: $0) },
            fraction: Double(percent) / 100,
            leadingIcon: "drop.fill",
            trailingIcon: "cloud.fill"
        ) { onChange(Int(($0 * 100).rounded())) }
        .help("Softness: vivid to pastel")
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(percent) }, set: { onChange(Int($0.rounded())) }), in: 0...100) {
                Text("Softness")
            }
        }
    }
}

/// Slow-to-fast bar for a flow or an animated lamp scene. Speed is a percentage of normal.
struct SpeedPill: View {
    let percent: Int
    let onChange: (Int) -> Void

    private static let range = LightFlow.speedRange
    private static var span: Double { Double(range.upperBound - range.lowerBound) }

    var body: some View {
        GradientPill(
            colors: [Color.primary.opacity(0.1), Color.primary.opacity(0.1)],
            fraction: Double(percent - Self.range.lowerBound) / Self.span,
            leadingIcon: "tortoise.fill",
            trailingIcon: "hare.fill",
            iconColor: .secondary
        ) { fraction in
            let value = Double(Self.range.lowerBound) + fraction * Self.span
            onChange(Int((value / 10).rounded()) * 10)
        }
        .help("Speed: \(percent)% of normal")
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(percent) }, set: { onChange(Int($0.rounded())) }),
                   in: Double(Self.range.lowerBound)...Double(Self.range.upperBound)) {
                Text("Speed")
            }
        }
    }
}

/// A caption row (name on the left, current value on the right) above a bar control.
struct LabeledBar<Content: View>: View {
    let title: String
    let value: String
    let content: Content

    init(_ title: String, value: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.value = value
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .fontWeight(.semibold)
                Spacer()
                Text(value)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            content
        }
    }
}

/// Gives custom controls a soft "press" so they feel touchable.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// View-local hover flag. An ObservableObject rather than @State: see the note at the top of this file.
final class HoverState: ObservableObject {
    @Published var isHovered = false
}

/// Lights a control up slightly under the pointer, so it is obvious what can be clicked.
struct HoverHighlight<S: Shape>: ViewModifier {
    @StateObject private var hover = HoverState()
    let shape: S
    let scale: CGFloat
    let wash: Double

    func body(content: Content) -> some View {
        content
            .overlay(shape.fill(Color.primary.opacity(hover.isHovered ? wash : 0)).allowsHitTesting(false))
            .scaleEffect(hover.isHovered ? scale : 1)
            .onHover { hover.isHovered = $0 }
            .animation(.snappy(duration: 0.15), value: hover.isHovered)
    }
}

extension View {
    func hoverHighlight<S: Shape>(in shape: S, scale: CGFloat = 1, wash: Double = 0.08) -> some View {
        modifier(HoverHighlight(shape: shape, scale: scale, wash: wash))
    }
}
