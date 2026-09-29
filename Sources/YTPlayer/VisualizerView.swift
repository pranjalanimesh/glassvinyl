import SwiftUI

/// Draws one visualizer style from the live audio analysis, every display frame.
///
/// - `artInset`: for `.radial`, the gap between the canvas edge and the artwork.
/// - `glowRoom`: for `.pulse`, how far the canvas extends past the artwork.
struct VisualizerView: View {
    let style: VisualizerStyle
    let palette: VisualizerColor
    let analyzer: AudioAnalyzer
    var artShape: ArtworkStyle = .square
    var artInset: CGFloat = 0
    var glowRoom: CGFloat = 0

    @State private var motion = Motion()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                motion.update(with: analyzer.frame, at: timeline.date)
                switch style {
                case .bars: drawBars(&context, size)
                case .mirror: drawMirror(&context, size)
                case .wave: drawWave(&context, size)
                case .radial: drawRadial(&context, size)
                case .pulse: drawPulse(&context, size)
                case .ambient: drawAmbient(&context, size)
                case .off: break
                }
            }
        }
    }

    // MARK: - Styles

    /// Rounded bars with a bright top, soft glow, and peak caps that fall slowly.
    private func drawBars(_ context: inout GraphicsContext, _ size: CGSize) {
        let levels = motion.levels
        let slot = size.width / CGFloat(levels.count)
        let width = max(slot * 0.58, 1.5)
        var bars = Path()
        var caps = Path()
        for i in levels.indices {
            let x = CGFloat(i) * slot + (slot - width) / 2
            let height = max(levels[i] * (size.height - 4), 2)
            bars.addRoundedRect(in: CGRect(x: x, y: size.height - height, width: width, height: height),
                                cornerSize: CGSize(width: width / 2, height: width / 2))
            let capY = size.height - motion.peaks[i] * (size.height - 4) - 3
            caps.addRoundedRect(in: CGRect(x: x, y: capY, width: width, height: 1.5),
                                cornerSize: CGSize(width: 0.75, height: 0.75))
        }
        let fill = horizontalGradient(size)
        glow(&context, radius: 5, opacity: 0.55) { $0.fill(bars, with: fill) }
        context.fill(bars, with: fill)
        context.fill(caps, with: .color(.white.opacity(0.85)))
    }

    /// Bars grow up and down from the middle; bass in the center, treble at the edges.
    private func drawMirror(_ context: inout GraphicsContext, _ size: CGSize) {
        let levels = motion.levels
        let count = levels.count
        let slot = size.width / CGFloat(count * 2)
        let width = max(slot * 0.6, 1.2)
        let mid = size.height / 2
        var bars = Path()
        for i in 0..<count {
            let half = max(levels[i] * mid, 1)
            for side in [-1.0, 1.0] {
                let x = size.width / 2 + CGFloat(side) * (CGFloat(i) + 0.5) * slot - width / 2
                bars.addRoundedRect(in: CGRect(x: x, y: mid - half, width: width, height: half * 2),
                                    cornerSize: CGSize(width: width / 2, height: width / 2))
            }
        }
        let colors = [palette.color(at: 1), palette.color(at: 0.5), palette.color(at: 0),
                      palette.color(at: 0.5), palette.color(at: 1)]
        let fill = GraphicsContext.Shading.linearGradient(
            Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
        glow(&context, radius: 6, opacity: 0.6) { $0.fill(bars, with: fill) }
        context.fill(bars, with: fill)
    }

    /// A smooth oscilloscope line with fading echoes of the last few frames.
    private func drawWave(_ context: inout GraphicsContext, _ size: CGSize) {
        let stroke = horizontalGradient(size)
        for (age, echo) in motion.waveTrail.enumerated() {
            var faded = context  // oldest echo is faintest
            faded.opacity = 0.12 + 0.12 * Double(age)
            faded.stroke(smoothCurve(echo, in: size), with: stroke, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        let path = smoothCurve(motion.wave, in: size)
        glow(&context, radius: 4, opacity: 0.7) {
            $0.stroke(path, with: stroke, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        context.stroke(path, with: stroke, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    /// Spectrum rays around the artwork, mirrored around the circle and turning slowly.
    private func drawRadial(_ context: inout GraphicsContext, _ size: CGSize) {
        let levels = motion.levels
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let inner = size.width / 2 - artInset + 2
        let count = levels.count * 2
        let spin = motion.time * 0.15
        var rays = Path()
        for i in 0..<count {
            let band = i < levels.count ? i : count - 1 - i
            let angle = CGFloat(i) / CGFloat(count) * 2 * .pi - .pi / 2 + spin
            let outer = inner + 1.5 + levels[band] * (artInset - 3)
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            rays.move(to: CGPoint(x: center.x + direction.x * inner, y: center.y + direction.y * inner))
            rays.addLine(to: CGPoint(x: center.x + direction.x * outer, y: center.y + direction.y * outer))
        }
        let shading = GraphicsContext.Shading.conicGradient(
            Gradient(colors: stride(from: 0.0, through: 1.0, by: 0.2).map { palette.color(at: $0) } + [palette.color(at: 0)]),
            center: center, angle: .radians(spin))
        let style = StrokeStyle(lineWidth: max(size.width / 70, 1.5), lineCap: .round)
        glow(&context, radius: 4, opacity: 0.7) { $0.stroke(rays, with: shading, style: style) }
        context.stroke(rays, with: shading, style: style)
    }

    /// Glow that swells with the bass, plus rings that ripple out on each beat.
    private func drawPulse(_ context: inout GraphicsContext, _ size: CGSize) {
        let art = CGRect(origin: .zero, size: size).insetBy(dx: glowRoom, dy: glowRoom)
        let bass = motion.bass
        let grow = 3 + bass * glowRoom * 0.6
        let color = palette.color(at: Double(bass))

        glow(&context, radius: 8 + bass * 14, opacity: 0.35 + Double(bass) * 0.55) {
            $0.fill(artPath(art.insetBy(dx: -grow, dy: -grow)), with: .color(color))
        }
        for ripple in motion.ripples {
            let spread = ripple.age * glowRoom
            context.stroke(artPath(art.insetBy(dx: -spread, dy: -spread)),
                           with: .color(color.opacity(Double(1 - ripple.age) * 0.7)),
                           lineWidth: 2 * (1 - ripple.age) + 0.5)
        }
    }

    /// Soft colored blobs drifting behind the card, sized by the music.
    private func drawAmbient(_ context: inout GraphicsContext, _ size: CGSize) {
        let groups = motion.groupLevels(4)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: size.height * 0.28))
            for (k, energy) in groups.enumerated() {
                let phase = Double(k) * 1.7
                let t = motion.time * (0.25 + Double(k) * 0.06)
                let center = CGPoint(x: size.width * (0.5 + 0.38 * cos(t + phase)),
                                     y: size.height * (0.5 + 0.35 * sin(t * 1.3 + phase)))
                let radius = size.height * (0.35 + energy * 0.5)
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                layer.fill(Path(ellipseIn: rect),
                           with: .color(palette.color(at: Double(k) / 3).opacity(0.28 + Double(energy) * 0.4)))
            }
        }
    }

    // MARK: - Helpers

    private func horizontalGradient(_ size: CGSize) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: stride(from: 0.0, through: 1.0, by: 0.25).map { palette.color(at: $0) }),
                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
    }

    /// Draws `content` blurred underneath, for a neon glow.
    private func glow(_ context: inout GraphicsContext, radius: CGFloat, opacity: Double,
                      _ content: (inout GraphicsContext) -> Void) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius))
            layer.opacity = opacity
            content(&layer)
        }
    }

    private func artPath(_ rect: CGRect) -> Path {
        artShape == .square ? Path(roundedRect: rect, cornerRadius: 12, style: .continuous) : Path(ellipseIn: rect)
    }

    private func smoothCurve(_ wave: [CGFloat], in size: CGSize) -> Path {
        var path = Path()
        let mid = size.height / 2
        let points = wave.enumerated().map { i, v in
            CGPoint(x: size.width * CGFloat(i) / CGFloat(max(wave.count - 1, 1)), y: mid - v * mid * 0.9)
        }
        guard let first = points.first else { return path }
        path.move(to: first)
        for i in 1..<points.count {
            let control = points[i - 1]
            let end = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: end, control: control)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

/// Per-view animation state: eased levels, falling peak caps, beat ripples, wave echoes.
/// A class so the Canvas can update it every frame without triggering SwiftUI updates.
private final class Motion {
    private(set) var levels = [CGFloat](repeating: 0, count: AudioAnalyzer.bandCount)
    private(set) var peaks = [CGFloat](repeating: 0, count: AudioAnalyzer.bandCount)
    private(set) var wave = [CGFloat](repeating: 0, count: AudioAnalyzer.waveCount)
    private(set) var waveTrail: [[CGFloat]] = []
    private(set) var ripples: [(start: Date, age: CGFloat)] = []
    private(set) var bass: CGFloat = 0
    private(set) var time: Double = 0
    private var lastBeat = 0
    private var lastDate: Date?

    func update(with frame: AudioAnalyzer.Frame, at date: Date) {
        let dt = min(date.timeIntervalSince(lastDate ?? date), 0.1)
        lastDate = date
        time = date.timeIntervalSinceReferenceDate

        for i in levels.indices {
            // A slow shimmer keeps the bars alive during silence.
            let idle = 0.03 + 0.03 * CGFloat(sin(time * 1.8 + Double(i) * 0.4) + 1) / 2
            let target = max(CGFloat(frame.bands[i]), idle)
            levels[i] += (target - levels[i]) * (target > levels[i] ? 0.55 : 0.2)
            peaks[i] = max(levels[i], peaks[i] - CGFloat(dt) * 0.5)
        }
        bass = levels.prefix(6).reduce(0, +) / 6

        waveTrail.append(wave)
        if waveTrail.count > 3 { waveTrail.removeFirst() }
        for i in wave.indices { wave[i] += (CGFloat(frame.wave[i]) - wave[i]) * 0.5 }

        if frame.beats != lastBeat {
            lastBeat = frame.beats
            ripples.append((date, 0))
        }
        ripples = ripples.compactMap { ripple in
            let age = CGFloat(date.timeIntervalSince(ripple.start) / 0.9)
            return age < 1 ? (ripple.start, age) : nil
        }
    }

    /// Average level of `count` equal slices of the spectrum.
    func groupLevels(_ count: Int) -> [CGFloat] {
        let size = levels.count / count
        return (0..<count).map { k in levels[k * size..<(k + 1) * size].reduce(0, +) / CGFloat(size) }
    }
}
