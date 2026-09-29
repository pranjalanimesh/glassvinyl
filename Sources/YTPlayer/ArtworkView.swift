import SwiftUI

/// Album art as a square, a circle, or a spinning vinyl disc, with the
/// artwork-bound visualizers (radial ring, pulse glow).
struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    let isPlaying: Bool
    let style: ArtworkStyle
    let spinSpeed: Double
    let visualizer: VisualizerStyle
    let palette: VisualizerColor
    let analyzer: AudioAnalyzer

    /// Room left around the art for the radial ring.
    private var inset: CGFloat { visualizer == .radial ? (size * 0.13).rounded() : 0 }
    private var glowRoom: CGFloat { (size * 0.26).rounded() }
    private var cornerRadius: CGFloat { size * 0.13 }

    @State private var spin = SpinClock()

    var body: some View {
        ZStack {
            if visualizer == .pulse {
                VisualizerView(style: .pulse, palette: palette, analyzer: analyzer, artShape: style, glowRoom: glowRoom)
                    .padding(-glowRoom)
                    .allowsHitTesting(false)
            }
            if visualizer == .radial {
                VisualizerView(style: .radial, palette: palette, analyzer: analyzer, artInset: inset)
            }
            art.frame(width: size - inset * 2, height: size - inset * 2)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var art: some View {
        let image = AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.white.opacity(0.1)
        }

        switch style {
        case .square:
            image.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        case .round:
            image.clipShape(Circle())
        case .disc:
            TimelineView(.animation(paused: !isPlaying)) { context in
                Disc(image: image)
                    .rotationEffect(.degrees(spin.angle(at: context.date, playing: isPlaying, speed: spinSpeed)))
            }
        }
    }
}

/// Vinyl record: grooves, the album art as the label, and a spindle hole.
private struct Disc<Label: View>: View {
    let image: Label

    var body: some View {
        GeometryReader { geo in
            let d = geo.size.width
            ZStack {
                Circle().fill(Color(white: 0.06))
                ForEach(1..<6) { i in
                    Circle()
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.6)
                        .padding(d * 0.04 * CGFloat(i))
                }
                image
                    .frame(width: d * 0.52, height: d * 0.52)
                    .clipShape(Circle())
                Circle().fill(Color(white: 0.06)).frame(width: d * 0.06, height: d * 0.06)
            }
        }
    }
}

/// Accumulates rotation only while playing, so pausing freezes the disc in place.
private final class SpinClock {
    private var angle: Double = 0
    private var last: Date?

    /// Degrees at `date`. One full turn every 4 seconds at speed 1.
    func angle(at date: Date, playing: Bool, speed: Double) -> Double {
        if playing, let last {
            // Capped so a resume after a pause doesn't jump.
            angle += min(date.timeIntervalSince(last), 0.1) * 90 * speed
        }
        last = playing ? date : nil
        return angle.truncatingRemainder(dividingBy: 360)
    }
}
