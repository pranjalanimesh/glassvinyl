import Foundation

struct PlaylistTrack: Codable, Equatable, Identifiable {
    let videoId: String
    var setVideoId: String?   // the entry's id inside the playlist; needed to remove it
    let title: String
    let artist: String
    let length: String
    let thumb: URL?
    let type: String?         // YouTube Music's musicVideoType; nil for a plain YouTube video

    var id: String { setVideoId ?? videoId }

    /// Songs and music videos; not plain YouTube videos or podcast episodes.
    var isMusic: Bool { type != nil && type != "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" }
}

struct LibraryPlaylist: Codable, Equatable, Identifiable {
    let id: String            // playlist id, e.g. "LM" for Liked Music
    var title: String
    var subtitle: String
    var thumb: URL?
    var tracks: [PlaylistTrack] = []
    var syncedAt: Date?

    static let likedId = "LM"
    var isLiked: Bool { id == Self.likedId }

    /// A YouTube Music playlist rather than a list of YouTube videos: at least half its
    /// tracks are songs or music videos. Unknown until its tracks have been synced.
    var isMusic: Bool {
        if isLiked { return true }
        guard syncedAt != nil, !tracks.isEmpty else { return false }
        return Double(tracks.filter(\.isMusic).count) / Double(tracks.count) >= 0.5
    }
}

/// A local copy of the YouTube Music library (playlists and Liked Music), saved to
/// ~/Library/Application Support/YTPlayer/library.json.
///
/// The UI reads from the copy, so it opens instantly and works while YouTube Music is
/// busy. `sync()` refreshes it from YouTube Music. Edits go to YouTube Music and the copy
/// together; if YouTube Music refuses one, the copy is put back.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var playlists: [LibraryPlaylist] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published var error: String?

    private let bridge: PlayerBridge
    private let fileURL: URL
    private var timer: Timer?

    /// Liked Music first, then the library's order; only playlists of music.
    var musicPlaylists: [LibraryPlaylist] { playlists.filter(\.isMusic) }

    init(bridge: PlayerBridge, directory: URL) {
        self.bridge = bridge
        fileURL = directory.appendingPathComponent("library.json")
        load()
        // First sync shortly after launch, then every 30 minutes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.sync() }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    func playlist(_ id: String) -> LibraryPlaylist? {
        playlists.first { $0.id == id }
    }

    func contains(_ videoId: String, in playlistId: String) -> Bool {
        playlist(playlistId)?.tracks.contains { $0.videoId == videoId } ?? false
    }

    // MARK: - Sync

    /// Refreshes the playlist list, then each playlist's tracks one at a time, saving as it goes.
    func sync() {
        guard !isSyncing else { return }
        isSyncing = true
        error = nil
        Task {
            do {
                struct Remote: Decodable { let id: String, title: String, subtitle: String, thumb: URL? }
                let remote: [Remote] = try await bridge.value { id in "__ytp.library(\(id))" }
                // Keep already-synced tracks until each playlist is refreshed below.
                playlists = remote.map { fresh in
                    var merged = playlist(fresh.id) ?? LibraryPlaylist(id: fresh.id, title: fresh.title, subtitle: fresh.subtitle)
                    merged.title = fresh.title
                    merged.subtitle = fresh.subtitle
                    merged.thumb = fresh.thumb
                    return merged
                }
                for list in remote {
                    let tracks: [PlaylistTrack] = try await bridge.value { id in
                        "__ytp.playlistTracks(\(id), \(PlayerBridge.literal(list.id)))"
                    }
                    update(list.id) {
                        $0.tracks = tracks
                        $0.syncedAt = Date()
                    }
                }
                lastSync = Date()
            } catch {
                self.error = error.localizedDescription
            }
            isSyncing = false
        }
    }

    // MARK: - Edits

    /// Adds a song to a playlist (or likes it, for Liked Music).
    func add(_ track: PlaylistTrack, to playlistId: String) async throws {
        guard !contains(track.videoId, in: playlistId) else { return }
        let before = playlists
        update(playlistId) { $0.tracks.insert(track, at: 0) }
        do {
            if playlistId == LibraryPlaylist.likedId {
                let _: Bool = try await bridge.value { id in
                    "__ytp.setLike(\(id), \(PlayerBridge.literal(track.videoId)), true)"
                }
            } else {
                let setIds: [String?] = try await bridge.value { id in
                    "__ytp.addToPlaylist(\(id), \(PlayerBridge.literal(playlistId)), [\(PlayerBridge.literal(track.videoId))])"
                }
                update(playlistId) { list in
                    if let i = list.tracks.firstIndex(where: { $0.videoId == track.videoId }) {
                        list.tracks[i].setVideoId = setIds.first ?? nil
                    }
                }
            }
        } catch {
            playlists = before
            save()
            throw error
        }
    }

    /// Removes a song from a playlist (or unlikes it, for Liked Music).
    func remove(_ track: PlaylistTrack, from playlistId: String) async throws {
        let before = playlists
        update(playlistId) { $0.tracks.removeAll { $0.id == track.id } }
        do {
            if playlistId == LibraryPlaylist.likedId {
                let _: Bool = try await bridge.value { id in
                    "__ytp.setLike(\(id), \(PlayerBridge.literal(track.videoId)), false)"
                }
            } else {
                guard let setVideoId = track.setVideoId else { throw PlayerBridge.BridgeError("Sync the library first") }
                let _: [String?] = try await bridge.value { id in
                    "__ytp.removeFromPlaylist(\(id), \(PlayerBridge.literal(playlistId)), \(PlayerBridge.literal(track.videoId)), \(PlayerBridge.literal(setVideoId)))"
                }
            }
        } catch {
            playlists = before
            save()
            throw error
        }
    }

    func createPlaylist(title: String) async throws {
        let id: String = try await bridge.value { callId in
            "__ytp.createPlaylist(\(callId), \(PlayerBridge.literal(title)))"
        }
        // New playlists hold no tracks yet, so they can't be classified; treat them as music.
        let created = LibraryPlaylist(id: id, title: title, subtitle: "0 songs", tracks: [], syncedAt: Date())
        playlists.insert(created, at: min(1, playlists.count))
        save()
    }

    /// Keeps Liked Music in step when a song is liked or unliked from the player card.
    func noteLike(_ track: PlaylistTrack, liked: Bool) {
        update(LibraryPlaylist.likedId) { list in
            list.tracks.removeAll { $0.videoId == track.videoId }
            if liked { list.tracks.insert(track, at: 0) }
        }
    }

    // MARK: - Storage

    private func update(_ playlistId: String, _ change: (inout LibraryPlaylist) -> Void) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        change(&playlists[i])
        save()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let saved = try? decoder.decode([LibraryPlaylist].self, from: data) {
            playlists = saved
            lastSync = saved.compactMap(\.syncedAt).max()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(playlists) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
