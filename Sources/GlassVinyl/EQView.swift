import SwiftUI

/// Settings panel for the 10-band equalizer: preamp, band sliders drawn over the live
/// spectrum and the EQ curve, presets. Changes are stored in UserDefaults; AppDelegate
/// forwards them to the page (see PlayerBridge.applyEQSoon).
struct EQPanel: View {
    let analyzer: AudioAnalyzer

    @AppStorage(SettingKey.eqEnabled) private var on = false
    @AppStorage(SettingKey.eqPreamp) private var preamp = 0.0
    @AppStorage(SettingKey.eqGains) private var gainsText = EQSettings.format(EQPreset.flat.gains)
    @AppStorage(SettingKey.eqPreset) private var preset = EQPreset.flat.rawValue

    private static let custom = "Custom"
    private static let sliderHeight: CGFloat = 140

    private var gains: [Double] { EQSettings.parse(gainsText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("On", isOn: $on)
                Spacer()
                Picker("Preset", selection: presetBinding) {
                    ForEach(EQPreset.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    if preset == Self.custom { Text(Self.custom).tag(Self.custom) }
                }
                .labelsHidden()
                .fixedSize()
                Button("Reset") {
                    apply(.flat)
                    preamp = 0
                }
            }

            HStack(alignment: .top, spacing: 10) {
                column(title: "Pre", value: preampBinding, range: EQSettings.preampRange)
                Divider().frame(height: Self.sliderHeight)
                bands
            }
            .opacity(on ? 1 : 0.45)

            Text("Runs inside YouTube Music in Brave. A limiter stops boosts from distorting. Once switched on, the page's audio goes through the EQ until the page reloads. Double-click a slider to reset it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bands

    private var bands: some View {
        VStack(spacing: 4) {
            ZStack {
                // Live spectrum and the EQ curve behind the sliders.
                VisualizerView(style: .bars, palette: .white, analyzer: analyzer)
                    .opacity(0.18)
                    .padding(.vertical, VerticalSlider.inset)
                ZeroLine(range: EQSettings.gainRange)
                    .stroke(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                ResponseCurve(gains: gains, range: EQSettings.gainRange)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                HStack(spacing: 0) {
                    ForEach(EQSettings.bands.indices, id: \.self) { i in
                        VerticalSlider(value: gainBinding(i), range: EQSettings.gainRange)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: Self.sliderHeight)

            HStack(spacing: 0) {
                ForEach(EQSettings.bands.indices, id: \.self) { i in
                    VStack(spacing: 1) {
                        Text(Self.label(EQSettings.bands[i])).font(.system(size: 10, weight: .medium))
                        Text(Self.decibels(gains[i])).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func column(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 4) {
            VerticalSlider(value: value, range: range).frame(width: 24, height: Self.sliderHeight)
            VStack(spacing: 1) {
                Text(title).font(.system(size: 10, weight: .medium))
                Text(Self.decibels(value.wrappedValue)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bindings

    /// Moving a band switches the EQ on and marks the settings as Custom.
    private func gainBinding(_ i: Int) -> Binding<Double> {
        Binding {
            gains[i]
        } set: { value in
            var updated = gains
            updated[i] = value
            gainsText = EQSettings.format(updated)
            preset = Self.custom
            on = true
        }
    }

    private var preampBinding: Binding<Double> {
        Binding { preamp } set: { preamp = $0; on = true }
    }

    private var presetBinding: Binding<String> {
        Binding {
            preset
        } set: { name in
            if let chosen = EQPreset(rawValue: name) { apply(chosen) }
        }
    }

    private func apply(_ chosen: EQPreset) {
        gainsText = EQSettings.format(chosen.gains)
        preset = chosen.rawValue
        on = true
    }

    // MARK: - Labels

    private static func label(_ hertz: Int) -> String {
        hertz >= 1000 ? "\(hertz / 1000)k" : "\(hertz)"
    }

    private static func decibels(_ value: Double) -> String {
        value == 0 ? "0" : String(format: "%+.1f", value)
    }
}

/// A vertical slider: drag to set, double-click to reset to 0.
private struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    /// Distance from the ends of the track to the thumb's travel limits (its radius).
    static let inset: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.height - Self.inset * 2
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let y = Self.inset + travel * (1 - fraction)
            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 3)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: Self.inset * 2, height: Self.inset * 2)
                    .position(x: geo.size.width / 2, y: y)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = 1 - min(max((drag.location.y - Self.inset) / travel, 0), 1)
                let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
                value = (raw * 2).rounded() / 2  // half-dB steps
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
        }
    }
}

/// Smooth line through the band gains, aligned with the slider thumbs.
private struct ResponseCurve: Shape {
    let gains: [Double]
    let range: ClosedRange<Double>

    func path(in rect: CGRect) -> Path {
        let travel = rect.height - VerticalSlider.inset * 2
        let points = gains.enumerated().map { i, gain in
            let fraction = (gain - range.lowerBound) / (range.upperBound - range.lowerBound)
            return CGPoint(x: rect.width * (CGFloat(i) + 0.5) / CGFloat(gains.count),
                           y: VerticalSlider.inset + travel * (1 - fraction))
        }
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: 0, y: first.y))
        path.addLine(to: first)
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1])
        }
        path.addQuadCurve(to: last, control: last)
        path.addLine(to: CGPoint(x: rect.width, y: last.y))
        return path
    }
}

/// Dashed 0 dB reference line.
private struct ZeroLine: Shape {
    let range: ClosedRange<Double>

    func path(in rect: CGRect) -> Path {
        let travel = rect.height - VerticalSlider.inset * 2
        let fraction = (0 - range.lowerBound) / (range.upperBound - range.lowerBound)
        let y = VerticalSlider.inset + travel * (1 - fraction)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: rect.width, y: y))
        return path
    }
}
