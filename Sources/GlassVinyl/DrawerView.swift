import SwiftUI

/// Expandable panel under the player: the Up Next queue and search.
struct DrawerView: View {
    @ObservedObject var model: PlayerModel
    let bridge: PlayerBridge
    let recommender: Recommender
    let library: LibraryStore

    var body: some View {
        VStack(spacing: 8) {
            // Custom tabs: the system segmented control draws an opaque blue pill on the glass.
            HStack(spacing: 4) {
                ForEach(DrawerTab.allCases, id: \.self) { tab in
                    let selected = model.tab == tab
                    Button { model.tab = tab } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Ink.primary : Ink.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(selected ? Color.white.opacity(0.14) : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.white.opacity(0.06), in: Capsule())

            switch model.tab {
            case .upNext: QueueList(model: model, bridge: bridge, library: library)
            case .search: SearchPane(model: model, bridge: bridge, library: library)
            case .forYou: ForYouPane(model: model, bridge: bridge, recommender: recommender, library: library)
            case .playlists: PlaylistsPane(model: model, library: library, bridge: bridge)
            }

            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
        }
    }
}

private struct QueueList: View {
    @ObservedObject var model: PlayerModel
    let bridge: PlayerBridge
    let library: LibraryStore
    /// Row being dragged, and how far it has moved (points, down is positive).
    @State private var drag: (id: String, offset: CGFloat)?
    /// Row under the pointer; it shows a play button over its artwork.
    @State private var hovered: String?

    private static let rowHeight: CGFloat = 42
    private static let rowSpacing: CGFloat = 2
    private static let pitch = rowHeight + rowSpacing

    var body: some View {
        if model.queue.isEmpty {
            Text("Queue is empty").foregroundStyle(Ink.secondary).frame(maxHeight: .infinity)
        } else {
            ThinScrollView {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(Array(model.queue.enumerated()), id: \.element.id) { position, item in
                        row(item, at: position)
                            .frame(height: Self.rowHeight)
                            .offset(y: offset(at: position, of: item))
                            .zIndex(drag?.id == item.id ? 1 : 0)
                            .animation(.easeOut(duration: 0.15), value: dragTarget)
                    }
                    if !model.autoplay.isEmpty {
                        Text("Autoplay")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Ink.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                            .padding(.leading, 6)
                        ForEach(model.autoplay) { item in
                            autoplayRow(item).frame(height: Self.rowHeight)
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: QueueItem, at position: Int) -> some View {
        let isDragged = drag?.id == item.id
        return SongRow(title: item.title, subtitle: item.artist, thumb: item.thumb,
                       highlighted: item.current || isDragged) {
            if item.current {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 11))
            } else {
                Text(item.length).font(.system(size: 10).monospacedDigit()).foregroundStyle(Ink.secondary)
                    .allowsHitTesting(false)
                Button { remove(item, at: position) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.secondary)
                .help("Remove from queue")
            }
        } thumbOverlay: {
            if hovered == item.id, !item.current, drag == nil {
                playOverlay { bridge.jump(to: absoluteIndex(position)) }
            }
        }
        .background {
            // Everything but the buttons falls through to this: drag anywhere on the row to reorder.
            if !item.current {
                RowDragArea(
                    onHover: { inside in setHovered(item.id, inside) },
                    onDrag: { offset in drag = (item.id, offset) },
                    onEnd: { offset in endDrag(item, from: position, offset: offset) },
                    onPlay: { bridge.jump(to: absoluteIndex(position)) },
                    onRemove: { remove(item, at: position) },
                    menuItems: { [AddToPlaylist.menuItem(for: PlaylistTrack(item), library: library, model: model)] }
                )
            } else {
                // The playing song: right-click only, no drag or remove.
                RowDragArea(
                    onHover: { _ in },
                    menuItems: { [AddToPlaylist.menuItem(for: PlaylistTrack(item), library: library, model: model)] }
                )
            }
        }
    }

    /// Songs YouTube Music plays once the queue runs out. Only playable: YouTube Music
    /// doesn't let you remove or reorder them either.
    private func autoplayRow(_ item: QueueItem) -> some View {
        SongRow(title: item.title, subtitle: item.artist, thumb: item.thumb, highlighted: false) {
            Text(item.length).font(.system(size: 10).monospacedDigit()).foregroundStyle(Ink.secondary)
                .allowsHitTesting(false)
        } thumbOverlay: {
            if hovered == item.id, drag == nil {
                playOverlay { bridge.playAutoplay(at: item.index, videoId: item.videoId) }
            }
        }
        .background {
            RowDragArea(
                onHover: { inside in setHovered(item.id, inside) },
                onPlay: { bridge.playAutoplay(at: item.index, videoId: item.videoId) },
                menuItems: { [AddToPlaylist.menuItem(for: PlaylistTrack(item), library: library, model: model)] }
            )
        }
    }

    private func playOverlay(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.45))
                Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .help("Play")
        .transition(.opacity)
    }

    private func setHovered(_ id: String, _ inside: Bool) {
        withAnimation(.easeOut(duration: 0.12)) {
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
    }

    // MARK: - Reordering

    /// The list starts at the current song, so a row's queue index is the first row's plus its position.
    /// Used instead of `item.index`, which is stale after a local reorder until the next poll.
    private func absoluteIndex(_ position: Int) -> Int {
        (model.queue.first?.index ?? 0) + position
    }

    /// Where the dragged row would land. Never above the current song at position 0.
    private var dragTarget: Int? {
        guard let drag, let from = model.queue.firstIndex(where: { $0.id == drag.id }) else { return nil }
        let moved = Int((drag.offset / Self.pitch).rounded())
        return min(max(from + moved, 1), model.queue.count - 1)
    }

    /// The dragged row follows the pointer; rows between its start and target shift to make room.
    private func offset(at position: Int, of item: QueueItem) -> CGFloat {
        guard let drag, let target = dragTarget,
              let from = model.queue.firstIndex(where: { $0.id == drag.id }) else { return 0 }
        if item.id == drag.id { return drag.offset }
        if from < target, position > from, position <= target { return -Self.pitch }
        if from > target, position >= target, position < from { return Self.pitch }
        return 0
    }

    private func endDrag(_ item: QueueItem, from position: Int, offset: CGFloat) {
        let target = dragTarget ?? position
        let from = absoluteIndex(position), to = absoluteIndex(target)
        withAnimation(.easeOut(duration: 0.12)) {
            drag = nil
            if target != position {
                // Shown right away; the next poll brings YouTube Music's own order.
                var reordered = model.queue
                reordered.insert(reordered.remove(at: position), at: target)
                model.queue = reordered
            }
        }
        if target != position { bridge.move(from: from, to: to, videoId: item.videoId) }
    }

    private func remove(_ item: QueueItem, at position: Int) {
        let index = absoluteIndex(position)
        withAnimation(.easeOut(duration: 0.15)) { model.queue.removeAll { $0.id == item.id } }
        bridge.remove(at: index, videoId: item.videoId)
    }
}

/// New songs Claude picked from the listening history (see Recommender).
private struct ForYouPane: View {
    @ObservedObject var model: PlayerModel
    let bridge: PlayerBridge
    let recommender: Recommender
    let library: LibraryStore

    /// Recommendations found on YouTube Music, in order.
    private var playableIds: [String] { model.recommendations.compactMap(\.videoId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            status.font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1)
            HStack(spacing: 6) {
                if !playableIds.isEmpty, !model.isRecommending {
                    pill("Queue all", symbol: "text.append", action: queueAll)
                }
                Spacer(minLength: 4)
                pill(model.recommendations.isEmpty ? "Find songs" : "Refresh", symbol: "sparkles", action: recommender.refresh)
                    .disabled(model.isRecommending)
            }

            if let error = model.recommendationError {
                Text(error).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(3)
            }

            if model.recommendations.isEmpty && !model.isRecommending {
                Text("Claude reads what you've been playing, searches Reddit and music blogs, and picks songs you haven't heard.")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
            } else {
                ThinScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.recommendations) { song in
                            SongRow(title: song.title, subtitle: "\(song.artist) · \(song.reason)",
                                    thumb: song.thumb, highlighted: false) {
                                accessory(for: song)
                            }
                            .help(song.reason)
                            .contentShape(Rectangle())
                            .contextMenu {
                                if let videoId = song.videoId {
                                    SongMenu(model: model, bridge: bridge, library: library, track: song.track(videoId))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if model.isRecommending {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Claude is searching, up to a few minutes")
            }
        } else if let date = model.recommendationsDate {
            Text("Picked ") + Text(date, style: .relative) + Text(" ago")
        } else {
            Text("Based on your listening")
        }
    }

    @ViewBuilder private func accessory(for song: Recommendation) -> some View {
        if let videoId = song.videoId {
            iconButton("play.fill", help: "Play") { bridge.playNow(videoId) }
            AddMenu(model: model, bridge: bridge, library: library, track: song.track(videoId))
        } else if model.isRecommending {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(Ink.secondary)
                .help("Not found on YouTube Music")
        }
    }

    /// Adds every found song to the end of Up Next.
    private func queueAll() {
        bridge.addToQueue(playableIds, next: false) { result in
            switch result {
            case .success(let count): model.flash("Added \(count) songs to the queue")
            case .failure(let error): model.flash("Couldn't add: \(error.localizedDescription)")
            }
        }
    }

    private func pill(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.secondary)
        .help(help)
    }
}

/// The queue row's drag, hover and right-click surface, behind the row's content.
/// An AppKit view so dragging reorders instead of moving the window, and so hover works
/// while the widget isn't the active window.
struct RowDragArea: NSViewRepresentable {
    let onHover: (Bool) -> Void
    /// Leave `onDrag`/`onEnd` nil for rows that can't be reordered, `onRemove` nil for rows
    /// that can't be removed.
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: ((CGFloat) -> Void)?
    var onPlay: (() -> Void)?
    var onRemove: (() -> Void)?
    var removeTitle = "Remove from Queue"
    /// A click that isn't a drag, e.g. to open a playlist.
    var onClick: (() -> Void)?
    /// Extra right-click items, built when the menu opens (e.g. Add to Playlist).
    var menuItems: (() -> [NSMenuItem])?

    func makeNSView(context: Context) -> RowDragView { RowDragView() }

    func updateNSView(_ view: RowDragView, context: Context) {
        view.onHover = onHover
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onPlay = onPlay
        view.onRemove = onRemove
        view.onClick = onClick
        view.removeTitle = removeTitle
        view.menuItems = menuItems
    }
}

final class RowDragView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: ((CGFloat) -> Void)?
    var onPlay: (() -> Void)?
    var onRemove: (() -> Void)?
    var onClick: (() -> Void)?
    var removeTitle = "Remove from Queue"
    var menuItems: (() -> [NSMenuItem])?

    private var startY: CGFloat?
    private var isDragging = false
    /// Movement needed before a press becomes a drag.
    private let threshold: CGFloat = 3

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    // MARK: Drag

    /// Vertical distance dragged, positive downward (screen y points up).
    private func distance() -> CGFloat {
        guard let startY else { return 0 }
        return startY - NSEvent.mouseLocation.y
    }

    override func mouseDown(with event: NSEvent) {
        startY = NSEvent.mouseLocation.y
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let onDrag else { return }
        let offset = distance()
        if !isDragging, abs(offset) >= threshold {
            isDragging = true
            NSCursor.closedHand.push()
        }
        if isDragging { onDrag(offset) }
    }

    override func mouseUp(with event: NSEvent) {
        // In the queue a plain click does nothing; playing is the hover button's job.
        if isDragging {
            onEnd?(distance())
            NSCursor.pop()
        } else {
            onClick?()
        }
        isDragging = false
        startY = nil
    }

    // MARK: Right-click

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if let onPlay { menu.addItem(ClosureMenuItem(title: "Play", action: onPlay)) }
        if let onRemove {
            menu.addItem(ClosureMenuItem(title: removeTitle, action: onRemove))
        }
        if let extra = menuItems?(), !extra.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            extra.forEach(menu.addItem)
        }
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

/// A ScrollView with a thin indicator on the left in place of the system scroller.
struct ThinScrollView<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var metrics = Metrics()

    private struct Metrics: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var visible: CGFloat = 0
    }

    var body: some View {
        ScrollView {
            content.padding(.leading, 8)  // room for the indicator
        }
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: Metrics.self) { geo in
            Metrics(offset: geo.contentOffset.y + geo.contentInsets.top,
                    content: geo.contentSize.height,
                    visible: geo.containerSize.height)
        } action: { _, new in
            metrics = new
        }
        .overlay(alignment: .topLeading) { indicator }
    }

    @ViewBuilder private var indicator: some View {
        if metrics.content > metrics.visible + 1 {
            let thumb = max(metrics.visible * metrics.visible / metrics.content, 24)
            let progress = min(max(metrics.offset / (metrics.content - metrics.visible), 0), 1)
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 3, height: thumb)
                .offset(x: 1, y: (metrics.visible - thumb) * progress)
                .allowsHitTesting(false)
        }
    }
}

private struct SearchPane: View {
    @ObservedObject var model: PlayerModel
    let bridge: PlayerBridge
    let library: LibraryStore
    @State private var query = ""

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.secondary)
                TextField("Search songs, artists…", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(runSearch)
                if model.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(7)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            ThinScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.results) { result in
                        SongRow(title: result.title, subtitle: result.subtitle, thumb: result.thumb, highlighted: false) {
                            AddMenu(model: model, bridge: bridge, library: library, track: PlaylistTrack(result))
                        }
                        .contentShape(Rectangle())
                        .contextMenu { SongMenu(model: model, bridge: bridge, library: library, track: PlaylistTrack(result)) }
                    }
                }
            }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        model.isSearching = true
        bridge.search(q) { result in
            model.isSearching = false
            switch result {
            case .success(let results): model.results = results
            case .failure(let error): model.flash(error.localizedDescription)
            }
        }
    }
}

/// ⊕ button for a song; opens SongMenu.
private struct AddMenu: View {
    let model: PlayerModel
    let bridge: PlayerBridge
    let library: LibraryStore
    let track: PlaylistTrack

    var body: some View {
        Menu {
            SongMenu(model: model, bridge: bridge, library: library, track: track)
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
    }
}

/// Actions for a song that isn't in the queue: play it now, play it next, add it to the
/// end of Up Next, or add it to a playlist. Used by the ⊕ button and right-click.
private struct SongMenu: View {
    let model: PlayerModel
    let bridge: PlayerBridge
    let library: LibraryStore
    let track: PlaylistTrack

    var body: some View {
        Button("Play Now") {
            bridge.playNow(track.videoId)
            model.flash("Playing \(track.title)")
        }
        Button("Play Next") { add(next: true) }
        Button("Add to Queue") { add(next: false) }
        Divider()
        AddToPlaylistMenu(track: track, library: library, model: model)
    }

    private func add(next: Bool) {
        bridge.addToQueue([track.videoId], next: next) { result in
            switch result {
            case .success: model.flash(next ? "\(track.title) plays next" : "Added \(track.title) to the queue")
            case .failure(let error): model.flash("Couldn't add: \(error.localizedDescription)")
            }
        }
    }
}

extension Recommendation {
    func track(_ videoId: String) -> PlaylistTrack {
        PlaylistTrack(videoId: videoId, setVideoId: nil, title: title, artist: artist,
                      length: "", thumb: thumb, type: "MUSIC_VIDEO_TYPE_ATV")
    }
}

/// Thumbnail, two lines of text, and trailing accessories.
/// The artwork and text don't take clicks, so anything behind the row (the queue's drag
/// area) gets them; buttons in the accessory and thumbnail overlay still work.
struct SongRow<Accessory: View, ThumbOverlay: View>: View {
    let title: String
    let subtitle: String
    let thumb: URL?
    let highlighted: Bool
    let accessory: Accessory
    let thumbOverlay: ThumbOverlay

    init(title: String, subtitle: String, thumb: URL?, highlighted: Bool,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder thumbOverlay: () -> ThumbOverlay) {
        self.title = title
        self.subtitle = subtitle
        self.thumb = thumb
        self.highlighted = highlighted
        self.accessory = accessory()
        self.thumbOverlay = thumbOverlay()
    }

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: thumb) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                Color.white.opacity(0.1)
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .allowsHitTesting(false)
            .overlay { thumbOverlay }

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            .allowsHitTesting(false)
            Spacer(minLength: 4)
            accessory
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(highlighted ? Color.white.opacity(0.12) : .clear)
                .allowsHitTesting(false)
        }
    }
}

extension SongRow where ThumbOverlay == EmptyView {
    init(title: String, subtitle: String, thumb: URL?, highlighted: Bool, @ViewBuilder accessory: () -> Accessory) {
        self.init(title: title, subtitle: subtitle, thumb: thumb, highlighted: highlighted,
                  accessory: accessory, thumbOverlay: { EmptyView() })
    }
}
