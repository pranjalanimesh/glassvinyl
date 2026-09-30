import SwiftUI

/// UserDefaults keys. Views read them with @AppStorage, so changes apply live.
enum SettingKey {
    static let artworkStyle = "artworkStyle"
    static let artworkCorner = "artworkCorner"
    static let artworkShadow = "artworkShadow"
    static let artworkBorder = "artworkBorder"
    static let artworkBackdrop = "artworkBackdrop"
    static let translucency = "translucency"
    static let visualizer = "visualizerStyle"
    static let visualizerColor = "visualizerColor"
    static let spinSpeed = "spinSpeed"
    static let layout = "layout"
    static let allSpaces = "showOnAllSpaces"
    static let compactWidth = "compactWidth"
    static let stackedWidth = "stackedWidth"
    static let eqEnabled = "eqEnabled"
    static let eqPreamp = "eqPreamp"
    static let eqGains = "eqGains"      // ten dB values, comma-separated
    static let eqPreset = "eqPreset"
    static let karaokeMode = "karaokeMode"
}

/// The equalizer, stored in UserDefaults and applied inside the YouTube Music page.
struct EQSettings: Equatable {
    static let bands = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let gainRange: ClosedRange<Double> = -12...12
    static let preampRange: ClosedRange<Double> = -12...6

    var on: Bool
    var preamp: Double
    var gains: [Double]

    static var current: EQSettings {
        let defaults = UserDefaults.standard
        return EQSettings(on: defaults.bool(forKey: SettingKey.eqEnabled),
                          preamp: defaults.double(forKey: SettingKey.eqPreamp),
                          gains: parse(defaults.string(forKey: SettingKey.eqGains)))
    }

    static func parse(_ text: String?) -> [Double] {
        let values = (text ?? "").split(separator: ",").compactMap { Double($0) }
        return values.count == bands.count ? values : Array(repeating: 0, count: bands.count)
    }

    static func format(_ gains: [Double]) -> String {
        gains.map { String(format: "%.1f", $0) }.joined(separator: ",")
    }

    /// The object the page script's setEq expects.
    var javaScript: String {
        "{on:\(on),preamp:\(preamp),gains:[\(gains.map { String($0) }.joined(separator: ","))]}"
    }
}

/// Starting points for the ten bands (31 Hz … 16 kHz), in dB.
enum EQPreset: String, CaseIterable, Identifiable {
    case flat = "Flat"
    case bassBoost = "Bass Boost"
    case trebleBoost = "Treble Boost"
    case vocal = "Vocal"
    case loudness = "Loudness"
    case warm = "Warm"
    case acoustic = "Acoustic"
    case electronic = "Electronic"
    case hipHop = "Hip-Hop"
    case classical = "Classical"
    case lateNight = "Late Night"
    var id: Self { self }

    var gains: [Double] {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bassBoost: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
        case .trebleBoost: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]
        case .vocal: [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]
        case .loudness: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]
        case .warm: [3, 3, 2, 1, 0, 1, 2, 1, 0, -1]
        case .acoustic: [3, 3, 2, 1, 1, 1, 2, 3, 2, 1]
        case .electronic: [5, 4, 1, 0, -2, 1, 0, 2, 4, 5]
        case .hipHop: [5, 4, 2, 3, -1, -1, 1, -1, 2, 3]
        case .classical: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]
        case .lateNight: [-3, -2, -1, 0, 1, 1, 0, -1, -2, -3]
        }
    }
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

    /// The card's width in points. Resizing changes this; text and icons keep their size.
    var defaultWidth: Double { self == .stacked ? 300 : 380 }
    var widthRange: ClosedRange<Double> { self == .stacked ? 240...560 : 320...680 }
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

enum ArtworkShadow: String, CaseIterable, Identifiable {
    case none, soft, floating
    var id: Self { self }
    var label: String { rawValue.capitalized }
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
    let analyzer: AudioAnalyzer
    @ObservedObject var karaoke: KaraokeEngine
    let model: PlayerModel

    @AppStorage(SettingKey.artworkStyle) private var artwork = ArtworkStyle.square
    @AppStorage(SettingKey.artworkCorner) private var corner = 0.13
    @AppStorage(SettingKey.artworkShadow) private var shadow = ArtworkShadow.soft
    @AppStorage(SettingKey.artworkBorder) private var border = false
    @AppStorage(SettingKey.artworkBackdrop) private var backdrop = false
    @AppStorage(SettingKey.translucency) private var translucency = 0.55
    @AppStorage(SettingKey.visualizer) private var visualizer = VisualizerStyle.bars
    @AppStorage(SettingKey.visualizerColor) private var color = VisualizerColor.white
    @AppStorage(SettingKey.spinSpeed) private var spinSpeed = 1.0
    @AppStorage(SettingKey.layout) private var layout = PlayerLayout.compact
    @AppStorage(SettingKey.allSpaces) private var allSpaces = true
    @AppStorage(SettingKey.compactWidth) private var compactWidth = PlayerLayout.compact.defaultWidth
    @AppStorage(SettingKey.stackedWidth) private var stackedWidth = PlayerLayout.stacked.defaultWidth

    private var design: ArtworkDesign {
        ArtworkDesign(style: artwork, corner: corner, shadow: shadow, border: border)
    }

    private enum Tab: String, CaseIterable {
        case player = "Player", artwork = "Artwork", sound = "Sound", karaoke = "Karaoke"
    }
    @State private var tab = Tab.player

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)

            Form {
                switch tab {
                case .player: playerTab
                case .artwork: artworkTab
                case .sound: soundTab
                case .karaoke: KaraokePanel(engine: karaoke, model: model)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var playerTab: some View {
        Section("Layout") {
            Picker("Layout", selection: $layout) {
                ForEach(PlayerLayout.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        Section("Window") {
            // Each layout keeps its own width.
            Slider(value: layout == .stacked ? $stackedWidth : $compactWidth, in: layout.widthRange) {
                Text("Width")
            }
            Slider(value: $translucency, in: 0...1) { Text("Translucency") }
            Picker("Show on", selection: $allSpaces) {
                Text("All desktops").tag(true)
                Text("Only this desktop").tag(false)
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private var artworkTab: some View {
        Section("Style") {
            ArtworkStylePicker(selection: $artwork, design: design)
            // Always shown (disabled when they don't apply) so the tab keeps its size.
            Slider(value: $corner, in: 0...0.5) { Text("Corner roundness") }
                .disabled(artwork != .square)
            Slider(value: $spinSpeed, in: 0.25...3) { Text("Spin speed") }
                .disabled(artwork != .disc)
        }
        Section("Finish") {
            Picker("Shadow", selection: $shadow) {
                ForEach(ArtworkShadow.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Thin border", isOn: $border)
            Toggle("Tint the card with the artwork", isOn: $backdrop)
        }
    }

    @ViewBuilder private var soundTab: some View {
        Section("Equalizer") {
            EQPanel(analyzer: analyzer)
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
}

/// Artwork styles as clickable previews, drawn with the current shadow, border and corners.
private struct ArtworkStylePicker: View {
    @Binding var selection: ArtworkStyle
    let design: ArtworkDesign

    private let sample = LinearGradient(
        colors: [Color(red: 0.98, green: 0.45, blue: 0.35), Color(red: 0.45, green: 0.3, blue: 0.9)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ArtworkStyle.allCases) { style in
                let selected = style == selection
                Button { selection = style } label: {
                    VStack(spacing: 8) {
                        StyledArtwork(design: design.with(style: style), size: 56) { sample }
                            .frame(width: 56, height: 56)
                        Text(style.label).font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
