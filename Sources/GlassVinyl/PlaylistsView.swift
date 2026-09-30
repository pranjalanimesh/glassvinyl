import SwiftUI

/// The Playlists tab: YouTube Music playlists and Liked Music from the local library copy.
///
/// A quiet list by default. Hovering a playlist offers play, shuffle and "add the current
/// song"; clicking opens it. The filter field searches every song in every playlist.
struct PlaylistsPane: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var library: LibraryStore
    let bridge: PlayerBridge

    @State private var openId: String?
    @State private var filter = ""
    @State private var hovered: String?
    @State private var isCreating = false
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let openId, let list = library.playlist(openId) {
                detail(list)
            } else {
                overview
            }
        }
    }

    // MARK: - Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                FilterField(text: $filter, prompt: "Filter songs in your library")
                iconButton("plus", help: "New playlist") { isCreating.toggle() }
                syncButton
            }
            if isCreating {
                TextField("Playlist name, then Return", text: $newTitle)
                    .textFieldStyle(.plain)
                    .padding(6)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    .onSubmit(createPlaylist)
            }

            if library.musicPlaylists.isEmpty {
                Text(library.isSyncing ? "Loading your library…" : "No playlists yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filter.isEmpty {
                ThinScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(library.musicPlaylists) { playlistRow($0) }
                    }
                }
            } else {
                ThinScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches, id: \.track.videoId) { match in
                            trackRow(match.track, in: match.playlist, subtitle: "\(match.track.artist) · \(match.playlist.title)")
                        }
                    }
                }
            }
        }
    }

    private func playlistRow(_ list: LibraryPlaylist) -> some View {
        let rowId = "p-\(list.id)"
        let isHovered = hovered == rowId
        return SongRow(title: list.title, subtitle: "\(list.tracks.count) songs",
                       thumb: list.thumb ?? list.tracks.first?.thumb, highlighted: false) {
            if isHovered {
                iconButton("play.fill", help: "Play") { bridge.playPlaylist(list.id, shuffle: false) }
                iconButton("shuffle", help: "Shuffle") { bridge.playPlaylist(list.id, shuffle: true) }
                addCurrentButton(to: list)
            } else {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 42)
        .background {
            RowDragArea(onHover: { setHovered(rowId, $0) },
                        onPlay: { bridge.playPlaylist(list.id, shuffle: false) },
                        onClick: { open(list.id) })
        }
    }

    /// Songs matching the filter across all playlists, each listed once.
    private var matches: [(track: PlaylistTrack, playlist: LibraryPlaylist)] {
        let query = filter.lowercased()
        var seen = Set<String>()
        var out: [(PlaylistTrack, LibraryPlaylist)] = []
        for list in library.musicPlaylists {
            for track in list.tracks where !seen.contains(track.videoId) {
                if track.title.lowercased().contains(query) || track.artist.lowercased().contains(query) {
                    seen.insert(track.videoId)
                    out.append((track, list))
                }
            }
        }
        return Array(out.prefix(200))
    }

    // MARK: - Detail

    private func detail(_ list: LibraryPlaylist) -> some View {
        let tracks = filter.isEmpty ? list.tracks : list.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(filter) || $0.artist.localizedCaseInsensitiveContains(filter)
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { close() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text(list.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("\(list.tracks.count)").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                Spacer(minLength: 4)
                iconButton("play.fill", help: "Play") { bridge.playPlaylist(list.id, shuffle: false) }
                iconButton("shuffle", help: "Shuffle") { bridge.playPlaylist(list.id, shuffle: true) }
                addCurrentButton(to: list)
            }
            FilterField(text: $filter, prompt: "Filter this playlist")
            ThinScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(tracks) { trackRow($0, in: list, subtitle: $0.artist) }
                }
            }
        }
    }

    private func trackRow(_ track: PlaylistTrack, in list: LibraryPlaylist, subtitle: String) -> some View {
        let rowId = "t-\(list.id)-\(track.id)"
        let isHovered = hovered == rowId
        let play = { bridge.playFromPlaylist(list.id, videoId: track.videoId) }
        return SongRow(title: track.title, subtitle: subtitle, thumb: track.thumb,
                       highlighted: track.videoId == model.state.videoId) {
            Text(track.length).font(.system(size: 10).monospacedDigit()).foregroundStyle(Ink.secondary)
                .allowsHitTesting(false)
            if isHovered {
                iconButton(list.isLiked ? "heart.slash" : "minus.circle",
                           help: list.isLiked ? "Unlike" : "Remove from \(list.title)") {
                    remove(track, from: list)
                }
            }
        } thumbOverlay: {
            if isHovered {
                Button(action: play) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.45))
                        Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .frame(height: 42)
        .background {
            RowDragArea(onHover: { setHovered(rowId, $0) }, onPlay: play,
                        onRemove: { remove(track, from: list) },
                        removeTitle: list.isLiked ? "Unlike" : "Remove from Playlist",
                        menuItems: { [AddToPlaylist.menuItem(for: track, library: library, model: model)] })
        }
    }

    // MARK: - Actions

    /// ＋ adds the song that's playing; ✓ means it's already there.
    @ViewBuilder private func addCurrentButton(to list: LibraryPlaylist) -> some View {
        let state = model.state
        if !state.videoId.isEmpty {
            let added = library.contains(state.videoId, in: list.id)
            iconButton(added ? "checkmark.circle.fill" : "plus.circle",
                       help: added ? "\(state.title) is in \(list.title)" : "Add \(state.title) to \(list.title)") {
                guard !added else { return }
                let track = PlaylistTrack.nowPlaying(state)
                Task {
                    do {
                        try await library.add(track, to: list.id)
                        model.flash("Added \(state.title) to \(list.title)")
                    } catch {
                        model.flash("Couldn't add: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func remove(_ track: PlaylistTrack, from list: LibraryPlaylist) {
        Task {
            do {
                try await library.remove(track, from: list.id)
                model.flash(list.isLiked ? "Unliked \(track.title)" : "Removed \(track.title) from \(list.title)")
            } catch {
                model.flash("Couldn't remove: \(error.localizedDescription)")
            }
        }
    }

    private func createPlaylist() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        newTitle = ""
        isCreating = false
        Task {
            do {
                try await library.createPlaylist(title: title)
                model.flash("Created \(title)")
            } catch {
                model.flash("Couldn't create: \(error.localizedDescription)")
            }
        }
    }

    private func open(_ id: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            filter = ""
            openId = id
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) {
            filter = ""
            openId = nil
        }
    }

    private func setHovered(_ id: String, _ inside: Bool) {
        withAnimation(.easeOut(duration: 0.12)) {
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
    }

    // MARK: - Small views

    private var syncButton: some View {
        Button { library.sync() } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
                .rotationEffect(.degrees(library.isSyncing ? 360 : 0))
                .animation(library.isSyncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                           value: library.isSyncing)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.secondary)
        .help(syncHelp)
        .disabled(library.isSyncing)
    }

    private var syncHelp: String {
        if library.isSyncing { return "Syncing with YouTube Music…" }
        if let error = library.error { return "Last sync failed: \(error)" }
        guard let date = library.lastSync else { return "Sync with YouTube Music" }
        return "Synced \(date.formatted(.relative(presentation: .named))). Click to sync now."
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

/// Compact search-style text field used for filtering.
private struct FilterField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(Ink.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

extension PlaylistTrack {
    /// The song that's playing, as a library entry.
    static func nowPlaying(_ state: PlayerState) -> PlaylistTrack {
        let seconds = Int(state.duration)
        return PlaylistTrack(videoId: state.videoId, setVideoId: nil, title: state.title, artist: state.artist,
                             length: seconds > 0 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : "",
                             thumb: state.artworkURL, type: "MUSIC_VIDEO_TYPE_ATV")
    }
}
