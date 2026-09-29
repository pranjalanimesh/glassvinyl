import SwiftUI

struct PlayerView: View {
    @ObservedObject var model: PlayerModel
    let bridge: PlayerBridge
    let analyzer: AudioAnalyzer
    let openMusicWindow: () -> Void
    let openSettings: () -> Void
    /// Animates the window to a size, keeping its top edge in place, then calls the completion.
    let resize: (CGSize, (() -> Void)?) -> Void

    @AppStorage(SettingKey.layout) private var layout = PlayerLayout.compact
    @AppStorage(SettingKey.artworkStyle) private var artworkStyle = ArtworkStyle.square
    @AppStorage(SettingKey.translucency) private var translucency = 0.55
    @AppStorage(SettingKey.visualizer) private var visualizer = VisualizerStyle.bars
    @AppStorage(SettingKey.visualizerColor) private var palette = VisualizerColor.white
    @AppStorage(SettingKey.spinSpeed) private var spinSpeed = 1.0

    /// Measured height of the player card (everything above the drawer).
    @State private var cardHeight: CGFloat = 96

    static func width(for layout: PlayerLayout) -> CGFloat { layout == .stacked ? 300 : 380 }
    private static let padding: CGFloat = 14
    private static let spacing: CGFloat = 10
    private static let drawerHeight: CGFloat = 310
    private static let stripHeight: CGFloat = 22

    private func windowSize(expanded: Bool) -> CGSize {
        CGSize(width: Self.width(for: layout),
               height: cardHeight + Self.padding * 2 + (expanded ? Self.spacing + Self.drawerHeight : 0))
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            card
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { Color.clear.preference(key: CardHeightKey.self, value: $0.size.height) })
            if model.isExpanded {
                DrawerView(model: model, bridge: bridge).frame(height: Self.drawerHeight)
            }
        }
        .padding(Self.padding)
        // Pinned to the top: while the window animates, the drawer is revealed from the bottom edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                GlassBackground(opacity: 1 - translucency * 0.85)
                if visualizer == .ambient {
                    VisualizerView(style: .ambient, palette: palette, analyzer: analyzer)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
        .onPreferenceChange(CardHeightKey.self) { cardHeight = $0 }
        .onChange(of: windowSize(expanded: model.isExpanded), initial: true) {
            resize(windowSize(expanded: model.isExpanded), nil)
        }
        .onChange(of: model.isExpanded, initial: true) { updateQueuePolling() }
        .onChange(of: model.tab) { updateQueuePolling() }
    }

    /// Opening adds the drawer, then the window grows to reveal it. Closing shrinks the
    /// window first and removes the drawer once it's hidden, so nothing jumps.
    private func toggleDrawer() {
        if model.isExpanded {
            resize(windowSize(expanded: false)) { model.isExpanded = false }
        } else {
            model.isExpanded = true
        }
    }

    private func updateQueuePolling() {
        bridge.wantsQueue = model.isExpanded && model.tab == .upNext
        if bridge.wantsQueue { bridge.poll() }
    }

    // MARK: - Card

    @ViewBuilder private var card: some View {
        if model.state.title.isEmpty {
            emptyState
        } else {
            switch layout {
            case .compact:
                VStack(spacing: Self.spacing) {
                    HStack(spacing: 14) {
                        artwork(size: 92)
                        details
                    }
                    strip
                }
            case .stacked:
                VStack(spacing: 12) {
                    artwork(size: Self.width(for: .stacked) - Self.padding * 2)
                    details
                    strip
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(model.problem ?? "Nothing playing")
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            HStack {
                Button("Open YouTube Music", action: openMusicWindow)
                Button("Settings", action: openSettings)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96)
    }

    private func artwork(size: CGFloat) -> some View {
        let s = model.state
        return ArtworkView(url: s.artworkURL, size: size, isPlaying: s.isPlaying, style: artworkStyle,
                           spinSpeed: spinSpeed, visualizer: visualizer, palette: palette, analyzer: analyzer)
            .onTapGesture(perform: openMusicWindow)
            .help("Open YouTube Music")
    }

    /// Title, artist, drawer and settings buttons, progress bar, transport controls.
    private var details: some View {
        let s = model.state
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(s.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                iconButton("list.bullet", help: "Queue & search", action: toggleDrawer)
                    .foregroundStyle(model.isExpanded ? .primary : .secondary)
                iconButton("gearshape", help: "Settings", action: openSettings)
                    .foregroundStyle(.secondary)
            }
            ProgressBar(position: s.position, duration: s.duration, onSeek: bridge.seek(to:))
                .padding(.top, 4)
            HStack(spacing: 26) {
                control("backward.fill", size: 14, action: bridge.previous)
                control(s.isPlaying ? "pause.fill" : "play.fill", size: 20, action: bridge.togglePlay)
                control("forward.fill", size: 14, action: bridge.next)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var strip: some View {
        if visualizer.usesStrip {
            VisualizerView(style: visualizer, palette: palette, analyzer: analyzer)
                .frame(height: Self.stripHeight)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    // Views that don't report a height contribute 0, so keep the largest.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Behind-window blur whose strength follows the Translucency setting.
private struct GlassBackground: NSViewRepresentable {
    let opacity: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.alphaValue = opacity
    }
}

/// Thin progress bar with time labels. Click anywhere on the track to seek.
private struct ProgressBar: View {
    let position: Double
    let duration: Double
    let onSeek: (Double) -> Void

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: geo.size.width * fraction)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard duration > 0 else { return }
                    onSeek(Double(location.x / geo.size.width) * duration)
                }
            }
            .frame(height: 10)

            HStack {
                Text(format(position))
                Spacer()
                Text(format(duration))
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var fraction: CGFloat {
        duration > 0 ? CGFloat(min(max(position / duration, 0), 1)) : 0
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
