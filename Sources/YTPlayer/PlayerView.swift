import SwiftUI

/// Fixed colors for the widget's text and icons. The system's .primary/.secondary are
/// vibrant on a translucent window: they blend with whatever is behind it and wash out
/// over bright wallpapers.
enum Ink {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.72)
    /// Soft shadow under text so it holds up on light backgrounds too.
    static let shadow = Color.black.opacity(0.35)
}

struct PlayerView: View {
    @ObservedObject var model: PlayerModel
    let bridge: PlayerBridge
    let recommender: Recommender
    @ObservedObject var library: LibraryStore
    let analyzer: AudioAnalyzer
    let openMusicWindow: () -> Void
    let openSettings: () -> Void
    /// Sets the window size in one step, keeping its top edge in place.
    let resize: (CGSize) -> Void
    /// Called when the drawer starts animating, so the window can keep its shadow in step.
    let drawerWillAnimate: (TimeInterval) -> Void

    @AppStorage(SettingKey.layout) private var layout = PlayerLayout.compact
    @AppStorage(SettingKey.artworkStyle) private var artworkStyle = ArtworkStyle.square
    @AppStorage(SettingKey.artworkCorner) private var artworkCorner = 0.13
    @AppStorage(SettingKey.artworkShadow) private var artworkShadow = ArtworkShadow.soft
    @AppStorage(SettingKey.artworkBorder) private var artworkBorder = false
    @AppStorage(SettingKey.artworkBackdrop) private var artworkBackdrop = false
    @AppStorage(SettingKey.translucency) private var translucency = 0.55
    @AppStorage(SettingKey.visualizer) private var visualizer = VisualizerStyle.bars
    @AppStorage(SettingKey.visualizerColor) private var palette = VisualizerColor.white
    @AppStorage(SettingKey.spinSpeed) private var spinSpeed = 1.0
    @AppStorage(SettingKey.compactWidth) private var compactWidth = PlayerLayout.compact.defaultWidth
    @AppStorage(SettingKey.stackedWidth) private var stackedWidth = PlayerLayout.stacked.defaultWidth

    /// Measured height of the player card (everything above the drawer).
    @State private var cardHeight: CGFloat = 96
    /// Like state shown right after a click, until YouTube Music confirms it.
    @State private var pendingLike: (videoId: String, liked: Bool)?
    /// Drives the drawer's open/close animation. `model.isExpanded` drives the window size.
    @State private var drawerRevealed = false

    private static let padding: CGFloat = 14
    private static let spacing: CGFloat = 10
    private static let drawerHeight: CGFloat = 310
    private static let stripHeight: CGFloat = 22
    private static let drawerDuration: TimeInterval = 0.3

    private var cardAreaHeight: CGFloat { cardHeight + Self.padding * 2 }
    /// The current layout's width setting. Only the width and the artwork change with it.
    private var widthSetting: Binding<Double> { layout == .stacked ? $stackedWidth : $compactWidth }
    private var width: CGFloat {
        CGFloat(min(max(widthSetting.wrappedValue, layout.widthRange.lowerBound), layout.widthRange.upperBound))
    }
    /// Height of the card plus however much of the drawer is showing, before scaling.
    private var visibleHeight: CGFloat {
        cardAreaHeight + (model.isExpanded && drawerRevealed ? Self.drawerHeight + Self.padding : 0)
    }
    private let cornerRadius: CGFloat = 22

    private func windowSize(expanded: Bool) -> CGSize {
        CGSize(width: width, height: cardAreaHeight + (expanded ? Self.drawerHeight + Self.padding : 0))
    }

    var body: some View {
        content
            .frame(width: width, height: visibleHeight, alignment: .top)
            // Keeps glows and shadows inside the rounded card instead of spilling into its corners.
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(alignment: .top) { cardBackground }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
            .overlay(alignment: .bottomTrailing) {
                // In the stacked layout the height follows the width, so dragging down also widens.
                ResizeGrip(width: widthSetting, range: layout.widthRange, followsVertical: layout == .stacked)
                    .frame(width: 16, height: 16)
                    .padding(4)
            }
            // While the drawer animates the window is already full size; the rest stays transparent.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onPreferenceChange(CardHeightKey.self) { cardHeight = $0 }
            .onChange(of: windowSize(expanded: model.isExpanded), initial: true) {
                resize(windowSize(expanded: model.isExpanded))
            }
            .onChange(of: model.isExpanded, initial: true) { updateQueuePolling() }
            .onChange(of: model.tab) { updateQueuePolling() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            card
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { Color.clear.preference(key: CardHeightKey.self, value: $0.size.height) })
                .padding(Self.padding)
            if model.isExpanded {
                DrawerView(model: model, bridge: bridge, recommender: recommender, library: library)
                    .shadow(color: Ink.shadow, radius: 1.5, y: 0.5)
                    .frame(height: Self.drawerHeight)
                    .padding([.horizontal, .bottom], Self.padding)
                    // Only the bottom edge moves: the drawer is clipped to a height that animates.
                    .frame(height: drawerRevealed ? Self.drawerHeight + Self.padding : 0, alignment: .top)
                    .clipped()
            }
        }
        .foregroundStyle(Ink.primary)
    }

    private var cardBackground: some View {
        ZStack(alignment: .top) {
            GlassBackground(opacity: 1 - translucency * 0.85)
            if artworkBackdrop {
                // Sized to the expanded window, so opening the drawer doesn't rescale it.
                // In an overlay so its size doesn't stretch the card's background.
                Color.clear.overlay(alignment: .top) {
                    AsyncImage(url: model.state.artworkURL) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                        Color.clear
                    }
                    .frame(width: windowSize(expanded: true).width, height: windowSize(expanded: true).height)
                    .blur(radius: 40)
                    .opacity(0.55)
                }
            }
            if visualizer == .ambient {
                // Sized to the card alone, so the drawer opening doesn't move it.
                VisualizerView(style: .ambient, palette: palette, analyzer: analyzer)
                    .frame(height: cardAreaHeight)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// The window never animates, so the card never moves. Opening: the window grows in one
    /// step (transparent below the card), then the drawer slides down. Closing: the drawer
    /// slides up, then the window shrinks.
    private func toggleDrawer() {
        if model.isExpanded {
            drawerWillAnimate(Self.drawerDuration)
            withAnimation(.smooth(duration: Self.drawerDuration)) {
                drawerRevealed = false
            } completion: {
                model.isExpanded = false
            }
        } else {
            model.isExpanded = true
            DispatchQueue.main.async {
                drawerWillAnimate(Self.drawerDuration)
                withAnimation(.smooth(duration: Self.drawerDuration)) { drawerRevealed = true }
            }
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
                        // Grows a little with the width; the rest goes to the title column.
                        artwork(size: min(max(width * 0.24, 84), 150))
                        details.shadow(color: Ink.shadow, radius: 1.5, y: 0.5)
                    }
                    strip
                }
            case .stacked:
                VStack(spacing: 12) {
                    artwork(size: width - Self.padding * 2)
                    details.shadow(color: Ink.shadow, radius: 1.5, y: 0.5)
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
        let design = ArtworkDesign(style: artworkStyle, corner: artworkCorner, shadow: artworkShadow, border: artworkBorder)
        return ArtworkView(url: s.artworkURL, size: size, isPlaying: s.isPlaying, design: design,
                           spinSpeed: spinSpeed, visualizer: visualizer, palette: palette, analyzer: analyzer)
            .onTapGesture(perform: openMusicWindow)
            .help("Open YouTube Music. Right-click to add to a playlist")
            .contextMenu { addToPlaylistMenu }
    }

    /// Title, artist, drawer and settings buttons, progress bar, transport controls.
    private var details: some View {
        let s = model.state
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(s.artist).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                likeButton
                iconButton("list.bullet", help: "Queue & search", action: toggleDrawer)
                    .foregroundStyle(model.isExpanded ? Ink.primary : Ink.secondary)
                iconButton("gearshape", help: "Settings", action: openSettings)
                    .foregroundStyle(Ink.secondary)
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

    // MARK: - Like

    private var isLiked: Bool {
        if let pendingLike, pendingLike.videoId == model.state.videoId { return pendingLike.liked }
        return model.state.isLiked
    }

    /// Flips immediately, then follows YouTube Music. If it doesn't confirm within
    /// 3 seconds, the heart goes back to the real state.
    private var likeButton: some View {
        Button {
            let target = (videoId: model.state.videoId, liked: !isLiked)
            withAnimation(.snappy(duration: 0.2)) { pendingLike = target }
            bridge.toggleLike()
            library.noteLike(.nowPlaying(model.state), liked: target.liked)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if pendingLike?.videoId == target.videoId, pendingLike?.liked == target.liked { pendingLike = nil }
            }
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: 12))
                .foregroundStyle(isLiked ? Color(red: 1, green: 0.3, blue: 0.45) : Ink.secondary)
                .symbolEffect(.bounce, value: isLiked)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isLiked ? "Unlike. Right-click to add to a playlist" : "Like. Right-click to add to a playlist")
        .contextMenu { addToPlaylistMenu }
        .onChange(of: model.state.isLiked) {
            if pendingLike?.liked == model.state.isLiked { pendingLike = nil }
        }
    }

    /// Right-click on the heart or artwork: add the current song to a playlist.
    private var addToPlaylistMenu: some View {
        AddToPlaylistMenu(track: .nowPlaying(model.state), library: library, model: model)
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
            .foregroundStyle(Ink.secondary)
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

/// Bottom-right grip; dragging it changes the card's width.
/// An AppKit view so the drag resizes instead of moving the window (dragging anywhere
/// else on the card moves it).
private struct ResizeGrip: NSViewRepresentable {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// Count vertical drag too, for layouts whose height grows with the width.
    let followsVertical: Bool

    func makeNSView(context: Context) -> GripView { GripView() }

    func updateNSView(_ view: GripView, context: Context) {
        view.width = width
        view.range = range
        view.followsVertical = followsVertical
        view.setWidth = { [binding = $width] in binding.wrappedValue = $0 }
    }
}

private final class GripView: NSView {
    var width = 0.0
    var range: ClosedRange<Double> = 0...0
    var followsVertical = false
    var setWidth: (Double) -> Void = { _ in }
    private var dragStart: (mouse: NSPoint, width: Double)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = (NSEvent.mouseLocation, width)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        // Screen coordinates, because the window (and this view) grows under the pointer.
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - start.mouse.x
        let dy = start.mouse.y - mouse.y  // screen y points up; dragging down enlarges
        let delta = followsVertical ? (dx + dy) / 2 : dx
        setWidth(min(max(start.width + delta, range.lowerBound), range.upperBound))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
    }

    /// Three short diagonal strokes, like a window's resize corner.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.4).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        for inset in [4.0, 8.0, 12.0] {
            path.move(to: NSPoint(x: bounds.maxX - inset, y: bounds.minY + 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + inset))
        }
        path.stroke()
    }
}
