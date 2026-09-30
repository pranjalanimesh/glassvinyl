import SwiftUI

/// How the artwork is drawn. Shared by the player and the previews in Settings.
struct ArtworkDesign: Equatable {
    var style: ArtworkStyle
    var corner: Double          // corner radius as a fraction of the size (square only)
    var shadow: ArtworkShadow
    var border: Bool

    func with(style: ArtworkStyle) -> ArtworkDesign {
        var copy = self
        copy.style = style
        return copy
    }
}

/// Album art with the artwork-bound visualizers (radial ring, pulse glow).
struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    let isPlaying: Bool
    let design: ArtworkDesign
    let spinSpeed: Double
    let visualizer: VisualizerStyle
    let palette: VisualizerColor
    let analyzer: AudioAnalyzer

    /// Room left around the art for the radial ring.
    private var inset: CGFloat { visualizer == .radial ? (size * 0.13).rounded() : 0 }
    private var glowRoom: CGFloat { (size * 0.26).rounded() }
    private var artSize: CGFloat { size - inset * 2 }

    @State private var spin = SpinClock()

    var body: some View {
        ZStack {
            if visualizer == .pulse {
                VisualizerView(style: .pulse, palette: palette, analyzer: analyzer, artShape: design.style,
                               artCornerRadius: artSize * design.corner, glowRoom: glowRoom)
                    .padding(-glowRoom)
                    .allowsHitTesting(false)
            }
            if visualizer == .radial {
                VisualizerView(style: .radial, palette: palette, analyzer: analyzer, artInset: inset)
            }
            art.frame(width: artSize, height: artSize)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var art: some View {
        let image = AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.white.opacity(0.1)
        }

        if design.style == .disc {
            TimelineView(.animation(paused: !isPlaying)) { context in
                StyledArtwork(design: design, size: artSize,
                              rotation: spin.angle(at: context.date, playing: isPlaying, speed: spinSpeed)) { image }
            }
        } else {
            StyledArtwork(design: design, size: artSize) { image }
        }
    }
}

/// Any image content shaped, bordered and shadowed per an `ArtworkDesign`.
struct StyledArtwork<Content: View>: View {
    let design: ArtworkDesign
    let size: CGFloat
    var rotation: Double = 0
    @ViewBuilder let content: Content

    var body: some View {
        shaped
            .overlay {
                if design.border {
                    outline.stroke(.white.opacity(0.35), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
    }

    @ViewBuilder private var shaped: some View {
        if design.style == .disc {
            Disc(label: content).rotationEffect(.degrees(rotation))
        } else {
            content.clipShape(outline)
        }
    }

    private var outline: AnyShape {
        design.style == .square
            ? AnyShape(RoundedRectangle(cornerRadius: size * design.corner, style: .continuous))
            : AnyShape(Circle())
    }

    /// Scaled with the artwork so the big stacked cover gets a proportionally larger shadow.
    private var shadow: (opacity: Double, radius: CGFloat, y: CGFloat) {
        let scale = size / 92
        switch design.shadow {
        case .none: return (0, 0, 0)
        case .soft: return (0.3, 5 * scale, 2 * scale)
        case .floating: return (0.5, 12 * scale, 8 * scale)
        }
    }
}

/// Vinyl record: grooves, the album art as the label, and a spindle hole.
private struct Disc<Label: View>: View {
    let label: Label

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
                label
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
