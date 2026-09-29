import SwiftUI

/// UserDefaults keys. Views read them with @AppStorage, so changes apply live.
enum SettingKey {
    static let artworkStyle = "artworkStyle"
    static let translucency = "translucency"
    static let visualizer = "visualizerStyle"
    static let visualizerColor = "visualizerColor"
    static let spinSpeed = "spinSpeed"
    static let layout = "layout"
}

enum PlayerLayout: String, CaseIterable, Identifiable {
    case compact, stacked
    var id: Self { self }
    var label: String {
        switch self {
        case .compact: "Art beside controls"
        case .stacked: "Art above controls"
        }
    }
}

enum ArtworkStyle: String, CaseIterable, Identifiable {
    case square, disc, round
    var id: Self { self }
    var label: String {
        switch self {
        case .square: "Square"
        case .disc: "Spinning disc"
        case .round: "Round"
        }
    }
}

enum VisualizerStyle: String, CaseIterable, Identifiable {
    case off, bars, mirror, wave, radial, pulse, ambient
    var id: Self { self }
    var label: String {
        switch self {
        case .off: "Off"
        case .bars: "Spectrum bars"
        case .mirror: "Mirrored bars"
        case .wave: "Waveform"
        case .radial: "Radial ring (around artwork)"
        case .pulse: "Pulse glow (around artwork)"
        case .ambient: "Ambient (card background)"
        }
    }
    /// Styles drawn in a strip under the controls; the others draw on the artwork or background.
    var usesStrip: Bool { self == .bars || self == .mirror || self == .wave }
}

enum VisualizerColor: String, CaseIterable, Identifiable {
    case white, pink, cyan, sunset, rainbow
    var id: Self { self }
    var label: String { rawValue.capitalized }

    /// Color for a position 0...1 across the visualizer (low to high frequency).
    func color(at position: Double) -> Color {
        switch self {
        case .white: .white
        case .pink: Color(red: 1, green: 0.36, blue: 0.62)
        case .cyan: Color(red: 0.35, green: 0.9, blue: 1)
        case .sunset: Color(hue: 0.98 + 0.12 * position, saturation: 0.75, brightness: 1)
        case .rainbow: Color(hue: position * 0.85, saturation: 0.7, brightness: 1)
        }
    }
}

struct SettingsView: View {
    @AppStorage(SettingKey.artworkStyle) private var artwork = ArtworkStyle.square
    @AppStorage(SettingKey.translucency) private var translucency = 0.55
    @AppStorage(SettingKey.visualizer) private var visualizer = VisualizerStyle.bars
    @AppStorage(SettingKey.visualizerColor) private var color = VisualizerColor.white
    @AppStorage(SettingKey.spinSpeed) private var spinSpeed = 1.0
    @AppStorage(SettingKey.layout) private var layout = PlayerLayout.compact

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Layout", selection: $layout) {
                    ForEach(PlayerLayout.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Artwork") {
                Picker("Style", selection: $artwork) {
                    ForEach(ArtworkStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if artwork == .disc {
                    Slider(value: $spinSpeed, in: 0.25...3) { Text("Spin speed") }
                }
            }
            Section("Window") {
                Slider(value: $translucency, in: 0...1) { Text("Translucency") }
            }
            Section("Visualizer") {
                Picker("Style", selection: $visualizer) {
                    ForEach(VisualizerStyle.allCases) { Text($0.label).tag($0) }
                }
                Picker("Color", selection: $color) {
                    ForEach(VisualizerColor.allCases) { Text($0.label).tag($0) }
                }
                .disabled(visualizer == .off)
                Text("Visualizers react to your Mac's audio output. macOS asks once for System Audio Recording permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
